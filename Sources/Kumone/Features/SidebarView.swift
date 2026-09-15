import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarItem
    @Binding var showLogin: Bool

    @EnvironmentObject private var account: AccountStore
    @State private var showNewPlaylist = false
    @State private var newPlaylistName = ""
    @State private var avatarImage: PlatformImage?
#if os(iOS)
    // iPad renders this sidebar layout (IOSMainWindow routes .pad to MainWindow)
    // and, unlike the iPhone tab bar, had no Settings entry — leaving audio
    // quality and other options unreachable (#67/#59). Surface it in the footer.
    @State private var showSettings = false
#endif

    var body: some View {
        List {
            Section {
                row(.home, title: "推荐", icon: "house.fill")
                row(.explore, title: "精选", icon: "square.grid.2x2.fill")
                row(.fm, title: "漫游", icon: "wave.3.right.circle.fill")
            }

            if !account.hasAuthCookie {
                Section("我的") {
                    row(.downloaded, title: "已下载", icon: "arrow.down.circle.fill")
                }
            }
            if account.hasAuthCookie {
                Section("我的") {
                    row(.likedSongs, title: "我喜欢的音乐", icon: "heart.fill")
                    row(.downloaded, title: "已下载", icon: "arrow.down.circle.fill")
                    row(.daily, title: "每日推荐", icon: "calendar")
                    row(.recents, title: "最近播放", icon: "clock.fill")
                    row(.collections, title: "我的收藏", icon: "star.fill")
                    row(.cloud, title: "音乐云盘", icon: "icloud.fill")
                }

                if !account.createdPlaylists.isEmpty {
                    Section {
                        ForEach(account.createdPlaylists) { playlist in
                            playlistRow(playlist)
                        }
                    } header: {
                        HStack {
                            Text("创建的歌单")
                            Spacer()
                            Button {
                                showNewPlaylist = true
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 10, weight: .semibold))
                                    .frame(width: 16, height: 16)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            // Align with the trailing edge of the playlist rows
                            // (rows carry 6pt list inset + 8pt inner padding).
                            .padding(.trailing, 14)
                        }
                    }
                }

                if !account.subscribedPlaylists.isEmpty {
                    Section("收藏的歌单") {
                        ForEach(account.subscribedPlaylists) { playlist in
                            playlistRow(playlist)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            accountFooter
        }
        .task(id: account.profile?.avatarUrl) {
            if let url = account.profile?.avatarUrl?.resizedImageURL(96) {
                avatarImage = await ImageCache.shared.image(for: url)
            } else {
                avatarImage = nil
            }
        }
        .alert("新建歌单", isPresented: $showNewPlaylist) {
            TextField("歌单名称", text: $newPlaylistName)
            Button("创建") {
                let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
                newPlaylistName = ""
                guard !name.isEmpty else { return }
                Task {
                    do {
                        try await NeteaseAPI.createPlaylist(name: name, isPrivate: false)
                        await account.refreshLibrary()
                        ToastCenter.shared.show(String(localized: "歌单已创建"))
                    } catch {
                        ToastCenter.shared.show(error.localizedDescription)
                    }
                }
            }
            Button("取消", role: .cancel) { newPlaylistName = "" }
        }
    }

    private func row(_ item: SidebarItem, title: LocalizedStringKey, icon: String) -> some View {
        SidebarRow(
            title: title, icon: icon, isSelected: selection == item,
            action: { selection = item }
        )
    }

    private func playlistRow(_ playlist: PlaylistSummary) -> some View {
        SidebarPlaylistRow(
            playlist: playlist,
            isSelected: selection == .playlist(playlist.id),
            action: { selection = .playlist(playlist.id) }
        )
        .contextMenu {
            Button("播放") {
                Task {
                    if let detail = try? await NeteaseAPI.playlistDetail(id: playlist.id) {
                        await playPlaylist(detail)
                    }
                }
            }
            Divider()
            if playlist.creator?.userId == account.profile?.userId {
                Button("删除歌单", role: .destructive) {
                    Task {
                        try? await NeteaseAPI.deletePlaylist(id: playlist.id)
                        await account.refreshLibrary()
                    }
                }
            } else {
                Button("取消收藏") {
                    Task {
                        try? await NeteaseAPI.subscribePlaylist(id: playlist.id, subscribe: false)
                        await account.refreshLibrary()
                    }
                }
            }
        }
    }

    private func playPlaylist(_ detail: NeteaseAPI.PlaylistDetailResponse) async {
        var tracks = detail.playlist.tracks
        if tracks.count < detail.playlist.trackCount {
            let ids = detail.playlist.trackIds.map(\.id)
            if let full = try? await NeteaseAPI.songDetails(ids: Array(ids.prefix(1000))) {
                tracks = full.songs
            }
        }
        PlayerService.shared.play(tracks: tracks, source: .playlist(detail.playlist.id))
    }

    @ViewBuilder
    private var accountFooter: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.35)
            HStack(spacing: 0) {
                accountEntry
                    .frame(maxWidth: .infinity, alignment: .leading)
#if os(iOS)
                // iPad-only entries (macOS has toolbar search + the Cmd+, scene).
                // The desktop toolbar doesn't surface search/settings on iPad, so
                // put reliable entries in the always-visible footer (#59/#67).
                Button {
                    selection = .search
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("搜索"))

                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 6)
                .accessibilityLabel(Text("设置"))
#endif
            }
        }
        .background(.ultraThinMaterial)
