import SwiftUI

struct MainWindow: View {
    private let externalPath: Binding<[Destination]>?
#if os(macOS)
    @Environment(\.openWindow) private var openWindow
#endif
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var settings: SettingsManager
    @EnvironmentObject private var toasts: ToastCenter

    /// Whether the main window is on screen at all — the page is put away
    /// while it is not (miniaturised or hidden), see the overlay below.
    @ObservedObject private var windowVisibility = MainWindowVisibility.shared

    #if os(macOS)
    @StateObject private var artworkStore = NowPlayingArtworkStore()
    #else
    @EnvironmentObject private var artworkStore: NowPlayingArtworkStore
    #endif
    @State private var selection: SidebarItem = .home
    @State private var localPath: [Destination] = []
    @State private var showLogin = false
    @State private var mainColumnGeometry = MainColumnGeometry()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var nowPlayingChromeHidden = false
    @State private var nowPlayingChromeTask: Task<Void, Never>?

    init(path: Binding<[Destination]>? = nil) {
        externalPath = path
    }

    private var path: [Destination] {
        get { externalPath?.wrappedValue ?? localPath }
        nonmutating set {
            if let externalPath {
                externalPath.wrappedValue = newValue
            } else {
                localPath = newValue
            }
        }
    }

    private var pathBinding: Binding<[Destination]> {
        externalPath ?? $localPath
    }

