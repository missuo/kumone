// CarPlayTemplateFactory.swift — Stateless CarPlay template builder.
// Converts data models into CarPlay template elements, kept fully decoupled from data loading and lifecycle logic.

#if os(iOS)
import CarPlay
import UIKit

/// Stateless factory that builds CarPlay templates.
enum CarPlayTemplateFactory {

    // MARK: - Playlist row → CPListSection

    /// Converts Recommend/Curated playlists into a CPListSection; tapping a row pushes the playlist detail.
    /// `header` is optional — the Library tab's "Created Playlists" / "Subscribed Playlists" sections need a header.
    static func playlistSections(
        _ playlists: [PlaylistSummary],
        onPlaylistTap: @escaping (PlaylistSummary) -> Void,
        header: String? = nil
    ) -> [CPListSection] {
        let items = playlists.map { playlist -> CPListItem in
            let item = CPListItem(text: playlist.name, detailText: playlist.playCount > 0 ? "\(formattedCount(playlist.playCount))次播放" : nil)
            item.accessoryType = .none
            item.handler = { _, completion in
                onPlaylistTap(playlist)
                completion()
            }
            // Async-load the cover image; the row refreshes itself when it lands.
            fillArtwork(item, from: playlist.coverURL)
            return item
        }
        return [CPListSection(items: items, header: header, sectionIndexTitle: nil)]
    }

    // MARK: - Toplist row → CPListSection

    /// Converts the toplist array into a CPListSection.
    static func toplistSections(
        _ items: [ToplistItem],
        onToplistTap: @escaping (ToplistItem) -> Void
    ) -> [CPListSection] {
        let listItems = items.map { toplist -> CPListItem in
            let item = CPListItem(text: toplist.name, detailText: toplist.updateFrequency)
            item.accessoryType = .none
            item.handler = { _, completion in
                onToplistTap(toplist)
                completion()
            }
            fillArtwork(item, from: toplist.coverImgUrl)
            return item
        }
        return [CPListSection(items: listItems)]
    }

    // MARK: - Playlist detail (track list)

    /// Builds the playlist detail template: "Play All" row + track rows.
    static func playlistDetailTemplate(
        playlist: PlaylistSummary,
        tracks: [Track],
        onPlayAll: @escaping () -> Void,
        onTrackTap: @escaping (Track, [Track]) -> Void
    ) -> CPListTemplate {
        return trackListTemplate(
            title: playlist.name,
            trackCount: tracks.count,
            tracks: tracks,
            onPlayAll: onPlayAll,
            onTrackTap: onTrackTap
        )
    }

    // MARK: - Toplist detail template

    /// Toplist detail, built standalone (`PlaylistSummary` has no memberwise init, so we can't reuse the helper above).
    static func toplistDetailTemplate(
        toplist: ToplistItem,
        tracks: [Track],
        onPlayAll: @escaping () -> Void,
        onTrackTap: @escaping (Track, [Track]) -> Void
    ) -> CPListTemplate {
        return trackListTemplate(
            title: toplist.name,
            trackCount: tracks.count,
            tracks: tracks,
            onPlayAll: onPlayAll,
            onTrackTap: onTrackTap
        )
    }

    // MARK: - Generic track-list template

    /// Generic "Play All" + track rows builder. Kept internal so `CarPlayConnector.pushLibraryEntry` can reuse it.
    static func trackListTemplate(
        title: String,
        trackCount: Int,
        tracks: [Track],
        onPlayAll: @escaping () -> Void,
        onTrackTap: @escaping (Track, [Track]) -> Void
    ) -> CPListTemplate {
        let playAllItem = CPListItem(text: "播放全部 · \(trackCount) 首", detailText: nil)
        playAllItem.accessoryType = .none
        playAllItem.handler = { _, completion in
            onPlayAll()
            completion()
        }

        let cappedTracks = Array(tracks.prefix(300))
        let trackItems = cappedTracks.map { track -> CPListItem in
            let item = CPListItem(text: track.name, detailText: track.artistNames)
            item.accessoryType = .none
            item.handler = { _, completion in
                onTrackTap(track, tracks)
                completion()
            }
            return item
        }

        let sections = [
            CPListSection(items: [playAllItem]),
            CPListSection(items: trackItems),
        ]
        let template = CPListTemplate(title: title, sections: sections)
        template.emptyViewTitleVariants = ["暂无曲目"]
        return template
    }

    // MARK: - Playback queue

