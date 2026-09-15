import Foundation
import Testing
@testable import KumoneCore

private final class DeferredAPIProtocol: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: DeferredAPIProtocol?
        func set(_ value: DeferredAPIProtocol?) { lock.lock(); pending = value; lock.unlock() }
        func get() -> DeferredAPIProtocol? { lock.lock(); defer { lock.unlock() }; return pending }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.state.set(self) }
    override func stopLoading() {}
    func finish() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Set-Cookie": "MUSIC_U=old-session-returned-late; Path=/; Secure"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"code\":200}".utf8))
        client?.urlProtocolDidFinishLoading(self)
        Self.state.set(nil)
    }
}

@Suite("Account response isolation", .serialized)
struct AccountIsolationTests {
    @Test(arguments: [false, true])
    func lateResponseCannotRestoreLoggedOutCredentials(switchAccount: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-auth-isolation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeferredAPIProtocol.self]
        let client = NeteaseClient(cookieDirectory: root, configuration: configuration)
        client.setCookies(["MUSIC_U": "synthetic-session-a"])
        let request = Task { try await client.weapi("/test-only") }
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
}
