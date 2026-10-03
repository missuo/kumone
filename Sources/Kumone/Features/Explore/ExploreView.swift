import SwiftUI

@MainActor
final class ExploreViewModel: ObservableObject {
    /// Shared so category selection and loaded pages survive sidebar switches.
    static let shared = ExploreViewModel()

    static let categories: [String] = [
        "全部", "推荐歌单", "精品歌单", "排行榜", "官方",
        "华语", "流行", "摇滚", "民谣", "电子", "轻音乐", "说唱", "爵士", "古典",
        "影视原声", "ACG", "古风", "怀旧", "治愈", "放松", "伤感", "快乐",
        "学习", "工作", "运动", "驾车", "夜晚",
    ]

    @Published var selectedCategory = "全部"
    @Published var playlists: [PlaylistSummary] = []
    @Published var toplists: [ToplistItem] = []
    @Published var isLoading = false
    @Published var hasMore = true
    private var offset = 0
    private var highQualityBefore = 0
    private var loadTask: Task<Void, Never>?

    func select(_ category: String) {
        guard category != selectedCategory || playlists.isEmpty else { return }
        selectedCategory = category
        playlists = []
        offset = 0
        highQualityBefore = 0
        hasMore = true
        loadTask?.cancel()
        loadTask = Task { await loadMore() }
    }

    func loadMore() async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        defer { isLoading = false }

        switch selectedCategory {
        case "排行榜":
            if let lists = try? await NeteaseAPI.toplists() {
                toplists = lists
            }
            hasMore = false
        case "推荐歌单":
            if let result = try? await NeteaseAPI.personalizedPlaylists(limit: 100) {
                playlists = result
            }
            hasMore = false
        case "精品歌单":
            if let result = try? await NeteaseAPI.highQualityPlaylists(before: highQualityBefore) {
                let existing = Set(playlists.map(\.id))
                playlists += result.playlists.filter { !existing.contains($0.id) }
                highQualityBefore = result.lasttime ?? 0
                hasMore = result.more ?? false
            } else {
                hasMore = false
            }
        default:
            let cat = selectedCategory == "官方" ? "官方" : selectedCategory
            if let result = try? await NeteaseAPI.topPlaylists(
                category: cat == "全部" ? "全部" : cat, offset: offset
            ) {
                let existing = Set(playlists.map(\.id))
                playlists += result.playlists.filter { !existing.contains($0.id) }
                offset += 50
                hasMore = (result.more ?? false) && offset < 500
            } else {
                hasMore = false
            }
        }
    }
}

struct ExploreView: View {
    @StateObject private var model = ExploreViewModel.shared
    @EnvironmentObject private var player: PlayerService

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                categoryChips
                    .padding(.top, 8)

                if model.selectedCategory == "排行榜" {
                    ToplistGrid(toplists: model.toplists)
                        .padding(.horizontal, Theme.Layout.contentInset)
                } else {
                    CardGrid {
                        ForEach(Array(model.playlists.enumerated()), id: \.element.id) { index, playlist in
                            AppDestinationLink(value: Destination.playlist(playlist.id)) {
                                CoverCardBody(
                                    coverURL: playlist.coverURL?.resizedImageURL(384),
                                    title: playlist.name,
                                    playCount: playlist.playCount
                                ) {
                                    playPlaylist(playlist.id)
                                }
                            }
                            .buttonStyle(.plain)
                            .staggeredAppearance(index: index % 10, id: "explore-\(playlist.id)")
                        }
                    }
                    .padding(.horizontal, Theme.Layout.contentInset)

                    if model.isLoading {
                        HStack {
                            Spacer()
                            ProgressView().controlSize(.small)
                            Spacer()
                        }
                        .padding(.vertical, 20)
                    } else if model.hasMore {
                        Color.clear
                            .frame(height: 1)
                            .onAppear {
                                Task { await model.loadMore() }
                            }
                    }
                }

                PlayerClearanceSpacer()
            }
        }
        .navigationTitle("精选")
        .task {
            if model.playlists.isEmpty, model.toplists.isEmpty {
                await model.loadMore()
            }
        }
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Spacer().frame(width: Theme.Layout.contentInset - 8)
                ForEach(ExploreViewModel.categories, id: \.self) { category in
                    Button {
                        model.select(category)
                    } label: {
                        Text(LocalizedStringKey(category))
                    }
                    .buttonStyle(.chip(isSelected: model.selectedCategory == category))
                }
                Spacer().frame(width: Theme.Layout.contentInset - 8)
            }
            .padding(.vertical, 2)
        }
    }

    private func playPlaylist(_ id: Int) {
        Task {
            guard let detail = try? await NeteaseAPI.playlistDetail(id: id) else { return }
            var tracks = detail.playlist.tracks
            if tracks.isEmpty {
                let ids = detail.playlist.trackIds.map(\.id)
                tracks = (try? await NeteaseAPI.songDetails(ids: Array(ids.prefix(500))))?.songs ?? []
            }
            player.play(tracks: tracks, source: .playlist(id),
                        context: .playlist(id: id, name: detail.playlist.name))
        }
    }
}

// MARK: - Toplist grid

struct ToplistGrid: View {
    let toplists: [ToplistItem]

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 20)],
            alignment: .leading, spacing: 20
        ) {
            ForEach(toplists) { toplist in
                AppDestinationLink(value: Destination.playlist(toplist.id)) {
                    HStack(spacing: 14) {
                        CachedAsyncImage(url: toplist.coverImgUrl?.resizedImageURL(256))
                            .frame(width: 110, height: 110)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(toplist.name)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(toplist.updateFrequency ?? "")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(toplist.tracks.prefix(3).enumerated()), id: \.offset) { i, preview in
                                    Text("\(i + 1). \(preview.first) - \(preview.second)")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(.primary.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct ToplistsView: View {
    @State private var toplists: [ToplistItem] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ToplistGrid(toplists: toplists)
                    .padding(Theme.Layout.contentInset)
                PlayerClearanceSpacer()
            }
        }
        .navigationTitle("排行榜")
        .task {
            if toplists.isEmpty {
                toplists = (try? await NeteaseAPI.toplists()) ?? []
            }
        }
    }
}