    /// The split between sidebar and page. On macOS the sidebar is a fixed
    /// panel and the page slides over it (see `MacSidebarShell`); iPad keeps
    /// the system split view.
    @ViewBuilder
    private var splitLayout: some View {
        #if os(macOS)
        MacSidebarShell {
            SidebarView(selection: $selection, showLogin: $showLogin)
        } detail: {
            measuredDetail
        } tint: {
            if settings.showMainWindowAmbientBackground {
                MainWindowAmbientBackground(
                    colors: artworkStore.colors,
                    intensity: settings.mainWindowAmbientBackgroundIntensity
                )
            }
        }
        #else
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $selection, showLogin: $showLogin)
                .navigationSplitViewColumnWidth(min: 200, ideal: Theme.Layout.sidebarWidth, max: 280)
        } detail: {
            measuredDetail
        }
        .navigationSplitViewStyle(.balanced)
        .overlay(alignment: .trailing) {
            if settings.showMainWindowAmbientBackground {
                MainColumnAmbientOverlay(
                    geometry: mainColumnGeometry,
                    colors: artworkStore.colors,
                    intensity: settings.mainWindowAmbientBackgroundIntensity
                )
            }
        }
        #endif
    }

    private var measuredDetail: some View {
        detailStack
            .onGeometryChange(for: MainColumnGeometry.Layout.self) { proxy in
                MainColumnGeometry.Layout(frame: proxy.frame(in: .named("mainWindow")))
            } action: { layout in
                mainColumnGeometry.update(layout)
            }
    }

    var body: some View {
        splitLayout
        .coordinateSpace(name: "mainWindow")
        .toolbar {
            if nowPlayingChromeHidden {
                // Immersive now-playing page: the real items step aside (the
                // sidebar toggle is hidden by the coordinator; `.toolbar(
                // removing:)` is a no-op for the toggle the split view
                // injects), but a 1pt clear placeholder keeps the NSToolbar
                // alive. SwiftUI tears the whole toolbar — and with it the
                // taller titlebar that parks the window buttons at their home
                // position — down when its last item leaves (#128).
                #if os(macOS)
                if #available(macOS 26.0, *) {
                    ToolbarItem(placement: .automatic) {
                        Color.clear.frame(width: 1, height: 1)
                    }
                    // Without this, macOS 26 wraps the 1pt item in a Liquid
                    // Glass capsule: a thin white bar beside the window
                    // buttons, over the page.
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .automatic) {
                        Color.clear.frame(width: 1, height: 1)
                    }
                }
                #else
                ToolbarItem(placement: .automatic) {
                    Color.clear.frame(width: 1, height: 1)
                }
                #endif
            } else {
                #if os(macOS)
                // The first item, beside the window buttons: it stays put
                // whether the sidebar is open or not.
                // Back follows it, ours rather than the navigation stack's:
                // the stack puts its own before the toggle, which would push
                // the toggle along whenever a page is opened, and wraps it in
                // a Liquid Glass capsule the toggle does not have.
                if #available(macOS 26.0, *) {
                    ToolbarItem(placement: .navigation) {
                        SidebarToggleButton()
                    }
                    // Plain icons over the page, as the split view drew them.
                    .sharedBackgroundVisibility(.hidden)
                    if !path.isEmpty {
                        ToolbarItem(placement: .navigation) {
                            BackButton { path.removeLast() }
                        }
                        .sharedBackgroundVisibility(.hidden)
                    }
                } else {
                    ToolbarItem(placement: .navigation) {
                        SidebarToggleButton()
                    }
                    if !path.isEmpty {
                        ToolbarItem(placement: .navigation) {
                            BackButton { path.removeLast() }
                        }
                    }
                }
                #endif
                #if os(macOS)
                if #available(macOS 26.0, *) {
                    // The window title is hidden (the page draws its own), and
                    // with it went the flexible space that kept the search
                    // field at the trailing end.
                    ToolbarSpacer(.flexible)
                } else {
                    // ToolbarSpacer is macOS 26+. On Sequoia the same title
                    // removal packs the search field next to the sidebar
                    // toggle, so it overflows the sidebar and covers the
                    // page title (#188). A Spacer toolbar item is the
                    // system flexible space.
                    ToolbarItem(id: "kumone.flexibleSpace") {
                        Spacer()
                    }
                }
                #endif
                if #available(macOS 26.0, iOS 26.0, *) {
                    ToolbarItem(placement: .primaryAction) {
                        SearchFieldView { query in
                            path.append(Destination.search(query))
                        }
                    }
                    // Hide the Liquid Glass shared toolbar background behind the
                    // custom capsule search field, else it double-backgrounds on
                    // macOS 26 (dropped by #86's toolbar rewrite, restored here).
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .primaryAction) {
                        SearchFieldView { query in
                            path.append(Destination.search(query))
                        }
                    }
                }
            }
        }
        #if os(macOS)
        // Immersive now-playing page: its real toolbar items (sidebar toggle,
        // title, search field) step aside, and a placeholder keeps the
        // NSToolbar — and the titlebar height that positions the window
        // buttons at the home position — alive (#128). Only full screen drops
        // the toolbar itself, where the system would otherwise pin it over the
        // page. Keep the single main window alive on Cmd+W / red button so the
        // Dock icon can always bring it back (#60/#63/#66/#70).
        .background(
            MainWindowConfigurator(
                chromeConfiguration: MainWindowChromeConfiguration(
                    toolbarItemsHidden: nowPlayingChromeHidden
                ),
                toolbarHidden: nowPlayingChromeHidden,
                toolbarItemsFaded: player.showNowPlaying
            )
        )
        #endif
        .playerChrome(geometry: mainColumnGeometry)
        #if os(macOS)
        .modifier(OfflinePlaybackAlert(player: player, onDownloads: { openDestination(.downloaded) }))
        .modifier(MeteredDownloadAlert())
        #endif
        .environment(\.openLogin, { showLogin = true })
        .environment(\.openDestination, openDestination)
        #if os(macOS)
        .modifier(PlaybackLifecycle())
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .showDownloadedMusic)) { _ in
            player.showNowPlaying = false
            selection = .downloaded
            path = []
        }
        #if os(macOS)
        .environmentObject(artworkStore)
        #endif
        .task {
#if os(macOS)
            // Keep this action in the app delegate: when the user closes the
            // last WindowGroup window, there is no view left to receive a
            // Dock reopen event directly.
            AppDelegate.shared?.openMainWindow = { openWindow(id: "main") }
            artworkStore.setArtworkNeeded(needsCurrentArtwork)
            // The page can be up from the start (restored with the player
            // state), and then `onChange` never sees it open: its toolbar
            // items must step aside all the same, or the sidebar toggle sits
            // over the page's collapse chevron and takes its clicks.
            if player.showNowPlaying { nowPlayingChromeHidden = true }
#endif
            DesktopLyricsController.shared.sync(with: settings.showDesktopLyrics)
            await DownloadManager.shared.start()
            if KumonePaths.isOfflineUITest { selection = .downloaded }
            await account.bootstrap()
        }
        .onChange(of: settings.showDesktopLyrics) { _ in
            DesktopLyricsController.shared.sync(with: settings.showDesktopLyrics)
        }
        #if os(macOS)
        .onChange(of: settings.showMainWindowAmbientBackground) { _ in
            artworkStore.setArtworkNeeded(needsCurrentArtwork)
        }
        // Warm the cover as soon as a track loads: the now-playing page only
        // slides in smoothly when the artwork is already in memory.
        .onChange(of: player.hasCurrentTrack) { _ in
            artworkStore.setArtworkNeeded(needsCurrentArtwork)
        }
        #endif
        .onChange(of: player.showNowPlaying) { _ in
            #if os(macOS)
            artworkStore.setArtworkNeeded(needsCurrentArtwork)
            nowPlayingChromeTask?.cancel()
            if player.showNowPlaying {
                // Swap the toolbar's items (search field, sidebar toggle) for
                // a placeholder once the rising page covers them — snapping
                // them away at once reads as a glitch above the page. The
                // page's title is part of the page and is simply covered.
                // The window buttons stay: this page is the whole window, so
                // they are its only way to close, dock or zoom it (#128).
                nowPlayingChromeTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    nowPlayingChromeHidden = true
                }
            } else {
                nowPlayingChromeHidden = false
            }
            #endif
        }
        .sheet(isPresented: $showLogin) {
            LoginSheet()
        }
        .overlay {
            // The page is put away while the window is off screen
            // (miniaturised or ordered out): the vinyl, lyrics and cover it
            // holds together add up to tens of megabytes, and rebuilding the
            // page takes a single frame when the window comes back. The
            // player state — and the page on restore — is untouched.
            #if os(macOS)
            // The container spans the whole window, the toolbar's band
            // included. The page's own `ignoresSafeArea` does not reach the
            // band while its transition runs, so it rose with the band above
            // it still showing the page underneath (title, tint) and snapped
            // over it only when the slide ended.
            ZStack {
                if player.showNowPlaying, windowVisibility.isOnScreen {
                    NowPlayingView(onOpenDestination: openDestination)
                        .environmentObject(artworkStore)
                        .background(ArrowCursorOverride())
                        // Resolve the slide at the page boundary, including artwork
                        // inserted asynchronously while the transition is running.
                        .geometryGroup()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .ignoresSafeArea()
            #else
            if player.showNowPlaying, windowVisibility.isOnScreen {
                NowPlayingView(onOpenDestination: openDestination)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            #endif
        }
        .overlay(alignment: .top) {
            if let toast = toasts.current {
                ToastView(toast: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 12)
            }
        }
        .animation(AppAnimation.smooth, value: player.showNowPlaying)
        .animation(.spring(duration: 0.3), value: toasts.current)
    }

    private var detailStack: some View {
        NavigationStack(path: pathBinding) {
            rootView
                .playerContentInset()
                .appDestinations()
        }
        .onChange(of: selection) { _ in
            path = []
        }
    }

    private func openDestination(_ destination: Destination) {
        #if os(macOS)
        guard player.showNowPlaying else {
            path.appendIfNotCurrent(destination)
            return
        }

        withAnimation(AppAnimation.smooth, completionCriteria: .removed) {
            player.showNowPlaying = false
        } completion: {
            path.appendIfNotCurrent(destination)
        }
        #else
        player.showNowPlaying = false
        path.appendIfNotCurrent(destination)
        #endif
    }

    @ViewBuilder
    private var rootView: some View {
        switch selection {
        case .downloaded:
            DownloadedMusicView()
        case .home:
            HomeView()
        case .explore:
            ExploreView()
        case .fm:
            FMView()
        case .search:
            // iPad search entry: SearchView's `.searchable` bar surfaces in the
            // detail nav bar (the desktop toolbar search field doesn't render on
            // iPad). (#59)
            SearchView(query: "")
        case .likedSongs:
            if let playlist = account.likedSongsPlaylist {
                PlaylistDetailView(playlistID: playlist.id, isLikedList: true)
                    .id(playlist.id)
            } else {
                loginPrompt
            }
        case .daily:
            DailySongsView()
        case .recents:
            RecentsView()
        case .collections:
            CollectionsView()
        case .cloud:
            CloudView()
        case .playlist(let id):
            PlaylistDetailView(playlistID: id)
                .id(id)
        }
    }

    private var loginPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "heart.circle")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("登录后查看你喜欢的音乐")
                .font(.headline)
            Button("登录") { showLogin = true }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    #if os(macOS)
    private var needsCurrentArtwork: Bool {
        settings.showMainWindowAmbientBackground || player.hasCurrentTrack
    }
    #endif
}

