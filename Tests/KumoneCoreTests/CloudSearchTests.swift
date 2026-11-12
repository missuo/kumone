import Foundation
import Testing
@testable import KumoneCore

@Suite("Cloud disk search", .timeLimit(.minutes(1)))
@MainActor
struct CloudSearchTests {
    @Test func loadsEveryPageSoSearchCoversTheWholeCloud() async throws {
        let all = try (1...2_500).map { try item(id: $0, name: $0 == 2_400 ? "夜曲" : "Ordinary") }
        var requests: [(limit: Int, offset: Int)] = []
        let model = CloudLibraryContent(pageSize: 1_000) { limit, offset in
            requests.append((limit, offset))
            let page = Array(all.dropFirst(offset).prefix(limit))
            return try response(page, hasMore: offset + page.count < all.count, size: "1073741824")
        }
        model.filter = "夜曲"
        await model.load()

        #expect(requests.map(\.offset) == [0, 1_000, 2_000])
        #expect(model.isComplete && !model.isLoading && !model.isLoadingMore && model.errorMessage == nil)
        #expect(model.tracks.count == 2_500)
        #expect(model.filteredTracks.map(\.id) == [2_400])
        #expect(model.usedBytes == 1_073_741_824)
    }

    @Test(arguments: ["\n 夜曲 \n", "周杰伦", "NOVEMBER", "cafe", "demo_take3", "FLAC", "Jay Chou"])
    func matchesSongArtistAlbumAndFileName(query: String) async throws {
        let model = CloudLibraryContent { _, _ in
            try response([
                try item(id: 1, name: "夜曲", artist: "周杰伦", album: "November Café",
                         extra: ["fileName": "demo_take3.flac", "artist": "Jay Chou"]),
                try item(id: 2, name: "Other", artist: "Other", album: "Other",
                         extra: ["fileName": "other.mp3"]),
            ], hasMore: false)
        }
        await model.load()

        model.filter = query
        #expect(model.filteredTracks.map(\.id) == [1])
        model.filter = " "
        #expect(model.filteredTracks.map(\.id) == [1, 2])
    }

    @Test func readsMetadataNestedUnderPrivateCloud() async throws {
        let model = CloudLibraryContent { _, _ in
            try response([
                try item(id: 1, name: "Track", extra: ["privateCloud": [
                    "songId": 1, "song": "Uploaded Title", "fileName": "Bootleg 1999.mp3", "album": "Live",
                ]]),
            ], hasMore: false)
        }
        await model.load()

        model.filter = "bootleg"
        #expect(model.filteredTracks.map(\.id) == [1])
        model.filter = "uploaded title"
        #expect(model.filteredTracks.map(\.id) == [1])
    }

    @Test func aFailedPageKeepsWhatLoadedAndCanBeRetried() async throws {
        let all = try (1...3).map { try item(id: $0, name: "Song \($0)") }
        var failSecondPage = true
        let model = CloudLibraryContent(pageSize: 2) { limit, offset in
            if offset > 0, failSecondPage { throw URLError(.networkConnectionLost) }
            let page = Array(all.dropFirst(offset).prefix(limit))
            return try response(page, hasMore: offset + page.count < all.count)
        }
        await model.load()
        #expect(model.tracks.map(\.id) == [1, 2])
        #expect(!model.isComplete && model.errorMessage != nil && !model.isLoadingMore)

        failSecondPage = false
        await model.load()
        #expect(model.tracks.map(\.id) == [1, 2, 3])
        #expect(model.isComplete && model.errorMessage == nil)
    }

    @Test func stopsWhenThePagerRepeatsItselfAndDropsDuplicates() async throws {
        var calls = 0
        let model = CloudLibraryContent(pageSize: 2) { _, _ in
            calls += 1
            // Claims more forever but never advances.
            return try response([try item(id: 1, name: "A"), try item(id: 2, name: "B")], hasMore: true)
        }
        await model.load()
        #expect(calls == 2)
        #expect(model.tracks.map(\.id) == [1, 2] && model.isComplete)
    }

    // MARK: - Fixtures

    private func item(id: Int, name: String, artist: String = "Artist", album: String = "Album",
                      extra: [String: Any] = [:]) throws -> [String: Any] {
        var json: [String: Any] = [
            "songId": id,
            "simpleSong": ["id": id, "name": name, "ar": [["id": 1, "name": artist]],
                           "al": ["id": 1, "name": album], "dt": 1],
        ]
        json.merge(extra) { _, new in new }
        return json
    }

    private func response(_ items: [[String: Any]], hasMore: Bool, size: String? = nil) throws -> MusicAPI.CloudResponse {
        var json: [String: Any] = ["data": items, "hasMore": hasMore, "code": 200]
        if let size { json["size"] = size; json["maxSize"] = "64424509440" }
        return try JSONDecoder().decode(MusicAPI.CloudResponse.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
