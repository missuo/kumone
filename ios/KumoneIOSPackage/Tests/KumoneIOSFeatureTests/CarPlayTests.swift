#if canImport(CarPlay) && os(iOS)
import Testing
import CarPlay
import UIKit
@testable import KumoneCore

@Suite("CarPlay personal content cache")
@MainActor struct CarPlayPersonalContentTests {
    @Test func reconnectUsesCachedListsIncludingEmptyResults() async {
        var calls = 0
        let store = CarPlayContentStore(resolveTracks: { _ in calls += 1; return [] }, isOnline: { true })
        await store.fetchDailyTracks(loggedIn: true)
        await store.fetchRecentsTracks(loggedIn: true)
        await store.fetchCloudTracks(loggedIn: true)
        let reconnect = store.copyForReload()
        await reconnect.fetchDailyTracks(loggedIn: true)
        await reconnect.fetchRecentsTracks(loggedIn: true)
        await reconnect.fetchCloudTracks(loggedIn: true)
        #expect(calls == 3)
        await reconnect.fetchDailyTracks(loggedIn: true, force: true)
        #expect(calls == 4)
        await reconnect.fetchCloudTracks(loggedIn: false)
        await reconnect.fetchCloudTracks(loggedIn: true)
        #expect(calls == 5)
    }

    @Test func offlineFallbackDoesNotDelayOnlineRefresh() async throws {
        var online = false, calls = 0
        let track = try JSONDecoder().decode(Track.self, from: Data("{\"id\":1,\"name\":\"Local\"}".utf8))
        let store = CarPlayContentStore(resolveTracks: { _ in calls += 1; return online ? [track, track] : [track] },
                                       isOnline: { online })
        await store.fetchDailyTracks(loggedIn: true)
        #expect(store.dailyTracks.count == 1)
        online = true
        let reconnect = store.copyForReload()
        await reconnect.fetchDailyTracks(loggedIn: true)
        #expect(reconnect.dailyTracks.count == 2 && calls == 2)
    }

    @Test func expiredCacheReloads() async {
        var calls = 0
        let store = CarPlayContentStore(ttl: 0, resolveTracks: { _ in calls += 1; return [] }, isOnline: { true })
        await store.fetchDailyTracks(loggedIn: true)
        await store.fetchDailyTracks(loggedIn: true)
        #expect(calls == 2)
    }
}