#if os(macOS)
// MARK: - Cursor override

/// Claims the arrow cursor over the whole now-playing page. AppKit cursor
/// rects ignore hit-testing, so without this the split-view divider's resize
/// cursor leaks through the full-window overlay wherever the divider sits (#6).
struct ArrowCursorOverride: NSViewRepresentable {
    func makeNSView(context: Context) -> CursorOverrideView { CursorOverrideView() }

    func updateNSView(_ nsView: CursorOverrideView, context: Context) {}

    final class CursorOverrideView: NSView {
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .arrow)
        }
    }
}

// MARK: - Main window configurator

/// Grabs the single main `NSWindow` once it exists and installs a close
/// interceptor: Cmd+W / the red button *hide* the window (`orderOut`) instead
/// of destroying the single-instance `Window` scene. Destroying the scene left
/// the app running with no way to reopen it (#60/#66/#70); hiding keeps the
/// SwiftUI scene fully alive so `AppDelegate.applicationShouldHandleReopen`
/// can front it again on a Dock click. Every other window-delegate callback is
/// forwarded untouched to SwiftUI's own delegate.
struct MainWindowConfigurator: NSViewRepresentable {
    let chromeConfiguration: MainWindowChromeConfiguration
    /// Drops the window toolbar while the immersive page covers the window in
    /// full screen, where the system otherwise pins it over the page. In a
    /// window the toolbar stays (its items swapped for a placeholder) so the
    /// titlebar keeps the height that positions the window buttons (#128).
    let toolbarHidden: Bool
    /// Fades the toolbar's items (sidebar toggle, search field) out as the
    /// immersive page starts to rise over them, and back in as it leaves,
    /// rather than leaving them over the page until it settles and then
    /// snapping them away.
    let toolbarItemsFaded: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        let configuration = chromeConfiguration
        DispatchQueue.main.async {
            context.coordinator.requestChromeConfiguration(
                from: view,
                configuration: configuration
            )
            context.coordinator.setToolbarHidden(toolbarHidden)
            context.coordinator.setToolbarItemsFaded(toolbarItemsFaded)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let configuration = chromeConfiguration
        DispatchQueue.main.async {
            context.coordinator.requestChromeConfiguration(
                from: nsView,
                configuration: configuration
            )
            context.coordinator.setToolbarHidden(toolbarHidden)
            context.coordinator.setToolbarItemsFaded(toolbarItemsFaded)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        private(set) weak var window: NSWindow?
        private weak var forwardee: NSWindowDelegate?
        private let chrome = MainWindowChromeController()
        private weak var configurationHost: NSView?
        private var pendingChromeConfiguration: MainWindowChromeConfiguration?
        private var hasScheduledChromeConfiguration = false
        private var windowToolbarHidden = false
        /// The toolbar items the immersive page hides, kept so the home page
        /// gets them back; see `suppressImmersiveToolbarItems`.
        private var hiddenToolbarItemIdentifiers: Set<String> = []
        private var titleObservation: NSKeyValueObservation?
        private var toolbarItemsFaded = false

        /// Drops the window toolbar while the immersive page is up *in full
        /// screen*, the classic AppKit way: `toolbar.isVisible = false` takes
        /// the bar away and leaves the window buttons in place. In a window
        /// the toolbar stays: the page swaps its items for a placeholder (see
        /// MainWindow) so the titlebar keeps the height that parks the buttons
        /// at their home position (#128). Hiding it through SwiftUI's
        /// `.toolbar(.hidden, for: .windowToolbar)` instead takes the entire
        /// titlebar — buttons included — down with it, and leaves AppKit's
        /// `isVisible` at `true`, which is what pins a toolbar over the page
        /// in full screen.
        func setToolbarHidden(_ hidden: Bool) {
            guard hidden != windowToolbarHidden else { return }
            windowToolbarHidden = hidden
            applyWindowToolbarVisibility()
        }

        /// See `toolbarItemsFaded`. The window buttons are not toolbar items
        /// and stay as they are.
        func setToolbarItemsFaded(_ faded: Bool) {
            guard faded != toolbarItemsFaded else { return }
            toolbarItemsFaded = faded
            guard let toolbar = window?.toolbar else { return }
            let views = toolbar.items.compactMap(\.view)
            if !faded {
                // Items coming back may be fresh views; start them from clear.
                for view in views { view.alphaValue = 0 }
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = faded ? 0.15 : 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                for view in views { view.animator().alphaValue = faded ? 0 : 1 }
            }
            guard !faded else { return }
            // SwiftUI may put an item's view back after this ran; never leave
            // one clear once the page has gone.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, !self.toolbarItemsFaded,
                      let toolbar = self.window?.toolbar else { return }
                for view in toolbar.items.compactMap(\.view) where view.alphaValue < 1 {
                    view.animator().alphaValue = 1
                }
            }
        }

        /// SwiftUI re-commits toolbar visibility on its own schedule and can
        /// bring the toolbar back mid-immersion, so re-apply whenever the
        /// window state may have moved underneath us. Only full screen hides
        /// the toolbar; in a window it must stay so the window buttons hold
        /// the home position (#128).
        private func applyWindowToolbarVisibility() {
            guard let window, let toolbar = window.toolbar else { return }
            let shouldBeVisible = !(windowToolbarHidden
                && window.styleMask.contains(.fullScreen))
            if toolbar.isVisible != shouldBeVisible {
                toolbar.isVisible = shouldBeVisible
            }
            suppressImmersiveToolbarItems(in: toolbar)
        }

        /// Takes every toolbar item out of the immersive page. The split view's
        /// sidebar toggle and separator, the navigation stack's back button
        /// when the page was opened from a pushed screen, and the 1pt
        /// placeholder MainWindow keeps the bar alive with are all laid out in
        /// the toolbar whether or not the page covers them; `.toolbar(
        /// removing:)` is a no-op for what the frameworks inject. Merely
        /// hiding an item's *view* is not enough: AppKit re-shows toolbar item
        /// views on its own schedule, so hovering brings a button right back,
        /// live and clickable, over the page. Swapping the view for an empty
        /// stand-in is not enough either: the item keeps its slot in the
        /// toolbar's layout, and that slot — the sidebar toggle's sits right
        /// where the page parks its collapse chevron — still swallows every
        /// click, so the chevron only answered to Escape. Hiding the *item*
        /// takes its slot out of the layout altogether; the toolbar itself
        /// stays, so the titlebar keeps the height that parks the window
        /// buttons at their home position (#128).
        private func suppressImmersiveToolbarItems(in toolbar: NSToolbar) {
            if windowToolbarHidden {
                for item in toolbar.items where !item.isHidden {
                    hiddenToolbarItemIdentifiers.insert(item.itemIdentifier.rawValue)
                    item.isHidden = true
                }
            } else {
                let identifiers = hiddenToolbarItemIdentifiers
                hiddenToolbarItemIdentifiers.removeAll()
                for item in toolbar.items where identifiers.contains(item.itemIdentifier.rawValue) {
                    item.isHidden = false
                }
            }
        }

        func attach(to window: NSWindow?) {
            guard let window, self.window == nil else { return }
            self.window = window
            window.isReleasedWhenClosed = false
            // Insert ourselves as the delegate, forwarding to whatever
            // delegate SwiftUI installed.
            if window.delegate !== self {
                forwardee = window.delegate
                window.delegate = self
            }
            AppDelegate.shared?.mainWindow = window
            // The page draws the title at its own leading edge, so it slides
            // with the page instead of sitting beside the toggle; it reads the
            // text SwiftUI still gives the window (see `PageTitleBand`).
            titleObservation = window.observe(\.title, options: [.initial, .new]) { window, _ in
                let title = window.title
                Task { @MainActor in PageTitle.shared.update(title) }
            }
            observeFullScreenChanges(of: window)
            observeWindowVisibility(of: window)
            refreshWindowVisibility()
        }

        /// Full screen hands the titlebar and toolbar to a system-managed
        /// window of their own, and the hand-off re-commits toolbar
        /// visibility: the toolbar can come back pinned over the immersive
        /// page, covering the page's controls and swallowing their clicks —
        /// the collapse chevron then only answers to Escape (#128). Re-assert
        /// the immersive state once the transition settles.
        private func observeFullScreenChanges(of window: NSWindow) {
            let center = NotificationCenter.default
            for name in [
                NSWindow.didEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification
            ] {
                center.addObserver(
                    forName: name,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in
                        self?.reassertChromeState()
                        // SwiftUI re-commits toolbar visibility around the
                        // hand-off (see MainWindowChromeController),
                        // so run one more pass once that commit settles.
                        try? await Task.sleep(for: .milliseconds(100))
                        self?.reassertChromeState()
                    }
                }
            }
        }

