// CarPlayContentStore.swift — CarPlay data loading layer.
// Pure data logic with no CarPlay framework dependencies, so it can be unit tested standalone.

#if os(iOS)
import Foundation

/// Backs the CarPlay templates with playlist / toplist / track data.
/// Track lists and discovery data have a short TTL; local playback remains shared with the phone.
@MainActor
final class CarPlayContentStore {

    // MARK: - Cached data

    private(set) var recommendPlaylists: [PlaylistSummary] = []
    private(set) var highQualityPlaylists: [PlaylistSummary] = []
    private(set) var hotPlaylists: [PlaylistSummary] = []
    private(set) var officialPlaylists: [PlaylistSummary] = []
    private(set) var chinesePlaylists: [PlaylistSummary] = []
    private(set) var toplists: [ToplistItem] = []
    private(set) var dailyTracks: [Track] = []
    private(set) var recentsTracks: [Track] = []
    private(set) var cloudTracks: [Track] = []
    private(set) var radarPlaylists: [CarPlayRadarPlaylist] = []
    private(set) var newAlbums: [AlbumSummary] = []
    private(set) var topArtists: [ArtistSummary] = []

    // MARK: - TTL management

    /// Cache lifetime in seconds.
    private let ttl: TimeInterval

    private var recommendFetchedAt: Date = .distantPast
    private var curatedFetchedAt: Date = .distantPast
    private var officialFetchedAt: Date = .distantPast
    private var chineseFetchedAt: Date = .distantPast
    private var toplistsFetchedAt: Date = .distantPast
    private var radarFetchedAt: Date = .distantPast
    private var albumsFetchedAt: Date = .distantPast
    private var artistsFetchedAt: Date = .distantPast
    private var dailyFetchedAt: Date = .distantPast
    private var recentsFetchedAt: Date = .distantPast
    private var cloudFetchedAt: Date = .distantPast
    private let resolveTracks: (PlayContext) async throws -> [Track]
    private let isOnline: @MainActor () -> Bool

    /// Custom TTL constructor (defaults to 5 minutes; tests can pass a shorter value).
    init(ttl: TimeInterval = 300,
         resolveTracks: @escaping (PlayContext) async throws -> [Track] = { try await PlayerService.shared.resolve($0)?.tracks ?? [] },
         isOnline: @escaping @MainActor () -> Bool = { DownloadManager.shared.network.connected }) {
        self.ttl = ttl
        self.resolveTracks = resolveTracks
        self.isOnline = isOnline
    }

    /// A reload works on its own snapshot, retaining TTLs across network changes.
    func copyForReload() -> CarPlayContentStore {
        let copy = CarPlayContentStore(ttl: ttl, resolveTracks: resolveTracks, isOnline: isOnline)
        copy.recommendPlaylists = recommendPlaylists
        copy.highQualityPlaylists = highQualityPlaylists
        copy.hotPlaylists = hotPlaylists
        copy.officialPlaylists = officialPlaylists
        copy.chinesePlaylists = chinesePlaylists
        copy.toplists = toplists
        copy.dailyTracks = dailyTracks
        copy.recentsTracks = recentsTracks
        copy.cloudTracks = cloudTracks
        copy.radarPlaylists = radarPlaylists
        copy.newAlbums = newAlbums
        copy.topArtists = topArtists
        copy.recommendFetchedAt = recommendFetchedAt
        copy.curatedFetchedAt = curatedFetchedAt
        copy.officialFetchedAt = officialFetchedAt
        copy.chineseFetchedAt = chineseFetchedAt
        copy.toplistsFetchedAt = toplistsFetchedAt
        copy.radarFetchedAt = radarFetchedAt
        copy.albumsFetchedAt = albumsFetchedAt
        copy.artistsFetchedAt = artistsFetchedAt
        copy.dailyFetchedAt = dailyFetchedAt
        copy.recentsFetchedAt = recentsFetchedAt
        copy.cloudFetchedAt = cloudFetchedAt
        return copy
    }