/// Covers the playback-queue template that backs CarPlay's Up Next button.
///
/// The rest of the CarPlay stack (CarPlayConnector) drives CPInterfaceController and
/// CPNowPlayingTemplate.shared, neither of which can be instantiated outside a live CarPlay
/// scene, so it is exercised on-device rather than here. `queueTemplate` is deliberately a
/// pure function of player state so this part stays unit-testable.
@Suite("CarPlay queue template")
struct CarPlayQueueTemplateTests {
    @Test("Repeated queue rows retain their occurrence and complete the selection")
    @MainActor
    func repeatedTrackSelectsTheTappedOccurrence() throws {
        let track = try makeTrack(id: 7, name: "Repeated", artist: "Artist", album: "Album")
        var selected: Int?, completed = false
        let template = CarPlayTemplateFactory.queueTemplate(current: nil, upcoming: [track, track],
            onCurrentTap: {}, onTrackTap: { index, chosen in selected = index; #expect(chosen.id == 7) })
        let item = try #require(template.sections[0].items[1] as? CPListItem)
        item.handler?(item, { completed = true })
        #expect(selected == 1 && completed)
    }

    @Test("The pinned current song shares the vehicle's item limit")
    @MainActor
    func currentSongIsIncludedInTheItemLimit() throws {
        let track = try makeTrack(id: 7, name: "Track", artist: "Artist", album: "Album")
        let template = CarPlayTemplateFactory.queueTemplate(current: track,
            upcoming: Array(repeating: track, count: CPListTemplate.maximumItemCount + 10),
            onCurrentTap: {}, onTrackTap: { _, _ in })
        #expect(template.sections.reduce(0) { $0 + $1.items.count } <= CPListTemplate.maximumItemCount)
    }

    @Test("Track selection passes the complete loaded list without fetching it again")
    @MainActor
    func loadedListStaysAvailableToPlayback() throws {
        let tracks = try (1...305).map { try makeTrack(id: $0, name: "Track \($0)", artist: "Artist", album: "Album") }
        var selected: [Track] = [], playedAll = false
        let template = CarPlayTemplateFactory.trackListTemplate(title: "Loaded", trackCount: tracks.count, tracks: tracks,
            onPlayAll: { playedAll = true }, onTrackTap: { _, all in selected = all })
        let item = try #require(template.sections[1].items.first as? CPListItem)
        item.handler?(item, {})
        let playAll = try #require(template.sections[0].items.first as? CPListItem)
        playAll.handler?(playAll, {})
        #expect(selected.map(\.id) == tracks.map(\.id) && playedAll)
    }

    private func makeTrack(id: Int, name: String, artist: String, album: String) throws -> Track {
        let json = """
        {
            "id": \(id),
            "name": "\(name)",
            "artists": [{"id": 1, "name": "\(artist)"}],
            "album": {"id": 10, "name": "\(album)"},
            "duration": 226000
        }
        """.data(using: .utf8)!
        return try JSONDecoder().decode(Track.self, from: json)
    }

    @Test("Pins the current track in its own section and lists what's next")
    @MainActor
    func buildsCurrentAndUpcomingSections() throws {
        let current = try makeTrack(id: 1, name: "夜曲", artist: "周杰伦", album: "十一月的萧邦")
        let next = try makeTrack(id: 2, name: "晴天", artist: "周杰伦", album: "叶惠美")

        let template = CarPlayTemplateFactory.queueTemplate(
            current: current,
            upcoming: [next],
            onCurrentTap: {},
            onTrackTap: { _, _ in }
        )

        #expect(template.sections.count == 2)

        let currentSection = template.sections[0]
        #expect(currentSection.header == "正在播放")
        #expect(currentSection.items.count == 1)

        let currentItem = try #require(currentSection.items.first as? CPListItem)
        #expect(currentItem.text == "夜曲")
        #expect(currentItem.detailText == "周杰伦")
        // The pinned row is the only one flagged as playing, so the driver can tell at a
        // glance which entry is live.
        #expect(currentItem.isPlaying == true)

        let upcomingSection = template.sections[1]
        #expect(upcomingSection.header == "即将播放 · 1 首")
        let nextItem = try #require(upcomingSection.items.first as? CPListItem)
        #expect(nextItem.text == "晴天")
        #expect(nextItem.isPlaying == false)
    }

    @Test("Tapping an upcoming row reports the track that was picked")
    @MainActor
    func upcomingRowForwardsItsTrack() throws {
        let first = try makeTrack(id: 2, name: "晴天", artist: "周杰伦", album: "叶惠美")
        let second = try makeTrack(id: 3, name: "稻香", artist: "周杰伦", album: "魔杰座")
        var picked: Track?

        let template = CarPlayTemplateFactory.queueTemplate(
            current: nil,
            upcoming: [first, second],
            onCurrentTap: {},
            onTrackTap: { _, track in picked = track }
        )

        // No current track → only the upcoming section is built.
        #expect(template.sections.count == 1)

        let item = try #require(template.sections[0].items[1] as? CPListItem)
        item.handler?(item, {})
        #expect(picked?.id == second.id)
    }

    @Test("Caps very long queues at CarPlay's limit but still reports the true count")
    @MainActor
    func capsQueueLength() throws {
        let total = CPListTemplate.maximumItemCount + 120
        let tracks = try (0..<total).map { try makeTrack(id: $0, name: "曲目\($0)", artist: "歌手", album: "专辑") }

        let template = CarPlayTemplateFactory.queueTemplate(
            current: nil,
            upcoming: tracks,
            onCurrentTap: {},
            onTrackTap: { _, _ in }
        )

        // Anything past the framework limit is dropped by CarPlay itself, so the template must
        // not rely on a hand-picked cap.
        #expect(template.sections[0].items.count == CPListTemplate.maximumItemCount)
        // ...but the header still tells the driver how long the queue really is.
        #expect(template.sections[0].header == "即将播放 · \(total) 首")
    }

    @Test("Shows an empty-state message when nothing is queued")
    @MainActor
    func emptyQueue() {
        let template = CarPlayTemplateFactory.queueTemplate(
            current: nil,
            upcoming: [],
            onCurrentTap: {},
            onTrackTap: { _, _ in }
        )

        #expect(template.sections.isEmpty)
        #expect(template.emptyViewTitleVariants == ["当前没有播放队列"])
    }
}
#endif
