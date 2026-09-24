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

    @Test func freshBackgroundSnapshotSkipsTheNetworkButForegroundStillRefreshes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshots = PlaylistSnapshotStore(directory: root)
        let data = try response(ids: [1, 2], loaded: [1, 2])
        var calls = 0
        let model = PlaylistContent(playlistID: 1, snapshots: snapshots, accountScope: { "a" }, detailLoader: { _ in calls += 1; return data })
        await model.load(background: true)
        await model.load(background: true)
        #expect(calls == 1 && model.tracks.count == 2)
        await model.load()
        #expect(calls == 2)
    }

    @Test func aPlaylistLoadsFromTheNetworkWhileTheProfileIsStillUnknown() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshots = PlaylistSnapshotStore(directory: root)
        let data = try response(ids: [1, 2], loaded: [1, 2])
        // A login cookie whose profile has not arrived yet has no scope: the
        // page still loads, and nothing is saved under an account it cannot name.
        let model = PlaylistContent(playlistID: 1, snapshots: snapshots, accountScope: { nil }, detailLoader: { _ in data })
        await model.load()
        #expect(model.tracks.count == 2 && model.errorMessage == nil && !model.isLoading)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).isEmpty)
    }

    @Test func backgroundFreshnessHonorsVersionCountAgeAndCompleteness() throws {
        let now = Date()
        func summary(count: Int = 2, version: Int? = nil) throws -> PlaylistSummary {
            var json: [String: Any] = ["id": 1, "name": "Fixture", "trackCount": count]
            if let version { json["updateTime"] = version }
            return try JSONDecoder().decode(PlaylistSummary.self, from: JSONSerialization.data(withJSONObject: json))
        }
        var snapshot = PlaylistSnapshot(detail: try response(ids: [1, 2], loaded: [1, 2]).playlist, privileges: [:], savedAt: now)
        #expect(!snapshot.needsBackgroundRefresh(summary: try summary(), now: now))
        #expect(snapshot.needsBackgroundRefresh(summary: try summary(count: 3), now: now))
        #expect(snapshot.needsBackgroundRefresh(summary: try summary(), now: now.addingTimeInterval(301)))
        snapshot.detail.tracks.removeLast()
        #expect(snapshot.needsBackgroundRefresh(summary: try summary(), now: now))
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot.detail)) as? [String: Any])
        json["updateTime"] = 100
        json["tracks"] = [["id": 1, "name": "One"], ["id": 2, "name": "Two"]]
        snapshot.detail = try JSONDecoder().decode(PlaylistDetail.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!snapshot.needsBackgroundRefresh(summary: try summary(version: 100), now: now.addingTimeInterval(3600)))
        #expect(snapshot.needsBackgroundRefresh(summary: try summary(version: 101), now: now))
    }

    @Test(arguments: [false, true])
    func missingMembershipUsesReturnedSongsAndPersistsThem(emptyIDs: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var json: [String: Any] = ["id": 1, "name": "Fixture", "trackCount": 2,
                                  "tracks": [["id": 7, "name": "First"], ["id": 3, "name": "Second"]]]
        if emptyIDs { json["trackIds"] = [] }
        let response = try JSONDecoder().decode(NeteaseAPI.PlaylistDetailResponse.self,
            from: JSONSerialization.data(withJSONObject: ["playlist": json]))
        let snapshots = PlaylistSnapshotStore(directory: root)
        let model = PlaylistContent(playlistID: 1, snapshots: snapshots, accountScope: { "a" }, detailLoader: { _ in response })
        await model.load()
        #expect(model.tracks.map(\.id) == [7, 3] && model.canDownloadAll)
        let reopened = PlaylistContent(playlistID: 1, snapshots: snapshots, accountScope: { "a" })
        await reopened.load(allowNetwork: false)
        #expect(reopened.tracks.map(\.id) == [7, 3] && reopened.canDownloadAll)
    }

    @Test func truncatedMembershipRetainsSnapshotAndShowsReadableError() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshots = PlaylistSnapshotStore(directory: root)
        let complete = try response(ids: [1, 2, 3], loaded: [1, 2, 3])
        var detail = complete.playlist
        detail.trackIds = []
        detail.tracks = Array(complete.playlist.tracks.prefix(1))
        let partial = NeteaseAPI.PlaylistDetailResponse(playlist: detail, privileges: [])
        let online = PlaylistContent(playlistID: 1, snapshots: snapshots, accountScope: { "a" }, detailLoader: { _ in complete })
        await online.load()
        let model = PlaylistContent(playlistID: 1, snapshots: snapshots, accountScope: { "a" }, detailLoader: { _ in partial })
        await model.load()
        #expect(model.tracks.map(\.id) == [1, 2, 3])
        #expect(model.errorMessage == String(localized: "歌单数据不完整，请重试"))
        #expect(await snapshots.load(id: 1, scope: "a")?.isComplete == true)
    }

    @Test func coldOfflineOpenRestores747SongsWithoutNetwork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-playlist-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlaylistSnapshotStore(directory: root)
        let ids = Array(1...747)
        let first = try response(ids: ids, loaded: [1])
        var pages: [[Int]] = []
        let online = PlaylistContent(playlistID: 1, snapshots: store, accountScope: { "a" },
            detailLoader: { _ in first }, tracksLoader: { chunk in
                pages.append(chunk)
                // The API's return order is not necessarily the playlist order.
                return .init(songs: try response(ids: chunk, loaded: chunk.reversed()).playlist.tracks, privileges: [])
            })
        await online.load()
        #expect(online.tracks.map(\.id) == ids && online.canDownloadAll)
        #expect(pages.map(\.count) == [500, 246])
        let reopened = PlaylistContent(playlistID: 1, snapshots: PlaylistSnapshotStore(directory: root),
            accountScope: { "a" }, detailLoader: { _ in
                Issue.record("Offline open requested the network")
                throw URLError(.notConnectedToInternet)
            })
        await reopened.load(allowNetwork: false)
        #expect(reopened.detail?.name == "Fixture")
        #expect(reopened.tracks.map(\.id) == ids && reopened.canDownloadAll)
        reopened.filter = "Track 747"
        #expect(reopened.filteredTracks.map(\.id) == [747])
    }

    @Test func unsyncedOfflinePlaylistKeepsItsTitleAndCount() async throws {
        let summary = try JSONDecoder().decode(PlaylistSummary.self,
            from: Data("{\"id\":1,\"name\":\"My playlist\",\"trackCount\":747}".utf8))
        let model = PlaylistContent(playlistID: 1, snapshots: nil, accountScope: { "a" }, detailLoader: { _ in
            Issue.record("An offline playlist tried to load from the network")
            throw URLError(.notConnectedToInternet)
        })
        await model.load(allowNetwork: false, summary: summary)
        #expect(model.detail?.name == "My playlist" && model.detail?.trackCount == 747)
        #expect(model.tracks.isEmpty && !model.canDownloadAll && !model.isLoading)
    }

    @Test func interruptedFirstSyncPersistsPagesAndLaterFillsOnlyMissingSongs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-playlist-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlaylistSnapshotStore(directory: root), ids = Array(1...747)
        let first = try response(ids: ids, loaded: [1])
        let interrupted = PlaylistContent(playlistID: 1, snapshots: store, accountScope: { "a" },
            detailLoader: { _ in first }, tracksLoader: { chunk in
                if chunk[0] > 501 { throw URLError(.networkConnectionLost) }
                return .init(songs: try response(ids: chunk, loaded: chunk).playlist.tracks, privileges: [])
            })
        await interrupted.load()
        #expect(interrupted.tracks.count == 501 && !interrupted.canDownloadAll)
        let resumed = PlaylistContent(playlistID: 1, snapshots: store, accountScope: { "a" },
            detailLoader: { _ in first }, tracksLoader: { chunk in
                #expect(chunk == Array(502...747))
                return .init(songs: try response(ids: chunk, loaded: chunk).playlist.tracks, privileges: [])
            })
        await resumed.load(allowNetwork: false)
        #expect(resumed.tracks.count == 501 && resumed.detail?.trackCount == 747)
        await resumed.load()
        #expect(resumed.tracks.map(\.id) == ids && resumed.canDownloadAll)
    }

    @Test func savedPlaylistAppearsBeforeRefreshAndSurvivesARefreshFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-playlist-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlaylistSnapshotStore(directory: root)
        let first = try response(ids: [1, 2, 3], loaded: [1, 2, 3])
        let token = try #require(await store.beginRefresh(id: 1, scope: "a", background: false))
        try await store.save(.init(detail: first.playlist, privileges: [:]), scope: "a", token: token)
        await store.finishRefresh(id: 1, scope: "a", token: token)
        let gate = PlaylistGate()
        defer { gate.open() }
        let model = PlaylistContent(playlistID: 1, snapshots: store, accountScope: { "a" }, detailLoader: { _ in
            await gate.wait()
            throw URLError(.timedOut)
        })
        let request = Task { await model.load() }
        for _ in 0..<200 where !gate.entered { try await Task.sleep(for: .milliseconds(5)) }
        #expect(gate.entered && model.tracks.map(\.id) == [1, 2, 3] && !model.isLoading)
        gate.open()
        await request.value
        #expect(model.tracks.map(\.id) == [1, 2, 3] && model.errorMessage != nil)
        #expect(await store.load(id: 1, scope: "a")?.detail.tracks.map(\.id) == [1, 2, 3])
    }

    @Test func refreshHandlesSameCountReorderingReplacementAndEmptyPlaylist() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-playlist-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlaylistSnapshotStore(directory: root)
        var latest = try response(ids: [1, 2, 3], loaded: [1, 2, 3])
        let model = PlaylistContent(playlistID: 1, snapshots: store, accountScope: { "a" },
            detailLoader: { _ in latest }, tracksLoader: { chunk in
                #expect(chunk == [4])
                return .init(songs: try response(ids: chunk, loaded: chunk).playlist.tracks, privileges: [])
            })
        await model.load()
        latest = try response(ids: [3, 4, 2], loaded: [3])
        await model.load()
        #expect(model.tracks.map(\.id) == [3, 4, 2])
        #expect(await store.load(id: 1, scope: "a")?.detail.tracks.map(\.id) == [3, 4, 2])
        latest = try response(ids: [], loaded: [])
        await model.load()
        #expect(model.tracks.isEmpty && model.detail?.trackCount == 0)
        #expect(await store.load(id: 1, scope: "a")?.isComplete == true)
    }

    @Test func deletingDuringPaginationUpdatesThePersistentSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-playlist-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlaylistSnapshotStore(directory: root), gate = PlaylistGate()
        defer { gate.open() }
        let first = try response(ids: [1, 2], loaded: [1])
        let model = PlaylistContent(playlistID: 1, snapshots: store, accountScope: { "a" },
            detailLoader: { _ in first }, tracksLoader: { chunk in
                await gate.wait()
                return .init(songs: try response(ids: chunk, loaded: chunk).playlist.tracks, privileges: [])
            })
        let request = Task { await model.load() }
        for _ in 0..<200 where !gate.entered { try await Task.sleep(for: .milliseconds(5)) }
        await model.remove(first.playlist.tracks[0])
        gate.open()
        await request.value
        #expect(await store.load(id: 1, scope: "a")?.detail.tracks.map(\.id) == [2])
        #expect(await store.load(id: 1, scope: "a")?.isComplete == true)
    }

    @Test func openedPlaylistTakesPriorityOverAnOlderBackgroundSync() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-playlist-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlaylistSnapshotStore(directory: root), gate = PlaylistGate()
        defer { gate.open() }
        let old = try response(ids: [1], loaded: [1]), new = try response(ids: [2], loaded: [2])
        let background = PlaylistContent(playlistID: 1, snapshots: store, accountScope: { "a" }, detailLoader: { _ in
            await gate.wait()
            return old
        })
        let request = Task { await background.load(background: true) }
        for _ in 0..<200 where !gate.entered { try await Task.sleep(for: .milliseconds(5)) }
        let opened = PlaylistContent(playlistID: 1, snapshots: store, accountScope: { "a" }, detailLoader: { _ in new })
        await opened.load()
        gate.open()
        await request.value
        #expect(await store.load(id: 1, scope: "a")?.detail.tracks.map(\.id) == [2])
    }

    @Test func simultaneousForegroundLoadsFinishWithoutOverwritingTheNewerSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlaylistSnapshotStore(directory: root), gate = PlaylistGate()
        defer { gate.open() }
        let first = try response(ids: [1, 2], loaded: [1])
        let second = try response(ids: [1, 3], loaded: [1, 3])
        let phone = PlaylistContent(playlistID: 1, snapshots: store, accountScope: { "a" },
            detailLoader: { _ in first }, tracksLoader: { chunk in
                await gate.wait()
                return .init(songs: try response(ids: chunk, loaded: chunk).playlist.tracks, privileges: [])
            })
        let request = Task { await phone.load() }
        for _ in 0..<200 where !gate.entered { try await Task.sleep(for: .milliseconds(5)) }
        #expect(gate.entered)
        let carPlay = PlaylistContent(playlistID: 1, snapshots: store, accountScope: { "a" },
            detailLoader: { _ in second })
        await carPlay.load()
        // The older visible page still has priority over background sync even
        // after the newer foreground caller has finished.
        #expect(await store.beginRefresh(id: 1, scope: "a", background: true) == nil)
        gate.open()
        await request.value
        #expect(phone.tracks.map(\.id) == [1, 2] && phone.canDownloadAll)
        #expect(carPlay.tracks.map(\.id) == [1, 3] && carPlay.canDownloadAll)
        #expect(await store.load(id: 1, scope: "a")?.detail.tracks.map(\.id) == [1, 3])
    }

    @Test func aSupersededForegroundLoadStillHonorsCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlaylistSnapshotStore(directory: root), gate = PlaylistGate()
        defer { gate.open() }
        let first = try response(ids: [1, 2], loaded: [1])
        let second = try response(ids: [3], loaded: [3])
        let phone = PlaylistContent(playlistID: 1, snapshots: store, accountScope: { "a" },
            detailLoader: { _ in first }, tracksLoader: { chunk in
                await gate.wait()
                return .init(songs: try response(ids: chunk, loaded: chunk).playlist.tracks, privileges: [])
            })
        let request = Task { await phone.load() }
        for _ in 0..<200 where !gate.entered { try await Task.sleep(for: .milliseconds(5)) }
        #expect(gate.entered)
        let carPlay = PlaylistContent(playlistID: 1, snapshots: store, accountScope: { "a" },
            detailLoader: { _ in second })
        await carPlay.load()
        request.cancel()
        gate.open()
        await request.value
        #expect(phone.tracks.map(\.id) == [1])
        #expect(await store.load(id: 1, scope: "a")?.detail.tracks.map(\.id) == [3])
    }

    @Test func switchingAccountRejectsThePreviousAccountsLateResponse() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-playlist-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlaylistSnapshotStore(directory: root), gate = PlaylistGate()
        defer { gate.open() }
        var scope = "a"
        let data = try response(ids: [1], loaded: [1])
        let model = PlaylistContent(playlistID: 1, snapshots: store, accountScope: { scope }, detailLoader: { _ in
            await gate.wait()
            return data
        })
        let request = Task { await model.load() }
        for _ in 0..<200 where !gate.entered { try await Task.sleep(for: .milliseconds(5)) }
        scope = "b"
        await model.load(allowNetwork: false)
        gate.open()
        await request.value
        #expect(model.tracks.isEmpty && model.detail == nil)
        #expect(await store.load(id: 1, scope: "a") == nil)
        #expect(await store.load(id: 1, scope: "b") == nil)
    }

    @Test func restartingLibrarySyncDoesNotSkipTheCancelledPlaylist() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-playlist-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlaylistSnapshotStore(directory: root), gate = PlaylistGate()
        defer { gate.open() }
        let data = try response(ids: [1, 2], loaded: [1, 2])
        let old = PlaylistContent(playlistID: 1, snapshots: store, accountScope: { "a" }, detailLoader: { _ in
            await gate.wait()
            return data
        })
        let oldRequest = Task { await old.load(background: true) }
        for _ in 0..<200 where !gate.entered { try await Task.sleep(for: .milliseconds(5)) }
        oldRequest.cancel()
        let replacement = PlaylistContent(playlistID: 1, snapshots: store, accountScope: { "a" }, detailLoader: { _ in data })
        await replacement.load(background: true)
        gate.open()
        await oldRequest.value
        #expect(await store.load(id: 1, scope: "a")?.isComplete == true)
        #expect(replacement.tracks.map(\.id) == [1, 2])
    }

    @Test func retryAfterAnInitialFailureRestoresTheDownloadAction() async throws {
        var attempts = 0
        let data = try response(ids: [1, 2], loaded: [1, 2])
        let model = PlaylistContent(playlistID: 1, snapshots: nil, accountScope: { "test" }, detailLoader: { _ in
            attempts += 1
            if attempts == 1 { throw URLError(.timedOut) }
            return data
        })
        await model.load()
        #expect(model.errorMessage != nil && !model.isLoading && !model.canDownloadAll)
        await model.load()
        #expect(model.errorMessage == nil && model.canDownloadAll)
        let removed = try #require(model.tracks.first)
        await model.remove(removed)
        #expect(model.tracks.map(\.id) == [2])
        #expect(model.detail?.trackIds.map(\.id) == [2] && model.detail?.trackCount == 1)
        #expect(model.canDownloadAll)
    }

    @Test func removalDuringPaginationKeepsDownloadReady() async throws {
        let gate = PlaylistGate()
        defer { gate.open() }
        let data = try response(ids: [1, 2, 3], loaded: [1, 2])
        let third = try response(ids: [3], loaded: [3]).playlist.tracks[0]
        let model = PlaylistContent(playlistID: 1, snapshots: nil, accountScope: { "test" }, detailLoader: { _ in data }, tracksLoader: { ids in
            #expect(ids == [3])
            await gate.wait()
            return .init(songs: [third], privileges: [])
        })
        let loading = Task { await model.load() }
        for _ in 0..<200 where !gate.entered { try await Task.sleep(for: .milliseconds(5)) }
        #expect(gate.entered && !model.canDownloadAll)
        await model.remove(data.playlist.tracks[0])
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
        let model = PlaylistContent(playlistID: 1, snapshots: nil, accountScope: { "test" }, detailLoader: { _ in
            calls += 1
            if calls == 2 { await gate.wait() }
            return data
        })
        await model.load()
        let reload = Task { await model.load() }
        for _ in 0..<200 where !gate.entered { try await Task.sleep(for: .milliseconds(5)) }
        #expect(gate.entered)
        await model.remove(data.playlist.tracks[0])
        gate.open()
        await reload.value
        #expect(model.tracks.map(\.id) == [2] && model.detail?.trackIds.map(\.id) == [2])
        #expect(model.canDownloadAll)
    }

    @Test(arguments: [false, true])
    func anOlderRequestCannotReplaceARetriedPlaylist(persisted: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = persisted ? PlaylistSnapshotStore(directory: root) : nil
        let gate = PlaylistGate()
        defer { gate.open() }
        var calls = 0
        let old = try response(ids: [1], loaded: [1]), new = try response(ids: [2], loaded: [2])
        let model = PlaylistContent(playlistID: 1, snapshots: store, accountScope: { "test" }, detailLoader: { _ in
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
        if let store { #expect(await store.load(id: 1, scope: "test")?.detail.tracks.map(\.id) == [2]) }
    }

    @Test func aFailedPageCanBeRetried() async throws {
        var failPage = true
        let data = try response(ids: [1, 2], loaded: [1]), second = try response(ids: [2], loaded: [2]).playlist.tracks[0]
        let model = PlaylistContent(playlistID: 1, snapshots: nil, accountScope: { "test" }, detailLoader: { _ in data }, tracksLoader: { _ in
            if failPage { throw URLError(.networkConnectionLost) }
            return .init(songs: [second], privileges: [])
        })
        await model.load()
        #expect(model.errorMessage != nil && !model.isLoadingMore && !model.canDownloadAll)
        failPage = false
        await model.load()
        #expect(model.errorMessage == nil && model.canDownloadAll)
    }

    @Test(arguments: [false, true])
    func recommendationReplacementSurvivesPagination(persisted: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = persisted ? PlaylistSnapshotStore(directory: root) : nil
        let gate = PlaylistGate()
        defer { gate.open() }
        let first = try response(ids: [1, 2], loaded: [1])
        let replacement = try response(ids: [3], loaded: [3]).playlist.tracks[0]
        let model = PlaylistContent(playlistID: 1, snapshots: store, accountScope: { "a" },
            detailLoader: { _ in first }, tracksLoader: { chunk in
                await gate.wait()
                return .init(songs: try response(ids: chunk, loaded: chunk).playlist.tracks, privileges: [])
            })
        let request = Task { await model.load() }
        for _ in 0..<200 where !gate.entered { try await Task.sleep(for: .milliseconds(5)) }
        #expect(gate.entered)
        await model.replaceRecommendation(first.playlist.tracks[0], with: replacement)?.value
        gate.open()
        await request.value
        #expect(model.tracks.map(\.id) == [3, 2])
        #expect(model.detail?.trackIds.map(\.id) == [3, 2] && model.canDownloadAll)
        if let store {
            let saved = await store.load(id: 1, scope: "a")
            #expect(saved?.detail.tracks.map(\.id) == [3, 2] && saved?.isComplete == true)
        }
    }

    @Test func recommendationReplacementSurvivesOfflineReloadAndReopening() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlaylistSnapshotStore(directory: root)
        let original = try response(ids: [1, 2], loaded: [1, 2])
        let replacement = try response(ids: [3], loaded: [3]).playlist.tracks[0]
        let model = PlaylistContent(playlistID: 1, snapshots: store, accountScope: { "a" },
            detailLoader: { _ in original })
        await model.load()
        let persistence = model.replaceRecommendation(original.playlist.tracks[0], with: replacement)
        // A network change can reload this view before the mutation reaches disk.
        await model.load(allowNetwork: false)
        #expect(model.tracks.map(\.id) == [3, 2] && model.canDownloadAll)
        await persistence?.value
        let reopened = PlaylistContent(playlistID: 1, snapshots: store, accountScope: { "a" })
        await reopened.load(allowNetwork: false)
        #expect(reopened.tracks.map(\.id) == [3, 2] && reopened.canDownloadAll)
        #expect(await store.load(id: 1, scope: "a")?.isComplete == true)
        #expect(await store.load(id: 1, scope: "b") == nil)
    }

    @Test func repeatedRecommendationReplacementsRespectRefreshMembershipAndAccountChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlaylistSnapshotStore(directory: root)
        var latest = try response(ids: [1, 2], loaded: [1, 2])
        let first = latest.playlist.tracks[0]
        let third = try response(ids: [3], loaded: [3]).playlist.tracks[0]
        let fourth = try response(ids: [4], loaded: [4]).playlist.tracks[0]
        var scope = "a"
        let model = PlaylistContent(playlistID: 1, snapshots: store, accountScope: { scope },
            detailLoader: { _ in latest })
        await model.load()
        await model.replaceRecommendation(first, with: third)?.value
        await model.replaceRecommendation(third, with: fourth)?.value
        // A refresh can still contain a rejected entry, or already include its replacement.
        latest = try response(ids: [1, 3, 2], loaded: [1, 3, 2])
        await model.load()
        #expect(model.tracks.map(\.id) == [4, 2] && model.canDownloadAll)
        #expect(await store.load(id: 1, scope: "a")?.isComplete == true)
        // A genuinely changed server list remains authoritative for membership.
        latest = try response(ids: [2, 5], loaded: [2, 5])
        await model.load()
        #expect(model.tracks.map(\.id) == [2, 5] && model.canDownloadAll)
        scope = "b"
        latest = try response(ids: [1, 2], loaded: [1, 2])
        await model.load()
        #expect(model.tracks.map(\.id) == [1, 2] && model.canDownloadAll)
        #expect(await store.load(id: 1, scope: "a")?.detail.tracks.map(\.id) == [2, 5])
    }

    @Test func anotherRefreshCannotPersistARejectedRecommendationAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlaylistSnapshotStore(directory: root), gate = PlaylistGate()
        defer { gate.open() }
        let original = try response(ids: [1, 2], loaded: [1, 2])
        let replacement = try response(ids: [3], loaded: [3]).playlist.tracks[0]
        let opened = PlaylistContent(playlistID: 1, snapshots: store, accountScope: { "a" },
            detailLoader: { _ in original })
        await opened.load()
        let refreshing = PlaylistContent(playlistID: 1, snapshots: store, accountScope: { "a" }, detailLoader: { _ in
            await gate.wait()
            return original
        })
        let request = Task { await refreshing.load() }
        for _ in 0..<200 where !gate.entered { try await Task.sleep(for: .milliseconds(5)) }
        #expect(gate.entered)
        await opened.replaceRecommendation(original.playlist.tracks[0], with: replacement)?.value
        gate.open()
        await request.value
        let saved = await store.load(id: 1, scope: "a")
        #expect(saved?.detail.tracks.map(\.id) == [3, 2] && saved?.isComplete == true)
    }
}
