import Foundation
import Testing
@testable import KumoneCore

private final class CookieLoginProtocol: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var body = ""
        private var requests: [URLRequest] = []
        func reset(_ body: String) { lock.lock(); self.body = body; requests = []; lock.unlock() }
        func receive(_ request: URLRequest) -> String {
            lock.lock(); defer { lock.unlock() }
            requests.append(request)
            return body
        }
        var received: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = Self.state.receive(request)
        if body == "transport-error" {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Cookie login", .serialized)
struct CookieLoginTests {
    init() { TestUpstream.configure() }

    private func candidate(directory: URL? = nil) -> MusicClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CookieLoginProtocol.self]
        return MusicClient(cookieDirectory: directory, configuration: configuration, persistsCookies: false)
    }

    @Test(arguments: [false, true])
    func validatesBrowserHeaderWithoutImportingUnrelatedCookies(includeCSRF: Bool) async throws {
        CookieLoginProtocol.state.reset("{\"code\":200,\"profile\":{\"userId\":42,\"nickname\":\"Fixture\"}}")
        let client = candidate()
        let header = " unrelated=ignored; MUSIC_U = synthetic=token== ; " + (includeCSRF ? "__csrf=synthetic-csrf;" : "")
        let login = try await MusicAPI.loginWithCookie(header, using: client)
        #expect(login.profile.userId == 42)
        let expected = includeCSRF ? ["MUSIC_U": "synthetic=token==", "__csrf": "synthetic-csrf"] : ["MUSIC_U": "synthetic=token=="]
        let permittedCookiesOnly = login.cookies == expected && client.cookie(named: "unrelated") == nil
        #expect(permittedCookiesOnly)
        let request = try #require(CookieLoginProtocol.state.received.first)
        #expect(request.url?.path == "/eapi/nuser/account/get")
        let sentAuthentication = request.value(forHTTPHeaderField: "Cookie")?.contains("MUSIC_U=synthetic=token==") == true
        #expect(sentAuthentication)
    }

    @Test func rejectsInvalidAuthenticationBeforeRequesting() async {
        CookieLoginProtocol.state.reset("")
        for header in ["", "  ", "__csrf=synthetic", "MUSIC_U=", "MUSIC_U", "MUSIC_U=synthetic; __csrf",
                       "MUSIC_U=synthetic; __csrf=", "MUSIC_U=one; MUSIC_U=two",
                       "MUSIC_U=synthetic; __csrf=one; __csrf=two", "MUSIC_U=bad\nvalue"] {
            await #expect(throws: MusicAPI.CookieLoginError.self) {
                _ = try await MusicAPI.loginWithCookie(header, using: candidate())
            }
        }
        #expect(CookieLoginProtocol.state.received.isEmpty)
    }

    @Test func failedValidationDoesNotPersistOrChangeTheLiveSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-cookie-login-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let live = MusicClient(cookieDirectory: root.appendingPathComponent("live"), configuration: .ephemeral)
        live.setCookies(["MUSIC_U": "synthetic-live"])
        let before = try Data(contentsOf: root.appendingPathComponent("live/cookies.json"))
        let candidateDirectory = root.appendingPathComponent("candidate")
        for body in ["{\"code\":301}", "{\"code\":500,\"message\":\"synthetic-secret\"}",
                     "{\"code\":200,\"profile\":null}", "{\"code\":200,\"profile\":{\"userId\":0}}",
                     "{\"code\":200,\"profile\":{\"userId\":-1}}", "malformed", "transport-error"] {
            CookieLoginProtocol.state.reset(body)
            do {
                _ = try await MusicAPI.loginWithCookie("MUSIC_U=synthetic-candidate", using: candidate(directory: candidateDirectory))
                Issue.record("Invalid session was accepted")
            } catch {
                let safeMessage = error is MusicAPI.CookieLoginError && !error.localizedDescription.contains("synthetic-secret")
                #expect(safeMessage)
            }
            let saved = try Data(contentsOf: root.appendingPathComponent("live/cookies.json"))
            let liveUnchanged = live.cookie(named: "MUSIC_U") == "synthetic-live" && saved == before
            #expect(liveUnchanged)
            #expect(!FileManager.default.fileExists(atPath: candidateDirectory.path))
        }
    }
}
