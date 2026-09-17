import Combine
import Foundation

@MainActor
final class PlaylistContent: ObservableObject {
    let playlistID: Int
    @Published var detail: PlaylistDetail?
    @Published var tracks: [Track] = []
    @Published var privileges: [Int: TrackPrivilege] = [:]
    @Published var isLoading = true
    @Published var isLoadingMore = false
    @Published var errorMessage: String?
    @Published var filter = ""
    private(set) var loadedScope: String?
    private var reducedRecommendationIDs: Set<Int> = []
    private var removedTrackIDs: Set<Int> = []
    private var loadGeneration = 0
    private let detailLoader: (Int) async throws -> NeteaseAPI.PlaylistDetailResponse
    private let tracksLoader: ([Int]) async throws -> NeteaseAPI.SongDetailResponse
    private let snapshots: PlaylistSnapshotStore?
    private let accountScope: @MainActor () -> String?

    init(playlistID: Int,
         snapshots: PlaylistSnapshotStore? = .shared,
         accountScope: @escaping @MainActor () -> String? = { AccountStore.shared.offlineScope },
         detailLoader: @escaping (Int) async throws -> NeteaseAPI.PlaylistDetailResponse = { try await NeteaseAPI.playlistDetail(id: $0) },
         tracksLoader: @escaping ([Int]) async throws -> NeteaseAPI.SongDetailResponse = { try await NeteaseAPI.songDetails(ids: $0) }) {
        self.playlistID = playlistID
        self.detailLoader = detailLoader
        self.tracksLoader = tracksLoader
        self.snapshots = snapshots
        self.accountScope = accountScope
    }

    var canDownloadAll: Bool {
        guard let detail, !isLoading, !isLoadingMore, !tracks.isEmpty else { return false }
        return detail.trackIds.count == detail.trackCount && Set(tracks.map(\.id)) == Set(detail.trackIds.map(\.id))
    }

    var filteredTracks: [Track] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return tracks }
        return tracks.filter {
            $0.name.lowercased().contains(query)
                || $0.artistNames.lowercased().contains(query)
                || $0.album.name.lowercased().contains(query)
        }
    }

    func load(allowNetwork: Bool = true, summary: PlaylistSummary? = nil, background: Bool = false) async {
        loadGeneration += 1
        let generation = loadGeneration
        let scope = accountScope()
        if loadedScope != scope {
            detail = nil
            tracks = []
            privileges = [:]
            reducedRecommendationIDs = []
            loadedScope = scope
        }
        removedTrackIDs = []
        isLoading = tracks.isEmpty
        isLoadingMore = false
        errorMessage = nil
        defer { if generation == loadGeneration { isLoading = false; isLoadingMore = false } }
        guard let scope else { return }
        if let snapshots, let saved = await snapshots.load(id: playlistID, scope: scope) {
            guard valid(generation, scope: scope) else { return }
            detail = saved.detail
            tracks = saved.detail.tracks
            privileges = saved.privileges
            isLoading = false
        }
        guard valid(generation, scope: scope) else { return }
        if detail == nil, let summary { detail = PlaylistDetail(summary: summary) }
        guard allowNetwork else { return }
        let token = await snapshots?.beginRefresh(id: playlistID, scope: scope, background: background)
        if snapshots != nil, token == nil { return }
        defer {
            if let snapshots, let token {
                Task { await snapshots.finishRefresh(id: playlistID, scope: scope, token: token) }
            }
        }
        do {
            let response = try await detailLoader(playlistID)
            guard await current(generation, scope: scope, token: token) else { return }
            var loaded = response.playlist
            // A truncated membership response cannot remove the tail of a saved list.
            if loaded.trackIds.count < loaded.trackCount, !tracks.isEmpty {
                throw OfflineAudioError.incomplete
            }
            if !removedTrackIDs.isEmpty {
                loaded.tracks.removeAll { removedTrackIDs.contains($0.id) }
                loaded.trackIds.removeAll { removedTrackIDs.contains($0.id) }
                loaded.trackCount = loaded.trackIds.count
            }
            let known = Dictionary((tracks + loaded.tracks).map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            loaded.tracks = loaded.trackIds.compactMap { known[$0.id] }
            detail = loaded
            tracks = loaded.tracks.filter { !reducedRecommendationIDs.contains($0.id) }
            let ids = Set(loaded.trackIds.map(\.id))
            privileges = privileges.filter { ids.contains($0.key) }
            merge(privileges: response.privileges)
            isLoading = false
            await save(scope: scope, token: token)
            try await loadRemainingTracks(generation: generation, scope: scope, token: token)
        } catch {
            guard await current(generation, scope: scope, token: token) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func loadRemainingTracks(generation: Int, scope: String, token: UUID?) async throws {
        guard let detail, tracks.count < detail.trackIds.count else { return }
        isLoadingMore = true
        let loadedIDs = Set(tracks.map(\.id))
        let remaining = detail.trackIds.map(\.id).filter { !loadedIDs.contains($0) && !reducedRecommendationIDs.contains($0) }
        for chunk in stride(from: 0, to: remaining.count, by: 500)
            .map({ Array(remaining.dropFirst($0).prefix(500)) }) {
            guard await current(generation, scope: scope, token: token) else { return }
            let response = try await tracksLoader(chunk)
            guard await current(generation, scope: scope, token: token) else { return }
            let known = Dictionary((tracks + response.songs).map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            tracks = (self.detail?.trackIds ?? []).compactMap { known[$0.id] }
                .filter { !reducedRecommendationIDs.contains($0.id) && !removedTrackIDs.contains($0.id) }
            merge(privileges: response.privileges)
            await save(scope: scope, token: token)
        }
    }

    private func valid(_ generation: Int, scope: String) -> Bool {
        generation == loadGeneration && !Task.isCancelled && scope == accountScope()
    }

    private func current(_ generation: Int, scope: String, token: UUID?) async -> Bool {
        guard valid(generation, scope: scope) else { return false }
        if let snapshots, let token, !(await snapshots.isCurrent(id: playlistID, scope: scope, token: token)) { return false }
        return valid(generation, scope: scope)
    }

    private func save(scope: String, token: UUID?) async {
        guard let snapshots, let token, var detail, scope == accountScope(), !Task.isCancelled else { return }
        detail.tracks = tracks
        try? await snapshots.save(.init(detail: detail, privileges: privileges), scope: scope, token: token)
    }

    private func merge(privileges list: [TrackPrivilege]?) {
        for privilege in list ?? [] {
            privileges[privilege.id] = privilege
        }
    }

    func remove(_ track: Track) async {
        removedTrackIDs.insert(track.id)
        tracks.removeAll { $0.id == track.id }
        detail?.tracks.removeAll { $0.id == track.id }
        detail?.trackIds.removeAll { $0.id == track.id }
        detail?.trackCount = detail?.trackIds.count ?? 0
        privileges[track.id] = nil
        if let scope = loadedScope, scope == accountScope() {
            try? await snapshots?.remove(trackID: track.id, playlistID: playlistID, scope: scope)
        }
    }

    func replaceRecommendation(_ rejected: Track, with replacement: Track) {
        if tracks.replaceRecommendation(rejected, with: replacement) {
            reducedRecommendationIDs.insert(rejected.id)
        }
    }
}
