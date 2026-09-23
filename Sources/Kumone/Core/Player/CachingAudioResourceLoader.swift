import AVFoundation
import Foundation
import UniformTypeIdentifiers

enum CachingAudioResourceLoaderError: LocalizedError {
    case unsupportedResponse(URLResponse)
    case byteRangesUnavailable(URL)
    case unsupportedFileType(URL)
    case redirectUnavailable(URL)
    case fileExceedsCacheLimit(contentLength: Int64, maximumSizeMB: Int)
    case unexpectedContentRange(String?)
    case incompleteRange(expected: Int64, actual: Int64)

    var errorDescription: String? {
        switch self {
        case .unsupportedResponse:
            return "The audio source did not return an HTTP response."
        case .byteRangesUnavailable(let url):
            return "The audio source does not support byte ranges: \(url.host ?? url.absoluteString)"
        case .unsupportedFileType(let url):
            return "The audio source has no cacheable file type: \(url.absoluteString)"
        case .redirectUnavailable(let url):
            return "The audio source could not be redirected: \(url.absoluteString)"
        case .fileExceedsCacheLimit(let contentLength, let maximumSizeMB):
            return "The audio source is \(contentLength) bytes and exceeds the \(maximumSizeMB) MB cache limit."
        case .unexpectedContentRange(let value):
            return "The audio source returned an invalid Content-Range: \(value ?? "missing")"
        case .incompleteRange(let expected, let actual):
            return "The audio source ended a range early (expected \(expected), received \(actual))."
        }
    }
}

struct ByteRangePlanner {
    struct ScheduledRange: Equatable {
        let id: UUID
        let range: Range<Int64>
    }

    private var cachedRanges: [Range<Int64>] = []
    private var inFlightRanges: [UUID: Range<Int64>] = [:]

    mutating func scheduleMissingRanges(in requestedRange: Range<Int64>) -> [ScheduledRange] {
        let coveredRanges = mergedRanges(cachedRanges + Array(inFlightRanges.values))
        let missingRanges = subtract(coveredRanges, from: requestedRange)
        let scheduledRanges = missingRanges.map { ScheduledRange(id: UUID(), range: $0) }
        for scheduledRange in scheduledRanges {
            inFlightRanges[scheduledRange.id] = scheduledRange.range
        }
        return scheduledRanges
    }

    mutating func recordCached(_ range: Range<Int64>) {
        cachedRanges = mergedRanges(cachedRanges + [range])
    }

    mutating func finish(_ scheduledRangeID: UUID) {
        inFlightRanges.removeValue(forKey: scheduledRangeID)
    }

    func cachedRange(containing offset: Int64) -> Range<Int64>? {
        cachedRanges.first { $0.lowerBound <= offset && offset < $0.upperBound }
    }

    func isComplete(contentLength: Int64) -> Bool {
        cachedRanges.count == 1
            && cachedRanges[0].lowerBound == 0
            && cachedRanges[0].upperBound == contentLength
    }

    private func subtract(_ coveredRanges: [Range<Int64>], from requestedRange: Range<Int64>) -> [Range<Int64>] {
        var missingRanges: [Range<Int64>] = []
        var nextOffset = requestedRange.lowerBound

        for coveredRange in coveredRanges where nextOffset < requestedRange.upperBound {
            guard coveredRange.upperBound > nextOffset else { continue }
            if coveredRange.lowerBound > nextOffset {
                missingRanges.append(nextOffset..<min(coveredRange.lowerBound, requestedRange.upperBound))
            }
            nextOffset = max(nextOffset, coveredRange.upperBound)
        }

        if nextOffset < requestedRange.upperBound {
            missingRanges.append(nextOffset..<requestedRange.upperBound)
        }
        return missingRanges
    }

    private func mergedRanges(_ ranges: [Range<Int64>]) -> [Range<Int64>] {
        var mergedRanges: [Range<Int64>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) where !range.isEmpty {
            guard let lastRange = mergedRanges.last else {
                mergedRanges.append(range)
                continue
            }
            if range.lowerBound <= lastRange.upperBound {
                mergedRanges[mergedRanges.count - 1] = lastRange.lowerBound..<max(lastRange.upperBound, range.upperBound)
            } else {
                mergedRanges.append(range)
            }
        }
        return mergedRanges
    }
}

/// Bridges AVFoundation resource requests to HTTP byte-range requests while
/// writing the same bytes into one sparse temporary file. Once all byte ranges
/// are present, the file is atomically promoted by `AudioCache`.
final class CachingAudioResourceLoader: NSObject {
    let assetURL: URL

