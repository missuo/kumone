import Foundation

/// A task-scoped delegate keeps the session's connection pool and delivers data
/// blocks. Each block suspends reception until its consumer has written it.
final class AudioChunkStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Event { case response(URLResponse), data(Data) }
    let events: AsyncThrowingStream<Event, Error>
    private let continuation: AsyncThrowingStream<Event, Error>.Continuation
    let task: URLSessionDataTask

    init(session: URLSession, request: URLRequest) {
        let stream = AsyncThrowingStream<Event, Error>.makeStream()
        events = stream.stream
        continuation = stream.continuation
        task = session.dataTask(with: request)
        super.init()
        task.delegate = self
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        continuation.yield(.response(response))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        dataTask.suspend()
        continuation.yield(.data(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { continuation.finish(throwing: error) }
        else { continuation.finish() }
    }

    func cancel() {
        task.cancel()
        continuation.finish(throwing: CancellationError())
    }
}
