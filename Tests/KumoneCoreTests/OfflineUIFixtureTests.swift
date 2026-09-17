import Foundation
import Testing
@testable import KumoneCore

/// Creates synthetic data for a separately bundled debug app. No real login
/// or library is read, and the fixture app disables all NetEase API requests.
@Suite("Offline UI fixtures")
struct OfflineUIFixtureTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KUMONE_UI_FIXTURE_ROOT"] != nil))
    func writeFixture() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["KUMONE_UI_FIXTURE_ROOT"]))
        let client = NeteaseClient(cookieDirectory: root)
        client.setCookies(["MUSIC_U": "synthetic-offline-ui-session"])
        let profile = try JSONDecoder().decode(UserProfile.self, from: Data("{\"userId\":12345,\"nickname\":\"离线体验测试\",\"vipType\":11}".utf8))
        try AccountSnapshotStorage(url: root.appendingPathComponent("account-snapshot.json")).save(
            .init(authenticationFingerprint: try #require(client.authenticationFingerprint), profile: profile,
                  likedTrackIDs: [1], playlists: [], savedAt: Date()))
        let scope = "netease:12345"
        let store = OfflineStore(directory: root.appendingPathComponent("Offline"), minimumFreeBytes: 0)
        let metadata = OfflineMetadataStore(directory: root.appendingPathComponent("Offline/metadata"))
        func track(_ id: Int, _ name: String) throws -> Track {
            try JSONDecoder().decode(Track.self, from: Data("""
            {"id":\(id),"name":"\(name)","dt":3000,"ar":[{"id":1,"name":"Kumone 测试音频"}],"al":{"id":1,"name":"测试歌单","picUrl":"https://example.test/cover.png"}}
            """.utf8))
        }
        let tracks = try [track(1, "地铁离线播放 · 測試曲"), track(2, "等待继续下载的歌曲"), track(3, "需要重试的歌曲"), track(4, "已缓存的歌曲")]
        var catalog = DownloadCatalog()
        catalog.revision = 1
        for (index, track) in tracks.enumerated() {
            try await metadata.save(track: track, scope: scope)
            var job = DownloadJob(scope: scope, track: track, quality: "exhigh", owner: "playlist:987", allowsMetered: false)
            if index == 0 || index == 3 {
                let fixture = try OfflineAudioFixture()
                let descriptor = OfflineAudioDescriptor(identity: .init(accountScope: scope, trackID: track.id, source: "netease", quality: "exhigh", format: .mp3,
                    contentMD5: fixture.descriptor.identity.contentMD5), byteCount: fixture.descriptor.byteCount, duration: 3)
                let input = root.appendingPathComponent("fixture-\(track.id).mp3")
                try fixture.data.write(to: input)
                try await store.importDownload(at: input, descriptor: descriptor)
                if index == 0 { try await store.retain(id: descriptor.identity.id, owner: job.retentionOwner) }
                job.descriptor = descriptor
                job.assetID = descriptor.identity.id
                job.status = .complete
                job.receivedBytes = descriptor.byteCount
                job.expectedBytes = descriptor.byteCount
                job.metadataPending = false
                let lyrics = try JSONDecoder().decode(LyricResponse.self, from: Data("{\"lrc\":{\"lyric\":\"[00:00.00]离线也能听见音乐\\n[00:01.00]次の駅へ\"}}".utf8))
                try await metadata.save(lyrics: lyrics, trackID: track.id, scope: scope)
                if let coverPath = ProcessInfo.processInfo.environment["KUMONE_UI_FIXTURE_COVER"] {
                    try await metadata.saveArtwork(Data(contentsOf: URL(fileURLWithPath: coverPath)), url: URL(string: "https://example.test/cover.png")!, scope: scope)
                }
            } else if index == 1 {
                job.status = .paused
                job.receivedBytes = 5_200_000
                job.expectedBytes = 20_300_000
            } else {
                job.status = .failed
                job.errorMessage = "音频校验失败，请重试"
            }
            if index < 3 { catalog.jobs.append(job) }
        }
        catalog.collections = [.init(id: "playlist:987", accountScope: scope, name: "离线测试歌单", tracks: Array(tracks.prefix(3)), savedAt: Date())]
        try await DownloadCatalogStore(directory: root.appendingPathComponent("Offline/downloads")).save(catalog)
        if let source = ProcessInfo.processInfo.environment["KUMONE_UI_AUTOMATIC_SOURCE"], let url = URL(string: source) {
            let fixture = try OfflineAudioFixture()
            let cover = url.deletingLastPathComponent().appendingPathComponent("cover.png").absoluteString
            let autoTrack = try JSONDecoder().decode(Track.self, from: JSONSerialization.data(withJSONObject: [
                "id": 6, "name": "自动缓存 · 离线验证", "dt": 3000,
                "ar": [["id": 1, "name": "Kumone 测试音频"]],
                "al": ["id": 6, "name": "当前歌曲自动缓存", "picUrl": cover]
            ]))
            let api = root.appendingPathComponent("api-fixtures")
            try FileManager.default.createDirectory(at: api, withIntermediateDirectories: true)
            let song: [String: Any] = ["id": 6, "url": source, "code": 200, "level": "exhigh", "type": "mp3",
                                       "size": fixture.data.count, "time": 3000, "md5": fixture.descriptor.identity.contentMD5]
            for (name, body) in ["_eapi_song_enhance_player_url_v1": ["data": [song]],
                                 "_eapi_song_enhance_download_url_v1": ["data": song]] as [String: [String: Any]] {
                try JSONSerialization.data(withJSONObject: body).write(to: api.appendingPathComponent(name + ".json"))
            }
            let lyric = ["lrc": ["lyric": "[00:00.00]边听边存\n[00:01.00]断网后继续听"]]
            for name in ["_weapi_song_lyric_v1", "_weapi_song_lyric"] {
                try JSONSerialization.data(withJSONObject: lyric).write(to: api.appendingPathComponent(name + ".json"))
            }
            let session = PlaybackSessionSnapshot(sessionID: UUID(), accountScope: scope, queue: [autoTrack], shuffledQueue: [],
                playNextList: [], fmUpcoming: [], currentIndex: 0, currentTrack: autoTrack, progress: 0, source: .none,
                repeatMode: "one", shuffle: false, isFM: false, recentContexts: [])
            try await PlaybackSessionStore(directory: root.appendingPathComponent("playback-sessions")).save(session, revision: 1)
        }
    }
}
