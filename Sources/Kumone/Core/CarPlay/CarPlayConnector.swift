// CarPlayConnector.swift — CarPlay lifecycle + template assembly + tap bridging.
// The single public type in KumoneCore, forwarded to by the app target's CarPlaySceneDelegate.

#if os(iOS)
import CarPlay
import Combine
import UIKit

/// Owns the CarPlay connection lifecycle, the template hierarchy, and data loading.
/// It's a singleton — activated when a CarPlay scene connects, cleaned up when it disconnects.
@MainActor
public final class CarPlayConnector: NSObject {

    public static let shared = CarPlayConnector()

    // MARK: - State

    private weak var interfaceController: CPInterfaceController?
    private var tabBar: CPTabBarTemplate?
    private var recommendTab: CPListTemplate?
    private var curatedTab: CPListTemplate?
    private var fmTab: CPListTemplate?
    private var libraryTab: CPListTemplate?
    private weak var playbackQueueTemplate: CPListTemplate?

    private var content = CarPlayContentStore()
    private var cancellables: Set<AnyCancellable> = []
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0

    // MARK: - Now Playing buttons
    // like / dislike are created once in didConnect and cached, because their visual state is
    // driven by mutable properties (isSelected / isEnabled). shuffle and repeat instead carry
    // their state in the button *image*, and CPNowPlayingImageButton's image is immutable, so
    // those two are rebuilt from scratch on every refresh.
    private var likeButton: CPNowPlayingAddToLibraryButton?
    private var dislikeButton: CPNowPlayingImageButton?

    override init() {
        super.init()
    }

    // MARK: - Lifecycle

    /// Called when the CarPlay scene connects. Builds the root template and kicks off data loading.
    public func didConnect(interfaceController: CPInterfaceController, window: CPWindow) {
        self.interfaceController = interfaceController
        content = CarPlayContentStore()
        cancellables.removeAll()

        // Force PlayerService to initialize (sets up the audio session and remote commands).
        _ = PlayerService.shared

        // Login / logout → rebuild every tab from scratch.
        AccountStore.shared.$profile
            .removeDuplicates(by: { $0?.userId == $1?.userId })
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildAllTabs()
            }
            .store(in: &cancellables)

