import SwiftUI


struct PlaylistDetailView: View {
    let playlistID: Int
    var isLikedList = false
    var recommendationContext: RecommendationContext?

    @StateObject private var model: PlaylistContent
    @ObservedObject private var downloads = DownloadManager.shared
    // This page only sends playback commands; individual rows observe playback.
    private let player = PlayerService.shared
    @EnvironmentObject private var account: AccountStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showFullDescription = false
    #if os(macOS)
    @State private var trackViewport = CGRect.zero
    #endif
    #if os(iOS)
    @State private var showSearch = false
    @State private var searchFocused = false
    #endif

    init(playlistID: Int, isLikedList: Bool = false, recommendationContext: RecommendationContext? = nil) {
        self.playlistID = playlistID
        self.isLikedList = isLikedList
        self.recommendationContext = recommendationContext
        _model = StateObject(wrappedValue: PlaylistContent(playlistID: playlistID))
    }

    private var isOwnPlaylist: Bool {
        model.detail?.creator?.userId == account.profile?.userId
    }

    private var isCompact: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone || horizontalSizeClass == .compact
        #else
        return false
        #endif
    }

    private var supportsPlaylistSearch: Bool {
        #if os(iOS)
        return model.detail?.specialType == 5 && isOwnPlaylist
        #else
        return false
        #endif
    }

    private var isSearchActive: Bool {
        #if os(iOS)
        return supportsPlaylistSearch && showSearch
        #else
        return false
        #endif
    }

    var body: some View {
        ScrollViewReader { proxy in
            onlineContent
                .task(id: "\(playlistID):\(account.offlineScope ?? ""):\(downloads.network.isKnown):\(downloads.network.connected)") {
                    await loadPlaylist()
                }
                .toolbar {
                    if model.errorMessage != nil, downloads.network.connected, model.detail != nil {
                        ToolbarItem(placement: .primaryAction) {
                            Button { Task { await loadPlaylist() } } label: { Image(systemName: "arrow.clockwise") }
                                .accessibilityLabel("重试")
                                .help("重试")
                        }
                    }
                    #if os(iOS)
                    if supportsPlaylistSearch && !isSearchActive {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Menu {
                                Button {
                                    withAnimation(AppAnimation.standard) {
                                        showSearch = true
                                        proxy.scrollTo("playlistTop", anchor: .top)
                                    }
                                    searchFocused = true
                                } label: {
                                    Label("在歌单内查找", systemImage: "magnifyingglass")
                                }
                                Menu {
                                    Picker("排序方式", selection: $model.sortOrder) {
                                        ForEach(PlaylistTrackSort.allCases, id: \.self) { order in
                                            Text(LocalizedStringKey(order.rawValue)).tag(order)
                                        }
                                    }
                                } label: {
                                    Label("排序方式", systemImage: "arrow.up.arrow.down")
                                }
                            } label: {
                                Label("更多", systemImage: "ellipsis")
                            }
                            .accessibilityIdentifier("likedSongsMenu")
                        }
                    }
                    #endif
                }
        }
    }

    private func loadPlaylist() async {
        await model.load(allowNetwork: !downloads.network.isKnown || downloads.network.connected,
                         summary: account.userPlaylists.first { $0.id == playlistID })
    }

    private var onlineContent: some View {
        #if os(macOS)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                playlistContents
            }
            .coordinateSpace(name: TrackListView.scrollContentCoordinateSpace)
        }
        .onScrollGeometryChange(for: CGRect.self) { $0.visibleRect } action: { _, rect in
            trackViewport = rect
        }
        // The window extends behind a transparent titlebar. Keep song content
        // inside the safe area instead of painting over the window title.
        .clipped()
        .navigationTitle(model.detail?.name ?? String(localized: "歌单"))
        #else
        ScrollView {
            VStack(alignment: .leading, spacing: isCompact ? 16 : 20) {
                playlistContents
            }
            .id("playlistTop")
            #if os(iOS)
            .background {
                if supportsPlaylistSearch {
                    PlaylistSearchScrollGesture(isSearchActive: showSearch, onPullDown: {
                        withAnimation(AppAnimation.standard) { showSearch = true }
                        searchFocused = true
                    }, onScrollUp: {
                        searchFocused = false
                        withAnimation(AppAnimation.standard) { showSearch = false }
                    })
                }
            }
            #endif
        }
        .navigationTitle(isSearchActive ? String(localized: "搜索歌单内歌曲") : "")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        #endif
    }

    private var trackListLayout: TrackListView.Layout {
        #if os(macOS)
        return .viewport(trackViewport)
        #else
        return .stack
        #endif
    }

    @ViewBuilder
    private var playlistContents: some View {
        if model.loadedScope == account.offlineScope, let detail = model.detail {
            let filteredTracks = model.filteredTracks
            if !isSearchActive {
                if isCompact {
                    compactHeader(detail)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                } else {
                    regularHeader(detail)
                        .padding(.horizontal, Theme.Layout.contentInset)
                        .padding(.top, 16)
                }
            }

            #if os(iOS)
            if isSearchActive {
                HStack(spacing: 4) {
                    PlaylistSearchField(text: $model.filter, isFocused: $searchFocused)
                    Button("取消") {
                        model.filter = ""
                        searchFocused = false
                        withAnimation(AppAnimation.standard) { showSearch = false }
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 8)
                }
                .frame(height: 52)
                .padding(.horizontal, isCompact ? 8 : Theme.Layout.contentInset - 8)
                .padding(.top, 8)
                .transition(.opacity)
            }

            if supportsPlaylistSearch && !model.filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack {
                    Text("找到 \(filteredTracks.count) 首匹配歌曲")
                    if !isSearchActive {
                        Spacer()
                        Button("清空搜索") { model.filter = "" }
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, isCompact ? 16 : Theme.Layout.contentInset)

                if filteredTracks.isEmpty && !model.isLoadingMore && model.errorMessage == nil {
                    EmptyStateView(icon: "magnifyingglass", title: "没有匹配的歌曲",
                                   subtitle: "试试其他歌名、歌手或专辑")
                        .frame(minHeight: 180)
                }
            }
            #endif

            TrackListView(
                tracks: filteredTracks,
                privileges: model.privileges,
                source: .playlist(playlistID),
                context: model.detail.map { .playlist(id: playlistID, name: $0.name) },
                removableFromPlaylistID: isOwnPlaylist ? playlistID : nil,
                onRemoved: { track in Task { await model.remove(track) } },
                recommendationContext: recommendationContext,
                onRecommendationReduced: { model.replaceRecommendation($0, with: $1) },
                layout: trackListLayout
            )
            .padding(.horizontal, isCompact ? 6 : Theme.Layout.contentInset - 10)

            if model.isLoading || model.isLoadingMore {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    #if os(iOS)
                    if supportsPlaylistSearch {
                        Text("正在加载歌单，搜索结果会继续更新…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    #endif
                    Spacer()
                }
                .padding(.vertical, 12)
            } else if model.tracks.isEmpty {
                Text(detail.trackCount == 0 ? String(localized: "歌单暂无歌曲") : String(localized: "联网后载入歌曲"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
            } else if model.tracks.count < detail.trackCount {
                Text("已载入 \(model.tracks.count)/\(detail.trackCount) 首")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, isCompact ? 16 : Theme.Layout.contentInset)
            }

            #if os(iOS)
            if supportsPlaylistSearch, model.tracks.count < detail.trackCount, let message = model.errorMessage {
                VStack(spacing: 8) {
                    Text("歌单未完整加载，搜索结果可能不完整")
                        .font(.subheadline)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("重试") { Task { await loadPlaylist() } }
                        .buttonStyle(.bordered)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, isCompact ? 16 : Theme.Layout.contentInset)
            }
            #endif
        } else if model.isLoading {
            loadingHeader
        } else if let message = model.errorMessage {
            ErrorStateView(message: message) {
                Task { await loadPlaylist() }
            }
            .frame(minHeight: 400)
        } else {
            EmptyStateView(icon: "music.note.list", title: "联网后载入歌曲")
                .frame(minHeight: 400)
        }
        PlayerClearanceSpacer()
    }

    // MARK: - Compact (Mobile) Header

    private func compactHeader(_ detail: PlaylistDetail) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                CachedAsyncImage(url: detail.coverImgUrl?.resizedImageURL(384))
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous))
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 4)

                VStack(alignment: .leading, spacing: 6) {
                    Text(isLikedList ? String(localized: "我喜欢的音乐") : detail.name)
                        .font(.system(size: 16, weight: .bold))
                        .lineLimit(3)

                    if let creator = detail.creator, !isLikedList {
                        HStack(spacing: 6) {
                            CachedAsyncImage(url: creator.avatarUrl?.resizedImageURL(48), animated: false)
                                .frame(width: 18, height: 18)
                                .clipShape(Circle())
                            Text(creator.nickname)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Text("\(detail.trackCount) 首 · \(Formatters.playCount(detail.playCount)) 次播放")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if let description = detail.description, !description.isEmpty {
                Button {
                    showFullDescription = true
                } label: {
                    HStack(spacing: 4) {
                        Text(description.replacingOccurrences(of: "\n", with: " "))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showFullDescription) {
                    NavigationStack {
                        ScrollView {
                            Text(description)
                                .font(.system(size: 14))
                                .padding(20)
                        }
                        .navigationTitle("歌单简介")
                        #if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                        .toolbar {
                            ToolbarItem(placement: .primaryAction) {
                                Button("完成") { showFullDescription = false }
                            }
                        }
                    }
                }
            }

            // Compact Action Bar
            HStack(spacing: 10) {
                Button {
                    player.play(tracks: playable, source: .playlist(playlistID),
                                context: model.detail.map { .playlist(id: playlistID, name: $0.name) })
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                        Text("播放全部 (\(playable.count))")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Theme.accentGradient, in: Capsule())
                    .shadow(color: Theme.accent.opacity(0.3), radius: 6, y: 2)
                }
                .buttonStyle(.pressable)
                .disabled(playable.isEmpty)

                downloadButton(detail, compact: true)

                if isLikedList {
                    Button {
                        startHeartbeat()
                    } label: {
                        Image(systemName: "heart.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 38, height: 38)
                            .background(.primary.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.pressable)
                } else if !isOwnPlaylist, account.isLoggedIn {
                    Button {
                        toggleSubscribe(detail)
                    } label: {
                        Image(systemName: detail.subscribed ? "checkmark" : "plus")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(detail.subscribed ? Theme.accent : .primary)
                            .frame(width: 38, height: 38)
                            .background(.primary.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.pressable)
                }
            }
        }
    }

    // MARK: - Regular (Desktop / iPad) Header

    private func regularHeader(_ detail: PlaylistDetail) -> some View {
        HStack(alignment: .bottom, spacing: 24) {
            CachedAsyncImage(url: detail.coverImgUrl?.resizedImageURL(512))
                .frame(width: 200, height: 200)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 16, y: 8)

            VStack(alignment: .leading, spacing: 8) {
                Text(isLikedList ? String(localized: "我喜欢的音乐") : String(localized: "歌单"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(detail.name)
                    .font(.title.weight(.bold))
                    .lineLimit(2)

                if let creator = detail.creator {
                    HStack(spacing: 6) {
                        CachedAsyncImage(url: creator.avatarUrl?.resizedImageURL(48), animated: false)
                            .frame(width: 18, height: 18)
                            .clipShape(Circle())
                        Text(creator.nickname)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                Text("\(detail.trackCount) 首 · \(Formatters.playCount(detail.playCount)) 次播放 · 更新于 \(Formatters.date(fromMS: detail.updateTime))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)

                if let description = detail.description, !description.isEmpty {
                    Button {
                        showFullDescription = true
                    } label: {
                        Text(description.replacingOccurrences(of: "\n", with: " "))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showFullDescription, arrowEdge: .bottom) {
                        ScrollView {
                            Text(description)
                                .font(.system(size: 13))
                                .padding(16)
                                .frame(width: 380, alignment: .leading)
                        }
                        .frame(maxHeight: 400)
                    }
                }

                Spacer(minLength: 4)

                actionRow(detail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 210)
    }

    private func actionRow(_ detail: PlaylistDetail) -> some View {
        HStack(spacing: 10) {
            Button {
                player.play(tracks: playable, source: .playlist(playlistID),
                            context: .playlist(id: playlistID, name: detail.name))
            } label: {
                Label("播放全部", systemImage: "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Theme.accentGradient, in: Capsule())
                    .shadow(color: Theme.accent.opacity(0.3), radius: 6, y: 2)
            }
            .buttonStyle(.pressable)
            .disabled(playable.isEmpty)

            downloadButton(detail)

            if isLikedList {
                Button {
                    startHeartbeat()
                } label: {
                    Label("心动模式", systemImage: "heart.circle")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.primary.opacity(0.06), in: Capsule())
                }
                .buttonStyle(.pressable)
            } else if !isOwnPlaylist, account.isLoggedIn {
                Button {
                    toggleSubscribe(detail)
                } label: {
                    Label(detail.subscribed ? String(localized: "已收藏") : String(localized: "收藏"),
                          systemImage: detail.subscribed ? "checkmark" : "plus")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.primary.opacity(0.06), in: Capsule())
                }
                .buttonStyle(.pressable)
            }

            #if os(macOS)
            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("搜索歌单内歌曲", text: $model.filter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 130)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.primary.opacity(0.05), in: Capsule())
            #endif
        }
    }

    private var playable: [Track] {
        let tracks = model.orderedTracks
        if SettingsManager.shared.canResolveUnblockedTracks { return tracks }
        return tracks.filter { track in
            downloads.offlineTracksByID[track.id] != nil || track.playability(privilege: model.privileges[track.id],
                           isLoggedIn: account.isLoggedIn,
                           vipType: account.vipType) == .playable
        }
    }

    private func startHeartbeat() {
        Task {
            guard let seed = playable.randomElement() else { return }
            do {
                let tracks = try await NeteaseAPI.intelligenceList(songID: seed.id, playlistID: playlistID)
                guard !tracks.isEmpty else {
                    ToastCenter.shared.show(String(localized: "心动模式暂时不可用"))
                    return
                }
                player.play(tracks: tracks, source: .playlist(playlistID), context: .heartbeat)
                ToastCenter.shared.show(String(localized: "已开启心动模式"))
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

    private func toggleSubscribe(_ detail: PlaylistDetail) {
        Task {
            do {
                try await NeteaseAPI.subscribePlaylist(id: detail.id, subscribe: !detail.subscribed)
                model.detail?.subscribed.toggle()
                await account.refreshLibrary()
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

    private func downloadButton(_ detail: PlaylistDetail, compact: Bool = false) -> some View {
        DownloadCollectionButton(tracks: model.tracks, owner: "playlist:\(playlistID)", name: detail.name,
                                 enabled: model.canDownloadAll, compact: compact)
            .accessibilityHint("等待歌单完整加载后下载全部歌曲")
    }

    private var loadingHeader: some View {
        HStack(alignment: .top, spacing: isCompact ? 14 : 24) {
            SkeletonView(cornerRadius: isCompact ? Theme.Radius.standard : Theme.Radius.large)
                .frame(width: isCompact ? 120 : 200, height: isCompact ? 120 : 200)

            VStack(alignment: .leading, spacing: 10) {
                SkeletonView(cornerRadius: 4).frame(width: 80, height: 14)
                SkeletonView(cornerRadius: 4).frame(maxWidth: isCompact ? 160 : 220, minHeight: 14, maxHeight: 14)
                SkeletonView(cornerRadius: 4).frame(width: 120, height: 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, isCompact ? 16 : Theme.Layout.contentInset)
        .padding(.top, isCompact ? 12 : 16)
    }
}