    // MARK: - Recommend

    /// Loads the Recommend tab's playlists. Login-aware behavior mirrors
    /// `HomeViewModel.fetchRecommendPlaylists` exactly so the two stay in sync.
    func fetchRecommendPlaylists(loggedIn: Bool, force: Bool = false) async {
        // TTL check
        if !force, Date().timeIntervalSince(recommendFetchedAt) < ttl, !recommendPlaylists.isEmpty { return }

        if loggedIn {
            async let recommend = try? NeteaseAPI.recommendResource()
            async let personalized = try? NeteaseAPI.personalizedPlaylists(limit: 30)
            let head = await recommend ?? []
            let tail = await personalized ?? []
            var seen = Set<Int>()
            recommendPlaylists = (head + tail).filter { seen.insert($0.id).inserted }
        } else {
            recommendPlaylists = (try? await NeteaseAPI.personalizedPlaylists(limit: 30)) ?? []
        }
        recommendFetchedAt = Date()
    }

    // MARK: - Curated

    /// Loads the Curated tab's two main buckets: high-quality and hot playlists.
    func fetchCuratedPlaylists(force: Bool = false) async {
        if !force, Date().timeIntervalSince(curatedFetchedAt) < ttl,
           !highQualityPlaylists.isEmpty, !hotPlaylists.isEmpty { return }

        async let hq = (try? await NeteaseAPI.highQualityPlaylists(limit: 50))?.playlists ?? []
        async let hot = (try? await NeteaseAPI.topPlaylists(category: "全部", limit: 50))?.playlists ?? []
        highQualityPlaylists = await hq
        hotPlaylists = await hot
        curatedFetchedAt = Date()
    }

    // MARK: - Curated sub-categories (mirror App ExploreView's chips)

    /// Official playlists — backs the "Official" chip in the App's Curated tab.
    func fetchOfficialPlaylists(force: Bool = false) async {
        if !force, Date().timeIntervalSince(officialFetchedAt) < ttl, !officialPlaylists.isEmpty { return }
        officialPlaylists = (try? await NeteaseAPI.topPlaylists(category: "官方", limit: 30))?.playlists ?? []
        officialFetchedAt = Date()
    }

    /// Chinese playlists — backs the "Chinese" chip in the App's Curated tab.
    func fetchChinesePlaylists(force: Bool = false) async {
        if !force, Date().timeIntervalSince(chineseFetchedAt) < ttl, !chinesePlaylists.isEmpty { return }
        chinesePlaylists = (try? await NeteaseAPI.topPlaylists(category: "华语", limit: 30))?.playlists ?? []
        chineseFetchedAt = Date()
    }

    // MARK: - Toplists

    /// Loads the toplist (chart) list.
    func fetchToplists(force: Bool = false) async {
        if !force, Date().timeIntervalSince(toplistsFetchedAt) < ttl, !toplists.isEmpty { return }

        toplists = (try? await NeteaseAPI.toplists()) ?? []
        toplistsFetchedAt = Date()
    }

    // MARK: - Daily recommend

    /// Loads the daily-recommend tracks. Login-only — logged-out callers get an
    /// empty array right away so we don't waste a request on a guaranteed 401.
    func fetchDailyTracks(loggedIn: Bool, force: Bool = false) async {
        guard loggedIn else { dailyTracks = []; dailyFetchedAt = .distantPast; return }
        if !force, Date().timeIntervalSince(dailyFetchedAt) < ttl { return }
        let online = isOnline()
        if let tracks = try? await resolveTracks(.daily), !Task.isCancelled {
            dailyTracks = tracks
            if online && isOnline() { dailyFetchedAt = Date() }
        }
    }

    // MARK: - Recently played

