import SwiftUI

enum RegularColumnPage: Hashable {
    case lyrics, comments
}

/// 歌词 | 评论 above the regular page's right column.
struct RegularColumnSwitch: View {
    @Binding var selection: RegularColumnPage

    var body: some View {
        HStack(spacing: 2) {
            option("歌词", page: .lyrics)
            option("评论", page: .comments)
        }
        .padding(3)
        .background(.white.opacity(0.1), in: Capsule())
        .accessibilityElement(children: .contain)
    }

    private func option(_ title: LocalizedStringKey, page: RegularColumnPage) -> some View {
        let isSelected = selection == page
        return Button {
            selection = page
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(isSelected ? 0.95 : 0.55))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background {
                    if isSelected {
                        Capsule().fill(.white.opacity(0.18))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The playing song's comments in the regular page's right column.
struct RegularCommentsPanel: View {
    let track: Track

    @StateObject private var content: SongCommentsContent

    init(track: Track) {
        self.track = track
        _content = StateObject(wrappedValue: SongCommentsContent(songID: track.id))
    }

    var body: some View {
        SongCommentsList(track: track, content: content)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 8)
            .mask(
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
            )
            .environment(\.colorScheme, .dark)
            .accessibilityIdentifier("regularNowPlayingComments")
            .task {
                if content.phase == .idle { await content.loadFirstPage() }
            }
    }
}
