import Foundation
import os.log

enum NeteaseAPIError: LocalizedError {
    case http(Int)
    case business(code: Int, message: String?)
    case needLogin
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .http(let status): return String(localized: "网络错误 (\(status))")
        case .business(let code, let message): return message ?? String(localized: "接口错误 (\(code))")
        case .needLogin: return String(localized: "需要登录")
        case .decoding: return String(localized: "数据加载失败，请稍后重试")
        }
    }
}

/// Transport layer for NetEase Cloud Music. Owns the cookie jar and performs
/// weapi / eapi encrypted requests.
final class NeteaseClient: @unchecked Sendable {
    static let shared = NeteaseClient()

    private static let log = Logger(subsystem: "im.missuo.kumone", category: "api")
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"

    private let session: URLSession
    private let cookieLock = NSLock()
    private var cookies: [String: String] = [:]
    private let cookieFileURL: URL

    init(cookieDirectory: URL? = nil) {
        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)

        let support = cookieDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kumone", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        cookieFileURL = support.appendingPathComponent("cookies.json")
        if let data = try? Data(contentsOf: cookieFileURL),
           let stored = try? JSONDecoder().decode([String: String].self, from: data) {
            cookies = stored
        }
    }

    // MARK: - Cookies

    var isLoggedIn: Bool { cookie(named: "MUSIC_U") != nil }

    func cookie(named name: String) -> String? {
        cookieLock.lock(); defer { cookieLock.unlock() }
        return cookies[name]
    }

    func setCookies(_ new: [String: String]) {
        cookieLock.lock()
        for (k, v) in new { cookies[k] = v }
        let snapshot = cookies
        cookieLock.unlock()
        persist(snapshot)
    }

    /// Ingests a `;;`-joined raw cookie string as returned by the QR login check.
    func ingestCookieString(_ raw: String) {
        var parsed: [String: String] = [:]
        for cookie in raw.components(separatedBy: ";;") {
            guard let pair = cookie.components(separatedBy: ";").first,
                  let eq = pair.firstIndex(of: "=") else { continue }
            let name = pair[..<eq].trimmingCharacters(in: .whitespaces)
            let value = String(pair[pair.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !value.isEmpty else { continue }
            parsed[name] = value
        }
        setCookies(parsed)
    }

    func clearAuthCookies() {
        cookieLock.lock()
        cookies.removeValue(forKey: "MUSIC_U")
        cookies.removeValue(forKey: "__csrf")
        let snapshot = cookies
        cookieLock.unlock()
        persist(snapshot)
    }

    private func persist(_ snapshot: [String: String]) {
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: cookieFileURL, options: .atomic)
        }
    }

    private func cookieHeader(extra: [String: String], overrides: [String: String] = [:]) -> String {
        cookieLock.lock()
        var all = cookies
        cookieLock.unlock()
        for (k, v) in extra where all[k] == nil { all[k] = v }
        for (k, v) in overrides { all[k] = v }
        return all.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    private func absorbSetCookies(from response: HTTPURLResponse, url: URL) {
        guard let fields = response.allHeaderFields as? [String: String] else { return }
        let parsed = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        guard !parsed.isEmpty else { return }
        var new: [String: String] = [:]
        for c in parsed where !c.value.isEmpty && c.value != "\"\"" {
            new[c.name] = c.value
        }
        if !new.isEmpty { setCookies(new) }
    }

    // MARK: - Requests

    /// POST to `https://music.163.com/weapi<path>` with weapi encryption.
    func weapi(_ path: String, _ payload: [String: Any] = [:],
               cookieOverrides: [String: String] = [:]) async throws -> Data {
        var body = payload
        body["csrf_token"] = cookie(named: "__csrf") ?? ""
        let json = try JSONSerialization.data(withJSONObject: body)
        let form = NeteaseCrypto.weapi(payload: json)

        var fullPath = path
        if let csrf = cookie(named: "__csrf"), !csrf.isEmpty {
            fullPath += (fullPath.contains("?") ? "&" : "?") + "csrf_token=\(csrf)"
        }
        let url = URL(string: "https://music.163.com/weapi\(fullPath)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(cookieHeader(extra: ["os": "pc", "appver": "3.1.17"], overrides: cookieOverrides),
                         forHTTPHeaderField: "Cookie")
        request.httpBody = Self.encodeForm(form)
        return try await perform(request)
    }

    /// POST to `https://interface.music.163.com/eapi<path>` with eapi encryption.
    /// The digest is computed over the corresponding `/api<path>` path.
    func eapi(_ path: String, _ payload: [String: Any] = [:],
              cookieOverrides: [String: String] = [:]) async throws -> Data {
        let apiPath = "/api" + path
        var body = payload
        var header: [String: String] = [
            "os": "pc",
            "appver": "3.1.17",
            "osver": "Version 14.0 (Build 23A344)",
            "deviceId": "kumone",
            "requestId": String(Int.random(in: 20_000_000...30_000_000)),
            "clientSign": "",
            "versioncode": "140",
            "buildver": String(Int(Date().timeIntervalSince1970)),
            "resolution": "1920x1080",
            "channel": "",
        ]
        if let musicU = cookie(named: "MUSIC_U") { header["MUSIC_U"] = musicU }
        if let csrf = cookie(named: "__csrf") { header["__csrf"] = csrf }
        body["header"] = header
        let json = try JSONSerialization.data(withJSONObject: body)
        let form = NeteaseCrypto.eapi(apiPath: apiPath, payload: json)

        let url = URL(string: "https://interface.music.163.com/eapi\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(cookieHeader(extra: ["os": "pc", "appver": "3.1.17"], overrides: cookieOverrides),
                         forHTTPHeaderField: "Cookie")
        request.httpBody = Self.encodeForm(form)
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NeteaseAPIError.http(-1) }
        absorbSetCookies(from: http, url: request.url!)
        guard (200..<300).contains(http.statusCode) else {
            Self.log.error("HTTP \(http.statusCode) for \(request.url?.path ?? "?")")
            throw NeteaseAPIError.http(http.statusCode)
        }
        return data
    }

    /// Performs a request and decodes the response, surfacing business-level errors.
    func decoded<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let code = obj["code"] as? Int, code != 200 {
            if code == 301 { throw NeteaseAPIError.needLogin }
            let message = (obj["message"] as? String) ?? (obj["msg"] as? String)
            throw NeteaseAPIError.business(code: code, message: message)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            Self.log.error("Decoding \(String(describing: T.self)) failed: \(error)")
            throw NeteaseAPIError.decoding(String(describing: error))
        }
    }

    private static func encodeForm(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = fields.map { key, value in
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(key)=\(v)"
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }
}
