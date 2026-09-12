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

    #if os(macOS)
    @StateObject private var artworkStore = NowPlayingArtworkStore()
    #endif
    @State private var selection: SidebarItem = .home
    @State private var localPath: [Destination] = []
    @State private var showLogin = false
    @State private var detailWidth: CGFloat = 0
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var visibilityBeforeNowPlaying: NavigationSplitViewVisibility?

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
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    detailWidth = width
                }
        }
        .navigationSplitViewStyle(.balanced)
        #if os(macOS)
        .overlay(alignment: .trailing) {
            if settings.showMainWindowAmbientBackground, detailWidth > 0 {
                MainWindowAmbientBackground(
                    colors: artworkStore.colors,
                    intensity: settings.mainWindowAmbientBackgroundIntensity
                )
                    .frame(width: detailWidth)
            }
        }
        #endif
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
        .toolbar(player.showNowPlaying ? .hidden : .automatic, for: .windowToolbar)
        // Keep the single main window alive on Cmd+W / red button so the Dock
        // icon can always bring it back (#60/#63/#66/#70).
        .background(
            MainWindowConfigurator(
                ambientConfiguration: MainWindowAmbientConfiguration(
                    showsAmbientBackground: settings.showMainWindowAmbientBackground,
                    showsTitlebarAmbientBackground: !player.showNowPlaying,
                    colors: artworkStore.colors,
                    mainColumnWidth: detailWidth,
                    intensity: settings.mainWindowAmbientBackgroundIntensity
                )
            )
        )
        #endif
        .playerChrome(detailWidth: detailWidth)
        .environment(\.openLogin, { showLogin = true })
        .environment(\.openDestination, openDestination)
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
            await account.bootstrap()
        }
        .onChange(of: settings.showDesktopLyrics) { _ in
            DesktopLyricsController.shared.sync(with: settings.showDesktopLyrics)
        }
        #if os(macOS)
        .onChange(of: settings.showMainWindowAmbientBackground) { _ in
            artworkStore.setArtworkNeeded(needsCurrentArtwork)
        }
        #endif
        // Collapse the sidebar while the immersive page is open: the split
        // view's divider keeps its resize-cursor rect active even underneath
        // an overlay, leaking the drag cursor onto the now-playing page (#6).
        .onChange(of: player.showNowPlaying) { _ in
            #if os(macOS)
            artworkStore.setArtworkNeeded(needsCurrentArtwork)
            #endif
            if player.showNowPlaying {
                visibilityBeforeNowPlaying = columnVisibility
                columnVisibility = .detailOnly
            } else {
                columnVisibility = visibilityBeforeNowPlaying ?? .all
                visibilityBeforeNowPlaying = nil
            }
        }
        .sheet(isPresented: $showLogin) {
            LoginSheet()
        }
        .overlay {
            if player.showNowPlaying {
                #if os(macOS)
                NowPlayingView(onOpenDestination: openDestination)
                    .environmentObject(artworkStore)
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
        settings.showMainWindowAmbientBackground || player.showNowPlaying
    }
    #endif
}

#if os(macOS)
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

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            context.coordinator.requestAmbientBackgroundConfiguration(
                from: view,
                ambientConfiguration: ambientConfiguration
            )
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.requestAmbientBackgroundConfiguration(
                from: nsView,
                ambientConfiguration: ambientConfiguration
            )
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
            if let window {
                ambientAppearance.updateLayout(in: window)
            }
            forwardee?.windowDidUpdate?(notification)
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