        /// SwiftUI keeps the page's `TimelineView`s ticking while the window
        /// is off screen, so track the states that take it there — and bring
        /// it back — and tell `MainWindowVisibility`.
        private func observeWindowVisibility(of window: NSWindow) {
            let center = NotificationCenter.default
            for name in [
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
                NSWindow.didChangeOcclusionStateNotification
            ] {
                center.addObserver(
                    forName: name,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in
                        self?.refreshWindowVisibility()
                    }
                }
            }
        }

        /// Miniaturised, ordered out and fully occluded all mean nothing can
        /// see the page: its animations stand their clocks down, and a window
        /// in the Dock (or hidden) also has the page itself put away
        /// (#128 performance work).
        private func refreshWindowVisibility() {
            guard let window else { return }
            let onScreen = window.isVisible && !window.isMiniaturized
            MainWindowVisibility.shared.update(
                isVisible: onScreen && window.occlusionState.contains(.visible),
                isOnScreen: onScreen
            )
        }

        private func reassertChromeState() {
            applyWindowToolbarVisibility()
            refreshWindowVisibility()
        }

        func requestChromeConfiguration(
            from host: NSView,
            configuration: MainWindowChromeConfiguration
        ) {
            configurationHost = host
            pendingChromeConfiguration = configuration
            guard !hasScheduledChromeConfiguration else { return }
            hasScheduledChromeConfiguration = true

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.hasScheduledChromeConfiguration = false
                guard let configuration = self.pendingChromeConfiguration else { return }
                self.pendingChromeConfiguration = nil
                self.attach(to: self.configurationHost?.window)
                guard let window = self.window else { return }
                self.chrome.configure(configuration, in: window)
                // SwiftUI re-commits toolbar visibility on its own schedule;
                // put the immersive state back whenever it may have drifted.
                self.applyWindowToolbarVisibility()
            }
        }

        func windowDidUpdate(_ notification: Notification) {
            forwardee?.windowDidUpdate?(notification)
            if let window {
                chrome.updateLayout(in: window)
                // SwiftUI and AppKit bring hidden toolbar items back on their
                // own schedule; while the immersive page is up, put them away
                // again at once. One that came back (faded out, so unseen)
                // sat over the page's collapse chevron and took its clicks.
                if windowToolbarHidden, let toolbar = window.toolbar {
                    suppressImmersiveToolbarItems(in: toolbar)
                }
            }
            refreshWindowVisibility()
        }

        func windowDidResize(_ notification: Notification) {
            forwardee?.windowDidResize?(notification)
            if let window {
                chrome.updateLayout(in: window)
            }
            refreshWindowVisibility()
        }

        // Hide instead of close; keep the scene alive.
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            sender.orderOut(nil)
            refreshWindowVisibility()
            return false
        }

        // Transparently forward every other delegate callback to SwiftUI.
        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (forwardee?.responds(to: aSelector) ?? false)
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if forwardee?.responds(to: aSelector) == true { return forwardee }
            return super.forwardingTarget(for: aSelector)
        }
    }
}
#endif

// MARK: - Search field

struct SearchFieldView: View {
    let onSubmit: (String) -> Void

    @State private var text = ""
    @State private var placeholder = String(localized: "搜索音乐、歌手、专辑")
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($focused)
                .frame(width: 168)
                .onSubmit {
                    let query = text.trimmingCharacters(in: .whitespaces)
                    let effective = query.isEmpty ? placeholderQuery : query
                    guard !effective.isEmpty else { return }
                    onSubmit(effective)
                    focused = false
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.primary.opacity(0.05), in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(focused ? 0.18 : 0.08), lineWidth: 1))
        #if os(macOS)
        // Keep the capsule off the window's rounded top-right corner (#88).
        .padding(.trailing, 8)
        #endif
        .animation(AppAnimation.quick, value: focused)
        .task {
            if let keyword = try? await MusicAPI.searchDefaultKeyword(), !keyword.isEmpty {
                placeholder = keyword
                placeholderQuery = keyword
            }
        }
    }

    @State private var placeholderQuery = ""
}

// MARK: - Toast

struct ToastView: View {
    let toast: Toast

    var body: some View {
        Text(toast.message)
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .compatGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }
}
