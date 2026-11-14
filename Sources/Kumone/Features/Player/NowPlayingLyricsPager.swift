import SwiftUI

#if os(iOS)
/// The iPhone now-playing lyrics with the song's comments one page to their
/// right: swipe left for the comments, right for the lyrics again. Songs
/// without a public thread (cloud uploads) show the lyrics alone.
struct NowPlayingLyricsPager<Lyrics: View>: View {
    private enum Page: Hashable {
        case lyrics, comments
    }

    /// Whether the lyrics are on screen. Hiding them returns to the lyrics
    /// page, so they open on the lyrics next time.
    let isShown: Bool
    /// The layout's horizontal margin. Pages slide edge to edge across it
    /// and keep it inside.
    let horizontalInset: CGFloat
    private let lyrics: Lyrics

    @EnvironmentObject private var player: PlayerService
    @State private var page = Page.lyrics
    /// Presented from here, outside the pager: a sheet raised from inside
    /// one of its pages closed again a moment later, when the pages refreshed.
    @State private var sharedComment: SharedComment?

    init(isShown: Bool, horizontalInset: CGFloat, @ViewBuilder lyrics: () -> Lyrics) {
        self.isShown = isShown
        self.horizontalInset = horizontalInset
        self.lyrics = lyrics()
    }

    var body: some View {
        if let track = player.currentTrack, SongCommentsMenuButton.isAvailable(for: track) {
            TabView(selection: $page) {
                lyrics
                    .padding(.horizontal, horizontalInset)
                    .tag(Page.lyrics)
                // The list keeps a 16pt margin of its own.
                NowPlayingCommentsPage(track: track, isActive: isShown && page == .comments) { comment in
                    sharedComment = SharedComment(track: track, comment: comment)
                }
                    .id(track.id)
                    .padding(.horizontal, max(horizontalInset - 16, 0))
                    .tag(Page.comments)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .padding(.horizontal, -horizontalInset)
            .overlay(alignment: .bottom) {
                pageIndicator
            }
            .sheet(item: $sharedComment) { shared in
                CommentShareSheet(track: shared.track, comment: shared.comment)
            }
            .onChange(of: isShown) { shown in
                guard !shown, page != .lyrics else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { page = .lyrics }
            }
        } else {
            lyrics
        }
    }

    private var pageIndicator: some View {
        HStack(spacing: 6) {
            ForEach([Page.lyrics, .comments], id: \.self) { item in
                Capsule()
                    .fill(.white.opacity(item == page ? 0.8 : 0.28))
                    .frame(width: item == page ? 14 : 5, height: 5)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: page)
        .padding(.bottom, 2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The current song's comments on the now-playing page. They load the
/// first time the page is turned to, not with every song that plays.
private struct SharedComment: Identifiable {
    let track: Track
    let comment: SongComment
    var id: Int { comment.id }
}

private struct NowPlayingCommentsPage: View {
    let track: Track
    let isActive: Bool
    let onShare: (SongComment) -> Void

    @StateObject private var content: SongCommentsContent

    init(track: Track, isActive: Bool, onShare: @escaping (SongComment) -> Void) {
        self.track = track
        self.isActive = isActive
        self.onShare = onShare
        _content = StateObject(wrappedValue: SongCommentsContent(songID: track.id))
    }

    var body: some View {
        SongCommentsList(track: track, content: content, onShare: onShare)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 12)
            .mask(edgeMask)
            .environment(\.colorScheme, .dark)
            .accessibilityIdentifier("nowPlayingComments")
            .onAppear { load(if: needsLoad) }
            // Watching the page and the phase together also restarts a load
            // that ended back at idle, as a cancelled one does, rather than
            // leaving the spinner up until the page is turned again (#214).
            .onChange(of: needsLoad) { load(if: $0) }
    }

    private var needsLoad: Bool { isActive && content.phase == .idle }

    /// Unstructured so that turning back to the lyrics mid-load doesn't
    /// cancel it into an error.
    private func load(if needed: Bool) {
        guard needed else { return }
        Task { await content.loadFirstPage() }
    }

    private var edgeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.03),
                .init(color: .black, location: 0.94),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
#endif
