import Foundation
import Testing
@testable import KumoneCore

private final class NonHTTPDownloadTask: URLSessionDownloadTask, @unchecked Sendable {
    override var response: URLResponse? {
        URLResponse(url: URL(string: "file:///audio")!, mimeType: "audio/mpeg", expectedContentLength: 0, textEncodingName: nil)
    }
}

@Suite("Background download response validation")
struct BackgroundDownloadTransportTests {
    @Test func nonHTTPResponseReportsFailureForItsJob() async {
        let stream = AsyncStream<DownloadTransportEvent>.makeStream()
        let delegate = DownloadSessionDelegate(inbox: FileManager.default.temporaryDirectory, continuation: stream.continuation)
        let task = NonHTTPDownloadTask()
        let token = "\(UUID()).\(UUID())"
        task.taskDescription = token
        delegate.urlSession(.shared, downloadTask: task, didFinishDownloadingTo: URL(fileURLWithPath: "/unused"))
        stream.continuation.finish()
        var iterator = stream.stream.makeAsyncIterator()
        guard case let .failed(received, domain, code, data) = await iterator.next() else {
            Issue.record("A non-HTTP response did not emit a failure")
            return
        }
        #expect(received == token && domain == NSURLErrorDomain && code == NSURLErrorBadServerResponse && data == nil)
    }
}
