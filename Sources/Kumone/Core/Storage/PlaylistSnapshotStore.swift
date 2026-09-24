import Foundation

struct PlaylistSnapshot: Codable {
    var detail: PlaylistDetail
    var privileges: [Int: TrackPrivilege]
    var savedAt: Date = .now

    var isComplete: Bool {
        detail.trackIds.count == detail.trackCount
            && Set(detail.tracks.map(\.id)) == Set(detail.trackIds.map(\.id))
    }

    func needsBackgroundRefresh(summary: PlaylistSummary?, now: Date = .now) -> Bool {
        guard isComplete else { return true }
        if let summary {
            guard summary.trackCount == detail.trackCount, summary.name == detail.name else { return true }
            if let updated = summary.updateTime, updated > 0, detail.updateTime > 0 {
                return updated != detail.updateTime
            }
        }
        let age = now.timeIntervalSince(savedAt)
        return age < 0 || age >= 5 * 60
    }

    mutating func remove(_ ids: Set<Int>) {
        detail.tracks.removeAll { ids.contains($0.id) }
        detail.trackIds.removeAll { ids.contains($0.id) }
        detail.trackCount = detail.trackIds.count
        privileges = privileges.filter { !ids.contains($0.key) }
    }

    mutating func replaceRecommendation(_ trackID: Int, with replacement: Track) {
        guard detail.trackIds.contains(where: { $0.id == trackID })
                || detail.tracks.contains(where: { $0.id == trackID }) else { return }
        let previousCount = detail.trackIds.count
        var seen: Set<Int> = []
        detail.trackIds = detail.trackIds.map { $0.id == trackID ? TrackIDRef(id: replacement.id) : $0 }
            .filter { seen.insert($0.id).inserted }
        detail.trackCount -= previousCount - detail.trackIds.count
        seen = []
        detail.tracks = detail.tracks.map { $0.id == trackID ? replacement : $0 }
            .filter { seen.insert($0.id).inserted }
        privileges[trackID] = nil
        if let privilege = replacement.embeddedPrivilege { privileges[replacement.id] = privilege }
    }
}

/// Library metadata is app data, independent of evictable audio and artwork.
actor PlaylistSnapshotStore {
    static let shared = PlaylistSnapshotStore(directory: KumonePaths.applicationSupport.appendingPathComponent("playlists"))
    let directory: URL
    private var refreshes: [URL: (token: UUID, background: Bool)] = [:]
    private var foregroundRefreshes: [URL: Set<UUID>] = [:]
    private var removedTracks: [URL: Set<Int>] = [:]
    private var recommendationReplacements: [URL: [Int: Track]] = [:]

    init(directory: URL) { self.directory = directory }

    func load(id: Int, scope: String) -> PlaylistSnapshot? {
        guard let data = try? Data(contentsOf: file(id: id, scope: scope)),
              let snapshot = try? JSONDecoder().decode(PlaylistSnapshot.self, from: data),
              snapshot.detail.id == id else { return nil }
        return snapshot
    }

    /// An opened playlist takes priority over a background library refresh.
    func beginRefresh(id: Int, scope: String, background: Bool) -> UUID? {
        let url = file(id: id, scope: scope)
        if background, foregroundRefreshes[url]?.isEmpty == false { return nil }
        let token = UUID()
        if !background { foregroundRefreshes[url, default: []].insert(token) }
        refreshes[url] = (token, background)
        removedTracks[url] = []
        recommendationReplacements[url] = [:]
        return token
    }

    func isCurrent(id: Int, scope: String, token: UUID) -> Bool {
        refreshes[file(id: id, scope: scope)]?.token == token
    }

    func finishRefresh(id: Int, scope: String, token: UUID) {
        let url = file(id: id, scope: scope)
        foregroundRefreshes[url]?.remove(token)
        if foregroundRefreshes[url]?.isEmpty == true { foregroundRefreshes[url] = nil }
        guard refreshes[url]?.token == token else { return }
        refreshes[url] = nil
        removedTracks[url] = nil
        recommendationReplacements[url] = nil
    }

    func save(_ snapshot: PlaylistSnapshot, scope: String, token: UUID) throws {
        let url = file(id: snapshot.detail.id, scope: scope)
        guard refreshes[url]?.token == token else { return }
        var snapshot = snapshot
        for (id, replacement) in recommendationReplacements[url] ?? [:] {
            snapshot.replaceRecommendation(id, with: replacement)
        }
        if let removed = removedTracks[url], !removed.isEmpty { snapshot.remove(removed) }
        try write(snapshot, to: url)
    }

    func remove(trackID: Int, playlistID: Int, scope: String) throws {
        let url = file(id: playlistID, scope: scope)
        if refreshes[url] != nil { removedTracks[url, default: []].insert(trackID) }
        guard var snapshot = load(id: playlistID, scope: scope) else { return }
        snapshot.remove([trackID])
        try write(snapshot, to: url)
    }

    func replaceRecommendation(trackID: Int, with replacement: Track, playlistID: Int, scope: String) throws {
        let url = file(id: playlistID, scope: scope)
        if refreshes[url] != nil {
            for (id, previous) in recommendationReplacements[url] ?? [:] where previous.id == trackID {
                recommendationReplacements[url]?[id] = replacement
            }
            recommendationReplacements[url, default: [:]][trackID] = replacement
        }
        guard var snapshot = load(id: playlistID, scope: scope) else { return }
        snapshot.replaceRecommendation(trackID, with: replacement)
        try write(snapshot, to: url)
    }

    private func file(id: Int, scope: String) -> URL {
        directory.appendingPathComponent(OfflineMetadataStore.key(scope), isDirectory: true)
            .appendingPathComponent("\(id).json")
    }

    private func write(_ snapshot: PlaylistSnapshot, to url: URL) throws {
        try DownloadFileProtection.prepareDirectory(url.deletingLastPathComponent())
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        try DownloadFileProtection.protect(url)
    }
}