    private let remoteURL: URL
    private let trackID: Int
    private let requestedQuality: String
    private let servedQuality: String?
    private let source: AudioCacheSource
    private let maximumCacheSizeMB: Int
    private let cache: AudioCache
    private let delegateQueue: OperationQueue
    private let resourceLoaderQueue: DispatchQueue
    private var session: URLSession!
    private var expectedContentLength: Int64?
    private var contentType: String?
    private var resourceContentType: String?
    private var writeSession: AudioCacheWriteSession?
    private var fileHandle: FileHandle?
    private var pendingRequests: [ObjectIdentifier: PendingRequest] = [:]
    private var pendingTasks: [Int: NetworkTask] = [:]
    private var rangePlanner = ByteRangePlanner()
    private var cacheCommitStarted = false
    private var cacheLeaseID: UUID?
    private var cachingDisabled = false
    private var fileHandleClosed = false
    private var redirectsToRemoteAsset = false
    private var cancelled = false

    private final class PendingRequest {
        let loadingRequest: AVAssetResourceLoadingRequest
        let requestedOffset: Int64
        let requestedLength: Int64
        let requestsAllDataToEnd: Bool
        var range: Range<Int64>?
        var deliveredOffset: Int64
        var directTaskIdentifier: Int?

        init(loadingRequest: AVAssetResourceLoadingRequest) {
            self.loadingRequest = loadingRequest
            if let dataRequest = loadingRequest.dataRequest {
                requestedOffset = dataRequest.requestedOffset
                requestedLength = Int64(dataRequest.requestedLength)
                requestsAllDataToEnd = dataRequest.requestsAllDataToEndOfResource
            } else {
                requestedOffset = 0
                requestedLength = 2
                requestsAllDataToEnd = false
            }
            deliveredOffset = requestedOffset
        }

        func resolveRange(contentLength: Int64) -> Bool {
            guard requestedOffset >= 0, requestedOffset < contentLength else { return false }
            let upperBound: Int64
            if requestsAllDataToEnd {
                upperBound = contentLength
            } else {
                guard requestedLength > 0,
                      requestedLength <= contentLength - requestedOffset else { return false }
                upperBound = requestedOffset + requestedLength
            }
            range = requestedOffset..<upperBound
            return true
        }
    }

    private final class NetworkTask {
        let requestedOffset: Int64
        let requestedUpperBound: Int64?
        var range: Range<Int64>?
        var scheduledRangeID: UUID?
        var directPendingRequestID: ObjectIdentifier?
        let initializesResource: Bool
        var responseStart: Int64?
        var receivedByteCount: Int64 = 0
        var task: URLSessionDataTask?

        init(
            range: Range<Int64>,
            scheduledRangeID: UUID? = nil,
            directPendingRequestID: ObjectIdentifier? = nil
        ) {
            requestedOffset = range.lowerBound
            requestedUpperBound = range.upperBound
            self.range = range
            self.scheduledRangeID = scheduledRangeID
            self.directPendingRequestID = directPendingRequestID
            initializesResource = false
        }

        init(initializing pending: PendingRequest, pendingRequestID: ObjectIdentifier) {
            requestedOffset = pending.requestedOffset
            requestedUpperBound = pending.requestsAllDataToEnd
                ? nil
                : pending.requestedOffset + pending.requestedLength
            range = nil
            scheduledRangeID = nil
            directPendingRequestID = pendingRequestID
            initializesResource = true
        }
    }

    init(
        remoteURL: URL,
        trackID: Int,
        requestedQuality: String,
        servedQuality: String?,
        source: AudioCacheSource,
        maximumCacheSizeMB: Int,
        cache: AudioCache = .shared
    ) throws {
        self.remoteURL = remoteURL
        self.trackID = trackID
        self.requestedQuality = requestedQuality
        self.servedQuality = servedQuality
        self.source = source
        self.maximumCacheSizeMB = maximumCacheSizeMB
        self.cache = cache

        var components = URLComponents(url: remoteURL, resolvingAgainstBaseURL: false)
        components?.scheme = "kumone-cache"
        guard let assetURL = components?.url else {
            throw CachingAudioResourceLoaderError.unsupportedFileType(remoteURL)
        }
        self.assetURL = assetURL

        let delegateQueue = OperationQueue()
        delegateQueue.name = "im.missuo.Kumone.CachingAudioResourceLoader"
        delegateQueue.maxConcurrentOperationCount = 1
        self.delegateQueue = delegateQueue
        resourceLoaderQueue = DispatchQueue(label: "im.missuo.Kumone.CachingAudioResourceLoader.Asset")

        super.init()

        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }

