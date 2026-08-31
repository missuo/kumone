import SwiftUI

// MARK: - Cover card (playlists / albums)

struct CoverCard: View {
    let coverURL: URL?
    let title: String
    var subtitle: String?
    var playCount: Int = 0
    var size: CGFloat = Theme.Layout.cardSize
    var onPlay: (() -> Void)?
    let onOpen: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomLeading) {
                    CachedAsyncImage(url: coverURL)
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous)
                                .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
                        )
                    if playCount > 0 {
                        PlayCountBadge(count: playCount)
                            .padding(6)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                    if let onPlay {
                        PlayOverlayButton(visible: isHovering, action: onPlay)
                            .padding(8)
                    }
                }
                .frame(width: size, height: size)

                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: size, minHeight: 36, alignment: .topLeading)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: size, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.interactiveCard)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Artist card (circular)

struct ArtistCard: View {
    let artist: ArtistSummary
    var size: CGFloat = 128
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 10) {
                CachedAsyncImage(url: artist.picUrl?.resizedImageURL(256))
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
                Text(artist.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }
            .frame(width: size + 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.interactiveCard)
    }
}

// MARK: - Horizontal shelf

/// A horizontal scroll section whose track reaches the column edges;
/// the resting inset lives inside the HStack (kaset's slide-under trick).
struct Shelf<Content: View>: View {
    let title: LocalizedStringKey
    var seeAll: (() -> Void)?
    var spacing: CGFloat = 16
    /// Height of one row of cards.
    ///
    /// Supplying it lets the shelf build its cards lazily, which matters more
    /// than it sounds: a plain `HStack` instantiates every card in the shelf and
    /// keeps it in the responder tree, so hit testing walks all of them on every
    /// frame of a *vertical* scroll — including the ones scrolled off the side
    /// and never seen. Measured at roughly half the cost of scrolling the home
    /// page. It has to be stated rather than measured because a `LazyHStack`
    /// reports no height until something has been scrolled into view, which
    /// leaves the enclosing horizontal ScrollView with nothing to lay out
    /// against and collapses the whole page.
    var rowHeight: CGFloat?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: title, action: seeAll)
                .padding(.horizontal, Theme.Layout.contentInset)
            ScrollView(.horizontal, showsIndicators: false) {
                cards
                    .padding(.vertical, 6)
            }
            .compatScrollClipDisabled()
        }
    }

    private var edgeInset: some View {
        Color.clear.frame(width: max(0, Theme.Layout.contentInset - spacing), height: 1)
    }

    @ViewBuilder
    private var cards: some View {
        if let rowHeight {
            LazyHStack(alignment: .top, spacing: spacing) {
                edgeInset
                content()
                edgeInset
            }
            .frame(height: rowHeight)
        } else {
            HStack(alignment: .top, spacing: spacing) {
                edgeInset
                content()
                edgeInset
            }
        }
    }
}

// MARK: - Adaptive card grid

/// Set by `CardGrid` on compact iOS so cards fill their (even) column instead
/// of staying a fixed 160pt — which on narrow iPhones only fit one per row.
private struct FlexibleCardWidthKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var flexibleCardWidth: Bool {
        get { self[FlexibleCardWidthKey.self] }
        set { self[FlexibleCardWidthKey.self] = newValue }
    }
}

struct CardGrid<Content: View>: View {
    var minWidth: CGFloat = Theme.Layout.cardSize
    @ViewBuilder var content: () -> Content

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isCompact: Bool { horizontalSizeClass == .compact }
    #else
    private var isCompact: Bool { false }
    #endif

    private var columns: [GridItem] {
        isCompact
            ? [GridItem(.flexible(), spacing: 16, alignment: .top),
               GridItem(.flexible(), spacing: 16, alignment: .top)]
            : [GridItem(.adaptive(minimum: minWidth, maximum: minWidth + 40),
                        spacing: 20, alignment: .top)]
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: isCompact ? 20 : 24) {
            content()
        }
        .environment(\.flexibleCardWidth, isCompact)
    }
}

// MARK: - Error / empty states

struct ErrorStateView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("加载失败").font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("重试", action: retry)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
