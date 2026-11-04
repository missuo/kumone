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
/// eapi encrypted requests, and the few plain web API ones eapi refuses.
final class NeteaseClient: @unchecked Sendable {
    static let shared: NeteaseClient = {
        #if DEBUG
        if KumonePaths.isOfflineUITest {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [OfflineUITestProtocol.self]
            return NeteaseClient(configuration: configuration)
        }
        #endif
        return NeteaseClient()
    }()

    private static let log = Logger(subsystem: "im.missuo.kumone", category: "api")
    private static let webUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    // The desktop client the eapi requests speak as, as mygo-cloudmusic's do.
    private static let eapiUserAgent = "NeteaseMusic 9.0.90/5038 (iPhone; iOS 16.2; zh_CN)"
    private static let eapiAppVersion = "3.1.17.204416"
    private static let eapiOSVersion = "Microsoft-Windows-10-Professional-build-19045-64bit"
    private static let eapiChannel = "netease"

    /// The device ID the eapi header carries, made once and kept beside the
    /// cookies: NetEase trusts a device it has seen before, and a constant
    /// every install shares looks like no device at all. It is no secret, so
    /// it stays out of the keychain.
    static let deviceID: String = loadDeviceID(in: KumonePaths.applicationSupport)

    static func loadDeviceID(in directory: URL?) -> String {
        let url = directory?.appendingPathComponent("device-id")
        if let url, let data = try? Data(contentsOf: url),
           let stored = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           stored.count == 52, stored.allSatisfy(\.isHexDigit) {
            return stored
        }
        let hex = Array("0123456789ABCDEF")
        let id = String((0..<52).map { _ in hex.randomElement()! })
        if let url {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(id.utf8).write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        return id
    }

    private let session: URLSession
    private let cookieLock = NSLock()
    // Serialize mutations and disk snapshots without blocking cookie readers.
    private let cookieWriteLock = NSLock()
    private var cookies: [String: String] = [:]
    private static let bindingKey = "__kumone_session_binding"
    private var sessionBinding: String?
    private var authEpoch: UInt64 = 0
    private let cookieFileURL: URL?

    init(cookieDirectory: URL? = nil, configuration: URLSessionConfiguration? = nil, persistsCookies: Bool = true) {
        let config = configuration ?? URLSessionConfiguration.default
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)

        guard persistsCookies else { cookieFileURL = nil; return }

        let support = cookieDirectory ?? KumonePaths.applicationSupport
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let url = support.appendingPathComponent("cookies.json")
        cookieFileURL = url
        if let data = try? Data(contentsOf: url),
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
        cookieWriteLock.lock(); defer { cookieWriteLock.unlock() }
        cookieLock.lock()
        if let expectedEpoch, expectedEpoch != authEpoch { cookieLock.unlock(); return false }
        if let token = new["MUSIC_U"], token != cookies["MUSIC_U"] {
            authEpoch += 1
            if !preservingSession || sessionBinding == nil { sessionBinding = Self.fingerprint(token) }
        }
        for (k, v) in new where k != Self.bindingKey { cookies[k] = v }
        var snapshot = cookies
        snapshot[Self.bindingKey] = sessionBinding
        cookieLock.unlock()
        persist(snapshot)
        return true
    }

    /// Commit a verified sign-in durably before changing the live cookie jar.
    /// Disk failures leave the current authentication untouched.
    func replaceAuthentication(with authentication: [String: String]) throws {
        guard let token = authentication["MUSIC_U"], !token.isEmpty else { throw NeteaseAPIError.needLogin }
        cookieWriteLock.lock(); defer { cookieWriteLock.unlock() }
        cookieLock.lock()
        var snapshot = cookies
        cookieLock.unlock()
        snapshot.removeValue(forKey: "MUSIC_U")
        snapshot.removeValue(forKey: "__csrf")
        snapshot.merge(authentication.filter { ["MUSIC_U", "__csrf"].contains($0.key) }) { _, new in new }
        try commitAuthentication(snapshot, binding: Self.fingerprint(token))
    }