    /// Loads the all-time recently-played tracks. We unwrap `.song` on each
    /// `PlayRecordItem` so callers get a plain `[Track]`.
    func fetchRecentsTracks(loggedIn: Bool, force: Bool = false) async {
        guard loggedIn else { recentsTracks = []; recentsFetchedAt = .distantPast; return }
        if !force, Date().timeIntervalSince(recentsFetchedAt) < ttl { return }
        let online = isOnline()
        if let tracks = try? await resolveTracks(.recents), !Task.isCancelled {
            recentsTracks = tracks
            if online && isOnline() { recentsFetchedAt = Date() }
        }
    }

    // MARK: - Cloud disk

    /// Uses the same cloud track metadata and local fallback as phone playback.
    func fetchCloudTracks(loggedIn: Bool, force: Bool = false) async {
        guard loggedIn else { cloudTracks = []; cloudFetchedAt = .distantPast; return }
        if !force, Date().timeIntervalSince(cloudFetchedAt) < ttl { return }
        let online = isOnline()
        if let tracks = try? await resolveTracks(.cloud), !Task.isCancelled {
            cloudTracks = tracks
            if online && isOnline() { cloudFetchedAt = Date() }
        }
    }

    // MARK: - Radar playlists

    /// Loads the four fixed-ID personalized radar playlists (login-only).
    /// NetEase names the radar playlists in the form "<seed-track intro>|Personal Radar", so we split on `|`
    /// to peel off the "Personal Radar" subtitle and keep the rest as the title.
    func fetchRadarPlaylists(loggedIn: Bool, force: Bool = false) async {
        guard loggedIn else { radarPlaylists = []; return }
        if !force, Date().timeIntervalSince(radarFetchedAt) < ttl, !radarPlaylists.isEmpty { return }
        let ids = CarPlayRadarPlaylist.ids
        let briefs = await withTaskGroup(of: (Int, NeteaseAPI.PlaylistBrief.Body?).self) { group in
            for id in ids {
                group.addTask {
                    (id, try? await NeteaseAPI.playlistBrief(id: id))
                }
            }
            var byID: [Int: NeteaseAPI.PlaylistBrief.Body] = [:]
            for await (id, brief) in group {
                if let brief { byID[id] = brief }
            }
            return byID
        }
        radarPlaylists = ids.compactMap { id in
            guard let brief = briefs[id] else { return nil }
            let parts = (brief.name ?? "").components(separatedBy: "|")
            let title = parts.count > 1 ? parts.last! : (brief.name ?? "雷达歌单")
            let subtitle = parts.count > 1 ? parts.dropLast().joined(separator: "|") : nil
            return CarPlayRadarPlaylist(id: id, title: title, subtitle: subtitle, coverURL: brief.coverImgUrl)
        }
        radarFetchedAt = Date()
    }

    // MARK: - New albums

    /// Loads the latest albums (first 20).
    func fetchNewAlbums(force: Bool = false) async {
        if !force, Date().timeIntervalSince(albumsFetchedAt) < ttl, !newAlbums.isEmpty { return }
        newAlbums = (try? await NeteaseAPI.newAlbums(limit: 20)) ?? []
        albumsFetchedAt = Date()
    }

    // MARK: - Top artists

    /// Loads the trending artists and picks 6 at random. We shuffle so the
    /// lineup changes between sessions, matching the App's HomeView which does
    /// the same — otherwise the same faces show up every time the user opens CarPlay.
    func fetchTopArtists(force: Bool = false) async {
        if !force, Date().timeIntervalSince(artistsFetchedAt) < ttl, !topArtists.isEmpty { return }
        let artists = (try? await NeteaseAPI.topArtists()) ?? []
        topArtists = Array(artists.shuffled().prefix(6))
        artistsFetchedAt = Date()
    }

    // MARK: - Playlist detail

    /// Fetches the full track list for a playlist (with pagination baked into
    /// `PlayerService.resolve`, so we just hand off to it).
    func fetchPlaylistTracks(id: Int, name: String) async -> [Track] {
        guard let resolved = try? await PlayerService.shared.resolve(
            .playlist(id: id, name: name)
        ) else { return [] }
        return resolved.tracks
    }
}
#endif