    /// Builds the "Up Next" list shown when the driver taps the Now Playing queue button.
    ///
    /// CarPlay's own up-next UI is only wired up for `MPPlayableContentManager`-era apps;
    /// template apps get an empty button unless they push their own list, which is what this
    /// template is for. The current track is pinned in its own section so the driver can see
    /// what's playing without hunting through the queue, and tapping any upcoming row jumps
    /// straight to that occurrence in the shared phone queue.
    ///
    /// - Parameters:
    ///   - current: The playing track, or nil when nothing is loaded.
    ///   - upcoming: `PlayerService.upcomingTracks` — already ordered and shuffle-aware.
    ///   - onCurrentTap: Invoked when the pinned "now playing" row is tapped.
    ///   - onTrackTap: Invoked with the upcoming row's index and track.
    static func queueTemplate(
        current: Track?,
        upcoming: [Track],
        onCurrentTap: @escaping () -> Void,
        onTrackTap: @escaping (Int, Track) -> Void
    ) -> CPListTemplate {
        var sections: [CPListSection] = []

        if let current {
            let item = CPListItem(text: current.name, detailText: current.artistNames)
            item.accessoryType = .none
            item.isPlaying = true
            item.handler = { _, completion in
                onCurrentTap()
                completion()
            }
            fillArtwork(item, from: current.album.picUrl)
            sections.append(CPListSection(items: [item], header: "正在播放", sectionIndexTitle: nil))
        }

        if !upcoming.isEmpty {
            // CarPlay silently drops anything past CPListTemplate.maximumItemCount, so cap
            // explicitly at the framework's own limit rather than a guessed number — a NetEase
            // queue is routinely longer than that. The section header still reports the real
            // total so the driver can tell the list is partial.
            let limit = max(0, CPListTemplate.maximumItemCount - (current == nil ? 0 : 1))
            let items = upcoming.prefix(limit).enumerated().map { index, track -> CPListItem in
                let item = CPListItem(text: track.name, detailText: track.artistNames)
                item.accessoryType = .none
                item.handler = { _, completion in
                    onTrackTap(index, track)
                    completion()
                }
                return item
            }
            sections.append(
                CPListSection(items: items, header: "即将播放 · \(upcoming.count) 首", sectionIndexTitle: nil)
            )
        }

        let template = CPListTemplate(title: "播放队列", sections: sections)
        template.emptyViewTitleVariants = ["当前没有播放队列"]
        return template
    }

    // MARK: - Async artwork loading

    /// Async-loads the cover image into a `CPListItem` and refreshes the row once it lands.
    static func fillArtwork(_ item: CPListItem, from coverURL: String?) {
        guard let urlStr = coverURL, let url = urlStr.resizedImageURL(120) else { return }
        Task { @MainActor in
            guard let image = await ImageCache.shared.image(for: url, onCachedImage: { item.setImage($0) }) else { return }
            item.setImage(image)
        }
    }

    // MARK: - Formatting

    /// Compact play-count formatter that returns Chinese-locale units when the count is large enough; smaller values are returned as a plain integer.
    private static func formattedCount(_ count: Int) -> String {
        if count >= 100_000_000 { return "\(count / 100_000_000)亿" }
        if count >= 10_000 { return "\(Double(count) / 10_000, default: "%.1f")万" }
        return "\(count)"
    }
}

// MARK: - FM tab