    deinit {
        session.invalidateAndCancel()
        if !fileHandleClosed, let fileHandle {
            do {
                try fileHandle.close()
            } catch {
                print("Audio cache could not close its temporary file: \(error)")
            }
        }
        releaseCacheLease()
        guard !cacheCommitStarted, !cachingDisabled, let writeSession else { return }
        let cache = cache
        Task {
            do {
                try await cache.discard(writeSession)
            } catch {
                print("Audio cache could not discard its temporary file: \(error)")
            }
        }
    }

    func attach(to asset: AVURLAsset) {
        asset.resourceLoader.setDelegate(self, queue: resourceLoaderQueue)
    }

    func cancel() {
        delegateQueue.addOperation { [weak self] in
            self?.cancelOnDelegateQueue()
        }
    }

    private func cancelOnDelegateQueue() {
        guard !cancelled else { return }
        cancelled = true
        let cancellationError = CancellationError()
        for pending in pendingRequests.values {
            pending.loadingRequest.finishLoading(with: cancellationError)
        }
        pendingRequests.removeAll()
        cancelNetworkTasks()
        session.invalidateAndCancel()
        closeFileHandle()
        releaseCacheLease()
        guard !cacheCommitStarted, !cachingDisabled, let writeSession else { return }
        self.writeSession = nil
        let cache = cache
        Task {
            do {
                try await cache.discard(writeSession)
            } catch {
                print("Audio cache could not discard a cancelled write: \(error)")
            }
        }
    }

    private func startLoading(_ loadingRequest: AVAssetResourceLoadingRequest) {
        guard !cancelled else {
            loadingRequest.finishLoading(with: CancellationError())
            return
        }
        if redirectsToRemoteAsset {
            redirectToRemoteAsset(loadingRequest)
            return
        }
        let pending = PendingRequest(loadingRequest: loadingRequest)
        let pendingRequestID = ObjectIdentifier(loadingRequest)
        pendingRequests[pendingRequestID] = pending
        guard let expectedContentLength else {
            if !pendingTasks.values.contains(where: \.initializesResource) {
                startInitializationNetworkRequest(for: pending, id: pendingRequestID)
            }
            return
        }
        guard pending.resolveRange(contentLength: expectedContentLength) else {
            fail(pending, with: CachingAudioResourceLoaderError.unexpectedContentRange(nil))
            return
        }
        fillContentInformation(loadingRequest.contentInformationRequest)
        guard loadingRequest.dataRequest != nil, let range = pending.range else {
            finish(pending)
            return
        }
        if cachingDisabled {
            startDirectNetworkRequest(for: pending, id: pendingRequestID)
        } else {
            respondWithCachedData(to: pending)
            guard pendingRequests[pendingRequestID] != nil else { return }
            startMissingNetworkRequests(in: range)
        }
    }

    private func fillContentInformation(_ request: AVAssetResourceLoadingContentInformationRequest?) {
        guard let expectedContentLength else { return }
        request?.contentType = resourceContentType
        request?.contentLength = expectedContentLength
        request?.isByteRangeAccessSupported = true
    }

