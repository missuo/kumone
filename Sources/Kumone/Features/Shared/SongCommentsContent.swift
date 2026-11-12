import Foundation

/// Paging and like state for one song's comments: hot comments from the
/// first page, then the latest ones a page at a time.
@MainActor
final class SongCommentsContent: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    let songID: Int
    let threadID: String
    let pageSize: Int

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var hot: [SongComment] = []
    @Published private(set) var latest: [SongComment] = []
    @Published private(set) var total = 0
    @Published private(set) var hasMore = false
    @Published private(set) var isLoadingMore = false
    /// Set when a later page failed; the comments already shown stay.
    @Published private(set) var loadMoreError: String?
    @Published private(set) var pendingLikes: Set<Int> = []

    private let client: MusicClient
    private var nextOffset = 0
    private var latestIDs: Set<Int> = []

    init(songID: Int, pageSize: Int = 20, client: MusicClient = .shared) {
        self.songID = songID
        self.threadID = MusicAPI.songCommentThread(songID: songID)
        self.pageSize = max(1, pageSize)
        self.client = client
    }

    var isEmpty: Bool { hot.isEmpty && latest.isEmpty }

    /// Loads the first page, replacing whatever is shown. A no-op while it runs.
    func loadFirstPage() async {
        guard phase != .loading else { return }
        phase = .loading
        loadMoreError = nil
        do {
            let page = try await MusicAPI.songComments(songID: songID, limit: pageSize, offset: 0, using: client)
            var hotIDs: Set<Int> = []
            hot = page.hot.filter { hotIDs.insert($0.id).inserted }
            latestIDs = []
            latest = page.latest.filter { latestIDs.insert($0.id).inserted }
            total = page.total
            nextOffset = pageSize
            hasMore = page.more && !page.latest.isEmpty
            phase = .loaded
        } catch is CancellationError {
            phase = .idle
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Appends the next page of latest comments, skipping ones already shown.
    func loadMore() async {
        guard phase == .loaded, hasMore, !isLoadingMore else { return }
        isLoadingMore = true
        loadMoreError = nil
        defer { isLoadingMore = false }
        do {
            let page = try await MusicAPI.songComments(songID: songID, limit: pageSize, offset: nextOffset,
                                                       using: client)
            let fresh = page.latest.filter { latestIDs.insert($0.id).inserted }
            latest.append(contentsOf: fresh)
            if page.total > 0 { total = page.total }
            nextOffset += pageSize
            // A page with nothing new would only be asked for again.
            hasMore = page.more && !fresh.isEmpty
        } catch is CancellationError {
            return
        } catch {
            loadMoreError = error.localizedDescription
        }
    }

    /// Retries whatever failed last: the first page, or the next one.
    func retry() async {
        if case .failed = phase {
            await loadFirstPage()
        } else if loadMoreError != nil {
            await loadMore()
        }
    }

    func comment(id: Int) -> SongComment? {
        hot.first(where: { $0.id == id }) ?? latest.first(where: { $0.id == id })
    }

    /// Likes or unlikes a comment at once, and puts it back if the service
    /// refuses. Rethrows that refusal for the caller to report.
    func toggleLike(commentID: Int) async throws {
        guard !pendingLikes.contains(commentID), let current = comment(id: commentID) else { return }
        let like = !current.liked
        pendingLikes.insert(commentID)
        defer { pendingLikes.remove(commentID) }
        apply(commentID: commentID, liked: like)
        do {
            try await MusicAPI.likeComment(threadID: threadID, commentID: commentID, like: like, using: client)
        } catch {
            apply(commentID: commentID, liked: !like)
            throw error
        }
    }

    /// The same comment can be both hot and latest; both rows follow.
    private func apply(commentID: Int, liked: Bool) {
        func update(_ list: inout [SongComment]) {
            for index in list.indices where list[index].id == commentID && list[index].liked != liked {
                list[index].liked = liked
                list[index].likedCount = max(0, list[index].likedCount + (liked ? 1 : -1))
            }
        }
        update(&hot)
        update(&latest)
    }
}