    /// The caller holds cookieWriteLock so a failed disk write cannot leave the
    /// persisted and live authentication states disagreeing.
    private func commitAuthentication(_ snapshot: [String: String], binding: String?) throws {
        if let cookieFileURL {
            var stored = snapshot
            stored[Self.bindingKey] = binding
            try JSONEncoder().encode(stored).write(to: cookieFileURL, options: .atomic)
        }
        cookieLock.lock()
        cookies = snapshot
        sessionBinding = binding
        authEpoch += 1
        cookieLock.unlock()
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

    func clearAuthCookies() throws {
        cookieWriteLock.lock(); defer { cookieWriteLock.unlock() }
        cookieLock.lock()
        var snapshot = cookies
        cookieLock.unlock()
        snapshot.removeValue(forKey: "MUSIC_U")
        snapshot.removeValue(forKey: "__csrf")
        try commitAuthentication(snapshot, binding: nil)
    }

    private func persist(_ snapshot: [String: String]) {
        guard let cookieFileURL else { return }
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

    private func absorbSetCookies(from response: HTTPURLResponse, url: URL, epoch: UInt64, preservingSession: Bool) -> Bool {
        guard let fields = response.allHeaderFields as? [String: String] else { return true }
        let parsed = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        guard !parsed.isEmpty else { return true }
        var new: [String: String] = [:]
        for c in parsed where !c.value.isEmpty && c.value != "\"\"" {
            new[c.name] = c.value
        }
        return setCookies(new, expectedEpoch: epoch, preservingSession: preservingSession)
    }

    // MARK: - Requests

    /// POST to `https://music.163.com/api<path>` with a plain form, as a
    /// browser. Only for what NetEase's risk control refuses through the eapi
    /// with -460, 检测到您的网络环境存在风险: the phone-number login and
    /// following an artist, as mygo-cloudmusic found for the latter.
    func api(_ path: String, _ form: [String: String] = [:]) async throws -> Data {
        let authentication = authenticationState
        var request = URLRequest(url: URL(string: "https://music.163.com/api\(path)")!)
        request.httpMethod = "POST"
        request.setValue(Self.webUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(cookieHeader(extra: [:]), forHTTPHeaderField: "Cookie")
        request.httpBody = Self.encodeForm(form)
        return try await perform(request, authentication: authentication)
    }

    /// POST to `https://interface.music.163.com/eapi<path>` with eapi encryption.
    /// The digest is computed over the corresponding `/api<path>` path.
    /// Sent as the desktop client from this install's device, header and
    /// cookie alike, as mygo-cloudmusic sends it: NetEase's risk control
    /// refuses some writes from a client it does not recognize, so requests
    /// go this way unless they are refused through it.
    func eapi(_ path: String, _ payload: [String: Any] = [:],
              cookieOverrides: [String: String] = [:], absorbResponseCookies: Bool = true) async throws -> Data {
        let authentication = authenticationState
        let apiPath = "/api" + path
        var body = payload
        let now = Date().timeIntervalSince1970
        var header: [String: String] = [
            "osver": Self.eapiOSVersion,
            "deviceId": Self.deviceID,
            "os": "pc",
            "appver": Self.eapiAppVersion,
            "versioncode": "140",
            "mobilename": "",
            "buildver": String(Int(now)),
            "resolution": "1920x1080",
            "channel": Self.eapiChannel,
            "requestId": String(format: "%lld_%04d", Int64(now * 1000), Int(now * 1_000_000) % 1000),
            "__csrf": cookie(named: "__csrf") ?? "",
        ]
        if let musicU = cookie(named: "MUSIC_U") { header["MUSIC_U"] = musicU }
        if let nmtid = cookie(named: "NMTID") { header["NMTID"] = nmtid }
        body["header"] = header
        body["e_r"] = false
        let json = try JSONSerialization.data(withJSONObject: body)
        let form = NeteaseCrypto.eapi(apiPath: apiPath, payload: json)

        let url = URL(string: "https://interface.music.163.com/eapi\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(Self.eapiUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(cookieHeader(extra: header, overrides: cookieOverrides), forHTTPHeaderField: "Cookie")
        request.httpBody = Self.encodeForm(form)
        return try await perform(request, authentication: authentication, absorbResponseCookies: absorbResponseCookies)
    }

    private func perform(_ request: URLRequest, authentication: (epoch: UInt64, binding: String?), absorbResponseCookies: Bool = true) async throws -> Data {
        try Task.checkCancellation()
        // A request sent without a login carries no account's data, so a login
        // finishing while it is in flight does not make its answer stale.
        let anonymous = authentication.binding == nil
        guard anonymous || isCurrent(authentication) else { throw CancellationError() }
        let (data, response) = try await session.data(for: request)
        guard anonymous || isCurrent(authentication) else { throw CancellationError() }
        guard let http = response as? HTTPURLResponse else { throw NeteaseAPIError.http(-1) }
        let refreshSucceeded = request.url?.path == "/eapi/login/token/refresh"
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

#if DEBUG
private final class OfflineUITestProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
#endif
