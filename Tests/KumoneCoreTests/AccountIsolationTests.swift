import Foundation
import Testing
@testable import KumoneCore

private final class DeferredAPIProtocol: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [String: DeferredAPIProtocol] = [:]
        func set(_ value: DeferredAPIProtocol) { lock.lock(); pending[value.request.url!.path] = value; lock.unlock() }
        func get(_ path: String? = nil) -> DeferredAPIProtocol? {
            lock.lock(); defer { lock.unlock() }
            if let path { return pending[path] }
            return pending.values.first
        }
        func remove(_ value: DeferredAPIProtocol) { lock.lock(); pending[value.request.url!.path] = nil; lock.unlock() }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.state.set(self) }
    override func stopLoading() {}
    func finish(token: String = "old-session-returned-late", code: Int = 200) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Set-Cookie": "MUSIC_U=\(token); Path=/; Secure"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"code\":\(code)}".utf8))
        client?.urlProtocolDidFinishLoading(self)
        Self.state.remove(self)
    }
}

@Suite("Account response isolation", .serialized)
struct AccountIsolationTests {
    @Test func concurrentCookieWritesPersistTheLatestCompleteSnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = NeteaseClient(cookieDirectory: root)
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            client.setCookies(["fixture-\(index)": String(index)])
        }
        client.setCookies(["MUSIC_U": "synthetic-session"])
        client.clearAuthCookies()
        let reopened = NeteaseClient(cookieDirectory: root)
        #expect(!reopened.isLoggedIn && reopened.authenticationFingerprint == nil)
        for index in 0..<100 { #expect(reopened.cookie(named: "fixture-\(index)") == String(index)) }
    }

    @Test func rejectedRenewalCannotBindANewCookieToThePreviousIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-rejected-renewal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeferredAPIProtocol.self]
        let client = NeteaseClient(cookieDirectory: root, configuration: configuration)
        client.setCookies(["MUSIC_U": "synthetic-before"])
        let before = client.authenticationFingerprint
        let refreshing = Task { try await client.weapi("/login/token/refresh") }
        for _ in 0..<200 where DeferredAPIProtocol.state.get() == nil { try await Task.sleep(for: .milliseconds(5)) }
        let reply = try #require(DeferredAPIProtocol.state.get())
        reply.finish(token: "synthetic-rejected", code: 301)
        _ = try await refreshing.value
        #expect(client.authenticationFingerprint != before)
    }

    @Test(arguments: [false, true], ["/test-only", "/login/token/refresh"])
    func lateResponseCannotRestoreLoggedOutCredentials(switchAccount: Bool, path: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-auth-isolation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeferredAPIProtocol.self]
        let client = NeteaseClient(cookieDirectory: root, configuration: configuration)
        client.setCookies(["MUSIC_U": "synthetic-session-a"])
        let request = Task { try await client.weapi(path) }
        for _ in 0..<200 where DeferredAPIProtocol.state.get() == nil { try await Task.sleep(for: .milliseconds(5)) }
        let pending = try #require(DeferredAPIProtocol.state.get())
        client.clearAuthCookies()
        if switchAccount { client.setCookies(["MUSIC_U": "synthetic-session-b"]) }
        pending.finish()
        await #expect(throws: CancellationError.self) { _ = try await request.value }
        let reloaded = NeteaseClient(cookieDirectory: root)
        // Check a Boolean so assertion diagnostics never echo cookie material.
        let expected = switchAccount ? "synthetic-session-b" : nil
        let unchanged = reloaded.cookie(named: "MUSIC_U") == expected
        #expect(unchanged)
    }

    @Test func renewalPreservesOfflineBindingAndDoesNotRollBackFromAnOlderReply() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-renewal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeferredAPIProtocol.self]
        let client = NeteaseClient(cookieDirectory: root, configuration: configuration)
        client.setCookies(["MUSIC_U": "synthetic-before"])
        let binding = try #require(client.authenticationFingerprint)
        let profile = try JSONDecoder().decode(UserProfile.self, from: Data("{\"userId\":1,\"nickname\":\"Fixture\"}".utf8))
        let snapshot = AccountSnapshotStorage(url: root.appendingPathComponent("account.json"))
        try snapshot.save(.init(authenticationFingerprint: binding, profile: profile, likedTrackIDs: [42], playlists: [], savedAt: Date()))
        let older = Task { try await client.weapi("/test-only") }
        for _ in 0..<200 where DeferredAPIProtocol.state.get("/weapi/test-only") == nil { try await Task.sleep(for: .milliseconds(5)) }
        let oldReply = try #require(DeferredAPIProtocol.state.get("/weapi/test-only"))
        let refresh = Task { try await client.weapi("/login/token/refresh") }
        for _ in 0..<200 where DeferredAPIProtocol.state.get("/weapi/login/token/refresh")?.request.url?.path != "/weapi/login/token/refresh" { try await Task.sleep(for: .milliseconds(5)) }
        let renewed = try #require(DeferredAPIProtocol.state.get("/weapi/login/token/refresh"))
        #expect(renewed.request.value(forHTTPHeaderField: "Cookie")?.contains("__kumone_session_binding") == false)
        renewed.finish(token: "synthetic-renewed")
        _ = try await refresh.value
        #expect(client.authenticationFingerprint == binding)
        #expect(snapshot.load(fingerprint: client.authenticationFingerprint)?.likedTrackIDs == [42])
        oldReply.finish(token: "synthetic-before")
        _ = try await older.value
        let keptRenewedToken = client.cookie(named: "MUSIC_U") == "synthetic-renewed"
        #expect(keptRenewedToken)
        let reopened = NeteaseClient(cookieDirectory: root, configuration: configuration)
        #expect(reopened.authenticationFingerprint == binding)
        #expect(snapshot.load(fingerprint: reopened.authenticationFingerprint)?.profile.userId == 1)
        let afterRestart = Task { try await reopened.weapi("/test-only") }
        for _ in 0..<200 where DeferredAPIProtocol.state.get() == nil { try await Task.sleep(for: .milliseconds(5)) }
        let restartedRequest = try #require(DeferredAPIProtocol.state.get())
        #expect(restartedRequest.request.value(forHTTPHeaderField: "Cookie")?.contains("__kumone_session_binding") == false)
        restartedRequest.finish(token: "synthetic-renewed")
        _ = try await afterRestart.value
        reopened.setCookies(["MUSIC_U": "different-login"])
        #expect(snapshot.load(fingerprint: reopened.authenticationFingerprint) == nil)
    }
}
