import Foundation

/// Login state and the user's library: profile, liked track IDs, playlists.
@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    @Published var profile: UserProfile?
    @Published var likedTrackIDs: Set<Int> = []
    @Published var userPlaylists: [PlaylistSummary] = []
    @Published var likedAlbums: [AlbumSummary] = []
    @Published var likedArtists: [ArtistSummary] = []
    @Published var isBootstrapped = false

    var isLoggedIn: Bool { NeteaseClient.shared.isLoggedIn && profile != nil }
    var hasAuthCookie: Bool { NeteaseClient.shared.isLoggedIn }
    var vipType: Int { profile?.vipType ?? 0 }
    var offlineScope: String? {
        guard hasAuthCookie else { return "guest" }
        guard profileBinding == NeteaseClient.shared.authenticationFingerprint else { return nil }
        return profile.map { "netease:\($0.userId)" }
    }
    private var profileBinding: String?
    private var bootstrapGeneration = 0

    var likedSongsPlaylist: PlaylistSummary? {
        userPlaylists.first(where: \.isLikedSongsList) ?? userPlaylists.first
    }

    var createdPlaylists: [PlaylistSummary] {
        guard let uid = profile?.userId else { return [] }
        return userPlaylists.filter { $0.creator?.userId == uid && !$0.isLikedSongsList }
    }

    var subscribedPlaylists: [PlaylistSummary] {
        guard let uid = profile?.userId else { return [] }
        return userPlaylists.filter { $0.creator?.userId != uid }
    }

    private init() {
        if let snapshot = AccountSnapshotStorage.shared.load(fingerprint: NeteaseClient.shared.authenticationFingerprint) {
            profile = snapshot.profile
            likedTrackIDs = snapshot.likedTrackIDs
            userPlaylists = snapshot.playlists
            profileBinding = snapshot.authenticationFingerprint
        }
    }

    /// Called at launch and after login succeeds.
    func bootstrap() async {
        bootstrapGeneration += 1
        let generation = bootstrapGeneration
        defer { if generation == bootstrapGeneration { isBootstrapped = true } }
        guard hasAuthCookie else { applyProfile(nil, binding: nil); return }
        if profileBinding != NeteaseClient.shared.authenticationFingerprint { applyProfile(nil, binding: nil) }
        await refreshCookieIfNeeded()
        guard generation == bootstrapGeneration, let binding = NeteaseClient.shared.authenticationFingerprint else { return }
        if profileBinding != binding { applyProfile(nil, binding: nil) }
        do {
            let fetched = try await NeteaseAPI.userAccount()
            guard generation == bootstrapGeneration, binding == NeteaseClient.shared.authenticationFingerprint else { return }
            applyProfile(fetched, binding: binding)
            saveSnapshot()
        } catch {
            return
        }
        await refreshLibrary()
    }

    func refreshLibrary() async {
        guard let uid = profile?.userId else { return }
        async let playlists = try? NeteaseAPI.userPlaylists(uid: uid)
        async let liked = try? NeteaseAPI.likedTrackIDs(uid: uid)
        let (fetchedPlaylists, fetchedLiked) = await (playlists, liked)
        guard profile?.userId == uid, profileBinding == NeteaseClient.shared.authenticationFingerprint else { return }
        userPlaylists = fetchedPlaylists ?? userPlaylists
        if let ids = fetchedLiked { likedTrackIDs = Set(ids) }
        saveSnapshot()
    }

    func refreshSublists() async {
        let scope = offlineScope
        async let albums = try? NeteaseAPI.likedAlbums()
        async let artists = try? NeteaseAPI.likedArtists()
        let (fetchedAlbums, fetchedArtists) = await (albums, artists)
        guard scope == offlineScope else { return }
        likedAlbums = fetchedAlbums ?? likedAlbums
        likedArtists = fetchedArtists ?? likedArtists
    }

    func isLiked(_ trackID: Int) -> Bool {
        likedTrackIDs.contains(trackID)
    }

    func toggleLike(trackID: Int) async {
        guard isLoggedIn else {
            ToastCenter.shared.show(String(localized: "登录后即可收藏歌曲"))
            return
        }
        let like = !likedTrackIDs.contains(trackID)
        let scope = offlineScope
        // Optimistic update
        if like { likedTrackIDs.insert(trackID) } else { likedTrackIDs.remove(trackID) }
        do {
            try await NeteaseAPI.likeTrack(id: trackID, like: like)
        } catch {
            guard scope == offlineScope else { return }
            if like { likedTrackIDs.remove(trackID) } else { likedTrackIDs.insert(trackID) }
            ToastCenter.shared.show(error.localizedDescription)
        }
        guard scope == offlineScope else { return }
        saveSnapshot()
        NowPlayingManager.shared.refreshLikeState()
    }

    func logout() async {
        bootstrapGeneration += 1
        let oldCookies = NeteaseClient.shared.authenticationCookies()
        NeteaseClient.shared.clearAuthCookies()
        AccountSnapshotStorage.shared.clear()
        applyProfile(nil, binding: nil)
        await NeteaseAPI.logout(detachedCookies: oldCookies)
    }

    private func applyProfile(_ value: UserProfile?, binding: String?) {
        let oldID = profile?.userId
        profile = value
        profileBinding = binding
        if oldID != value?.userId {
            likedTrackIDs = []
            userPlaylists = []
            likedAlbums = []
            likedArtists = []
            PlayerService.shared.activateAccount(scope: offlineScope)
        }
        DownloadManager.shared.activate(accountScope: offlineScope)
    }

    private func saveSnapshot() {
        guard let profile, let binding = profileBinding, binding == NeteaseClient.shared.authenticationFingerprint else { return }
        try? AccountSnapshotStorage.shared.save(.init(authenticationFingerprint: binding, profile: profile,
                                                      likedTrackIDs: likedTrackIDs, playlists: userPlaylists, savedAt: Date()))
    }

    /// Refresh the login cookie at most once per calendar day.
    private func refreshCookieIfNeeded() async {
        let key = "auth.lastCookieRefresh"
        let today = Calendar.current.startOfDay(for: .now).timeIntervalSince1970
        guard UserDefaults.standard.double(forKey: key) < today else { return }
        UserDefaults.standard.set(today, forKey: key)
        await NeteaseAPI.refreshLogin()
    }
}

// MARK: - Toasts

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
}

@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    @Published var current: Toast?
    private var dismissTask: Task<Void, Never>?

    private init() {}

    func show(_ message: String) {
        current = Toast(message: message)
        dismissTask?.cancel()
        dismissTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            current = nil
        }
    }
}
