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
}

/// Library metadata is app data, independent of evictable audio and artwork.
actor PlaylistSnapshotStore {
    static let shared = PlaylistSnapshotStore(directory: KumonePaths.applicationSupport.appendingPathComponent("playlists"))
    let directory: URL
    private var refreshes: [URL: (token: UUID, background: Bool)] = [:]
    private var removedTracks: [URL: Set<Int>] = [:]

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
        if background, refreshes[url]?.background == false { return nil }
        let token = UUID()
        refreshes[url] = (token, background)
        removedTracks[url] = []
        return token
    }

    func isCurrent(id: Int, scope: String, token: UUID) -> Bool {
        refreshes[file(id: id, scope: scope)]?.token == token
    }

    func finishRefresh(id: Int, scope: String, token: UUID) {
        let url = file(id: id, scope: scope)
        guard refreshes[url]?.token == token else { return }
        refreshes[url] = nil
        removedTracks[url] = nil
    }

    func save(_ snapshot: PlaylistSnapshot, scope: String, token: UUID) throws {
        let url = file(id: snapshot.detail.id, scope: scope)
        guard refreshes[url]?.token == token else { return }
        var snapshot = snapshot
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
