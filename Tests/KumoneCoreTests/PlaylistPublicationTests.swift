import Combine
import Foundation
import Testing
@testable import KumoneCore

@Suite("Playlist publication")
@MainActor
struct PlaylistPublicationTests {
    @Test func largePlaylistPublishesCompletePrivilegeBatches() async throws {
        let ids = Array(1...1_200)
        let tracks = try makeTracks(ids)
        let detail = try makeDetail(ids: ids, tracks: Array(tracks.prefix(200)))
        let model = PlaylistContent(playlistID: 1, snapshots: nil, accountScope: { nil },
            detailLoader: { _ in
                .init(playlist: detail, privileges: privileges(Array(ids.prefix(200))))
            }, tracksLoader: { chunk in
                .init(songs: chunk.reversed().map { tracks[$0 - 1] }, privileges: privileges(chunk))
            })
        var publications: [Int] = []
        var retained: [Int: TrackPrivilege] = [:]
        let observation = model.$privileges.dropFirst().sink {
            publications.append($0.count)
            retained = $0
        }
        defer { observation.cancel() }

        await model.load()

        // A 500-song response must not send 500 intermediate dictionaries to
        // observers (or copy them once per song when a view retains the value).
        #expect(publications == [200, 700, 1_200])
        #expect(model.tracks.map(\.id) == ids)
        #expect(model.canDownloadAll)
        #expect(retained[1_200]?.pl == 320_000)

        publications.removeAll()
        await model.load()
        #expect(publications.isEmpty, "An unchanged refresh should not invalidate the list")
    }

    @Test func refreshPrunesRemovedPrivilegesAndReplacesChangedValuesTogether() async throws {
        let tracks = try makeTracks([1, 2, 3])
        var detail = try makeDetail(ids: [1, 2, 3], tracks: tracks)
        var incoming = privileges([1, 2, 3])
        let model = PlaylistContent(playlistID: 1, snapshots: nil, accountScope: { nil },
            detailLoader: { _ in .init(playlist: detail, privileges: incoming) })
        await model.load()
        detail = try makeDetail(ids: [2, 3], tracks: Array(tracks.suffix(2)))
        // Keep 3's existing privilege when the response omits it. For repeated
        // IDs the last entry wins, just as it does for sequential assignments.
        incoming = [
            TrackPrivilege(id: 2, fee: 1, pl: 0, st: 0, cs: nil, maxbr: nil),
            TrackPrivilege(id: 2, fee: 4, pl: 0, st: 0, cs: nil, maxbr: nil),
        ]
        var publications: [Int] = []
        var retained: [Int: TrackPrivilege] = [:]
        let observation = model.$privileges.dropFirst().sink {
            publications.append($0.count)
            retained = $0
        }
        defer { observation.cancel() }

        await model.load()

        #expect(publications.count == 1)
        #expect(Set(model.privileges.keys) == [2, 3])
        #expect(model.privileges[2]?.fee == 4)
        #expect(retained[3]?.pl == 320_000)
        #expect(model.tracks[0].playability(privilege: model.privileges[2], isLoggedIn: true, vipType: 11) == .paidAlbum)
    }

    private func privileges(_ ids: [Int]) -> [TrackPrivilege] {
        ids.map { TrackPrivilege(id: $0, fee: 0, pl: 320_000, st: 0, cs: nil, maxbr: nil) }
    }

    private func makeTracks(_ ids: [Int]) throws -> [Track] {
        try JSONDecoder().decode([Track].self, from: JSONSerialization.data(withJSONObject:
            ids.map { ["id": $0, "name": "Track \($0)"] }))
    }

    private func makeDetail(ids: [Int], tracks: [Track]) throws -> PlaylistDetail {
        var detail = try JSONDecoder().decode(PlaylistDetail.self, from: JSONSerialization.data(withJSONObject: [
            "id": 1, "name": "Large playlist", "trackCount": ids.count,
            "trackIds": ids.map { ["id": $0] },
        ]))
        detail.tracks = tracks
        return detail
    }
}