        // userPlaylists changes → only refresh the Library tab. (Also fires on logout when the list gets emptied.)
        AccountStore.shared.$userPlaylists
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.refreshLibraryTab()
            }
            .store(in: &cancellables)

        // FM mode toggle → flips the FM tab action button between "Start Roaming" and "Next", and shows/hides the dislike button on Now Playing.
        PlayerService.shared.$isFMMode
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.refreshNowPlayingButtons()
                self?.updateFMTab()
            }
            .store(in: &cancellables)

        // Shuffle / repeat changes → rebuild those two buttons so their icons reflect the new mode.
        // They can be toggled from the phone, the App UI or CarPlay itself, so CarPlay can't assume
        // it is the only mutator and has to follow the published state.
        PlayerService.shared.$shuffleEnabled
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.refreshNowPlayingButtons()
            }
            .store(in: &cancellables)

        PlayerService.shared.$repeatMode
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.refreshNowPlayingButtons()
            }
            .store(in: &cancellables)

        // Subscribe to isPlaying in addition to isFMMode: the action button label
        // ("Next" vs "Resume Roaming") and the "Now Roaming" row both need to react
        // when playback starts or stops. Watching only isFMMode is what caused the
        // original sync bug — the button would stay stuck on "Start Roaming" forever
        // even after FM was actually playing, because isFMMode flips to true
        // synchronously inside startFM(), well before fmAdvance() has finished
        // fetching tracks and startPlaying() has flipped isPlaying to true.
        // Without this observer there's no later trigger to refresh the tab.
        PlayerService.shared.$isPlaying
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.updateFMTab()
            }
            .store(in: &cancellables)

        // Current track changes → sync the Now Playing "like" button's selected state.
        PlayerService.shared.$currentTrack
            .removeDuplicates(by: { $0?.id == $1?.id })
            .sink { [weak self] track in
                guard let self else { return }
                let liked = track.map { AccountStore.shared.isLiked($0.id) } ?? false
                self.likeButton?.isSelected = liked
            }
            .store(in: &cancellables)

        // Liked-IDs changes (user toggled like somewhere else in the UI) → keep the Now Playing "like" button in sync.
        AccountStore.shared.$likedTrackIDs
            .sink { [weak self] _ in
                guard let self,
                      let track = PlayerService.shared.currentTrack else { return }
                self.likeButton?.isSelected = AccountStore.shared.isLiked(track.id)
            }
            .store(in: &cancellables)

        let player = PlayerService.shared
        Publishers.MergeMany([
            player.$queue.map { _ in () }.eraseToAnyPublisher(),
            player.$shuffledQueue.map { _ in () }.eraseToAnyPublisher(),
            player.$playNextList.map { _ in () }.eraseToAnyPublisher(),
            player.$currentTrack.map { _ in () }.eraseToAnyPublisher(),
            player.$currentIndex.map { _ in () }.eraseToAnyPublisher(),
            player.$shuffleEnabled.map { _ in () }.eraseToAnyPublisher(),
            player.$fmUpcoming.map { _ in () }.eraseToAnyPublisher(),
            player.$isFMMode.map { _ in () }.eraseToAnyPublisher(),
        ])
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.updateQueue() }
        .store(in: &cancellables)

        DownloadManager.shared.$network.map(\.connected).removeDuplicates().dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                if connected { self?.scheduleFullReload(bootstrapIfNeeded: true) }
            }
            .store(in: &cancellables)

        // Configure the Now Playing buttons (persistent — live for the singleton's lifetime).
        configureNowPlayingButtons()

        // Build and install the root template.
        let root = makeRootTemplate()
        tabBar = root
        interfaceController.setRootTemplate(root, animated: true, completion: nil)
        updateLibraryTab()
        updateFMTab()

        // On cold start, finish account bootstrap first, then load all four tabs in their final logged-in/out state.
        scheduleFullReload(bootstrapIfNeeded: true)
    }

    /// Called when the CarPlay scene disconnects. Clears template references but doesn't stop playback.
    public func didDisconnect() {
        CPNowPlayingTemplate.shared.remove(self)
        cancellables.removeAll()
        loadGeneration += 1
        loadTask?.cancel()
        loadTask = nil
        interfaceController = nil
        tabBar = nil
        recommendTab = nil
        curatedTab = nil
        fmTab = nil
        libraryTab = nil
        playbackQueueTemplate = nil
    }

    // MARK: - Root template

    /// Builds the CPTabBarTemplate (Recommend / Curated / Roaming / Library) — mirrors the App's IOSTab layout 1:1.
    private func makeRootTemplate() -> CPTabBarTemplate {
        let recommend = CPListTemplate(title: "推荐", sections: [])
        recommend.tabImage = UIImage(systemName: "house")
        recommend.emptyViewTitleVariants = ["正在加载推荐…"]

        let curated = CPListTemplate(title: "精选", sections: [])
        curated.tabImage = UIImage(systemName: "square.grid.2x2")
        curated.emptyViewTitleVariants = ["正在加载精选…"]

        let fm = CPListTemplate(title: "漫游", sections: [])
        fm.tabImage = UIImage(systemName: "dot.radiowaves.left.and.right")
        fm.emptyViewTitleVariants = [String(localized: "请先登录网易云音乐")]

        let library = CPListTemplate(title: "我的", sections: [])
        library.tabImage = UIImage(systemName: "person.crop.circle")
        library.emptyViewTitleVariants = [String(localized: "请先登录网易云音乐")]

        self.recommendTab = recommend
        self.curatedTab = curated
        self.fmTab = fm
        self.libraryTab = library

        // CPNowPlayingTemplate is auto-presented by CarPlay whenever audio plays; it can't be added as a CPTabBarTemplate tab.
        return CPTabBarTemplate(templates: [recommend, curated, fm, library])
    }

    // MARK: - Now Playing button configuration

    /// Creates and caches the like / dislike buttons in didConnect, wires up the queue and
    /// album-artist controls, then installs the button row on CPNowPlayingTemplate.
    /// - like (CPNowPlayingAddToLibraryButton): always shown, mirrors the App's global LikeButton.
    /// - dislike (CPNowPlayingImageButton): only shown while in FM mode, mirroring the trash button in the App's FMView.
    /// - shuffle / repeat: only shown outside FM mode, where the queue is fixed and reorderable.
    ///   FM has no queue to shuffle or loop, so showing them there would be dead controls.
    private func configureNowPlayingButtons() {
        let nowPlaying = CPNowPlayingTemplate.shared

        // Up Next: CarPlay leaves this button dead unless the app both enables it and pushes its
        // own template from the observer callback below.
        nowPlaying.isUpNextButtonEnabled = true
        nowPlaying.upNextTitle = "播放队列"
        nowPlaying.isAlbumArtistButtonEnabled = true
        nowPlaying.add(self)

        // "Like" button — uses the system's "add to library" styled button.
        let like = CPNowPlayingAddToLibraryButton(handler: { _ in
            guard let trackID = PlayerService.shared.currentTrack?.id else { return }
            Task { await AccountStore.shared.toggleLike(trackID: trackID) }
        })
        like.isEnabled = true
        like.isSelected = PlayerService.shared.currentTrack
            .map { AccountStore.shared.isLiked($0.id) } ?? false
        self.likeButton = like

        // "Dislike" button — custom SF Symbol icon, only shown and enabled while FM mode is on.
        let dislike = CPNowPlayingImageButton(
            image: UIImage(systemName: "hand.thumbsdown.fill")!,
            handler: { _ in PlayerService.shared.fmTrash() }
        )
        dislike.isEnabled = PlayerService.shared.isFMMode
        self.dislikeButton = dislike

        refreshNowPlayingButtons()
    }

    /// Recomputes the whole Now Playing button row from current player state.
    private func refreshNowPlayingButtons() {
        guard let likeButton, let dislikeButton else { return }
        let player = PlayerService.shared
        let isFMMode = player.isFMMode

        dislikeButton.isEnabled = isFMMode

        var buttons: [CPNowPlayingButton] = [likeButton]
        if isFMMode {
            buttons.append(dislikeButton)
        } else {
            buttons.append(makeShuffleButton(enabled: player.shuffleEnabled))
            buttons.append(makeRepeatButton(mode: player.repeatMode))
        }

        CPNowPlayingTemplate.shared.updateNowPlayingButtons(buttons)
    }

    /// A tinted `shuffle` glyph — red when shuffle is on, muted when off.
    /// The tint has to be baked into the image (`.alwaysOriginal`) because
    /// CPNowPlayingImageButton exposes no selected/tint state of its own.
    private func makeShuffleButton(enabled: Bool) -> CPNowPlayingImageButton {
        let image = nowPlayingGlyph("shuffle", active: enabled)
        return CPNowPlayingImageButton(image: image) { _ in
            PlayerService.shared.toggleShuffle()
        }
    }

    /// A tinted `repeat` / `repeat.1` glyph tracking the three-state repeat mode.
    private func makeRepeatButton(mode: RepeatMode) -> CPNowPlayingImageButton {
        let symbol = mode == .one ? "repeat.1" : "repeat"
        let image = nowPlayingGlyph(symbol, active: mode != .off)
        return CPNowPlayingImageButton(image: image) { _ in
            PlayerService.shared.cycleRepeatMode()
        }
    }

    private func nowPlayingGlyph(_ systemName: String, active: Bool) -> UIImage {
        let config = UIImage.SymbolConfiguration(pointSize: 18, weight: active ? .bold : .regular)
        let tint: UIColor = active ? .systemRed : .secondaryLabel
        return UIImage(systemName: systemName, withConfiguration: config)?
            .withTintColor(tint, renderingMode: .alwaysOriginal)
            ?? UIImage()
    }

    // MARK: - Now Playing navigation

    /// Pushes the live playback queue when the driver taps the Up Next button.
    func queueSnapshot() -> CPListTemplate {
        let player = PlayerService.shared
        let scope = AccountStore.shared.offlineScope
        return CarPlayTemplateFactory.queueTemplate(
            current: player.currentTrack, upcoming: player.upcomingTracks,
            onCurrentTap: { [weak self] in
                guard scope == AccountStore.shared.offlineScope else { return }
                self?.interfaceController?.popTemplate(animated: true, completion: nil)
            },
            onTrackTap: { [weak self] index, track in
                guard scope == AccountStore.shared.offlineScope else { return }
                player.jumpToUpcoming(at: index, matching: track.id)
                self?.interfaceController?.popTemplate(animated: true, completion: nil)
            }
        )
    }

    private func showQueue() {
        let template = queueSnapshot()
        playbackQueueTemplate = template
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func updateQueue() {
        guard let template = playbackQueueTemplate else { return }
        template.updateSections(queueSnapshot().sections)
    }

    /// The list already contains the phone's track metadata. Playback resolves
    /// audio through its shared local-first player without loading the list again.
    static func playLoadedTracks(_ tracks: [Track], context: PlayContext, startAt: Track? = nil) {
        PlayerService.shared.play(tracks: tracks, source: context.source, startAt: startAt, context: context)
    }

    /// Opens the current track's album, falling back to its first artist when the track carries no
    /// album (cloud-disk uploads and some FM tracks decode with `album.id == 0`).
    private func showAlbumOrArtistOfCurrentTrack() {
        guard let track = PlayerService.shared.currentTrack else { return }

        if track.album.id > 0 {
            pushTracks(
                title: track.album.name,
                context: .album(id: track.album.id, name: track.album.name)
            )
        } else if let artist = track.artists.first, artist.id > 0 {
            pushTracks(
                title: artist.name,
                context: .artist(id: artist.id, name: artist.name)
            )
        }
    }

    // MARK: - Data loading

    /// The Recommend tab's section order matches `HomeView.loadedBody` 1:1.
    private static let homeToplistWhitelist: Set<Int> = [
        19_723_756, 3_779_629, 2_884_035, 3_778_678, 60_198
    ]

    /// Loads all four tabs' data into an independent snapshot in parallel.
    /// The last three fetchers are guarded by `loggedIn` so logged-out callers don't hit a guaranteed 401.
    private func loadAllTabs(into content: CarPlayContentStore, loggedIn: Bool) async {
        if DownloadManager.shared.network.isKnown && !DownloadManager.shared.network.connected {
            await content.fetchDailyTracks(loggedIn: loggedIn)
            await content.fetchRecentsTracks(loggedIn: loggedIn)
            await content.fetchCloudTracks(loggedIn: loggedIn)
            return
        }
        async let r: Void = content.fetchRecommendPlaylists(loggedIn: loggedIn)
        async let c: Void = content.fetchCuratedPlaylists()
        async let o: Void = content.fetchOfficialPlaylists()
        async let ch: Void = content.fetchChinesePlaylists()
        async let t: Void = content.fetchToplists()
        async let d: Void = content.fetchDailyTracks(loggedIn: loggedIn)
        async let e: Void = content.fetchRecentsTracks(loggedIn: loggedIn)
        async let l: Void = content.fetchCloudTracks(loggedIn: loggedIn)
        async let rd: Void = content.fetchRadarPlaylists(loggedIn: loggedIn)
        async let al: Void = content.fetchNewAlbums()
        async let ar: Void = content.fetchTopArtists()

        _ = await (r, c, o, ch, t, d, e, l, rd, al, ar)
    }

    /// Only the latest batch of requests is allowed to commit, so cold-start or account-switch races can't let an older account's data clobber a newer one.
    private func scheduleFullReload(bootstrapIfNeeded: Bool) {
        loadGeneration += 1
        let generation = loadGeneration
        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await DownloadManager.shared.start()
            guard !Task.isCancelled, generation == loadGeneration, interfaceController != nil else { return }
            updateLibraryTab()
            updateFMTab()
            if bootstrapIfNeeded, !AccountStore.shared.isBootstrapped,
               !DownloadManager.shared.network.isKnown || DownloadManager.shared.network.connected {
                await AccountStore.shared.bootstrap()
            }
            guard !Task.isCancelled,
                  generation == loadGeneration,
                  interfaceController != nil else { return }

            let nextContent = content.copyForReload()
            let loggedIn = AccountStore.shared.isLoggedIn
            await loadAllTabs(into: nextContent, loggedIn: loggedIn)
            guard !Task.isCancelled,
                  generation == loadGeneration,
                  interfaceController != nil else { return }

            content = nextContent
            updateRecommendTab()
            updateCuratedTab()
            updateFMTab()
            updateLibraryTab()
        }
    }

    /// Refreshes the Recommend tab's sections, matching `App HomeView.loadedBody` exactly:
    /// 1. Today's picks (feature cards: Daily / Personal FM / Heartbeat) — login-only
    /// 2. Recommended playlists
    /// 3. Radar playlists — login-only
    /// 4. Toplists (5 fixed IDs, same as the App)
    /// 5. New albums
    /// 6. Recommended artists
    private func updateRecommendTab() {
        guard let recommendTab else { return }
        var sections: [CPListSection] = []
        let loggedIn = AccountStore.shared.isLoggedIn

        // 1. Today's picks — feature cards
        if loggedIn {
            sections.append(contentsOf: CarPlayTemplateFactory.recommendFeatureSections(
                onTap: { [weak self] feature in self?.handleRecommendFeatureTap(feature) }
            ))
        }

        // 2. Recommended playlists
        sections.append(contentsOf: CarPlayTemplateFactory.playlistSections(
            content.recommendPlaylists,
            onPlaylistTap: { [weak self] playlist in
                self?.pushPlaylistDetail(playlist)
            }
        ))

        // 3. Radar playlists — login-only
        if loggedIn, !content.radarPlaylists.isEmpty {
            sections.append(contentsOf: CarPlayTemplateFactory.radarPlaylistSections(
                content.radarPlaylists,
                onTap: { [weak self] radar in self?.pushRadarPlaylist(radar) }
            ))
        }

        // 4. Toplists (5 entries, filtered with the same whitelist App HomeView uses).
        let homeToplists = content.toplists.filter {
            Self.homeToplistWhitelist.contains($0.id)
        }
        if !homeToplists.isEmpty {
            let toplistItems = homeToplists.map { toplist -> CPListItem in
                let item = CPListItem(text: toplist.name, detailText: toplist.updateFrequency)
                item.accessoryType = .none
                item.handler = { [weak self] _, completion in
                    self?.pushToplistDetail(toplist)
                    completion()
                }
                CarPlayTemplateFactory.fillArtwork(item, from: toplist.coverImgUrl)
                return item
            }
            sections.append(CPListSection(items: toplistItems, header: "排行榜", sectionIndexTitle: nil))
        }

        // 5. New albums
        if !content.newAlbums.isEmpty {
            sections.append(contentsOf: CarPlayTemplateFactory.newAlbumSections(
                content.newAlbums,
                onTap: { [weak self] album in self?.pushAlbum(album) }
            ))
        }

        // 6. Recommended artists
        if !content.topArtists.isEmpty {
            sections.append(contentsOf: CarPlayTemplateFactory.topArtistSections(
                content.topArtists,
                onTap: { [weak self] artist in self?.pushArtist(artist) }
            ))
        }

        recommendTab.updateSections(sections)
        if sections.isEmpty {
            recommendTab.emptyViewTitleVariants = ["暂无推荐歌单"]
        }
    }

    /// Tap handler for the Recommend tab's top feature rows:
    /// - Daily → push the tracks list (reuses the Library tab's .daily entry)
    /// - Personal FM → start FM
    /// - Heartbeat → use `likedSongsPlaylist` + `likedTrackIDs` to drive `intelligenceList` (same as HomeView)
    private func handleRecommendFeatureTap(_ feature: CarPlayRecommendFeature) {
        switch feature {
        case .daily:
            pushLibraryEntry(.daily, liked: nil)
        case .fm:
            PlayerService.shared.startFM()
        case .heartbeat:
            startHeartbeatMode()
        }
    }

    /// Heartbeat mode: pick one random liked track as a seed, then ask
    /// `intelligenceList` for a similar queue. Copied from `HomeView.startHeartbeatMode`
    /// so we don't have to expose HomeView to CarPlay.
    private func startHeartbeatMode() {
        let account = AccountStore.shared
        guard let likedList = account.likedSongsPlaylist else {
            ToastCenter.shared.show(String(localized: "未找到我喜欢的音乐"))
            return
        }
        Task {
            guard let seed = account.likedTrackIDs.randomElement() else {
                ToastCenter.shared.show(String(localized: "先收藏一些喜欢的歌曲吧"))
                return
            }
            do {
                let tracks = try await NeteaseAPI.intelligenceList(songID: seed, playlistID: likedList.id)
                guard !tracks.isEmpty else {
                    ToastCenter.shared.show(String(localized: "心动模式暂时不可用"))
                    return
                }
                PlayerService.shared.play(
                    tracks: tracks,
                    source: .playlist(likedList.id),
                    context: .heartbeat
                )
                ToastCenter.shared.show(String(localized: "已开启心动模式"))
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

    /// Refreshes the Curated tab's sections: high-quality + hot + toplists + official + Chinese playlists.
    /// Mirrors the category chips in App ExploreView (All / Featured / Toplists / Official / Chinese).
    private func updateCuratedTab() {
        guard let curatedTab else { return }
        var sections = CarPlayTemplateFactory.playlistSections(
            content.highQualityPlaylists,
            onPlaylistTap: { [weak self] playlist in
                self?.pushPlaylistDetail(playlist)
            }
        )
        if !content.hotPlaylists.isEmpty {
            let hotItems = content.hotPlaylists.map { playlist -> CPListItem in
                let item = CPListItem(text: playlist.name, detailText: nil)
                item.accessoryType = .none
                item.handler = { [weak self] _, completion in
                    self?.pushPlaylistDetail(playlist)
                    completion()
                }
                CarPlayTemplateFactory.fillArtwork(item, from: playlist.coverURL)
                return item
            }
            sections.append(CPListSection(items: hotItems, header: "热门歌单", sectionIndexTitle: nil))
        }
        // Toplists get their own section below.
        if !content.toplists.isEmpty {
            let toplistItems = content.toplists.map { toplist -> CPListItem in
                let item = CPListItem(text: toplist.name, detailText: toplist.updateFrequency)
                item.accessoryType = .none
                item.handler = { [weak self] _, completion in
                    self?.pushToplistDetail(toplist)
                    completion()
                }
                CarPlayTemplateFactory.fillArtwork(item, from: toplist.coverImgUrl)
                return item
            }
            sections.append(CPListSection(items: toplistItems, header: "排行榜", sectionIndexTitle: nil))
        }
        // Official playlists — backs the "Official" chip in App ExploreView.
        if !content.officialPlaylists.isEmpty {
            sections.append(contentsOf: CarPlayTemplateFactory.playlistSections(
                content.officialPlaylists,
                onPlaylistTap: { [weak self] playlist in self?.pushPlaylistDetail(playlist) },
                header: "官方歌单"
            ))
        }
        // Chinese playlists — backs the "Chinese" chip in App ExploreView.
        if !content.chinesePlaylists.isEmpty {
            sections.append(contentsOf: CarPlayTemplateFactory.playlistSections(
                content.chinesePlaylists,
                onPlaylistTap: { [weak self] playlist in self?.pushPlaylistDetail(playlist) },
                header: "华语歌单"
            ))
        }
        curatedTab.updateSections(sections)
        if content.highQualityPlaylists.isEmpty, content.hotPlaylists.isEmpty, content.toplists.isEmpty,
           content.officialPlaylists.isEmpty, content.chinesePlaylists.isEmpty {
            curatedTab.emptyViewTitleVariants = ["暂无精选歌单"]
        }
    }

    /// Refreshes the Roaming tab on CarPlay. Logged-in users get the FM template
    /// with the currently playing track row plus the action button (Start Roaming /
    /// Next / Resume Roaming). Logged-out users see an empty view prompting them
    /// to sign in to NetEase Music first.
    private func updateFMTab() {
        guard let fmTab else { return }
        let loggedIn = AccountStore.shared.isLoggedIn
        if !loggedIn {
            fmTab.updateSections([])
            fmTab.emptyViewTitleVariants = [String(localized: "请先登录网易云音乐")]
            return
        }
        let player = PlayerService.shared
        let sections = CarPlayTemplateFactory.fmSection(
            isFMMode: player.isFMMode,
            isPlaying: player.isPlaying,
            currentTrack: player.currentTrack,
            onActionTap: { [weak self] in self?.handleFMTap() }
        )
        fmTab.updateSections(sections)
        fmTab.emptyViewTitleVariants = ["正在加载…"]
    }

    /// What happens when the driver taps the FM tab's action button, depending
    /// on what the player is doing right now:
    /// - FM mode is off entirely → fire `startFM()` to begin a fresh roaming
    ///   session (fetches recommendations from NetEase and starts playing).
    /// - FM mode is on and we're playing → skip ahead via `fmNext()`. We
    ///   intentionally don't reuse `next()` here because FM doesn't use the
    ///   normal queue — its tracks are pulled one batch at a time from
    ///   NetEase's recommendation API, and CPNowPlayingTemplate's built-in
    ///   "next" button doesn't know about that semantics. Putting the skip
    ///   right on the FM tab keeps the driver's intent obvious.
    /// - FM mode is on but we're paused → just resume with `togglePlayPause()`.
    ///   Using `startFM()` here would wipe the FM queue and start a brand-new
    ///   session, which is definitely not what the driver wants when they
    ///   just hit pause and are tapping to come back.
    private func handleFMTap() {
        let player = PlayerService.shared
        if !player.isFMMode {
            player.startFM()
        } else if player.isPlaying {
            player.fmNext()
        } else {
            player.togglePlayPause()
        }
    }

    /// Refreshes the Library tab: pulls `userPlaylists` from `AccountStore` and renders 3 sections.
    private func updateLibraryTab() {
        guard let libraryTab else { return }
        let account = AccountStore.shared
        guard account.isLoggedIn else {
            libraryTab.updateSections([])
            libraryTab.emptyViewTitleVariants = [String(localized: "请先登录网易云音乐")]
            return
        }
        let model = CarPlayLibraryModel(
            liked: account.likedSongsPlaylist,
            created: Array(account.createdPlaylists.prefix(20)),
            subscribed: Array(account.subscribedPlaylists.prefix(20)),
            isLoggedIn: true
        )
        let sections = CarPlayTemplateFactory.librarySections(
            library: model,
            onEntryTap: { [weak self] entry in self?.pushLibraryEntry(entry, liked: model.liked) },
            onPlaylistTap: { [weak self] playlist in self?.pushPlaylistDetail(playlist) }
        )
        libraryTab.updateSections(sections)
        libraryTab.emptyViewTitleVariants = ["暂无内容"]
    }

    private func pushLibraryEntry(_ entry: CarPlayLibraryEntry, liked: PlaylistSummary?) {
        let context: PlayContext
        switch entry {
        case .liked:
            guard let liked else { return }
            context = .playlist(id: liked.id, name: liked.name)
        case .daily: context = .daily
        case .recents: context = .recents
        case .cloud: context = .cloud
        }
        pushTracks(title: entry.title, load: { [weak self] in
            await self?.fetchTracks(for: entry, liked: liked)
        }, context: context)
    }

    /// Fetches tracks for a given Library entry. An empty array means "no tracks" or "not logged in".
    private func fetchTracks(for entry: CarPlayLibraryEntry, liked: PlaylistSummary?) async -> [Track] {
        switch entry {
        case .liked:
            guard let liked else { return [] }
            return await content.fetchPlaylistTracks(id: liked.id, name: liked.name)
        case .daily:
            await content.fetchDailyTracks(loggedIn: AccountStore.shared.isLoggedIn)
            return content.dailyTracks
        case .recents:
            await content.fetchRecentsTracks(loggedIn: AccountStore.shared.isLoggedIn)
            return content.recentsTracks
        case .cloud:
            await content.fetchCloudTracks(loggedIn: AccountStore.shared.isLoggedIn)
            return content.cloudTracks
        }
    }

    // MARK: - Radar / album / artist detail

    /// Recommend tab radar tap: `radar.id` is itself a playlist id, so it goes straight through `fetchPlaylistTracks`.
    private func pushRadarPlaylist(_ radar: CarPlayRadarPlaylist) {
        pushTracks(
            title: radar.title,
            load: { [weak self] in
                guard let self else { return nil }
                return await self.content.fetchPlaylistTracks(id: radar.id, name: radar.title)
            },
            context: .playlist(id: radar.id, name: radar.title)
        )
    }

    /// Recommend tab album tap: fetch album details, play the whole album or one song.
    private func pushAlbum(_ album: AlbumSummary) {
        pushTracks(
            title: album.name,
            context: .album(id: album.id, name: album.name)
        )
    }

    /// Recommend tab artist tap: fetch the artist's hot tracks.
    private func pushArtist(_ artist: ArtistSummary) {
        pushTracks(
            title: artist.name,
            context: .artist(id: artist.id, name: artist.name)
        )
    }

    /// Generic "push tracks" helper: shows an empty template first, then fills it with `trackListTemplate` once tracks load.
    private func pushTracks(
        title: String,
        load: (() async -> [Track]?)? = nil,
        context: PlayContext
    ) {
        let loading = CPListTemplate(title: title, sections: [])
        loading.emptyViewTitleVariants = ["正在加载…"]

        guard let controller = interfaceController else { return }
        let scope = AccountStore.shared.offlineScope
        controller.pushTemplate(loading, animated: true) { [weak self, weak controller] _, _ in
            Task { @MainActor in
                guard let self, let controller, self.interfaceController === controller else { return }
                let tracks: [Track]?
                if let load { tracks = await load() }
                else { tracks = (try? await PlayerService.shared.resolve(context))?.tracks }
                guard self.interfaceController === controller, scope == AccountStore.shared.offlineScope else { return }
                guard let tracks, !tracks.isEmpty else {
                    loading.emptyViewTitleVariants = ["暂无曲目"]
                    loading.updateSections([])
                    return
                }
                let detail = CarPlayTemplateFactory.trackListTemplate(
                    title: title, trackCount: tracks.count, tracks: tracks,
                    onPlayAll: { [weak self, weak controller] in
                        guard let self, let controller, self.interfaceController === controller,
                              scope == AccountStore.shared.offlineScope else { return }
                        Self.playLoadedTracks(tracks, context: context)
                    },
                    onTrackTap: { [weak self, weak controller] track, allTracks in
                        guard let self, let controller, self.interfaceController === controller,
                              scope == AccountStore.shared.offlineScope else { return }
                        Self.playLoadedTracks(allTracks, context: context, startAt: track)
                    }
                )
                loading.updateSections(detail.sections)
            }
        }
    }

    // MARK: - Playlist detail

    /// Pushes the playlist detail template: empty template with title first, then populated once tracks load.
    private func pushPlaylistDetail(_ playlist: PlaylistSummary) {
        pushTracks(title: playlist.name, context: .playlist(id: playlist.id, name: playlist.name))
    }

    private func pushToplistDetail(_ toplist: ToplistItem) {
        pushTracks(title: toplist.name, context: .playlist(id: toplist.id, name: toplist.name))
    }

    // MARK: - Login-state rebuild

    /// When the account changes, rebuild all tab data (forces a full cache refresh).
    private func rebuildAllTabs() {
        guard let controller = interfaceController else { return }
        content = CarPlayContentStore()
        playbackQueueTemplate = nil
        let root = makeRootTemplate()
        tabBar = root
        controller.setRootTemplate(root, animated: false, completion: nil)
        updateLibraryTab()
        updateFMTab()
        scheduleFullReload(bootstrapIfNeeded: false)
    }

    /// Library-tab-only refresh (fired when `userPlaylists` changes; doesn't trigger another network roundtrip).
    private func refreshLibraryTab() {
        Task { @MainActor in updateLibraryTab() }
    }
}

// MARK: - CPNowPlayingTemplateObserver

// CPNowPlayingTemplateObserver isn't @MainActor-annotated, so the callbacks have to be declared
// nonisolated and hop back onto the main actor themselves.
extension CarPlayConnector: CPNowPlayingTemplateObserver {

    public nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { @MainActor in self.showQueue() }
    }

    public nonisolated func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { @MainActor in self.showAlbumOrArtistOfCurrentTrack() }
    }
}
#endif
