import Foundation
import os.log

enum AudioSourceError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpStatus(Int)
    case transport(URLError.Code)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid audio-source URL"
        case .invalidResponse: return "Invalid audio-source HTTP response"
        case .httpStatus(let status): return "Audio-source HTTP status \(status)"
        case .transport(let code): return "Audio-source network error \(code.rawValue)"
        }
    }
}

struct AudioSourceClient {
    static let shared = AudioSourceClient()

    private static let log = Logger(subsystem: "im.missuo.kumone", category: "audio-source")
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
            return
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        self.session = URLSession(configuration: configuration)
    }

    func data(
        from urlString: String,
        source: AudioSourceID,
        operation: String,
        userAgent: String = "Mozilla/5.0"
    ) async throws -> Data {
        guard let url = URL(string: urlString) else { throw AudioSourceError.invalidURL }
        return try await data(from: url, source: source, operation: operation, userAgent: userAgent)
    }

    func data(
        from url: URL,
        source: AudioSourceID,
        operation: String,
        userAgent: String = "Mozilla/5.0"
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return try await execute(request, source: source, operation: operation)
    }

    private func execute(
        _ request: URLRequest,
        source: AudioSourceID,
        operation: String
    ) async throws -> Data {
        let startedAt = Date()
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                logFailure(source: source, operation: operation, url: request.url, detail: "non-http", startedAt: startedAt)
                throw AudioSourceError.invalidResponse
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                logFailure(
                    source: source,
                    operation: operation,
                    url: request.url,
                    detail: "status=\(httpResponse.statusCode)",
                    startedAt: startedAt
                )
                throw AudioSourceError.httpStatus(httpResponse.statusCode)
            }
            return data
        } catch let error as AudioSourceError {
            throw error
        } catch let error as URLError {
            logFailure(
                source: source,
                operation: operation,
                url: request.url,
                detail: "url-error=\(error.code.rawValue)",
                startedAt: startedAt
            )
            throw AudioSourceError.transport(error.code)
        } catch {
            logFailure(source: source, operation: operation, url: request.url, detail: "unexpected", startedAt: startedAt)
            throw error
        }
    }

    private func logFailure(
        source: AudioSourceID,
        operation: String,
        url: URL?,
        detail: String,
        startedAt: Date
    ) {
        let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1_000)
        Self.log.error(
            "source=\(source.rawValue, privacy: .public) operation=\(operation, privacy: .public) host=\(url?.host ?? "", privacy: .public) detail=\(detail, privacy: .public) elapsed-ms=\(elapsedMS, privacy: .public)"
        )
    }
}
