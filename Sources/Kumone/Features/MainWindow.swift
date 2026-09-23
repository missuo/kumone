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
        #if os(macOS)
        // Immersive now-playing page: hide the whole window toolbar
        // (sidebar toggle, navigation title, search field).
        .toolbar(nowPlayingChromeHidden ? .hidden : .automatic, for: .windowToolbar)
        // Keep the single main window alive on Cmd+W / red button so the Dock
        // icon can always bring it back (#60/#63/#66/#70).
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
                titlebarFadedOut: nowPlayingChromeFadedOut
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
                // Fade the titlebar out as the page rises to cover it, then
                // drop the toolbar once nothing is left to see — snapping it
                // away at once reads as a glitch above the rising page.
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
            if player.showNowPlaying {
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
    let titlebarFadedOut: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            context.coordinator.requestAmbientBackgroundConfiguration(
                from: view,
                ambientConfiguration: ambientConfiguration
            )
            context.coordinator.setTitlebarFadedOut(titlebarFadedOut)
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

        /// Fades the titlebar chrome (traffic lights, title, toolbar) instead
        /// of letting `.toolbar(.hidden)` snap it away. The superview of the
        /// standard window buttons is the titlebar container, so one alpha
        /// animation covers the whole bar.
        func setTitlebarFadedOut(_ fadedOut: Bool) {
            guard fadedOut != titlebarFadedOut else { return }
            titlebarFadedOut = fadedOut
            guard let titlebar = window?
                .standardWindowButton(.closeButton)?.superview
            else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = fadedOut ? 0.2 : 0.25
                context.timingFunction = CAMediaTimingFunction(
                    name: fadedOut ? .easeIn : .easeOut
                )
                titlebar.animator().alphaValue = fadedOut ? 0 : 1
            }
            ambientAppearance.setTitlebarMaskFadedOut(fadedOut)
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
            }
        }

        func windowDidUpdate(_ notification: Notification) {
            forwardee?.windowDidUpdate?(notification)
            if let window {
                ambientAppearance.updateLayout(in: window)
            }
        }

        func windowDidResize(_ notification: Notification) {
            forwardee?.windowDidResize?(notification)
            if let window {
                ambientAppearance.updateLayout(in: window)
            }
        }

        // Hide instead of close; keep the scene alive.
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            sender.orderOut(nil)
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