    private func startInitializationNetworkRequest(for pending: PendingRequest, id: ObjectIdentifier) {
        guard pending.requestedOffset >= 0,
              pending.requestsAllDataToEnd || pending.requestedLength > 0 else {
            fail(pending, with: CachingAudioResourceLoaderError.unexpectedContentRange(nil))
            return
        }
        var request = URLRequest(url: remoteURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let rangeValue: String
        if pending.requestsAllDataToEnd {
            rangeValue = "bytes=\(pending.requestedOffset)-"
        } else {
            let (upperBound, overflow) = pending.requestedOffset.addingReportingOverflow(
                pending.requestedLength - 1
            )
            guard !overflow else {
                fail(pending, with: CachingAudioResourceLoaderError.unexpectedContentRange(nil))
                return
            }
            rangeValue = "bytes=\(pending.requestedOffset)-\(upperBound)"
        }
        request.setValue(rangeValue, forHTTPHeaderField: "Range")
        let task = session.dataTask(with: request)
        let networkTask = NetworkTask(initializing: pending, pendingRequestID: id)
        networkTask.task = task
        pending.directTaskIdentifier = task.taskIdentifier
        pendingTasks[task.taskIdentifier] = networkTask
        task.resume()
    }

    private func startMissingNetworkRequests(in range: Range<Int64>) {
        for scheduledRange in rangePlanner.scheduleMissingRanges(in: range) {
            startNetworkRequest(for: scheduledRange)
        }
    }

    private func startNetworkRequest(for scheduledRange: ByteRangePlanner.ScheduledRange) {
        var request = URLRequest(url: remoteURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(
            "bytes=\(scheduledRange.range.lowerBound)-\(scheduledRange.range.upperBound - 1)",
            forHTTPHeaderField: "Range"
        )
        let task = session.dataTask(with: request)
        let networkTask = NetworkTask(range: scheduledRange.range, scheduledRangeID: scheduledRange.id)
        networkTask.task = task
        pendingTasks[task.taskIdentifier] = networkTask
        task.resume()
    }

    private func startDirectNetworkRequest(for pending: PendingRequest, id: ObjectIdentifier) {
        guard let pendingRange = pending.range,
              pending.deliveredOffset < pendingRange.upperBound else { return }
        let range = pending.deliveredOffset..<pendingRange.upperBound
        var request = URLRequest(url: remoteURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        let task = session.dataTask(with: request)
        let networkTask = NetworkTask(range: range, directPendingRequestID: id)
        networkTask.task = task
        pending.directTaskIdentifier = task.taskIdentifier
        pendingTasks[task.taskIdentifier] = networkTask
        task.resume()
    }

    private func respondWithCachedData(to pending: PendingRequest) {
        guard let range = pending.range, let writeSession else { return }
        do {
            let fileURL = FileManager.default.fileExists(atPath: writeSession.finalFileURL.path)
                ? writeSession.finalFileURL
                : writeSession.partialFileURL
            let reader = try FileHandle(forReadingFrom: fileURL)
            defer {
                do {
                    try reader.close()
                } catch {
                    print("Audio cache could not close its reader: \(error)")
                }
            }
            while pending.deliveredOffset < range.upperBound,
                  let cachedRange = rangePlanner.cachedRange(containing: pending.deliveredOffset) {
                let endOffset = min(cachedRange.upperBound, range.upperBound)
                let byteCount = Int(endOffset - pending.deliveredOffset)
                try reader.seek(toOffset: UInt64(pending.deliveredOffset))
                let data = try reader.read(upToCount: byteCount)
                guard let data, data.count == byteCount else {
                    throw CachingAudioResourceLoaderError.incompleteRange(
                        expected: Int64(byteCount), actual: Int64(data?.count ?? 0)
                    )
                }
                pending.loadingRequest.dataRequest?.respond(with: data)
                pending.deliveredOffset = endOffset
            }
            if pending.deliveredOffset == range.upperBound {
                finish(pending)
            }
        } catch {
            fail(pending, with: error)
        }
    }

    private func respondWithCachedDataToPendingRequests() {
        for pending in Array(pendingRequests.values) {
            respondWithCachedData(to: pending)
        }
    }

    private func receiveResponse(
        _ response: URLResponse,
        for networkTask: NetworkTask,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        if networkTask.initializesResource {
            initializeResource(from: response, for: networkTask, completionHandler: completionHandler)
            return
        }
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 206 else {
            failRequests(for: networkTask, with: CachingAudioResourceLoaderError.byteRangesUnavailable(remoteURL))
            completionHandler(.cancel)
            return
        }
        guard let range = networkTask.range,
              let expectedContentLength,
              let contentRange = httpResponse.value(forHTTPHeaderField: "Content-Range"),
              let parsedRange = Self.parseContentRange(contentRange),
              parsedRange.lowerBound == range.lowerBound,
              parsedRange.upperBound == range.upperBound,
              parsedRange.totalLength == expectedContentLength else {
            failRequests(for: networkTask, with: CachingAudioResourceLoaderError.unexpectedContentRange(
                httpResponse.value(forHTTPHeaderField: "Content-Range")
            ))
            completionHandler(.cancel)
            return
        }
        networkTask.responseStart = parsedRange.lowerBound
        completionHandler(.allow)
    }

    private func initializeResource(
        from response: URLResponse,
        for networkTask: NetworkTask,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let httpResponse = response as? HTTPURLResponse else {
            redirectToRemoteAsset(
                after: CachingAudioResourceLoaderError.unsupportedResponse(response),
                completionHandler: completionHandler
            )
            return
        }
        guard httpResponse.statusCode == 206 else {
            redirectToRemoteAsset(
                after: CachingAudioResourceLoaderError.byteRangesUnavailable(remoteURL),
                completionHandler: completionHandler
            )
            return
        }
        let contentRangeValue = httpResponse.value(forHTTPHeaderField: "Content-Range")
        guard let contentRangeValue,
              let parsedRange = Self.parseContentRange(contentRangeValue),
              parsedRange.lowerBound == networkTask.requestedOffset else {
            redirectToRemoteAsset(
                after: CachingAudioResourceLoaderError.unexpectedContentRange(contentRangeValue),
                completionHandler: completionHandler
            )
            return
        }
        let expectedUpperBound = networkTask.requestedUpperBound.map {
            min($0, parsedRange.totalLength)
        } ?? parsedRange.totalLength
        guard parsedRange.upperBound == expectedUpperBound else {
            redirectToRemoteAsset(
                after: CachingAudioResourceLoaderError.unexpectedContentRange(contentRangeValue),
                completionHandler: completionHandler
            )
            return
        }

        let responseContentType = httpResponse.mimeType
            ?? httpResponse.value(forHTTPHeaderField: "Content-Type")
        guard let fileExtension = Self.fileExtension(
            for: remoteURL,
            contentType: responseContentType
        ), let resourceContentType = Self.resourceContentType(for: fileExtension) else {
            redirectToRemoteAsset(
                after: CachingAudioResourceLoaderError.unsupportedFileType(remoteURL),
                completionHandler: completionHandler
            )
            return
        }

        networkTask.range = parsedRange.lowerBound..<parsedRange.upperBound
        networkTask.responseStart = parsedRange.lowerBound
        guard Self.canCache(
            contentLength: parsedRange.totalLength,
            maximumSizeMB: maximumCacheSizeMB
        ) else {
            print(CachingAudioResourceLoaderError.fileExceedsCacheLimit(
                contentLength: parsedRange.totalLength,
                maximumSizeMB: maximumCacheSizeMB
            ).localizedDescription)
            beginRangeStreaming(
                contentLength: parsedRange.totalLength,
                contentType: responseContentType,
                resourceContentType: resourceContentType,
                networkTask: networkTask,
                completionHandler: completionHandler
            )
            return
        }

        let cache = cache
        let trackID = trackID
        let requestedQuality = requestedQuality
        let servedQuality = servedQuality
        let source = source
        let maximumCacheSizeMB = maximumCacheSizeMB
        let delegateQueue = delegateQueue
        guard let taskIdentifier = networkTask.task?.taskIdentifier else {
            redirectToRemoteAsset(
                after: CachingAudioResourceLoaderError.unexpectedContentRange(nil),
                completionHandler: completionHandler
            )
            return
        }
        Task {
            do {
                let writeSession = try await cache.beginWrite(
                    trackID: trackID,
                    requestedQuality: requestedQuality,
                    servedQuality: servedQuality,
                    source: source,
                    fileExtension: fileExtension,
                    maximumSizeMB: maximumCacheSizeMB
                )
                let fileHandle: FileHandle
                do {
                    fileHandle = try FileHandle(forUpdating: writeSession.partialFileURL)
                } catch {
                    try await cache.discard(writeSession)
                    throw error
                }
                delegateQueue.addOperation { [weak self] in
                    guard let self,
                          !self.cancelled,
                          let networkTask = self.pendingTasks[taskIdentifier] else {
                        do {
                            try fileHandle.close()
                        } catch {
                            print("Audio cache could not close an unused temporary file: \(error)")
                        }
                        Task {
                            do {
                                try await cache.discard(writeSession)
                            } catch {
                                print("Audio cache could not discard an unused write session: \(error)")
                            }
                        }
                        completionHandler(.cancel)
                        return
                    }
                    self.beginCaching(
                        contentLength: parsedRange.totalLength,
                        contentType: responseContentType,
                        resourceContentType: resourceContentType,
                        writeSession: writeSession,
                        fileHandle: fileHandle,
                        networkTask: networkTask,
                        completionHandler: completionHandler
                    )
                }
            } catch {
                let failureDescription = String(describing: error)
                delegateQueue.addOperation { [weak self] in
                    guard let self,
                          !self.cancelled,
                          let networkTask = self.pendingTasks[taskIdentifier] else {
                        completionHandler(.cancel)
                        return
                    }
                    print("Audio cache write disabled for this track: \(failureDescription)")
                    self.beginRangeStreaming(
                        contentLength: parsedRange.totalLength,
                        contentType: responseContentType,
                        resourceContentType: resourceContentType,
                        networkTask: networkTask,
                        completionHandler: completionHandler
                    )
                }
            }
        }
    }

    private func beginCaching(
        contentLength: Int64,
        contentType: String?,
        resourceContentType: String,
        writeSession: AudioCacheWriteSession,
        fileHandle: FileHandle,
        networkTask: NetworkTask,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        expectedContentLength = contentLength
        self.contentType = contentType
        self.resourceContentType = resourceContentType
        self.writeSession = writeSession
        self.fileHandle = fileHandle
        guard let range = networkTask.range,
              let scheduledRange = rangePlanner.scheduleMissingRanges(in: range).first else {
            redirectToRemoteAsset(
                after: CachingAudioResourceLoaderError.unexpectedContentRange(nil),
                completionHandler: completionHandler
            )
            return
        }
        networkTask.scheduledRangeID = scheduledRange.id
        if let pendingRequestID = networkTask.directPendingRequestID {
            pendingRequests[pendingRequestID]?.directTaskIdentifier = nil
        }
        networkTask.directPendingRequestID = nil
        resolvePendingRequests(excluding: nil)
        completionHandler(.allow)
    }

    private func beginRangeStreaming(
        contentLength: Int64,
        contentType: String?,
        resourceContentType: String,
        networkTask: NetworkTask,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        expectedContentLength = contentLength
        self.contentType = contentType
        self.resourceContentType = resourceContentType
        cachingDisabled = true
        resolvePendingRequests(excluding: networkTask.directPendingRequestID)
        completionHandler(.allow)
    }

    private func resolvePendingRequests(excluding directRequestID: ObjectIdentifier?) {
        guard let expectedContentLength else { return }
        for (pendingRequestID, pending) in Array(pendingRequests) {
            guard pending.resolveRange(contentLength: expectedContentLength) else {
                fail(pending, with: CachingAudioResourceLoaderError.unexpectedContentRange(nil))
                continue
            }
            fillContentInformation(pending.loadingRequest.contentInformationRequest)
            guard pending.loadingRequest.dataRequest != nil, let range = pending.range else {
                finish(pending)
                continue
            }
            if cachingDisabled {
                if pendingRequestID != directRequestID {
                    startDirectNetworkRequest(for: pending, id: pendingRequestID)
                }
            } else {
                respondWithCachedData(to: pending)
                if pendingRequests[pendingRequestID] != nil {
                    startMissingNetworkRequests(in: range)
                }
            }
        }
    }

    private func redirectToRemoteAsset(
        after error: Error,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard !cancelled else {
            completionHandler(.cancel)
            return
        }
        redirectsToRemoteAsset = true
        print("Audio cache bypassed for this track: \(error.localizedDescription)")
        let loadingRequests = pendingRequests.values.map(\.loadingRequest)
        pendingRequests.removeAll()
        cancelNetworkTasks()
        session.invalidateAndCancel()
        closeFileHandle()
        completionHandler(.cancel)
        for loadingRequest in loadingRequests {
            redirectToRemoteAsset(loadingRequest)
        }
        if !cacheCommitStarted, let writeSession {
            self.writeSession = nil
            let cache = cache
            Task {
                do {
                    try await cache.discard(writeSession)
                } catch {
                    print("Audio cache could not discard a bypassed write: \(error)")
                }
            }
        }
    }

    private func redirectToRemoteAsset(_ loadingRequest: AVAssetResourceLoadingRequest) {
        let redirectRequest = URLRequest(url: remoteURL)
        guard let redirectResponse = HTTPURLResponse(
            url: loadingRequest.request.url ?? assetURL,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": remoteURL.absoluteString]
        ) else {
            loadingRequest.finishLoading(
                with: CachingAudioResourceLoaderError.redirectUnavailable(remoteURL)
            )
            return
        }
        loadingRequest.redirect = redirectRequest
        loadingRequest.response = redirectResponse
        loadingRequest.finishLoading()
    }

    private func receive(_ data: Data, for networkTask: NetworkTask) {
        guard let responseStart = networkTask.responseStart,
              let range = networkTask.range else {
            failRequests(for: networkTask, with: CachingAudioResourceLoaderError.unexpectedContentRange(nil))
            return
        }
        let dataStart = responseStart + networkTask.receivedByteCount
        let dataEnd = dataStart + Int64(data.count)
        guard dataStart >= range.lowerBound, dataEnd <= range.upperBound else {
            failRequests(for: networkTask, with: CachingAudioResourceLoaderError.unexpectedContentRange(nil))
            return
        }

        networkTask.receivedByteCount += Int64(data.count)
        if let directPendingRequestID = networkTask.directPendingRequestID {
            receiveDirect(
                data,
                startingAt: dataStart,
                from: networkTask,
                for: directPendingRequestID
            )
            return
        }

        if !cachingDisabled {
            guard let fileHandle else {
                switchToDirectStreaming(after: "Audio cache temporary file is unavailable.")
                return
            }
            do {
                try fileHandle.seek(toOffset: UInt64(dataStart))
                try fileHandle.write(contentsOf: data)
                rangePlanner.recordCached(dataStart..<dataEnd)
            } catch {
                switchToDirectStreaming(after: String(describing: error))
                return
            }
        }
        respondWithCachedDataToPendingRequests()
    }

    private func receiveDirect(
        _ data: Data,
        startingAt dataStart: Int64,
        from networkTask: NetworkTask,
        for pendingRequestID: ObjectIdentifier
    ) {
        guard let pending = pendingRequests[pendingRequestID],
              let range = pending.range else { return }
        guard dataStart == pending.deliveredOffset,
              pending.deliveredOffset + Int64(data.count) <= range.upperBound else {
            fail(pending, with: CachingAudioResourceLoaderError.unexpectedContentRange(nil))
            return
        }
        pending.loadingRequest.dataRequest?.respond(with: data)
        pending.deliveredOffset += Int64(data.count)
        if pending.deliveredOffset == range.upperBound {
            finish(pending)
        }
    }

    private func complete(_ networkTask: NetworkTask, error: Error?) {
        if let taskID = networkTask.task?.taskIdentifier {
            pendingTasks.removeValue(forKey: taskID)
        }
        if let scheduledRangeID = networkTask.scheduledRangeID {
            rangePlanner.finish(scheduledRangeID)
        }

        guard let range = networkTask.range else {
            if let error, (error as? URLError)?.code != .cancelled {
                failRequests(for: networkTask, with: error)
            }
            return
        }
        if let error {
            if (error as? URLError)?.code == .cancelled,
               networkTask.receivedByteCount == Int64(range.count) {
                finishCacheIfReady()
                return
            }
            failRequests(for: networkTask, with: error)
            return
        }
        guard networkTask.receivedByteCount == Int64(range.count) else {
            failRequests(for: networkTask, with: CachingAudioResourceLoaderError.incompleteRange(
                expected: Int64(range.count), actual: networkTask.receivedByteCount
            ))
            return
        }
        if networkTask.directPendingRequestID == nil {
            respondWithCachedDataToPendingRequests()
        }
        finishCacheIfReady()
    }

    private func finish(_ pending: PendingRequest) {
        pendingRequests.removeValue(forKey: ObjectIdentifier(pending.loadingRequest))
        pending.loadingRequest.finishLoading()
    }

    private func fail(_ pending: PendingRequest, with error: Error) {
        pendingRequests.removeValue(forKey: ObjectIdentifier(pending.loadingRequest))
        if let taskID = pending.directTaskIdentifier,
           let networkTask = pendingTasks.removeValue(forKey: taskID) {
            networkTask.task?.cancel()
        }
        pending.loadingRequest.finishLoading(with: error)
        finishCacheIfReady()
    }

    private func failRequests(for networkTask: NetworkTask, with error: Error) {
        networkTask.task?.cancel()
        if let pendingRequestID = networkTask.directPendingRequestID {
            if let pending = pendingRequests[pendingRequestID] {
                fail(pending, with: error)
            }
            return
        }

        guard let networkRange = networkTask.range else { return }
        for pending in Array(pendingRequests.values) {
            guard let pendingRange = pending.range,
                  pendingRange.overlaps(networkRange),
                  pending.deliveredOffset < networkRange.upperBound else { continue }
            fail(pending, with: error)
        }
    }

    private func cancelNetworkTasks() {
        for networkTask in pendingTasks.values {
            networkTask.task?.cancel()
            if let scheduledRangeID = networkTask.scheduledRangeID {
                rangePlanner.finish(scheduledRangeID)
            }
        }
        pendingTasks.removeAll()
    }

    private func finishCacheIfReady() {
        guard !cachingDisabled,
              !cacheCommitStarted,
              pendingTasks.isEmpty,
              let expectedContentLength,
              let writeSession,
              rangePlanner.isComplete(contentLength: expectedContentLength) else { return }
        cacheCommitStarted = true
        closeFileHandle()
        let cache = cache
        let contentType = contentType
        let delegateQueue = delegateQueue
        Task {
            do {
                switch try await cache.commitAndRetain(
                    writeSession,
                    byteCount: expectedContentLength,
                    contentType: contentType
                ) {
                case .retained(_, let leaseID):
                    delegateQueue.addOperation { [weak self] in
                        guard let self, !self.cancelled else {
                            Task {
                                do {
                                    try await cache.release(leaseID)
                                } catch {
                                    print("Audio cache could not release a cancelled cache lease: \(error)")
                                }
                            }
                            return
                        }
                        self.cacheLeaseID = leaseID
                    }
                case .deferredDiscard, .rejectedForCurrentLimit:
                    delegateQueue.addOperation { [weak self] in
                        guard let self else {
                            Task {
                                do {
                                    try await cache.discard(writeSession)
                                } catch {
                                    print("Audio cache could not discard a non-persistent write: \(error)")
                                }
                            }
                            return
                        }
                        self.switchToDirectStreaming()
                    }
                }
            } catch {
                let failureDescription = String(describing: error)
                delegateQueue.addOperation { [weak self] in
                    guard let self else {
                        Task {
                            do {
                                try await cache.discard(writeSession)
                            } catch {
                                print("Audio cache could not discard a failed completed track: \(error)")
                            }
                        }
                        return
                    }
                    self.switchToDirectStreaming(after: failureDescription)
                }
            }
        }
    }

    private func closeFileHandle() {
        guard !fileHandleClosed else { return }
        fileHandleClosed = true
        guard let fileHandle else { return }
        do {
            try fileHandle.close()
        } catch {
            print("Audio cache could not close its temporary file: \(error)")
        }
    }

    private func switchToDirectStreaming(after failureDescription: String? = nil) {
        guard !cachingDisabled else { return }
        cachingDisabled = true
        if let failureDescription {
            print("Audio cache write disabled for this track: \(failureDescription)")
        }
        closeFileHandle()
        let pendingRequestIDs = Array(pendingRequests.keys)
        cancelNetworkTasks()
        for pendingRequestID in pendingRequestIDs {
            guard let pending = pendingRequests[pendingRequestID] else { continue }
            startDirectNetworkRequest(for: pending, id: pendingRequestID)
        }
        let cache = cache
        guard let writeSession else { return }
        Task {
            do {
                try await cache.discard(writeSession)
            } catch {
                print("Audio cache could not discard a failed write: \(error)")
            }
        }
    }

    private func releaseCacheLease() {
        guard let cacheLeaseID else { return }
        self.cacheLeaseID = nil
        let cache = cache
        Task {
            do {
                try await cache.release(cacheLeaseID)
            } catch {
                print("Audio cache could not release its resource-loader lease: \(error)")
            }
        }
    }

    private static func parseContentRange(_ value: String) -> (lowerBound: Int64, upperBound: Int64, totalLength: Int64)? {
        let parts = value.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bytes" else { return nil }
        let rangeAndLength = parts[1].split(separator: "/", maxSplits: 1)
        guard rangeAndLength.count == 2,
              let totalLength = Int64(rangeAndLength[1]),
              totalLength > 0 else { return nil }
        let bounds = rangeAndLength[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2,
              let lowerBound = Int64(bounds[0]),
              let inclusiveUpperBound = Int64(bounds[1]),
              lowerBound >= 0,
              inclusiveUpperBound >= lowerBound else { return nil }
        return (lowerBound, inclusiveUpperBound + 1, totalLength)
    }

    static func fileExtension(for url: URL, contentType: String?) -> String? {
        let pathExtension = url.pathExtension.lowercased()
        if !pathExtension.isEmpty,
           pathExtension.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }),
           pathExtension.count <= 10 {
            return pathExtension
        }

        let normalizedContentType = contentType?.split(separator: ";", maxSplits: 1)
            .first?.lowercased()
        switch normalizedContentType {
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/mp4", "audio/x-m4a": return "m4a"
        case "audio/aac": return "aac"
        case "audio/flac", "audio/x-flac": return "flac"
        case "audio/ogg": return "ogg"
        default: return nil
        }
    }

    static func resourceContentType(for fileExtension: String) -> String? {
        guard let type = UTType(filenameExtension: fileExtension),
              !type.isDynamic,
              type.conforms(to: .audio) else { return nil }
        return type.identifier
    }

    static func canCache(contentLength: Int64, maximumSizeMB: Int) -> Bool {
        contentLength > 0 && contentLength <= Int64(max(maximumSizeMB, 0)) * 1_000_000
    }
}

extension CachingAudioResourceLoader: AVAssetResourceLoaderDelegate {
    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        delegateQueue.addOperation { [weak self] in
            self?.startLoading(loadingRequest)
        }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        delegateQueue.addOperation { [weak self] in
            guard let self,
                  let pending = self.pendingRequests[ObjectIdentifier(loadingRequest)] else { return }
            self.pendingRequests.removeValue(forKey: ObjectIdentifier(loadingRequest))
            if let taskID = pending.directTaskIdentifier,
               let networkTask = self.pendingTasks.removeValue(forKey: taskID) {
                networkTask.task?.cancel()
            }
            if self.pendingRequests.isEmpty {
                self.cancelNetworkTasks()
            }
            self.finishCacheIfReady()
        }
    }
}

extension CachingAudioResourceLoader: URLSessionDataDelegate {
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let networkTask = pendingTasks[dataTask.taskIdentifier] else {
            completionHandler(.cancel)
            return
        }
        receiveResponse(response, for: networkTask, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let networkTask = pendingTasks[dataTask.taskIdentifier] else { return }
        receive(data, for: networkTask)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let networkTask = pendingTasks[task.taskIdentifier] else { return }
        complete(networkTask, error: error)
    }
}
