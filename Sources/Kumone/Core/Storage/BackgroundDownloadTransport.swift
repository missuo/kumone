import Foundation

struct CompletedDownload: Codable {
    let token: String
    let statusCode: Int
    let mimeType: String?
    let fileName: String
}

enum DownloadFileProtection {
    static func prepareDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try protect(url)
    }
    static func protect(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
}

enum DownloadTransportEvent {
    case progress(token: String, received: Int64, expected: Int64)
    case waiting(token: String)
    case finished(CompletedDownload)
    case failed(token: String, domain: String, code: Int, resumeData: Data?)
    case backgroundEventsFinished
}

@MainActor
protocol DownloadTransport: AnyObject {
    var events: AsyncStream<DownloadTransportEvent> { get }
    var inbox: URL { get }
    /// Active task tokens and the bytes already written by URLSession.
    func restoreTasks() async -> [String: Int64]
    func completedDownloads() throws -> [CompletedDownload]
    func start(resource: OfflineAudioResource, token: String, allowsMetered: Bool, resumeData: Data?)
    func pause(token: String) async -> Data?
    func cancel(token: String)
    func acknowledge(_ receipt: CompletedDownload)
}

/// The delegate first moves system temporary files into a durable inbox. The
/// receipt lets the manager recover a completion even if the app dies before
/// importing the audio or saving its final job state.
final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let inbox: URL
    let continuation: AsyncStream<DownloadTransportEvent>.Continuation
    private var progressDates: [String: Date] = [:]

    init(inbox: URL, continuation: AsyncStream<DownloadTransportEvent>.Continuation) {
        self.inbox = inbox
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let token = downloadTask.taskDescription, Self.validToken(token) else { return }
        guard let response = downloadTask.response as? HTTPURLResponse else {
            continuation.yield(.failed(token: token, domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse, resumeData: nil))
            return
        }
        if let url = response.url { NeteaseCDNHost.markReachable(url) }
        do {
            try DownloadFileProtection.prepareDirectory(inbox)
            let fileName = "\(token).audio"
            let destination = inbox.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: location, to: destination)
            try DownloadFileProtection.protect(destination)
            let receipt = CompletedDownload(token: token, statusCode: response.statusCode, mimeType: response.mimeType, fileName: fileName)
            try JSONEncoder().encode(receipt).write(to: inbox.appendingPathComponent("\(token).json"), options: .atomic)
            try DownloadFileProtection.protect(inbox.appendingPathComponent("\(token).json"))
            continuation.yield(.finished(receipt))
        } catch {
            let error = error as NSError
            continuation.yield(.failed(token: token, domain: error.domain, code: error.code, resumeData: nil))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let token = downloadTask.taskDescription else { return }
        let now = Date()
        guard now.timeIntervalSince(progressDates[token] ?? .distantPast) >= 0.25 || totalBytesWritten == totalBytesExpectedToWrite else { return }
        progressDates[token] = now
        continuation.yield(.progress(token: token, received: totalBytesWritten, expected: totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        if let token = task.taskDescription { continuation.yield(.waiting(token: token)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let token = task.taskDescription else { return }
        progressDates[token] = nil
        if let url = task.response?.url { NeteaseCDNHost.markReachable(url) }
        guard let error = error as NSError? else { return }
        if task.response == nil, let url = task.currentRequest?.url ?? task.originalRequest?.url {
            _ = NeteaseCDNHost.failover(from: url, after: error)
        }
        continuation.yield(.failed(token: token, domain: error.domain, code: error.code,
                                   resumeData: error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        continuation.yield(.backgroundEventsFinished)
    }

    static func validToken(_ value: String) -> Bool {
        let parts = value.split(separator: ".")
        return parts.count == 2 && parts.allSatisfy { UUID(uuidString: String($0)) != nil }
    }
}

@MainActor
final class BackgroundDownloadTransport: DownloadTransport {
    nonisolated static let identifier = "im.missuo.Kumone.offline-downloads.v1"
    let events: AsyncStream<DownloadTransportEvent>
    let inbox: URL
    private let session: URLSession
    private let delegate: DownloadSessionDelegate
    private var tasks: [String: URLSessionDownloadTask] = [:]

    init(inbox: URL, backgroundIdentifier: String? = BackgroundDownloadTransport.identifier) {
        self.inbox = inbox
        let stream = AsyncStream<DownloadTransportEvent>.makeStream()
        events = stream.stream
        delegate = DownloadSessionDelegate(inbox: inbox, continuation: stream.continuation)
        let config = backgroundIdentifier.map(URLSessionConfiguration.background(withIdentifier:)) ?? .ephemeral
        config.waitsForConnectivity = true
        config.isDiscretionary = false
        config.httpMaximumConnectionsPerHost = 2
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
    }

    func restoreTasks() async -> [String: Int64] {
        let existing = await session.allTasks
        var received: [String: Int64] = [:]
        for task in existing {
            guard let download = task as? URLSessionDownloadTask, let token = task.taskDescription,
                  DownloadSessionDelegate.validToken(token) else { task.cancel(); continue }
            tasks[token] = download
            received[token] = max(0, download.countOfBytesReceived)
        }
        return received
    }

    func completedDownloads() throws -> [CompletedDownload] {
        guard FileManager.default.fileExists(atPath: inbox.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let receipt = try? JSONDecoder().decode(CompletedDownload.self, from: Data(contentsOf: url)),
                      DownloadSessionDelegate.validToken(receipt.token), receipt.fileName == "\(receipt.token).audio" else { return nil }
                return receipt
            }
    }

    func start(resource: OfflineAudioResource, token: String, allowsMetered: Bool, resumeData: Data?) {
        let preferred = NeteaseCDNHost.preferred(for: resource.url)
        var request = URLRequest(url: preferred)
        request.allowsCellularAccess = allowsMetered
        request.allowsExpensiveNetworkAccess = allowsMetered
        request.allowsConstrainedNetworkAccess = allowsMetered
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: request)
        task.taskDescription = token
        tasks[token] = task
        task.resume()
    }

    func pause(token: String) async -> Data? {
        guard let task = tasks.removeValue(forKey: token) else { return nil }
        return await withCheckedContinuation { continuation in
            task.cancel { continuation.resume(returning: $0) }
        }
    }

    func cancel(token: String) { tasks.removeValue(forKey: token)?.cancel() }

    func acknowledge(_ receipt: CompletedDownload) {
        tasks[receipt.token] = nil
        try? FileManager.default.removeItem(at: inbox.appendingPathComponent(receipt.fileName))
        try? FileManager.default.removeItem(at: inbox.appendingPathComponent("\(receipt.token).json"))
    }

    func shutdown() {
        session.invalidateAndCancel()
        delegate.continuation.finish()
    }
}
