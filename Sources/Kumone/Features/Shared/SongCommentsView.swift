import SwiftUI

/// "查看评论" in a song's menus. Cloud uploads have no public thread.
struct SongCommentsMenuButton: View {
    let track: Track
    var showsIcons = false
    let action: () -> Void

    static func isAvailable(for track: Track) -> Bool { track.id > 0 && !track.isCloud }

    var body: some View {
        if Self.isAvailable(for: track) {
            Button(action: action) {
                if showsIcons {
                    Label("查看评论", systemImage: "text.bubble")
                } else {
                    Text("查看评论")
                }
            }
        }
    }
}

/// A song's hot and latest comments, presented as a sheet on both platforms.
struct SongCommentsView: View {
    let track: Track

    @StateObject private var content: SongCommentsContent
    @ObservedObject private var toasts = ToastCenter.shared
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @State private var detent: PresentationDetent = .medium
    #endif

    init(track: Track) {
        self.track = track
        _content = StateObject(wrappedValue: SongCommentsContent(songID: track.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            phaseContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 520, maxWidth: 760, minHeight: 420, idealHeight: 640, maxHeight: 960)
        #else
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        #endif
        // A sheet covers the window's own toast overlay (#182); errors from a
        // like must still be seen here.
        .overlay(alignment: .top) {
            if showsToastHere, let toast = toasts.current {
                ToastView(toast: toast)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: toasts.current)
        .accessibilityIdentifier("songCommentsSheet")
        .task {
            if content.phase == .idle { await content.loadFirstPage() }
        }
    }

    /// On a medium-height iPhone sheet the window's toast is still in view above it.
    private var showsToastHere: Bool {
        #if os(iOS)
        return detent == .large
        #else
        return true
        #endif
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: track.album.picUrl?.resizedImageURL(96), animated: false)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(.quaternary.opacity(0.6), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.pressable)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("关闭")
        }
        .padding(16)
    }

    private var subtitle: String {
        var parts: [String] = []
        if !track.artistNames.isEmpty { parts.append(track.artistNames) }
        if content.phase == .loaded, content.total > 0 {
            parts.append(String(localized: "\(content.total) 条评论"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: States

    private var phaseContent: some View {
        SongCommentsList(content: content)
    }
}

/// One song's comments with their loading, error and empty states: hot ones,
/// then the latest a page at a time. Shared by the comments sheet and the
/// iPhone now-playing page.
struct SongCommentsList: View {
    @ObservedObject var content: SongCommentsContent
    @EnvironmentObject private var account: AccountStore

    private var canLike: Bool { account.authenticatedAccountID != nil }

    var body: some View {
        phaseContent
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch content.phase {
        case .idle, .loading:
            ProgressView()
                .controlSize(.small)
        case .failed(let message):
            ErrorStateView(message: message) {
                Task { await content.retry() }
            }
        case .loaded:
            if content.isEmpty {
                EmptyStateView(icon: "text.bubble", title: "还没有评论")
            } else {
                commentList
            }
        }
    }

    private var commentList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !content.hot.isEmpty {
                    sectionTitle("热门评论")
                    ForEach(content.hot) { comment in
                        row(comment)
                    }
                }
                if !content.latest.isEmpty {
                    sectionTitle("最新评论")
                    ForEach(content.latest) { comment in
                        row(comment)
                            .onAppear {
                                if comment.id == content.latest.last?.id {
                                    Task { await content.loadMore() }
                                }
                            }
                    }
                }
                footer
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 14)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ comment: SongComment) -> some View {
        SongCommentRow(
            comment: comment,
            canLike: canLike,
            isPending: content.pendingLikes.contains(comment.id),
            onLike: { toggleLike(comment) }
        )
    }

    @ViewBuilder
    private var footer: some View {
        Group {
            if content.isLoadingMore {
                ProgressView()
                    .controlSize(.small)
            } else if let error = content.loadMoreError {
                VStack(spacing: 6) {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("重试") {
                        Task { await content.retry() }
                    }
                    .controlSize(.small)
                }
            } else if !content.hasMore, !content.latest.isEmpty {
                Text("没有更多评论了")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    private func toggleLike(_ comment: SongComment) {
        guard canLike else {
            ToastCenter.shared.show(String(localized: "登录后可点赞评论"))
            return
        }
        Task {
            do {
                try await content.toggleLike(commentID: comment.id)
            } catch is CancellationError {
                return
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }
}

private struct SongCommentRow: View {
    let comment: SongComment
    let canLike: Bool
    let isPending: Bool
    let onLike: () -> Void

    #if os(macOS)
    private static let nameFont = Font.system(size: 12.5, weight: .medium)
    private static let metaFont = Font.system(size: 11)
    private static let bodyFont = Font.system(size: 13.5)
    private static let replyFont = Font.system(size: 12.5)
    private static let avatarSize: CGFloat = 34
    #else
    private static let nameFont = Font.footnote.weight(.medium)
    private static let metaFont = Font.caption2
    private static let bodyFont = Font.subheadline
    private static let replyFont = Font.footnote
    private static let avatarSize: CGFloat = 36
    #endif

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CachedAsyncImage(url: comment.avatarURL?.resizedImageURL(96), animated: false) {
                ZStack {
                    Circle().fill(.quaternary.opacity(0.5))
                    Image(systemName: "person.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: Self.avatarSize, height: Self.avatarSize)
            .clipShape(Circle())
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(comment.nickname.isEmpty ? String(localized: "匿名用户") : comment.nickname)
                            .font(Self.nameFont)
                            .lineLimit(1)
                        if !metadata.isEmpty {
                            Text(metadata)
                                .font(Self.metaFont)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    likeButton
                }

                Text(comment.content)
                    .font(Self.bodyFont)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let reply = comment.reply {
                    Text(replyText(reply))
                        .font(Self.replyFont)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.quaternary.opacity(0.45),
                                    in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                }
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Divider()
                .opacity(0.5)
                .padding(.leading, Self.avatarSize + 10)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("songCommentRow")
    }

    private var metadata: String {
        var parts: [String] = []
        if let time = comment.time {
            parts.append(time.formatted(.relative(presentation: .named)))
        }
        if let location = comment.ipLocation {
            parts.append(String(localized: "来自 \(location)"))
        }
        return parts.joined(separator: " · ")
    }

    private func replyText(_ reply: SongComment.Reply) -> String {
        if let content = reply.content {
            return String(localized: "回复 @\(reply.nickname)：\(content)")
        }
        return String(localized: "回复 @\(reply.nickname)")
    }

    private var likeButton: some View {
        Button(action: onLike) {
            HStack(spacing: 3) {
                Image(systemName: comment.liked ? "hand.thumbsup.fill" : "hand.thumbsup")
                if comment.likedCount > 0 {
                    Text(Formatters.playCount(comment.likedCount))
                        .monospacedDigit()
                }
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(comment.liked ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .disabled(!canLike || isPending)
        .opacity(canLike ? 1 : 0.7)
        .accessibilityLabel(comment.liked ? "取消点赞" : "点赞")
        .accessibilityValue(Text(verbatim: String(comment.likedCount)))
        .accessibilityIdentifier("songCommentLikeButton")
    }
}