extension CarPlayTemplateFactory {
    /// Builds the sections for the FM (Roaming) tab.
    ///
    /// When FM mode is off we just show a single "Start Roaming" button to kick
    /// things off. When FM mode is on we lead with the currently playing track
    /// (assuming we already have one loaded) so the driver can see at a glance
    /// what they're listening to — that's the "Now Roaming" row. If FM is on but
    /// the first track hasn't loaded yet (we're still talking to NetEase),
    /// we drop in a small "Preparing roaming…" placeholder so the tab doesn't look
    /// broken in the meantime.
    ///
    /// Below the track row sits the action button, which does double duty:
    /// while playing it reads "Next" and jumps to the next recommendation,
    /// and while paused (but with a loaded track) it reads "Resume Roaming" and
    /// resumes from the same spot via `togglePlayPause`.
    static func fmSection(
        isFMMode: Bool,
        isPlaying: Bool,
        currentTrack: Track?,
        onActionTap: @escaping () -> Void
    ) -> [CPListSection] {
        var sections: [CPListSection] = []

        // The currently playing track — purely informational. Tapping it is a
        // no-op because CarPlay's system Now Playing template already shows
        // the song with full transport controls.
        if isFMMode {
            if let track = currentTrack {
                let trackItem = CPListItem(text: track.name, detailText: track.artistNames)
                trackItem.accessoryType = .none
                trackItem.setImage(UIImage(systemName: "dot.radiowaves.left.and.right"))
                trackItem.handler = { _, completion in
                    completion()
                }
                sections.append(CPListSection(
                    items: [trackItem],
                    header: "正在漫游",
                    sectionIndexTitle: nil
                ))
            } else {
                let placeholder = CPListItem(text: "正在准备漫游…", detailText: nil)
                placeholder.accessoryType = .none
                placeholder.handler = { _, completion in completion() }
                sections.append(CPListSection(
                    items: [placeholder],
                    header: "正在漫游",
                    sectionIndexTitle: nil
                ))
            }
        }

        // The action button section — one row that changes its label and icon
        // depending on whether FM is on and whether we're playing.
        let actionItem: CPListItem
        if isFMMode {
            actionItem = CPListItem(
                text: isPlaying ? "换一首" : "继续漫游",
                detailText: nil
            )
            actionItem.setImage(UIImage(systemName: isPlaying ? "forward.fill" : "play.fill"))
        } else {
            actionItem = CPListItem(
                text: "开始漫游",
                detailText: "根据你的口味生成连续推荐"
            )
            actionItem.setImage(UIImage(systemName: "dot.radiowaves.left.and.right"))
        }
        actionItem.accessoryType = .none
        actionItem.handler = { _, completion in
            onActionTap()
            completion()
        }
        sections.append(CPListSection(items: [actionItem]))

        return sections
    }
}

// MARK: - Library tab

/// Data snapshot for the Library tab — the caller assembles it from `AccountStore` and passes it to the factory.
struct CarPlayLibraryModel {
    let liked: PlaylistSummary?
    let created: [PlaylistSummary]
    let subscribed: [PlaylistSummary]
    let isLoggedIn: Bool
}

/// Four sub-entries under the "My Music" section, matching the App's IOSLibraryView.
enum CarPlayLibraryEntry {
    case liked, daily, recents, cloud

    var title: String {
        switch self {
        case .liked: return "我喜欢的音乐"
        case .daily: return "每日推荐"
        case .recents: return "最近播放"
        case .cloud: return "音乐云盘"
        }
    }

    var icon: String {
        switch self {
        case .liked: return "heart.fill"
        case .daily: return "calendar"
        case .recents: return "clock.fill"
        case .cloud: return "icloud.fill"
        }
    }
}

extension CarPlayTemplateFactory {
    /// Builds the Library tab's sections: My Music + Created Playlists + Subscribed Playlists.
    /// Returns `[]` when logged out — the caller is responsible for showing the empty view.
    static func librarySections(
        library: CarPlayLibraryModel,
        onEntryTap: @escaping (CarPlayLibraryEntry) -> Void,
        onPlaylistTap: @escaping (PlaylistSummary) -> Void
    ) -> [CPListSection] {
        guard library.isLoggedIn else { return [] }

        var myMusicItems: [CPListItem] = []
        if library.liked != nil {
            myMusicItems.append(makeEntryItem(.liked, onTap: onEntryTap))
        }
        myMusicItems.append(makeEntryItem(.daily, onTap: onEntryTap))
        myMusicItems.append(makeEntryItem(.recents, onTap: onEntryTap))
        myMusicItems.append(makeEntryItem(.cloud, onTap: onEntryTap))

        var sections: [CPListSection] = [
            CPListSection(items: myMusicItems, header: "我的音乐", sectionIndexTitle: nil)
        ]

        if !library.created.isEmpty {
            sections.append(contentsOf: playlistSections(
                library.created,
                onPlaylistTap: onPlaylistTap,
                header: "创建的歌单"
            ))
        }

        if !library.subscribed.isEmpty {
            sections.append(contentsOf: playlistSections(
                library.subscribed,
                onPlaylistTap: onPlaylistTap,
                header: "收藏的歌单"
            ))
        }

        return sections
    }

    /// Single sub-menu item (no cover, just an SF Symbol).
    private static func makeEntryItem(
        _ entry: CarPlayLibraryEntry,
        onTap: @escaping (CarPlayLibraryEntry) -> Void
    ) -> CPListItem {
        let item = CPListItem(text: entry.title, detailText: nil)
        item.accessoryType = .none
        item.setImage(UIImage(systemName: entry.icon))
        item.handler = { _, completion in
            onTap(entry)
            completion()
        }
        return item
    }
}

