import Combine
import SwiftUI

#if os(macOS)
public struct KumoneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var player = PlayerService.shared
    @StateObject private var account = AccountStore.shared
    @StateObject private var settings = SettingsManager.shared
    @StateObject private var toasts = ToastCenter.shared

    public init() {}

    public var body: some Scene {
        Window("Kumone", id: "main") {
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
                Button("循环模式") { player.cycleRepeatMode() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])

                Divider()

                SleepTimerMenu(player: player)

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
        }

        Settings {
            SettingsView()
                .environment(\.openDestination, { destination in
                    guard destination == .downloaded else { return }
                    NotificationCenter.default.post(name: .showDownloadedMusic, object: nil)
                    _ = AppDelegate.shared?.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true)
                })
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
    private var appearanceObserver: AnyCancellable?
    /// Installed by the SwiftUI main scene. Calling it recreates the scene
    /// when its NSWindow was released after the user closed the last window.
    var openMainWindow: (() -> Void)?
    /// The single main window, captured by `MainWindowConfigurator`. Its close
    /// interceptor hides (orders out) the window instead of destroying the
    /// single-instance `Window` scene, so we can always bring it back here.
    weak var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        // Drive NSApp.appearance from the setting so the NATIVE window chrome
        // (both main and Settings window titlebars/forms) tracks it. SwiftUI's
        // `.preferredColorScheme` alone doesn't reliably revert the native
        // titlebar when switching a fixed theme back to "follow system" (#94).
        applyAppearance(SettingsManager.shared.appearance.colorScheme)
        appearanceObserver = SettingsManager.shared.$appearance
            .map(\.colorScheme)
            .removeDuplicates()
            .sink { [weak self] scheme in self?.applyAppearance(scheme) }
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

    private func applyAppearance(_ scheme: ColorScheme?) {
        switch scheme {
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil // follow system
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
        // `hasVisibleWindows` is unreliable here: helper windows such as the
        // desktop-lyrics overlay make it `true` even when the main window is
        // gone, so decide based on the main window itself.
        //
        // `MainWindowConfigurator` keeps the main window alive on close
        // (orders it out rather than destroying the scene), so it is normally
        // still around — just hidden and/or miniaturised, and possibly behind
        // other windows. Restore and front it. Only if it truly no longer
        // exists do we ask SwiftUI to recreate the scene.
        let target = mainWindow ?? sender.windows.first {
            $0.styleMask.contains(.titled) && $0.canBecomeMain
        }
        if let window = target {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            openMainWindow?()
        }
        // Fully handled above; returning `false` prevents AppKit from also
        // enqueuing another SwiftUI scene request (which re-created #58's
        // duplicate window).
        return false
    }
}
#endif
