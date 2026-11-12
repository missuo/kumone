import Combine
import Foundation

/// The 音乐云盘 list. The service pages uploads, so `load` keeps fetching until
/// it reports no more: play-all and in-list search then cover every song, not
/// only the first page.
@MainActor
final class CloudLibraryContent: ObservableObject {
    @Published private(set) var items: [CloudSongItem] = [] {
        didSet { tracks = items.compactMap(\.simpleSong) }
    }
    /// The playable songs of `items`, in cloud order.
    private(set) var tracks: [Track] = []
    @Published var filter = ""
    @Published private(set) var isLoading = true
    @Published private(set) var isLoadingMore = false
    @Published private(set) var errorMessage: String?
    /// Every page arrived; nothing is left to fetch.
    @Published private(set) var isComplete = false
    @Published private(set) var usedBytes: Int64?
    @Published private(set) var maxBytes: Int64?

    private let pageSize: Int
    private let pageLoader: (_ limit: Int, _ offset: Int) async throws -> MusicAPI.CloudResponse
    private var generation = 0

    init(pageSize: Int = 1000,
         pageLoader: @escaping (_ limit: Int, _ offset: Int) async throws -> MusicAPI.CloudResponse = {
             try await MusicAPI.cloudSongs(limit: $0, offset: $1)
         }) {
        self.pageSize = pageSize
        self.pageLoader = pageLoader
    }

    /// Songs matching `filter`, in cloud order.
    var filteredTracks: [Track] {
        guard let query = TrackSearch.query(filter) else { return tracks }
        return items.compactMap { $0.matches(query) ? $0.simpleSong : nil }
    }

    func load() async {
        generation += 1
        let generation = generation
        isLoading = items.isEmpty
        isLoadingMore = false
        errorMessage = nil
        defer {
            if generation == self.generation { isLoading = false; isLoadingMore = false }
        }
        var loaded: [CloudSongItem] = []
        var seen: Set<Int> = []
        var offset = 0
        do {
            while true {
                let page = try await pageLoader(pageSize, offset)
                guard generation == self.generation, !Task.isCancelled else { return }
                if offset == 0 {
                    usedBytes = page.size
                    maxBytes = page.maxSize
                }
                let data = page.data ?? []
                let before = loaded.count
                for item in data where seen.insert(item.songId).inserted {
                    loaded.append(item)
                }
                offset += data.count
                // A page of only repeats means the service is not advancing.
                let more = page.hasMore == true && loaded.count > before
                // A refresh keeps the longer list on screen until it is overtaken.
                if !more || loaded.count >= items.count { items = loaded }
                isLoading = false
                guard more else { break }
                isLoadingMore = true
            }
            isComplete = true
        } catch {
            guard generation == self.generation, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
}
