import Foundation

/// One coordinator owns one resource. All AVFoundation range consumers share
/// its transfer; OfflineStore rejects a second concurrent writer for that asset.
/// Playback and current-track completion read from the same byte ranges.
actor AudioTransferCoordinator {
    nonisolated let resource: OfflineAudioResource
    private let store: OfflineStore
    private let session: URLSession
    private let writer = UUID()
    private var started = false
    private var preparation: Task<Void, Error>?
    private let cacheContext: MusicCacheContext?
    private var closed = false
    private var active: Task<Void, Error>?
    private var activeIsCompletion = false
    private var completionAllowed = true
    private var failure: Error?
    private var etag: String?
    private var progressVersion = 0
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private(set) var receivedByteCount: Int64 = 0

    init(resource: OfflineAudioResource, store: OfflineStore, session: URLSession = .shared, cacheContext: MusicCacheContext? = nil) {
        self.resource = resource
        self.store = store
        self.session = session
        self.cacheContext = cacheContext
    }

    func prepare() async throws {
        guard !closed else { throw CancellationError() }
        if started { return }
        if preparation == nil {
            preparation = Task { [store, resource, writer, cacheContext] in
                try Task.checkCancellation()
                if let cacheContext {
                    try await store.beginCaching(resource.descriptor, writer: writer, context: cacheContext)
                    try await store.protectPlaybackRead(id: resource.descriptor.identity.id, token: writer)
                }
                else { try await store.begin(resource.descriptor, writer: writer) }
            }
        }
        try await preparation?.value
        guard !closed else {
            await store.releaseWriter(id: resource.descriptor.identity.id, writer: writer)
            throw CancellationError()
        }
        started = true
    }

    func setCompletionAllowed(_ allowed: Bool) {
        completionAllowed = allowed
        if !allowed, activeIsCompletion { active?.cancel() }
        wakeWaiters()
    }

    nonisolated static func isConnectivityFailure(_ error: Error) -> Bool {
        var value = error as NSError
        for _ in 0..<4 {
            if value.domain == NSURLErrorDomain,
               [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut,
                NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed,
                NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff].contains(value.code) { return true }
            guard let underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            value = underlying
        }
        return false
    }

    /// Returns a contiguous available prefix, never sparse/unreceived bytes.
    func read(at offset: Int64, maximum: Int, forCompletion: Bool = false) async throws -> Data {
        try Task.checkCancellation()
        guard !closed, offset >= 0, offset < resource.descriptor.byteCount, maximum > 0 else {
            throw OfflineAudioError.unavailable
        }
        try await prepare()
        let maximum = min(maximum, 256 * 1024, Int(resource.descriptor.byteCount - offset))
        while true {
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            if forCompletion, !completionAllowed { throw CancellationError() }
            let observedVersion = progressVersion
            if let data = try await store.read(id: resource.descriptor.identity.id, at: offset, maximum: maximum) {
                guard !closed else { throw CancellationError() }
                return data
            }
            if progressVersion != observedVersion { continue }
            if let failure { throw failure }
            // Check again after the actor hop; close or another request may
            // have changed ownership while the store was reading.
            guard !closed else { throw CancellationError() }
            if active == nil {
                let record = try await store.record(id: resource.descriptor.identity.id)
                guard !closed else { throw CancellationError() }
                if progressVersion != observedVersion || active != nil { continue }
                let nextReceivedOffset = record?.ranges.ranges.first(where: { $0.lowerBound > offset })?.lowerBound
                    ?? resource.descriptor.byteCount
                let end = min(nextReceivedOffset, offset + 256 * 1024)
                activeIsCompletion = forCompletion
                active = Task { try await self.fetch(offset..<end, forCompletion: forCompletion) }
            }
            try await waitForProgress()
        }
    }

    func download(forCompletion: Bool = false) async throws {
        var offset: Int64 = 0
        while offset < resource.descriptor.byteCount {
            offset += Int64(try await read(at: offset, maximum: 256 * 1024, forCompletion: forCompletion).count)
        }
        if let active { try await active.value }
        if let failure { throw failure }
        try await store.finalize(id: resource.descriptor.identity.id, writer: writer)
    }

    func close() async {
        closed = true
        preparation?.cancel()
        _ = try? await preparation?.value
        let task = active
        task?.cancel()
        wakeWaiters(error: CancellationError())
        // Release ownership only after the old task has stopped writing.
        _ = try? await task?.value
        await store.releaseWriter(id: resource.descriptor.identity.id, writer: writer)
        try? await store.releasePlaybackRead(token: writer)
    }

    private func fetch(_ range: Range<Int64>, forCompletion: Bool) async throws {
        do {
            var request = URLRequest(url: resource.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            if forCompletion {
                // Additional completion is Wi-Fi-only. Playback-driven reads
                // keep following the listener's ordinary streaming behavior.
                request.allowsExpensiveNetworkAccess = false
                request.allowsConstrainedNetworkAccess = false
                request.allowsCellularAccess = false
            }
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            if let etag { request.setValue(etag, forHTTPHeaderField: "If-Range") }
            let stream = AudioChunkStream(session: session, request: request)
            defer { stream.cancel() }
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                stream.task.resume()
                var info: AudioHTTPResponse?
                var offset: Int64 = 0
                var buffer = Data()
                buffer.reserveCapacity(64 * 1024)
                for try await event in stream.events {
                    try Task.checkCancellation()
                    switch event {
                    case .response(let response):
                        guard info == nil, let http = response as? HTTPURLResponse else { throw OfflineAudioError.invalidResponse }
                        let received = try AudioHTTPResponse(response: http, requested: range, descriptor: resource.descriptor, previousETag: etag)
                        info = received
                        etag = received.etag
                        offset = received.offset
                    case .data(let data):
                        guard let info, Int64(data.count) <= info.offset + info.length - offset - Int64(buffer.count) else {
                            throw OfflineAudioError.invalidResponse
                        }
                        var remaining = data.startIndex
                        while remaining < data.endIndex {
                            let end = min(data.endIndex, remaining + 64 * 1024 - buffer.count)
                            buffer.append(contentsOf: data[remaining..<end])
                            remaining = end
                            if buffer.count == 64 * 1024 {
                                try await append(buffer, at: offset)
                                offset += Int64(buffer.count)
                                buffer.removeAll(keepingCapacity: true)
                            }
                        }
                        stream.task.resume()
                    }
                }
                guard let info else { throw OfflineAudioError.invalidResponse }
                if !buffer.isEmpty {
                    try await append(buffer, at: offset)
                    offset += Int64(buffer.count)
                }
                guard offset == info.offset + info.length else { throw OfflineAudioError.incomplete }
            } onCancel: { stream.cancel() }
            if let record = try await store.record(id: resource.descriptor.identity.id), record.ranges.covers(record.descriptor.byteCount) {
                try await store.finalize(id: record.id, writer: writer)
            }
            active = nil
            wakeWaiters()
        } catch {
            active = nil
            // Only a policy change or close cancels this owned fetch task.
            // Eligibility may already be enabled again by the time its
            // cancellation arrives; that must not poison ordinary reads.
            if forCompletion, Task.isCancelled, !closed {
                wakeWaiters()
                return
            }
            // A failed network request ends that read, not the resource. Playback
            // can retry its missing range on the available connection; integrity
            // and storage failures still require abandoning this cached stream.
            if !Self.isConnectivityFailure(error) { failure = error }
            wakeWaiters(error: error)
            throw error
        }
    }

    private func append(_ data: Data, at offset: Int64) async throws {
        try Task.checkCancellation()
        try await store.write(data, at: offset, id: resource.descriptor.identity.id, writer: writer)
        receivedByteCount += Int64(data.count)
        wakeWaiters()
    }

    private func waitForProgress() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled || closed { continuation.resume(throwing: CancellationError()) }
                else { waiters[id] = continuation }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func wakeWaiters(error: Error? = nil) {
        progressVersion += 1
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending {
            if let error { waiter.resume(throwing: error) } else { waiter.resume() }
        }
    }
}