// MARK: - Recommend tab feature cards

/// Three feature entries in the "Today's Picks" section, matching App HomeView's FeatureCard.
enum CarPlayRecommendFeature {
    case daily, fm, heartbeat

    var title: String {
        switch self {
        case .daily: return "每日推荐"
        case .fm: return "私人漫游"
        case .heartbeat: return "心动模式"
        }
    }

    var detail: String {
        switch self {
        case .daily: return "根据你的口味生成"
        case .fm: return "从喜欢的歌开始漫游"
        case .heartbeat: return "你的红心歌曲和相似推荐"
        }
    }

    var icon: String {
        switch self {
        case .daily: return "calendar"
        case .fm: return "wave.3.right.circle.fill"
        case .heartbeat: return "heart.circle.fill"
        }
    }
}

// MARK: - Radar playlists / new albums / recommended artists

/// Snapshot of the personalized radar playlists; mirrors `HomeView.RadarPlaylist` 1:1.
struct CarPlayRadarPlaylist: Identifiable, Hashable {
    let id: Int
    let title: String
    let subtitle: String?
    let coverURL: String?

    /// Must stay in sync with `HomeViewModel.radarPlaylistIDs`.
    static let ids: [Int] = [
        3_136_952_023, // Personal radar
        2_829_883_282, // Chinese radar
        2_829_816_518, // Western radar
        2_829_896_389, // Japanese radar
    ]
}

extension CarPlayTemplateFactory {
    /// The "Today's Picks" section at the top of the Recommend tab — three feature entry rows.
    /// Only shown when logged in; the caller skips this section otherwise.
    static func recommendFeatureSections(
        onTap: @escaping (CarPlayRecommendFeature) -> Void
    ) -> [CPListSection] {
        let items = [
            makeFeatureItem(.daily, onTap: onTap),
            makeFeatureItem(.fm, onTap: onTap),
            makeFeatureItem(.heartbeat, onTap: onTap),
        ]
        return [CPListSection(items: items, header: "今日推荐", sectionIndexTitle: nil)]
    }

    private static func makeFeatureItem(
        _ feature: CarPlayRecommendFeature,
        onTap: @escaping (CarPlayRecommendFeature) -> Void
    ) -> CPListItem {
        let item = CPListItem(text: feature.title, detailText: feature.detail)
        item.accessoryType = .none
        item.setImage(UIImage(systemName: feature.icon))
        item.handler = { _, completion in
            onTap(feature)
            completion()
        }
        return item
    }
}

// MARK: - Radar / new album / top artist sections

extension CarPlayTemplateFactory {
    /// Radar playlist section: one `CPListItem` per radar (with cover), tapping opens the playlist detail.
    static func radarPlaylistSections(
        _ radars: [CarPlayRadarPlaylist],
        onTap: @escaping (CarPlayRadarPlaylist) -> Void
    ) -> [CPListSection] {
        let items = radars.map { radar -> CPListItem in
            let item = CPListItem(text: radar.title, detailText: radar.subtitle)
            item.accessoryType = .none
            item.handler = { _, completion in
                onTap(radar)
                completion()
            }
            fillArtwork(item, from: radar.coverURL)
            return item
        }
        return [CPListSection(items: items, header: "雷达歌单", sectionIndexTitle: nil)]
    }

    /// New albums section.
    static func newAlbumSections(
        _ albums: [AlbumSummary],
        onTap: @escaping (AlbumSummary) -> Void
    ) -> [CPListSection] {
        let items = albums.map { album -> CPListItem in
            let item = CPListItem(text: album.name, detailText: album.artistName)
            item.accessoryType = .none
            item.handler = { _, completion in
                onTap(album)
                completion()
            }
            fillArtwork(item, from: album.picUrl)
            return item
        }
        return [CPListSection(items: items, header: "新碟上架", sectionIndexTitle: nil)]
    }

    /// Recommended artists section — no cover image, only the circular avatar placeholder that CPListItem renders by default.
    static func topArtistSections(
        _ artists: [ArtistSummary],
        onTap: @escaping (ArtistSummary) -> Void
    ) -> [CPListSection] {
        let items = artists.map { artist -> CPListItem in
            let item = CPListItem(text: artist.name, detailText: nil)
            item.accessoryType = .none
            item.handler = { _, completion in
                onTap(artist)
                completion()
            }
            fillArtwork(item, from: artist.picUrl)
            return item
        }
        return [CPListSection(items: items, header: "推荐歌手", sectionIndexTitle: nil)]
    }
}
#endif
