import SwiftUI

#if os(macOS)
public struct KumoneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var player = PlayerService.shared
    @StateObject private var account = AccountStore.shared
    @StateObject private var settings = SettingsManager.shared
    @StateObject private var toasts = ToastCenter.shared
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some Scene {
        WindowGroup("Kumone", id: "main") {
            MainWindow()
                .environmentObject(player)
                .environmentObject(account)
                .environmentObject(settings)
                .environmentObject(toasts)
                .tint(Theme.accent)
                .preferredColorScheme(settings.appearance.colorScheme)
                .frame(minWidth: player.showNowPlaying
                           ? Theme.Layout.minWindowWidthSidebarCollapsed
                           : Theme.Layout.minWindowWidth,
                       minHeight: Theme.Layout.minWindowHeight)
        }
        .defaultSize(width: Theme.Layout.defaultWindowWidth,
                     height: Theme.Layout.defaultWindowHeight)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton()
            }

            CommandMenu("播放") {
                Button(player.isPlaying ? String(localized: "暂停") : String(localized: "播放")) {
                    player.togglePlayPause()
                }
                .disabled(!player.hasCurrentTrack)

                Button("下一首") { player.next() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button("上一首") { player.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)

                Divider()

                Button("随机播放") { player.toggleShuffle() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("AutoMix 顺序") { player.toggleAutoMixOrder() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(!player.autoMixOrderAvailable)
                Button("循环模式") { player.cycleRepeatMode() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])

                Divider()

                Button(player.currentTrack.map { AccountStore.shared.isLiked($0.id) ? String(localized: "取消喜欢") : String(localized: "喜欢") } ?? String(localized: "喜欢")) {
                    if let track = player.currentTrack {
                        Task { await account.toggleLike(trackID: track.id) }
                    }
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!player.hasCurrentTrack)

                Button("歌词") {
                    player.activePanel = player.activePanel == .lyrics ? nil : .lyrics
                }
                .keyboardShortcut("l", modifiers: .command)

                Button("播放队列") {
                    player.activePanel = player.activePanel == .queue ? nil : .queue
                }
                .keyboardShortcut("u", modifiers: .command)
            }

            // Developer tooling, shipped in every macOS build: the listening
            // machine runs whatever `Scripts/build-app.sh` produced, and a panel
            // that only exists in some configurations is one nobody reaches for.
            // Inert until opened — see `AutoMixDebugModel`.
            CommandMenu(AutoMixDebugPanel.menuTitle) {
                Button {
                    openWindow(id: AutoMixDebugPanel.windowID)
                } label: {
                    Text(verbatim: "AutoMix Debug")
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }

        Window(AutoMixDebugPanel.windowTitle, id: AutoMixDebugPanel.windowID) {
            AutoMixDebugPanel()
                .preferredColorScheme(settings.appearance.colorScheme)
        }
        .defaultSize(width: 460, height: 620)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environmentObject(account)
                .environmentObject(settings)
                .tint(Theme.accent)
                .preferredColorScheme(settings.appearance.colorScheme)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    private var keyMonitor: Any?
    /// Installed by the SwiftUI main scene. Calling it recreates the scene
    /// when its NSWindow was released after the user closed the last window.
    var openMainWindow: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        // Space toggles play/pause unless a text field is being edited.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let noModifiers = event.modifierFlags
                .intersection([.command, .option, .control, .shift]).isEmpty
            let editingText = NSApp.keyWindow?.firstResponder is NSText
                || NSApp.keyWindow?.firstResponder is NSTextView

            // Space: play/pause (unless typing)
            if event.keyCode == 49, noModifiers, !editingText {
                Task { @MainActor in
                    PlayerService.shared.togglePlayPause()
                }
                return nil
            }
            // Esc: close the immersive now-playing page
            if event.keyCode == 53, noModifiers, MainActor.assumeIsolated({ PlayerService.shared.showNowPlaying }) {
                Task { @MainActor in
                    PlayerService.shared.showNowPlaying = false
                }
                return nil
            }
            return event
        }
    }

    @MainActor
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        DockMenu.shared.makeMenu()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        // `hasVisibleWindows` includes helper windows such as desktop lyrics.
        // If the WindowGroup has already released its NSWindow, use the
        // SwiftUI scene action below to create it again.
        if let mainWindow = sender.windows.first(where: {
            $0.styleMask.contains(.titled) && $0.canBecomeMain
        }), !mainWindow.isVisible {
            mainWindow.makeKeyAndOrderFront(nil)
        } else if !sender.windows.contains(where: {
            $0.isVisible && $0.styleMask.contains(.titled) && $0.canBecomeMain
        }) {
            openMainWindow?()
        }
        return true
    }
}
#endif