#if os(iOS)
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .navigationTitle("设置")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("完成") { showSettings = false }
                        }
                    }
            }
        }
#endif
    }

    @ViewBuilder
    private var accountEntry: some View {
        if let profile = account.profile {
            AccountChip(profile: profile, avatarImage: avatarImage)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        } else {
            Button {
                showLogin = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                    Text("登录网易云音乐")
                        .font(.system(size: 12.5, weight: .medium))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}

// MARK: - Account chip

private struct AccountChip: View {
    let profile: UserProfile
    let avatarImage: PlatformImage?

    @EnvironmentObject private var account: AccountStore
    @State private var showPopover = false
    @State private var isHovering = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: 8) {
                avatar(diameter: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.nickname)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if profile.vipType > 0 {
                        Text("黑胶 VIP")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Theme.accent)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous)
                    .fill(isHovering ? Color.primary.opacity(0.06) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(AppAnimation.quick) { isHovering = hovering }
        }
        .popover(isPresented: $showPopover, arrowEdge: .top) {
            accountCard
        }
    }

    @ViewBuilder
    private func avatar(diameter: CGFloat) -> some View {
        if let avatarImage {
            Image(platformImage: avatarImage.circularCropped(diameter: diameter))
                .resizable()
                .frame(width: diameter, height: diameter)
        } else {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: diameter - 2))
                .foregroundStyle(.tertiary)
                .frame(width: diameter, height: diameter)
        }
    }

    private var accountCard: some View {
        VStack(spacing: 12) {
            avatar(diameter: 56)
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            VStack(spacing: 3) {
                HStack(spacing: 6) {
                    Text(profile.nickname)
                        .font(.system(size: 14, weight: .semibold))
                    if profile.vipType > 0 {
                        VIPBadge()
                    }
                }
                if let signature = profile.signature, !signature.isEmpty {
                    Text(signature)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }
            Divider().opacity(0.4)
            Button {
                showPopover = false
                Task { await account.logout() }
            } label: {
                Text("退出登录")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(Theme.accent.opacity(0.1), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.pressable)
        }
        .padding(16)
        .frame(width: 220)
    }
}

// MARK: - Rows

private struct SidebarRow: View {
    let title: LocalizedStringKey
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                Text(title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            } icon: {
                Image(systemName: icon)
                    .foregroundStyle(Theme.accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(selectionBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 6))
    }

    @ViewBuilder
    private var selectionBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous)
                .fill(Color.secondary.opacity(0.22))
        }
    }
}

private struct SidebarPlaylistRow: View {
    let playlist: PlaylistSummary
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                CachedAsyncImage(url: playlist.coverURL?.resizedImageURL(64), animated: false)
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                Text(playlist.name)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(selectionBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 6))
    }

    @ViewBuilder
    private var selectionBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous)
                .fill(Color.secondary.opacity(0.22))
        }
    }
}
