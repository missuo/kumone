import Foundation
import Testing
@testable import KumoneCore

@Suite("Playlist Search")
@MainActor
struct PlaylistSearchTests {
    @Test func searchesAllLoadedTracksInPlaylistOrder() throws {
        let model = PlaylistContent(playlistID: 1)
        model.tracks = try (1...2_500).map { try track(id: $0, name: "Ordinary") }
        model.tracks[499] = try track(id: 500, name: "夜曲")
        model.tracks[2_499] = try track(id: 2_500, name: "夜曲 (Live)")

        model.filter = "夜曲"
        #expect(model.filteredTracks.map(\.id) == [500, 2_500])
        #expect(model.tracks.count == 2_500)

        model.filter = "不存在的歌曲"
        #expect(model.filteredTracks.isEmpty)

        model.filter = " \n "
        #expect(model.filteredTracks.map(\.id) == model.tracks.map(\.id))
    }

    @Test(arguments: ["\n 夜曲 \n", "周杰伦", "NOVEMBER", "cafe"])
    func searchesSongArtistAndAlbum(query: String) throws {
        let model = PlaylistContent(playlistID: 1)
        model.tracks = [
            try track(id: 1, name: "夜曲", artist: "周杰伦", album: "November Café"),
            try track(id: 2, name: "Other", artist: "Other", album: "Other"),
        ]

        model.filter = query
        #expect(model.filteredTracks.map(\.id) == [1])
    }

    @Test func updatesResultsAsMoreTracksArriveOrAreRemoved() async throws {
        let model = PlaylistContent(playlistID: 1)
        model.tracks = [try track(id: 1, name: "Other")]
        model.filter = "夜曲"
        #expect(model.filteredTracks.isEmpty)

        let matching = try track(id: 2, name: "夜曲")
        model.tracks.append(matching)
        #expect(model.filteredTracks.map(\.id) == [2])

        await model.remove(matching)
        #expect(model.filteredTracks.isEmpty)

        model.filter = ""
        #expect(model.filteredTracks.map(\.id) == [1])
    }

    @Test(arguments: [
        (PlaylistTrackSort.addedNewestFirst, [30, 10, 20]),
        (.addedOldestFirst, [20, 10, 30]),
        (.songName, [10, 20, 30]),
        (.albumName, [30, 20, 10]),
        (.artistName, [10, 20, 30]),
    ])
    func sortsStablyWithoutChangingCanonicalOrder(order: PlaylistTrackSort, expected: [Int]) throws {
        let model = PlaylistContent(playlistID: 1)
        model.tracks = [
            try track(id: 30, name: "Song 10", artist: "B", album: "A"),
            try track(id: 10, name: "Song 2", artist: "A", album: "B"),
            try track(id: 20, name: "Song 2", artist: "A", album: "A"),
        ]

        model.sortOrder = order
        #expect(model.filteredTracks.map(\.id) == expected)
        #expect(model.tracks.map(\.id) == [30, 10, 20])
    }

    @Test func keepsSortOrderWhileSearchingLoadingAndClearing() async throws {
        let model = PlaylistContent(playlistID: 1)
        model.tracks = [try track(id: 1, name: "Song 10")]
        model.sortOrder = .songName
        model.filter = "song"

        let earlier = try track(id: 2, name: "Song 2")
        model.tracks.append(earlier)
        #expect(model.filteredTracks.map(\.id) == [2, 1])

        model.filter = "10"
        #expect(model.filteredTracks.map(\.id) == [1])

        model.filter = ""
        #expect(model.filteredTracks.map(\.id) == [2, 1])

        await model.remove(earlier)
        #expect(model.filteredTracks.map(\.id) == [1])
    }

    /// Large playlists arrive as one detail response plus 500-song pages; a
    /// search opened before the tail arrives still finds songs on later pages.
    @Test func searchCoversSongsLoadedAfterTheFirstPage() async throws {
        let ids = Array(1...1_200)
        let detail = try JSONDecoder().decode(MusicAPI.PlaylistDetailResponse.self, from: JSONSerialization.data(
            withJSONObject: ["playlist": ["id": 1, "name": "Big", "trackCount": ids.count,
                                          "trackIds": ids.map { ["id": $0] },
                                          "tracks": [["id": 1, "name": "Ordinary", "dt": 1]]]]))
        var pages: [[Int]] = []
        let model = PlaylistContent(playlistID: 1, snapshots: nil, accountScope: { "test" },
                                    detailLoader: { _ in detail },
                                    tracksLoader: { chunk in
            pages.append(chunk)
            return .init(songs: try chunk.map { try track(id: $0, name: $0 == 1_150 ? "夜曲" : "Ordinary") },
                         privileges: [])
        })
        model.filter = "夜曲"
        await model.load()

        #expect(pages.map(\.count) == [500, 500, 199])
        #expect(model.tracks.count == 1_200 && model.canDownloadAll)
        #expect(model.filteredTracks.map(\.id) == [1_150])
    }

    private func track(id: Int, name: String, artist: String = "Artist", album: String = "Album") throws -> Track {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": id, "name": name,
            "ar": [["id": 1, "name": artist]],
            "al": ["id": 1, "name": album], "dt": 1,
        ])
        return try JSONDecoder().decode(Track.self, from: data)
    }
}
