import Foundation
import Testing
@testable import KumoneCore

private final class BlacklistAPIProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, url.path == "/eapi/music-blacklist/add",
              request.httpMethod == "POST",
              request.httpBody != nil || request.httpBodyStream != nil,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let code = request.value(forHTTPHeaderField: "X-Test-Response-Code") ?? "200"
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"code\":\(code)}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Music blacklist")
struct MusicBlacklistTests {
    init() { TestUpstream.configure() }

    @Test(arguments: [MusicBlacklistTarget.song(28754102), .artist(7763)], [200, 301, 403, -460])
    func requiresServerAcceptance(target: MusicBlacklistTarget, code: Int) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BlacklistAPIProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Test-Response-Code": String(code)]
        let client = MusicClient(configuration: configuration, persistsCookies: false)
        client.setCookies(["MUSIC_U": "blacklist-test-session"])

        do {
            try await MusicAPI.addToMusicBlacklist(target, using: client)
            #expect(code == 200)
        } catch MusicAPIError.needLogin {
            #expect(code == 301)
        } catch MusicAPIError.business(let received, _) {
            #expect(code != 200 && received == code)
        }
    }

    @Test func rejectsGuestRequests() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BlacklistAPIProtocol.self]
        let client = MusicClient(configuration: configuration, persistsCookies: false)
        do {
            try await MusicAPI.addToMusicBlacklist(.song(28754102), using: client)
            Issue.record("A guest must not submit a blacklist entry")
        } catch MusicAPIError.needLogin {
            // Expected before any request is sent.
        }
    }

    @Test(arguments: [MusicBlacklistTarget.song(0), .song(-1), .artist(0), .artist(-1)])
    func rejectsInvalidContentIDs(target: MusicBlacklistTarget) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BlacklistAPIProtocol.self]
        let client = MusicClient(configuration: configuration, persistsCookies: false)
        client.setCookies(["MUSIC_U": "blacklist-test-session"])
        do {
            try await MusicAPI.addToMusicBlacklist(target, using: client)
            Issue.record("Invalid content IDs must not be submitted")
        } catch MusicAPIError.business(let code, _) {
            #expect(code == 400)
        }
    }
}
