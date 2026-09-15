import Foundation
import Testing
@testable import KumoneCore

@Suite("Offline display and session persistence")
struct OfflineSessionTests {
    private func track(_ id: Int) throws -> Track {
        try JSONDecoder().decode(Track.self, from: Data("""
        {"id":\(id),"name":"Track","dt":3000,"pc":{},"noCopyrightRcmd":{},"privilege":{"id":\(id),"cs":true}}
        """.utf8))
    }

    @Test func preservesPrivateCloudAndPrivilegeFields() throws {
        let original = try track(1)
        let decoded = try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        #expect(decoded.isCloud && decoded.noCopyright && decoded.embeddedPrivilege?.cs == true)
    }

    @Test func accountSnapshotRequiresTheSameLogin() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-account-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = AccountSnapshotStorage(url: root.appendingPathComponent("account.json"))
        let profile = try JSONDecoder().decode(UserProfile.self, from: Data("{\"userId\":1,\"nickname\":\"Local\"}".utf8))
        let playlist = try JSONDecoder().decode(PlaylistSummary.self, from: Data("{\"id\":2,\"name\":\"Saved\",\"picUrl\":\"https://example.test/cover\"}".utf8))
        try storage.save(.init(authenticationFingerprint: "login-a", profile: profile, likedTrackIDs: [3, 4], playlists: [playlist], savedAt: Date()))
        #expect(storage.load(fingerprint: "login-a")?.playlists.first?.coverURL == playlist.coverURL)
        #expect(storage.load(fingerprint: "login-b") == nil)
        #expect(storage.load(fingerprint: nil) == nil)
        storage.clear()
        #expect(storage.load(fingerprint: "login-a") == nil)
    }

    @Test func restoresExactQueueAndPositionWithoutCrossingSessions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-session-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlaybackSessionStore(directory: root)
        let first = try track(1), second = try track(2), inserted = try track(3)
        let snapshot = PlaybackSessionSnapshot(sessionID: UUID(), accountScope: "a", queue: [first, second],
            shuffledQueue: [second, first], playNextList: [inserted], fmUpcoming: [], currentIndex: 0,
            currentTrack: second, progress: 0, source: .playlist(9), repeatMode: "all", shuffle: true, isFM: false, recentContexts: [])
        try await store.save(snapshot, revision: 2)
        try await store.savePosition(.init(sessionID: snapshot.sessionID, trackID: 2, progress: 1.25), scope: "a", revision: 3)
        let restored = try #require(store.load(scope: "a"))
        #expect(restored.shuffledQueue.map(\.id) == [2, 1])
        #expect(restored.playNextList.map(\.id) == [3])
        #expect(restored.progress == 1.25)
        #expect(restored.source == .playlist(9))
        #expect(store.load(scope: "b") == nil)
        try await store.savePosition(.init(sessionID: UUID(), trackID: 2, progress: 99), scope: "a", revision: 1)
        #expect(store.load(scope: "a")?.progress == 1.25)
        let next = PlaybackSessionSnapshot(sessionID: UUID(), accountScope: "a", queue: [second], shuffledQueue: [],
            playNextList: [], fmUpcoming: [], currentIndex: 0, currentTrack: second, progress: 0,
            source: .none, repeatMode: "off", shuffle: false, isFM: false, recentContexts: [])
        try await store.save(next, revision: 4)
        try await store.savePosition(.init(sessionID: snapshot.sessionID, trackID: 2, progress: 2), scope: "a", revision: 5)
        #expect(store.load(scope: "a")?.progress == 0)
    }

    @Test func metadataPersistsLyricsAcrossReopening() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-metadata-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OfflineMetadataStore(directory: root)
        let lyrics = try JSONDecoder().decode(LyricResponse.self, from: Data("{\"lrc\":{\"lyric\":\"[00:01.00]Offline lyrics\"},\"tlyric\":{\"lyric\":\"[00:01.00]离线歌词\"}}".utf8))
        try await store.save(track: track(1), scope: "a")
        try await store.save(lyrics: lyrics, trackID: 1, scope: "a")
        let reopened = OfflineMetadataStore(directory: root)
        #expect(await reopened.lyrics(trackID: 1, scope: "a")?.lrc?.lyric == lyrics.lrc?.lyric)
        #expect(await reopened.lyrics(trackID: 1, scope: "b") == nil)
    }

    @Test func offlineArtworkIsIndependentOfThumbnailSizeAndAccount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-artwork-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OfflineMetadataStore(directory: root)
        let data = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a5XkAAAAASUVORK5CYII="))
        let original = URL(string: "http://example.test/cover.png?param=640y640")!
        let thumbnail = URL(string: "https://example.test/cover.png?param=96y96")!
        try await store.saveArtwork(data, url: original, scope: "a")
        #expect(await store.artwork(url: thumbnail, scope: "a") == data)
        #expect(await store.artwork(url: thumbnail, scope: "b") == nil)
    }
}
