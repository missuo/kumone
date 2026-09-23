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

enum MainWindowAmbientOpacity {
    static func gradient(isDark: Bool, intensity: Double) -> Double {
        (isDark ? 0.14 : 0.08) * intensity
    }

    static func glow(isDark: Bool, intensity: Double) -> Double {
        (isDark ? 0.18 : 0.12) * intensity
    }
}

#if os(macOS)
struct MainWindowAmbientConfiguration {
    let showsAmbientBackground: Bool
    let showsTitlebarAmbientBackground: Bool
    let showsNowPlaying: Bool
    let colors: ArtworkColors
    let mainColumnLeadingInset: CGFloat
    let intensity: Double
    let isDark: Bool
}

/// Shares titlebar extension between the artwork tint and now-playing page,
/// restoring the original appearance when neither needs it.
@MainActor
final class MainWindowAmbientAppearanceController {
    private var configuration = MainWindowAmbientConfiguration(
        showsAmbientBackground: false,
        showsTitlebarAmbientBackground: false,
        showsNowPlaying: false,
        colors: .fallback,
        mainColumnLeadingInset: 0,
        intensity: 1,
        isDark: false
    )
    private var titlebarWasTransparent: Bool?
    private var hadFullSizeContentView = false
    private var titlebarMask: TitlebarMaskView?
    private var toolbarUpdateTask: Task<Void, Never>?
    private var isUpdatingLayout = false

    private var extendsContentIntoTitlebar: Bool {
        configuration.showsAmbientBackground || configuration.showsNowPlaying
    }

    /// Fades the titlebar tint along with the window chrome while the
    /// now-playing page covers it.
    func setTitlebarMaskFadedOut(_ fadedOut: Bool) {
        guard let titlebarMask else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadedOut ? 0.2 : 0.25
            titlebarMask.animator().alphaValue = fadedOut ? 0 : 1
        }
    }

    func configure(_ configuration: MainWindowAmbientConfiguration, in window: NSWindow) {
        let wasExtendingContent = extendsContentIntoTitlebar
        let toolbarVisibilityChanged = self.configuration.showsTitlebarAmbientBackground
            != configuration.showsTitlebarAmbientBackground
        self.configuration = configuration

        if !wasExtendingContent, extendsContentIntoTitlebar {
            titlebarWasTransparent = window.titlebarAppearsTransparent
            hadFullSizeContentView = window.styleMask.contains(.fullSizeContentView)
        }
        updateLayout(in: window)
        if !extendsContentIntoTitlebar {
            titlebarWasTransparent = nil
        }

        // SwiftUI can reset the window style after committing toolbar visibility.
        // Reapply after that commit; a quick close/reopen cancels the old request.
        if toolbarVisibilityChanged {
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

        if extendsContentIntoTitlebar || titlebarWasTransparent != nil {
            let transparent = extendsContentIntoTitlebar || titlebarWasTransparent == true
            let fullSize = extendsContentIntoTitlebar || hadFullSizeContentView
            let styleChanged = window.styleMask.contains(.fullSizeContentView) != fullSize
            if window.titlebarAppearsTransparent != transparent {
                window.titlebarAppearsTransparent = transparent
            }
            if styleChanged {
                // Finish the new content geometry in the same transaction. A
                // deferred layout can leave the backdrop behind during zoom.
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    context.allowsImplicitAnimation = false
                    if fullSize {
                        window.styleMask.insert(.fullSizeContentView)
                    } else {
                        window.styleMask.remove(.fullSizeContentView)
                    }
                    window.contentView?.superview?.layoutSubtreeIfNeeded()
                }
            }
        }

        guard configuration.showsAmbientBackground,
              configuration.showsTitlebarAmbientBackground else {
            titlebarMask?.removeFromSuperview()
            titlebarMask = nil
            return
        }
        installTitlebarMask(in: window)
        layoutTitlebarMask(in: window)
    }

    private func installTitlebarMask(in window: NSWindow) {
        guard titlebarMask == nil, let contentView = window.contentView else { return }
        let mask = TitlebarMaskView()
        mask.autoresizingMask = [.width, contentView.isFlipped ? .maxYMargin : .minYMargin]
        contentView.addSubview(mask, positioned: .above, relativeTo: nil)
        titlebarMask = mask
    }

    private func layoutTitlebarMask(in window: NSWindow) {
        guard let mask = titlebarMask, let contentView = window.contentView else { return }
        // During zoom, SwiftUI's detail width can lag behind the window bounds.
        // Anchor to the sidebar edge and size from AppKit's current bounds.
        let leadingInset = max(configuration.mainColumnLeadingInset, 0)
        let width = max(contentView.bounds.width - leadingInset, 0)
        guard width > 0 else {
            mask.isHidden = true
            return
        }

        let titlebarHeight = contentView.bounds.height - window.contentLayoutRect.height
        guard titlebarHeight > 0 else {
            mask.isHidden = true
            return
        }
        let y = contentView.isFlipped
            ? contentView.bounds.minY
            : contentView.bounds.maxY - titlebarHeight
        let frame = CGRect(
            x: contentView.bounds.maxX - width,
            y: y,
            width: width,
            height: titlebarHeight
        )

        if mask.frame != frame {
            mask.frame = frame
        }
        if mask.isHidden {
            mask.isHidden = false
        }
        mask.update(
            colors: configuration.colors,
            intensity: configuration.intensity,
            isDark: configuration.isDark
        )
    }
}

private final class TitlebarMaskView: NSView {
    private let gradientLayer = CAGradientLayer()
    private var appliedColors: ArtworkColors?
    private var appliedIntensity: Double?
    private var appliedIsDark: Bool?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(gradientLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.frame = bounds
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(colors: ArtworkColors, intensity: Double, isDark: Bool) {
        guard appliedColors != colors
                || appliedIntensity != intensity
                || appliedIsDark != isDark else {
            return
        }
        appliedColors = colors
        appliedIntensity = intensity
        appliedIsDark = isDark

        let opacity = CGFloat(
            MainWindowAmbientOpacity.gradient(isDark: isDark, intensity: intensity)
        )
        let appearanceName: NSAppearance.Name = isDark ? .darkAqua : .aqua
        var base = NSColor.windowBackgroundColor.usingColorSpace(.extendedSRGB)
            ?? NSColor.windowBackgroundColor
        NSAppearance(named: appearanceName)?.performAsCurrentDrawingAppearance {
            base = NSColor.windowBackgroundColor.usingColorSpace(.extendedSRGB)
                ?? NSColor.windowBackgroundColor
        }
        let primary = blended(NSColor(colors.primary), over: base, opacity: opacity)
        let secondary = blended(NSColor(colors.secondary), over: base, opacity: opacity)

        CATransaction.begin()
        CATransaction.setDisableActions(Platform.isReduceMotionEnabled)
        CATransaction.setAnimationDuration(0.6)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        gradientLayer.colors = [primary.cgColor, secondary.cgColor]
        gradientLayer.startPoint = CGPoint(x: 0, y: 1)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0)
        CATransaction.commit()
    }

    private func blended(_ color: NSColor, over base: NSColor, opacity: CGFloat) -> NSColor {
        let foreground = color.usingColorSpace(.extendedSRGB) ?? color
        let background = base.usingColorSpace(.extendedSRGB) ?? base
        return NSColor(
            red: background.redComponent + (foreground.redComponent - background.redComponent) * opacity,
            green: background.greenComponent + (foreground.greenComponent - background.greenComponent) * opacity,
            blue: background.blueComponent + (foreground.blueComponent - background.blueComponent) * opacity,
            alpha: 1
        )
    }
}
#endif
