import Foundation
import CryptoKit
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
    private static let bindingKey = "__kumone_session_binding"
    private var sessionBinding: String?
    private var authEpoch: UInt64 = 0
    private let cookieFileURL: URL

    init(cookieDirectory: URL? = nil, configuration: URLSessionConfiguration? = nil) {
        let config = configuration ?? URLSessionConfiguration.default
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)

        let support = cookieDirectory ?? KumonePaths.applicationSupport
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        cookieFileURL = support.appendingPathComponent("cookies.json")
        if let data = try? Data(contentsOf: cookieFileURL),
           let stored = try? JSONDecoder().decode([String: String].self, from: data) {
            cookies = stored
            let savedBinding = cookies.removeValue(forKey: Self.bindingKey)
            sessionBinding = cookies["MUSIC_U"].map { savedBinding ?? Self.fingerprint($0) }
        }
    }

    // MARK: - Cookies

    var isLoggedIn: Bool { cookie(named: "MUSIC_U") != nil }

    /// Identifies the login across token renewals; a new sign-in gets a new binding.
    var authenticationFingerprint: String? {
        cookieLock.lock(); defer { cookieLock.unlock() }
        return sessionBinding
    }

    private static func fingerprint(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private var authenticationState: (epoch: UInt64, binding: String?) {
        cookieLock.lock(); defer { cookieLock.unlock() }
        return (authEpoch, sessionBinding)
    }

    private func isCurrent(_ authentication: (epoch: UInt64, binding: String?)) -> Bool {
        cookieLock.lock(); defer { cookieLock.unlock() }
        return authentication.epoch == authEpoch || (authentication.binding != nil && authentication.binding == sessionBinding)
    }

    func authenticationCookies() -> [String: String] {
        cookieLock.lock(); defer { cookieLock.unlock() }
        return cookies.filter { ["MUSIC_U", "__csrf"].contains($0.key) }
    }

    func cookie(named name: String) -> String? {
        cookieLock.lock(); defer { cookieLock.unlock() }
        return cookies[name]
    }

    @discardableResult
    func setCookies(_ new: [String: String], expectedEpoch: UInt64? = nil, preservingSession: Bool = false) -> Bool {
        cookieLock.lock()
        defer { cookieLock.unlock() }
        if let expectedEpoch, expectedEpoch != authEpoch { return false }
        if let token = new["MUSIC_U"], token != cookies["MUSIC_U"] {
            authEpoch += 1
            if !preservingSession || sessionBinding == nil { sessionBinding = Self.fingerprint(token) }
        }
        for (k, v) in new where k != Self.bindingKey { cookies[k] = v }
        persist(cookies)
        return true
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
        defer { cookieLock.unlock() }
        authEpoch += 1
        sessionBinding = nil
        cookies.removeValue(forKey: "MUSIC_U")
        cookies.removeValue(forKey: "__csrf")
        persist(cookies)
    }

    private func persist(_ snapshot: [String: String]) {
        var stored = snapshot
        stored[Self.bindingKey] = sessionBinding
        if let data = try? JSONEncoder().encode(stored) {
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

    private func absorbSetCookies(from response: HTTPURLResponse, url: URL, epoch: UInt64, preservingSession: Bool) -> Bool {
        guard let fields = response.allHeaderFields as? [String: String] else { return authenticationState.epoch == epoch }
        let parsed = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        guard !parsed.isEmpty else { return authenticationState.epoch == epoch }
        var new: [String: String] = [:]
        for c in parsed where !c.value.isEmpty && c.value != "\"\"" {
            new[c.name] = c.value
        }
        return setCookies(new, expectedEpoch: epoch, preservingSession: preservingSession)
    }

    // MARK: - Requests

    /// POST to `https://music.163.com/weapi<path>` with weapi encryption.
    func weapi(_ path: String, _ payload: [String: Any] = [:],
               cookieOverrides: [String: String] = [:], absorbResponseCookies: Bool = true) async throws -> Data {
        let authentication = authenticationState
        var body = payload
        let csrf = cookieOverrides["__csrf"] ?? cookie(named: "__csrf")
        body["csrf_token"] = csrf ?? ""
        let json = try JSONSerialization.data(withJSONObject: body)
        let form = NeteaseCrypto.weapi(payload: json)

        var fullPath = path
        if let csrf, !csrf.isEmpty {
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
        return try await perform(request, authentication: authentication, absorbResponseCookies: absorbResponseCookies)
    }

    /// POST to `https://interface.music.163.com/eapi<path>` with eapi encryption.
    /// The digest is computed over the corresponding `/api<path>` path.
    func eapi(_ path: String, _ payload: [String: Any] = [:],
              cookieOverrides: [String: String] = [:]) async throws -> Data {
        let authentication = authenticationState
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
        return try await perform(request, authentication: authentication)
    }

    private func perform(_ request: URLRequest, authentication: (epoch: UInt64, binding: String?), absorbResponseCookies: Bool = true) async throws -> Data {
        if KumonePaths.isOfflineUITest { throw URLError(.notConnectedToInternet) }
        try Task.checkCancellation()
        guard isCurrent(authentication) else { throw CancellationError() }
        let (data, response) = try await session.data(for: request)
        guard isCurrent(authentication) else { throw CancellationError() }
        guard let http = response as? HTTPURLResponse else { throw NeteaseAPIError.http(-1) }
        let refreshSucceeded = request.url?.path == "/weapi/login/token/refresh"
            && (200..<300).contains(http.statusCode)
            && (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["code"] as? Int == 200
        if absorbResponseCookies,
           !absorbSetCookies(from: http, url: request.url!, epoch: authentication.epoch, preservingSession: refreshSucceeded) {
            // A reply from before a token renewal still belongs to this login,
            // but its older Set-Cookie must not roll back the renewed credentials.
            guard isCurrent(authentication) else { throw CancellationError() }
        }
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
