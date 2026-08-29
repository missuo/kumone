#if os(macOS)
import Darwin
import Foundation

// A blocking, thread-per-connection HTTP/1.1 server, small enough to read in
// one sitting. It exists because the tuning console needs exactly three
// things — serve one HTML page, answer JSON over POST, and stream rendered
// WAVs with byte ranges so `<audio>` can seek — and none of that is worth a
// dependency. Keeping it in-process is the point: the planner and the
// analyses stay warm, so moving a slider re-plans in milliseconds instead of
// paying a process launch per keystroke.

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    var json: [String: Any] {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }
}

struct HTTPResponse {
    var status: Int = 200
    var headers: [String: String] = [:]
    var body: Data = Data()

    static func text(_ s: String, status: Int = 200,
                     type: String = "text/plain; charset=utf-8") -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": type], body: Data(s.utf8))
    }

    static func html(_ s: String) -> HTTPResponse {
        text(s, type: "text/html; charset=utf-8")
    }

    static func json(_ data: Data, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status,
                     headers: ["Content-Type": "application/json; charset=utf-8",
                               "Cache-Control": "no-store"],
                     body: data)
    }

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object,
                                                options: [.fragmentsAllowed]))
            ?? Data("{}".utf8)
        return .json(data, status: status)
    }

    static func error(_ message: String, status: Int = 400) -> HTTPResponse {
        .json(["error": message], status: status)
    }
}

private let statusText: [Int: String] = [
    200: "OK", 206: "Partial Content", 304: "Not Modified", 400: "Bad Request",
    404: "Not Found", 405: "Method Not Allowed", 416: "Range Not Satisfiable",
    500: "Internal Server Error",
]

final class HTTPServer {
    typealias Handler = (HTTPRequest) -> HTTPResponse

    private let handler: Handler
    private var listeners: [Int32] = []

    init(handler: @escaping Handler) { self.handler = handler }

    /// Bind one listening socket per address. Addresses that fail (a ZeroTier
    /// interface that happens to be down, say) are reported and skipped, so
    /// the loopback console always comes up.
    @discardableResult
    func listen(on addresses: [String], port: UInt16) -> [String] {
        // A browser scrubbing an <audio> element aborts Range requests
        // constantly; writing to that closed socket raises SIGPIPE, whose
        // default action kills the whole process without a crash report.
        // Ignore it — the write() then fails with EPIPE, which the serve
        // loop already treats as a closed connection.
        signal(SIGPIPE, SIG_IGN)
        var bound: [String] = []
        for address in addresses {
            guard let fd = bind(address: address, port: port) else { continue }
            listeners.append(fd)
            bound.append(address)
            Thread.detachNewThread { [weak self] in self?.accept(on: fd) }
        }
        return bound
    }

    private func bind(address: String, port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(address)
        guard addr.sin_addr.s_addr != INADDR_NONE else { close(fd); return nil }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ok == 0, Darwin.listen(fd, 64) == 0 else {
            FileHandle.standardError.write(
                Data("audition: cannot bind \(address):\(port) — \(String(cString: strerror(errno)))\n"
                     .utf8))
            close(fd)
            return nil
        }
        return fd
    }

    private func accept(on fd: Int32) {
        while true {
            let client = Darwin.accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            var yes: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes,
                       socklen_t(MemoryLayout<Int32>.size))
            Thread.detachNewThread { [weak self] in
                self?.serve(client)
                close(client)
            }
        }
    }

    // MARK: - One connection

    private func serve(_ fd: Int32) {
        // No keep-alive: the console makes a handful of requests per
        // interaction and one connection each keeps this readable.
        var nodelay: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &nodelay, socklen_t(MemoryLayout<Int32>.size))
        guard let request = readRequest(fd) else { return }
        var response = handler(request)
        response.headers["Connection"] = "close"
        write(fd, response, headOnly: request.method == "HEAD")
    }

    private func readRequest(_ fd: Int32) -> HTTPRequest? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        var headerEnd: Range<Data.Index>?

        while headerEnd == nil {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<n])
            headerEnd = buffer.range(of: Data("\r\n\r\n".utf8))
            if buffer.count > 1 << 20 { return nil }
        }
        guard let headerEnd else { return nil }

        let head = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ", maxSplits: 2)
        guard requestLine.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[line.startIndex..<colon].lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        // Body, per Content-Length.
        var body = Data(buffer[headerEnd.upperBound...])
        let expected = Int(headers["content-length"] ?? "") ?? 0
        while body.count < expected {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { break }
            body.append(contentsOf: chunk[0..<n])
        }

        // Path + query.
        let target = String(requestLine[1])
        var path = target, query: [String: String] = [:]
        if let q = target.firstIndex(of: "?") {
            path = String(target[target.startIndex..<q])
            for pair in target[target.index(after: q)...].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let value = kv.count > 1
                    ? (String(kv[1]).replacingOccurrences(of: "+", with: " ")
                        .removingPercentEncoding ?? String(kv[1]))
                    : ""
                query[key] = value
            }
        }
        return HTTPRequest(method: String(requestLine[0]).uppercased(),
                           path: path.removingPercentEncoding ?? path,
                           query: query, headers: headers, body: body)
    }

    private func write(_ fd: Int32, _ response: HTTPResponse, headOnly: Bool) {
        var head = "HTTP/1.1 \(response.status) \(statusText[response.status] ?? "OK")\r\n"
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        sendAll(fd, Data(head.utf8))
        if !headOnly { sendAll(fd, response.body) }
    }

    private func sendAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let n = send(fd, base.advanced(by: sent), raw.count - sent, 0)
                if n <= 0 {
                    if errno == EINTR { continue }
                    return
                }
                sent += n
            }
        }
    }
}

// MARK: - Range-served files

enum FileServing {
    /// Serve `url` honouring a `Range: bytes=…` header, so `<audio>` can seek
    /// inside a rendered WAV instead of refetching it.
    static func serve(_ url: URL, request: HTTPRequest, contentType: String) -> HTTPResponse {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size])
                  as? Int
        else { return .error("no such file: \(url.lastPathComponent)", status: 404) }
        defer { try? handle.close() }

        var headers = ["Content-Type": contentType,
                       "Accept-Ranges": "bytes",
                       "Cache-Control": "no-store"]

        guard let raw = request.header("Range"),
              raw.hasPrefix("bytes=") else {
            let body = (try? handle.readToEnd()) ?? Data()
            return HTTPResponse(status: 200, headers: headers, body: body)
        }

        let spec = raw.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
        var start = 0, end = size - 1
        if spec.count == 2, spec[0].isEmpty, let suffix = Int(spec[1]) {
            start = Swift.max(0, size - suffix)            // bytes=-N
        } else {
            start = Int(spec.first ?? "") ?? 0
            if spec.count == 2, let e = Int(spec[1]) { end = Swift.min(e, size - 1) }
        }
        guard start <= end, start < size else {
            headers["Content-Range"] = "bytes */\(size)"
            return HTTPResponse(status: 416, headers: headers, body: Data())
        }
        try? handle.seek(toOffset: UInt64(start))
        let body = (try? handle.read(upToCount: end - start + 1)) ?? Data()
        headers["Content-Range"] = "bytes \(start)-\(end)/\(size)"
        return HTTPResponse(status: 206, headers: headers, body: body)
    }
}
#endif
