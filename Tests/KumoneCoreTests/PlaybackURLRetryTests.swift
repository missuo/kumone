import Foundation
import Testing
@testable import KumoneCore

/// Answers each request with the next scripted outcome.
private final class ScriptedProtocol: URLProtocol, @unchecked Sendable {
    enum Outcome { case fail(URLError.Code), body(String) }
    nonisolated(unsafe) static var script: [Outcome] = []
    nonisolated(unsafe) static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        let outcome = Self.script.isEmpty ? .fail(.badServerResponse) : Self.script.removeFirst()
        switch outcome {
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .body(let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

@Suite("Playback URL retry", .serialized)
struct PlaybackURLRetryTests {
    init() { TestUpstream.configure() }

    private static let playable = #"{"code":200,"data":[{"id":7,"url":"https://cdn.example/7.mp3","br":320000}]}"#

    private func client(_ script: [ScriptedProtocol.Outcome]) -> MusicClient {
        ScriptedProtocol.script = script
        ScriptedProtocol.requests = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedProtocol.self]
        return MusicClient(configuration: configuration, persistsCookies: false)
    }

    @Test(arguments: [URLError.Code.networkConnectionLost, .timedOut, .cannotConnectToHost])
    func aRequestThatDiesInTransitIsAskedOnceMore(code: URLError.Code) async throws {
        let client = client([.fail(code), .body(Self.playable)])
        let data = try await MusicAPI.songURLRetrying(ids: [7], level: "exhigh", using: client, retryDelay: .zero)
        #expect(data.first?.url == "https://cdn.example/7.mp3")
        #expect(ScriptedProtocol.requests == 2)
    }

    @Test func aSecondFailureIsReported() async {
        let client = client([.fail(.networkConnectionLost), .fail(.networkConnectionLost)])
        await #expect(throws: (any Error).self) {
            _ = try await MusicAPI.songURLRetrying(ids: [7], level: "exhigh", using: client, retryDelay: .zero)
        }
        #expect(ScriptedProtocol.requests == 2)
    }

    @Test func offlineOrARefusalIsNotRetried() async {
        let offline = client([.fail(.notConnectedToInternet), .body(Self.playable)])
        await #expect(throws: (any Error).self) {
            _ = try await MusicAPI.songURLRetrying(ids: [7], level: "exhigh", using: offline, retryDelay: .zero)
        }
        #expect(ScriptedProtocol.requests == 1)

        let refused = client([.body(#"{"code":-460,"message":"Cheating"}"#), .body(Self.playable)])
        await #expect(throws: MusicAPIError.self) {
            _ = try await MusicAPI.songURLRetrying(ids: [7], level: "exhigh", using: refused, retryDelay: .zero)
        }
        #expect(ScriptedProtocol.requests == 1)
    }
}
