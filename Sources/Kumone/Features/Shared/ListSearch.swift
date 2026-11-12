import SwiftUI

/// "找到 N 首匹配歌曲" above an in-list search's results, and the empty state
/// once a finished list has no match. Shared by the playlist and cloud pages.
struct SongSearchSummary: View {
    let count: Int
    /// Loading has finished without error, so no match means none.
    let isSettled: Bool
    var emptySubtitle: LocalizedStringKey = "试试其他歌名、歌手或专辑"
    /// Shown as 清空搜索 when the search field itself is out of sight.
    var onClear: (() -> Void)?
    var horizontalPadding: CGFloat

    var body: some View {
        HStack {
            Text("找到 \(count) 首匹配歌曲")
            if let onClear {
                Spacer()
                Button("清空搜索", action: onClear)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.horizontal, horizontalPadding)

        if count == 0 && isSettled {
            EmptyStateView(icon: "magnifyingglass", title: "没有匹配的歌曲", subtitle: emptySubtitle)
                .frame(minHeight: 180)
        }
    }
}

#if os(iOS)
/// The revealed search row of a song list: the search bar and 取消.
struct ListSearchBar: View {
    @Binding var text: String
    @Binding var isFocused: Bool
    var placeholder = String(localized: "搜索歌单内歌曲")
    var hint = String(localized: "按歌名、歌手或专辑搜索")
    var identifier = "likedSongsSearch"
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            PlaylistSearchField(text: $text, isFocused: $isFocused,
                                placeholder: placeholder, hint: hint, identifier: identifier)
            Button("取消", action: onCancel)
                .buttonStyle(.plain)
                .padding(.trailing, 8)
        }
        .frame(height: 52)
    }
}
#endif

#if os(macOS)
/// The desktop in-list search capsule, at the trailing end of a list's action row.
struct ListFilterField: View {
    let placeholder: LocalizedStringKey
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 130)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.primary.opacity(0.05), in: Capsule())
    }
}
#endif
