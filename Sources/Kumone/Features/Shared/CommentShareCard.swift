import SwiftUI
#if os(iOS)
import Photos
#endif

/// The picture a shared comment becomes: the comment as a quote over the
/// song's artwork colours, who wrote it, and the song it was left on.
struct CommentShareCard: View {
    static let width: CGFloat = 360

    let track: Track
    let comment: SongComment
    let artwork: PlatformImage?
    let avatar: PlatformImage?
    let colors: ArtworkColors

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: "\u{201C}")
                .font(.system(size: 64, weight: .bold, design: .serif))
                .foregroundStyle(.white.opacity(0.32))
                .frame(height: 40, alignment: .top)
                .accessibilityHidden(true)

            Text(comment.content)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
                .lineSpacing(7)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            commenter
                .padding(.top, 22)

            songPanel
                .padding(.top, 30)

            footer
                .padding(.top, 18)
        }
        .padding(.horizontal, 28)
        .padding(.top, 30)
        .padding(.bottom, 22)
        .frame(width: Self.width, alignment: .leading)
        // The text makes the height fractional; the picture's last pixel row then
        // sat outside the background and came out as a white line. A whole number of
        // points leaves no partly covered row at any render scale.
        .wholePointHeight()
        .background(backdrop)
        .environment(\.colorScheme, .dark)
    }

    private var backdrop: some View {
        ZStack {
            LinearGradient(
                colors: [colors.primary, colors.secondary],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            if let artwork {
                // A wash of the cover itself, far too soft to compete with the text.
                Image(platformImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 60)
                    .opacity(0.45)
            }
            LinearGradient(
                colors: [.black.opacity(0.12), .black.opacity(0.5)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .clipped()
    }

    private var commenter: some View {
        HStack(spacing: 10) {
            Group {
                if let avatar {
                    Image(platformImage: avatar)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Circle().fill(.white.opacity(0.18))
                        Image(systemName: "person.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            .frame(width: 30, height: 30)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))

            Text(comment.nickname.isEmpty ? String(localized: "匿名用户") : comment.nickname)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)

            Spacer(minLength: 8)

            if comment.likedCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "hand.thumbsup.fill")
                    Text(Formatters.playCount(comment.likedCount))
                        .monospacedDigit()
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private var songPanel: some View {
        HStack(spacing: 12) {
            Group {
                if let artwork {
                    Image(platformImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Rectangle().fill(.white.opacity(0.12))
                        Image(systemName: "music.note")
                            .font(.system(size: 20, weight: .light))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(track.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if !track.artistNames.isEmpty {
                    Text(track.artistNames)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
    }

    private var footer: some View {
        HStack {
            if let time = comment.time {
                Text(time.formatted(.dateTime.year().month().day()))
            }
            Spacer()
            Label {
                Text(verbatim: "Kumone")
            } icon: {
                Image(systemName: "music.note")
            }
            .labelStyle(.titleAndIcon)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.42))
    }
}

/// Previews the comment as a picture, and shares or saves it.
struct CommentShareSheet: View {
    let track: Track
    let comment: SongComment

    @Environment(\.dismiss) private var dismiss
    @State private var image: PlatformImage?
    @State private var saveState = SaveState.idle

    private enum SaveState: Equatable {
        case idle, saving, saved
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if let image {
                    ScrollView {
                        Image(platformImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: CommentShareCard.width)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 16)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel(Text("评论卡片：\(comment.content)"))
                    }
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            actions
        }
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 460, minHeight: 620, idealHeight: 720)
        #else
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #endif
        .tint(Theme.accent)
        .accessibilityIdentifier("commentShareSheet")
        .task { await render() }
    }

    private var header: some View {
        HStack {
            Text("分享评论")
                .font(.headline)
            Spacer()
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

    @ViewBuilder
    private var actions: some View {
        if let image {
            let shared = Image(platformImage: image)
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    ShareLink(
                        item: shared,
                        preview: SharePreview(Text("\(track.name) 的评论"), image: shared)
                    ) {
                        Label("分享", systemImage: "square.and.arrow.up")
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    saveButton(image)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
                if case .failed(let message) = saveState {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
    }

    @ViewBuilder
    private func saveButton(_ image: PlatformImage) -> some View {
        #if os(iOS)
        Button {
            Task { await save(image) }
        } label: {
            Group {
                switch saveState {
                case .saved:
                    Label("已保存", systemImage: "checkmark")
                case .saving:
                    ProgressView().controlSize(.small)
                default:
                    Label("保存", systemImage: "square.and.arrow.down")
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity)
        }
        .disabled(saveState == .saving || saveState == .saved)
        #else
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
            saveState = .saved
        } label: {
            Label(saveState == .saved ? "已拷贝" : "拷贝图片",
                  systemImage: saveState == .saved ? "checkmark" : "doc.on.doc")
                .frame(maxWidth: .infinity)
        }
        #endif
    }

    #if os(iOS)
    private func save(_ image: PlatformImage) async {
        saveState = .saving
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
            saveState = .saved
        } catch {
            let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            saveState = .failed(status == .denied || status == .restricted
                ? String(localized: "没有相册权限，请在系统设置中允许 Kumone 添加照片")
                : error.localizedDescription)
        }
    }
    #endif

    /// The artwork and avatar are fetched first: the renderer draws what it
    /// is given and does not wait for images to load.
    private func render() async {
        let artworkURL = track.album.picUrl?.resizedImageURL(300)
        let avatarURL = comment.avatarURL?.resizedImageURL(120)
        async let artworkImage: PlatformImage? = artworkURL.asyncMap { await ImageCache.shared.image(for: $0) }
        async let avatarImage: PlatformImage? = avatarURL.asyncMap { await ImageCache.shared.image(for: $0) }
        let (artwork, avatar) = await (artworkImage, avatarImage)
        guard !Task.isCancelled else { return }

        let colors = artwork.map {
            ArtworkPalette.extract(from: $0, cacheKey: track.album.picUrl ?? "")
        } ?? .fallback
        let card = CommentShareCard(
            track: track,
            comment: comment,
            artwork: artwork,
            avatar: avatar,
            colors: colors
        )
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        renderer.proposedSize = ProposedViewSize(width: CommentShareCard.width, height: nil)
        #if os(iOS)
        image = renderer.uiImage
        #else
        image = renderer.nsImage
        #endif
    }
}

/// Rounds its content's height up to a whole number of points, top-aligned.
private struct WholePointHeight: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let size = content.sizeThatFits(proposal)
        return CGSize(width: size.width, height: size.height.rounded(.up))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

private extension View {
    func wholePointHeight() -> some View {
        WholePointHeight { self }
    }
}

private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async -> T?) async -> T? {
        guard let self else { return nil }
        return await transform(self)
    }
}
