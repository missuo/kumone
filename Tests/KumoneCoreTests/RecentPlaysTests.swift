import Foundation
import Testing
@testable import KumoneCore

private final class RecentPlaysProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = ""
    nonisolated(unsafe) static var paths: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.paths.append(request.url?.path ?? "")
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Recent plays", .serialized)
struct RecentPlaysTests {
    init() { TestUpstream.configure() }

    private func client() -> MusicClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecentPlaysProtocol.self]
        let client = MusicClient(configuration: configuration, persistsCookies: false)
        client.setCookies(["MUSIC_U": "recent-plays-test-session"])
        return client
    }

    private func entry(_ id: Int, _ name: String, playTime: Int64?) -> [String: Any] {
        var entry: [String: Any] = [
            "resourceId": String(id), "resourceType": "SONG",
            "data": ["id": id, "name": name, "dt": 200_000,
                     "ar": [["id": 1, "name": "Artist"]], "al": ["id": 2, "name": "Album"]],
        ]
        if let playTime { entry["playTime"] = playTime }
        return entry
    }

    @Test func keepsTheServiceOrderNewestFirst() async throws {
        let list: [Any] = [
            entry(3, "Latest", playTime: 1_762_900_000_000),
            ["resourceType": "VOICE", "data": ["programId": 9]], // not a song: skipped
            entry(1, "Earlier", playTime: 1_762_800_000_000),
            entry(3, "Latest again", playTime: 1_762_700_000_000), // duplicate: first wins
            entry(2, "No time", playTime: nil),
        ]
        let json: [String: Any] = ["code": 200, "data": ["total": list.count, "list": list]]
        RecentPlaysProtocol.body = String(data: try JSONSerialization.data(withJSONObject: json), encoding: .utf8)!
        RecentPlaysProtocol.paths = []

        let plays = try await MusicAPI.recentSongs(using: client())

        #expect(RecentPlaysProtocol.paths == ["/eapi/play-record/song/list"])
        #expect(plays.map(\.song.id) == [3, 1, 2])
        #expect(plays.map(\.song.name) == ["Latest", "Earlier", "No time"])
        #expect(plays[0].song.artists.first?.name == "Artist" && plays[0].song.album.name == "Album")
        #expect(plays[0].playedAt == Date(timeIntervalSince1970: 1_762_900_000))
        #expect(plays[2].playedAt == nil)
    }

    @Test func anEmptyHistoryIsAnEmptyList() async throws {
        RecentPlaysProtocol.body = #"{"code":200,"data":null}"#
        #expect(try await MusicAPI.recentSongs(using: client()).isEmpty)
    }
}
