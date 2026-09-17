import Foundation
import Testing
@testable import KumoneCore

@MainActor private final class PlaylistGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}

@Suite("Playlist loading and downloads", .timeLimit(.minutes(1)))
@MainActor struct PlaylistLoadingTests {
    private func response(ids: [Int], loaded: [Int]) throws -> NeteaseAPI.PlaylistDetailResponse {
        let json: [String: Any] = ["playlist": ["id": 1, "name": "Fixture", "trackCount": ids.count,
            "trackIds": ids.map { ["id": $0] }, "tracks": loaded.map { ["id": $0, "name": "Track \($0)", "dt": 3000] }]]
        return try JSONDecoder().decode(NeteaseAPI.PlaylistDetailResponse.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func retryAfterAnInitialFailureRestoresTheDownloadAction() async throws {
        var attempts = 0
        let data = try response(ids: [1, 2], loaded: [1, 2])
        let model = PlaylistDetailViewModel(playlistID: 1, detailLoader: { _ in
            attempts += 1
            if attempts == 1 { throw URLError(.timedOut) }
            return data
        })
        await model.load()
        #expect(model.errorMessage != nil && !model.isLoading && !model.canDownloadAll)
        await model.load()
        #expect(model.errorMessage == nil && model.canDownloadAll)
        let removed = try #require(model.tracks.first)
        model.remove(removed)
        #expect(model.tracks.map(\.id) == [2])
        #expect(model.detail?.trackIds.map(\.id) == [2] && model.detail?.trackCount == 1)
        #expect(model.canDownloadAll)
    }

    @Test func removalDuringPaginationKeepsDownloadReady() async throws {
        let gate = PlaylistGate()
        defer { gate.open() }
        let data = try response(ids: [1, 2, 3], loaded: [1, 2])
        let third = try response(ids: [3], loaded: [3]).playlist.tracks[0]
        let model = PlaylistDetailViewModel(playlistID: 1, detailLoader: { _ in data }, tracksLoader: { ids in
            #expect(ids == [3])
            await gate.wait()
            return .init(songs: [third], privileges: [])
        })
        let loading = Task { await model.load() }
        for _ in 0..<200 where !gate.entered { try await Task.sleep(for: .milliseconds(5)) }
        #expect(gate.entered && !model.canDownloadAll)
        model.remove(data.playlist.tracks[0])
        gate.open()
        await loading.value
        #expect(model.tracks.map(\.id) == [2, 3])
        #expect(model.detail?.trackIds.map(\.id) == [2, 3])
        #expect(model.canDownloadAll)
    }

    @Test func reloadCannotRestoreASongRemovedWhileItWasLoading() async throws {
        let gate = PlaylistGate()
        defer { gate.open() }
        var calls = 0
        let data = try response(ids: [1, 2], loaded: [1, 2])
        let model = PlaylistDetailViewModel(playlistID: 1, detailLoader: { _ in
            calls += 1
            if calls == 2 { await gate.wait() }
            return data
        })
        await model.load()
        let reload = Task { await model.load() }
        for _ in 0..<200 where !gate.entered { try await Task.sleep(for: .milliseconds(5)) }
        #expect(gate.entered)
        model.remove(data.playlist.tracks[0])
        gate.open()
        await reload.value
        #expect(model.tracks.map(\.id) == [2] && model.detail?.trackIds.map(\.id) == [2])
        #expect(model.canDownloadAll)
    }

    @Test func anOlderRequestCannotReplaceARetriedPlaylist() async throws {
        let gate = PlaylistGate()
        defer { gate.open() }
        var calls = 0
        let old = try response(ids: [1], loaded: [1]), new = try response(ids: [2], loaded: [2])
        let model = PlaylistDetailViewModel(playlistID: 1, detailLoader: { _ in
            calls += 1
            if calls == 1 { await gate.wait(); return old }
            return new
        })
        let first = Task { await model.load() }
        for _ in 0..<200 where !gate.entered { try await Task.sleep(for: .milliseconds(5)) }
        #expect(gate.entered)
        await model.load()
        gate.open()
        await first.value
        #expect(model.tracks.map(\.id) == [2] && model.canDownloadAll)
    }

    @Test func aFailedPageCanBeRetried() async throws {
        var failPage = true
        let data = try response(ids: [1, 2], loaded: [1]), second = try response(ids: [2], loaded: [2]).playlist.tracks[0]
        let model = PlaylistDetailViewModel(playlistID: 1, detailLoader: { _ in data }, tracksLoader: { _ in
            if failPage { throw URLError(.networkConnectionLost) }
            return .init(songs: [second], privileges: [])
        })
        await model.load()
        #expect(model.errorMessage != nil && !model.isLoadingMore && !model.canDownloadAll)
        failPage = false
        await model.load()
        #expect(model.errorMessage == nil && model.canDownloadAll)
    }
}
