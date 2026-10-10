import SwiftUI

struct MainWindow: View {
    private let externalPath: Binding<[Destination]>?
#if os(macOS)
    @Environment(\.openWindow) private var openWindow
#endif
    @Environment(\.colorScheme) private var colorScheme
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
    @State private var detailWidth: CGFloat = 0
    @State private var mainColumnLeadingInset: CGFloat = 0
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var nowPlayingChromeHidden = false
    @State private var nowPlayingChromeFadedOut = false
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

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $selection, showLogin: $showLogin)
                .navigationSplitViewColumnWidth(min: 200, ideal: Theme.Layout.sidebarWidth, max: 280)
        } detail: {
            detailStack
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named("mainWindow"))
                } action: { frame in
                    detailWidth = frame.width
                    mainColumnLeadingInset = frame.minX
                }
        }
        .navigationSplitViewStyle(.balanced)
        .coordinateSpace(name: "mainWindow")
        .overlay(alignment: .trailing) {
            if settings.showMainWindowAmbientBackground, detailWidth > 0 {
                MainWindowAmbientBackground(
                    colors: artworkStore.colors,
                    intensity: settings.mainWindowAmbientBackgroundIntensity
                )
                    .frame(width: detailWidth)
            }
        }
        .toolbar {
            if nowPlayingChromeHidden {
                // Immersive now-playing page: the real items step aside (the
                // sidebar toggle is hidden by the coordinator; `.toolbar(
                // removing:)` is a no-op for the toggle the split view
                // injects), but a 1pt clear placeholder keeps the NSToolbar
                // alive. SwiftUI tears the whole toolbar — and with it the
                // taller titlebar that parks the window buttons at their home
                // position — down when its last item leaves (#128).
                ToolbarItem(placement: .automatic) {
                    Color.clear.frame(width: 1, height: 1)
                }
            } else {
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
                ambientConfiguration: MainWindowAmbientConfiguration(
                    showsAmbientBackground: settings.showMainWindowAmbientBackground,
                    showsTitlebarAmbientBackground: !nowPlayingChromeHidden,
                    showsNowPlaying: player.showNowPlaying,
                    colors: artworkStore.colors,
                    mainColumnLeadingInset: mainColumnLeadingInset,
                    intensity: settings.mainWindowAmbientBackgroundIntensity,
                    isDark: isDarkAppearance
                ),
                titlebarFadedOut: nowPlayingChromeFadedOut,
                toolbarHidden: nowPlayingChromeHidden
            )
        )
        #endif
        .playerChrome(detailWidth: detailWidth)
        #if os(macOS)
        .modifier(OfflinePlaybackAlert(player: player, onDownloads: { openDestination(.downloaded) }))
        .modifier(MeteredDownloadAlert())
        #endif
        .environment(\.openLogin, { showLogin = true })
        .environment(\.openDestination, openDestination)
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
                // Quiet the titlebar as the page rises to cover it: hide the
                // title text, then swap the toolbar's items (search field,
                // sidebar toggle) for a placeholder once nothing is left to
                // see — snapping them away at once reads as a glitch above
                // the rising page. The buttons stay: this page is the whole
                // window, so they are its only way to close, dock or zoom it
                // (#128).
                nowPlayingChromeTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(120))
                    guard !Task.isCancelled else { return }
                    nowPlayingChromeFadedOut = true
                    try? await Task.sleep(for: .milliseconds(230))
                    guard !Task.isCancelled else { return }
                    nowPlayingChromeHidden = true
                }
            } else {
                nowPlayingChromeHidden = false
                nowPlayingChromeFadedOut = false
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
            if player.showNowPlaying, windowVisibility.isOnScreen {
                #if os(macOS)
                NowPlayingView(onOpenDestination: openDestination)
                    .environmentObject(artworkStore)
                    .background(ArrowCursorOverride())
                    // Resolve the slide at the page boundary, including artwork
                    // inserted asynchronously while the transition is running.
                    .geometryGroup()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                #else
                NowPlayingView(onOpenDestination: openDestination)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                #endif
            }
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

    private var isDarkAppearance: Bool {
        (settings.appearance.colorScheme ?? colorScheme) == .dark
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
    let ambientConfiguration: MainWindowAmbientConfiguration
    /// Hides the titlebar text while the immersive page covers the window;
    /// the window buttons stay on top of the page (#128).
    let titlebarFadedOut: Bool
    /// Drops the window toolbar while the immersive page covers the window in
    /// full screen, where the system otherwise pins it over the page. In a
    /// window the toolbar stays (its items swapped for a placeholder) so the
    /// titlebar keeps the height that positions the window buttons (#128).
    let toolbarHidden: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            context.coordinator.requestAmbientBackgroundConfiguration(
                from: view,
                ambientConfiguration: ambientConfiguration
            )
            context.coordinator.setTitlebarFadedOut(titlebarFadedOut)
            context.coordinator.setToolbarHidden(toolbarHidden)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.requestAmbientBackgroundConfiguration(
                from: nsView,
                ambientConfiguration: ambientConfiguration
            )
            context.coordinator.setTitlebarFadedOut(titlebarFadedOut)
            context.coordinator.setToolbarHidden(toolbarHidden)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        private(set) weak var window: NSWindow?
        private weak var forwardee: NSWindowDelegate?
        private let ambientAppearance = MainWindowAmbientAppearanceController()
        private weak var configurationHost: NSView?
        private var pendingAmbientConfiguration: MainWindowAmbientConfiguration?
        private var hasScheduledAmbientConfiguration = false
        private var titlebarFadedOut = false
        private var windowToolbarHidden = false

        /// Hides the titlebar text while the immersive page covers the window.
        /// The toolbar is dropped separately, and the window buttons stay: this
        /// page is the whole window, so they are its only way to close,
        /// minimize or zoom it — and the page paints its backdrop around them
        /// (#128). Leaving them in the system's hands also keeps their
        /// full-screen behaviour (auto-hide, reveal on hover) for free.
        func setTitlebarFadedOut(_ fadedOut: Bool) {
            guard fadedOut != titlebarFadedOut else { return }
            titlebarFadedOut = fadedOut
            window?.titleVisibility = fadedOut ? .hidden : .visible
            ambientAppearance.setTitlebarMaskFadedOut(fadedOut)
        }

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
            applySidebarToggleVisibility(in: toolbar)
        }

        /// Hides the split view's system sidebar-toggle item while the
        /// immersive page is up. `.toolbar(removing: .sidebarToggle)` is a
        /// no-op for the toggle `NavigationSplitView` injects on this macOS,
        /// and a SwiftUI-owned item cannot be dropped by hand — but its view
        /// can be hidden: a hidden view draws nothing while the toolbar keeps
        /// its items and its height (#128). SwiftUI may rebuild the item at
        /// will, so this rides the same re-assert path as the toolbar itself.
        private func applySidebarToggleVisibility(in toolbar: NSToolbar) {
            let shouldHide = windowToolbarHidden
            for item in toolbar.items {
                guard item.itemIdentifier.rawValue
                    .lowercased()
                    .contains("togglesidebar")
                else { continue }
                if item.view?.isHidden != shouldHide {
                    item.view?.isHidden = shouldHide
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
                        // hand-off (see MainWindowAmbientAppearanceController),
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
            window?.titleVisibility = titlebarFadedOut ? .hidden : .visible
            applyWindowToolbarVisibility()
            refreshWindowVisibility()
        }

        func requestAmbientBackgroundConfiguration(
            from host: NSView,
            ambientConfiguration: MainWindowAmbientConfiguration
        ) {
            configurationHost = host
            pendingAmbientConfiguration = ambientConfiguration
            guard !hasScheduledAmbientConfiguration else { return }
            hasScheduledAmbientConfiguration = true

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.hasScheduledAmbientConfiguration = false
                guard let configuration = self.pendingAmbientConfiguration else { return }
                self.pendingAmbientConfiguration = nil
                self.attach(to: self.configurationHost?.window)
                guard let window = self.window else { return }
                self.ambientAppearance.configure(configuration, in: window)
                // SwiftUI re-commits toolbar visibility on its own schedule;
                // put the immersive state back whenever it may have drifted.
                self.applyWindowToolbarVisibility()
            }
        }

        func windowDidUpdate(_ notification: Notification) {
            forwardee?.windowDidUpdate?(notification)
            if let window {
                ambientAppearance.updateLayout(in: window)
            }
            refreshWindowVisibility()
        }

        func windowDidResize(_ notification: Notification) {
            forwardee?.windowDidResize?(notification)
            if let window {
                ambientAppearance.updateLayout(in: window)
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
    @State private var placeholder = "搜索音乐、歌手、专辑"
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
            if let keyword = try? await NeteaseAPI.searchDefaultKeyword(), !keyword.isEmpty {
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
