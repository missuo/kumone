import SwiftUI

#if os(macOS)
import AppKit
#endif

/// A non-interactive artwork tint layered above opaque system surfaces. The low
/// opacity keeps system materials and controls readable.
struct MainWindowAmbientBackground: View {
    let colors: ArtworkColors
    let intensity: Double

    @Environment(\.colorScheme) private var colorScheme

    private var gradientOpacity: Double {
        MainWindowAmbientOpacity.gradient(
            isDark: colorScheme == .dark,
            intensity: intensity
        )
    }

    private var glowOpacity: Double {
        MainWindowAmbientOpacity.glow(
            isDark: colorScheme == .dark,
            intensity: intensity
        )
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [colors.primary, colors.secondary],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .opacity(gradientOpacity)

            RadialGradient(
                colors: [colors.primary.opacity(glowOpacity), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 680
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(
            Platform.isReduceMotionEnabled ? nil : .easeInOut(duration: 0.6),
            value: colors
        )
        .animation(
            Platform.isReduceMotionEnabled ? nil : .easeInOut(duration: 0.6),
            value: intensity
        )
    }
}

/// Geometry changes resize this overlay without invalidating MainWindow.
struct MainColumnAmbientOverlay: View {
    @ObservedObject var geometry: MainColumnGeometry
    let colors: ArtworkColors
    let intensity: Double

    var body: some View {
        if geometry.layout.width > 0 {
            MainWindowAmbientBackground(colors: colors, intensity: intensity)
                .frame(width: geometry.layout.width)
        }
    }
}

enum MainWindowAmbientOpacity {
    static func gradient(isDark: Bool, intensity: Double) -> Double {
        (isDark ? 0.14 : 0.08) * intensity
    }

    static func glow(isDark: Bool, intensity: Double) -> Double {
        (isDark ? 0.18 : 0.12) * intensity
    }
}

#if os(macOS)
/// What the main window's chrome needs from AppKit.
struct MainWindowChromeConfiguration: Equatable {
    /// The immersive now-playing page has taken the toolbar's items away.
    let toolbarItemsHidden: Bool
}

/// Keeps the main window's content running up under a transparent titlebar.
/// The sidebar panel reaches up under the window buttons and the page paints
/// its own backdrop, tint and title in the toolbar's band (`MacSidebarShell`),
/// so the titlebar itself must draw nothing.
@MainActor
final class MainWindowChromeController {
    private var configuration = MainWindowChromeConfiguration(toolbarItemsHidden: false)
    private var toolbarUpdateTask: Task<Void, Never>?
    private var isUpdatingLayout = false

    func configure(_ configuration: MainWindowChromeConfiguration, in window: NSWindow) {
        let toolbarItemsChanged = self.configuration != configuration
        self.configuration = configuration
        updateLayout(in: window)

        // SwiftUI can reset the window style after committing a toolbar
        // change. Reapply after that commit; a quick close/reopen cancels the
        // old request.
        if toolbarItemsChanged {
            toolbarUpdateTask?.cancel()
            toolbarUpdateTask = Task { @MainActor [weak self, weak window] in
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self, let window else { return }
                self.updateLayout(in: window)
            }
        }
    }

    func updateLayout(in window: NSWindow) {
        // Changing styleMask can synchronously send windowDidResize back here.
        guard !isUpdatingLayout else { return }
        isUpdatingLayout = true
        defer { isUpdatingLayout = false }

        if !window.titlebarAppearsTransparent {
            window.titlebarAppearsTransparent = true
        }
        guard !window.styleMask.contains(.fullSizeContentView) else { return }
        // Finish the new content geometry in the same transaction. A deferred
        // layout can leave the backdrop behind during zoom.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            window.styleMask.insert(.fullSizeContentView)
            window.contentView?.superview?.layoutSubtreeIfNeeded()
        }
    }
}
#endif
