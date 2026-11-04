#if os(macOS)
import AppKit
import SwiftUI

/// LyricsX-style desktop lyrics: a borderless, transparent, screen-sized
/// window that never becomes key. Only the lyric box is hit-testable
/// (transparent regions pass clicks through); position is stored as two
/// 0…1 factors so display changes and multi-monitor setups just work.
@MainActor
final class DesktopLyricsController {
    static let shared = DesktopLyricsController()

    private var window: NSWindow?
    private var observers: [NSObjectProtocol] = []

    private init() {}

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        if window == nil {
            let window = KeylessWindow(
                contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true
            )
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            window.sharingType = .none // keep lyrics out of screenshots/recordings
            window.isReleasedWhenClosed = false

            let host = NSHostingView(rootView: DesktopLyricsSurface())
            host.layer?.backgroundColor = .clear
            window.contentView = host
            self.window = window

            let center = NotificationCenter.default
            observers.append(center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.updateFrame() }
            })
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.updateFrame() }
            })
        }
        updateFrame()
        window?.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    func sync(with enabled: Bool) {
        enabled ? show() : hide()
    }

    private func updateFrame() {
        guard let window else { return }
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        window.setFrame(screen.visibleFrame, display: true)
    }
}

/// A borderless window that never steals focus.
private final class KeylessWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Content

/// Screen-sized transparent surface positioning the lyric box by two 0…1
/// factors (x from left, y from top), draggable with an 8pt center snap.
private struct DesktopLyricsSurface: View {
    @StateObject private var player = PlayerService.shared
    @StateObject private var settings = SettingsManager.shared

    @AppStorage("desktopLyrics.xFactor") private var xFactor = 0.5
    @AppStorage("desktopLyrics.yFactor") private var yFactor = 0.9
    @State private var dragOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let centered = settings.desktopLyricsCentered
            let effectiveX = centered ? 0.5 : xFactor
            let base = CGPoint(x: geo.size.width * effectiveX, y: geo.size.height * yFactor)
            DesktopLyricsBox()
                .position(x: base.x + (centered ? 0 : dragOffset.width),
                          y: base.y + dragOffset.height)
                .gesture(
                    // Global coordinate space: measuring the drag in the box's
                    // own (moving) space feedback-loops and flings it off screen.
                    DragGesture(coordinateSpace: .global)
                        .onChanged { value in
                            // When centred, only vertical movement matters.
                            dragOffset = centered
                                ? CGSize(width: 0, height: value.translation.height)
                                : value.translation
                        }
                        .onEnded { value in
                            if !centered {
                                var x = (base.x + value.translation.width) / geo.size.width
                                if abs(x - 0.5) * geo.size.width < 8 { x = 0.5 }
                                xFactor = min(max(x, 0.02), 0.98)
                            }
                            var y = (base.y + value.translation.height) / geo.size.height
                            if abs(y - 0.5) * geo.size.height < 8 { y = 0.5 }
                            yFactor = min(max(y, 0.02), 0.98)
                            dragOffset = .zero
                        }
                )
        }
        .environmentObject(player)
        .environmentObject(settings)
    }
}

private struct DesktopLyricsBox: View {
    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var lyricsCursor = PlayerService.shared.lyricsCursor
    @EnvironmentObject private var settings: SettingsManager

    private var currentLine: LyricLine? {
        guard player.isPlaying || PlayerService.shared.progress > 0,
              let lyrics = player.lyrics, !lyrics.isEmpty,
              let index = lyricsCursor.activeIndex else { return nil }
        return lyrics.lines[index]
    }

    var body: some View {
        Group {
            if let line = currentLine, !line.text.isEmpty {
                // The box itself stays put; only the text crossfades and the
                // capsule width eases to the new line's size.
                VStack(spacing: 5) {
                    if settings.lyricsAnnotation == .romaji, let romaji = line.romaji {
                        Text(romaji)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.78))
                            .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                            .contentTransition(.opacity)
                    }
                    mainText(for: line)
                        .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                        .contentTransition(.opacity)
                    if settings.showLyricsTranslation, let translation = line.translation {
                        Text(translation)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.78))
                            .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                            .contentTransition(.opacity)
                    }
                }
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 26)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.black.opacity(0.42))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
                        )
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: currentLine?.id)
        .animation(.easeInOut(duration: 0.25), value: currentLine == nil)
        .fixedSize()
    }

    /// The lyric itself: the same per-character karaoke wipe as the
    /// now-playing page when the reader has it on and the line carries word
    /// timings, otherwise the plain line.
    ///
    /// The wipe rides a `TimelineView` here rather than the display-link host
    /// the page uses: this window holds nothing but the box, so re-measuring
    /// it per frame is cheap, and the SwiftUI path keeps the text shadow and
    /// the crossfade between lines. It is not tied to the main window's
    /// visibility — desktop lyrics are mostly read while that window is away.
    @ViewBuilder
    private func mainText(for line: LyricLine) -> some View {
        if settings.verbatimLyrics, let words = line.words, !words.isEmpty {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !player.isPlaying)) { _ in
                LyricText(
                    line: line,
                    size: 26,
                    weight: .bold,
                    color: .white,
                    alignment: .center,
                    rounded: true,
                    alphas: LyricMainText.alphas(for: line, words: words, at: player.livePlaybackTime)
                )
            }
        } else {
            LyricText(
                line: line,
                size: 26,
                weight: .bold,
                color: .white,
                alignment: .center,
                rounded: true
            )
        }
    }
}

#else
import SwiftUI

@MainActor
final class DesktopLyricsController {
    static let shared = DesktopLyricsController()
    private init() {}
    var isVisible: Bool { false }
    func show() {}
    func hide() {}
    func sync(with enabled: Bool) {}
}
#endif
