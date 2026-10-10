import CoreText
import QuartzCore
import SwiftUI

/// The active lyric line, drawn imperatively.
///
/// The wipe used to ride a `TimelineView`: a SwiftUI value changed on every
/// display frame, so SwiftUI re-measured the line — and the page's whole
/// layout chain above it — for as long as a verbatim line was on screen,
/// worth ~40% of a core to fade a handful of glyphs (the vinyl learnt the
/// same lesson). A display link now advances the per-character opacities and
/// redraws the Core Text line directly: the geometry never changes, so the
/// layout above it never hears a frame.
struct KaraokeLyricLine: PlatformViewRepresentable {
    let line: LyricLine
    let words: [LyricWord]
    let size: CGFloat
    let weight: Font.Weight
    var color: Color = .white
    var alignment: NSTextAlignment = .left
    var rounded: Bool = false
    /// The wipe only advances while this reads true; otherwise the line stays
    /// frozen exactly where it was.
    let playing: Bool

    #if os(macOS)
    func makeNSView(context: Context) -> KaraokeLineView {
        let view = KaraokeLineView()
        view.update(line: line, words: words, size: size, weight: weight,
                    color: color, alignment: alignment, rounded: rounded,
                    playing: playing)
        return view
    }

    func updateNSView(_ view: KaraokeLineView, context: Context) {
        view.update(line: line, words: words, size: size, weight: weight,
                    color: color, alignment: alignment, rounded: rounded,
                    playing: playing)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: KaraokeLineView, context: Context) -> CGSize? {
        KaraokeLineView.fittedSize(line: line, size: size, weight: weight,
                                   alignment: alignment, rounded: rounded,
                                   width: proposal.width)
    }
    #else
    func makeUIView(context: Context) -> KaraokeLineView {
        let view = KaraokeLineView()
        view.update(line: line, words: words, size: size, weight: weight,
                    color: color, alignment: alignment, rounded: rounded,
                    playing: playing)
        return view
    }

    func updateUIView(_ view: KaraokeLineView, context: Context) {
        view.update(line: line, words: words, size: size, weight: weight,
                    color: color, alignment: alignment, rounded: rounded,
                    playing: playing)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: KaraokeLineView, context: Context) -> CGSize? {
        KaraokeLineView.fittedSize(line: line, size: size, weight: weight,
                                   alignment: alignment, rounded: rounded,
                                   width: proposal.width)
    }
    #endif
}

/// What the line draws, shared by both platforms' hosts: rebuilds the
/// attributed line from the current playback time, one wipe step at a time.
@MainActor
private struct KaraokeLineContent {
    private var line: LyricLine?
    private var words: [LyricWord] = []
    private var style: RubyAttributedString.Style?
    private var lastQuantizedAlphas: [Int] = []

    mutating func update(line: LyricLine, words: [LyricWord], size: CGFloat,
                         weight: Font.Weight, color: PlatformColor,
                         alignment: NSTextAlignment, rounded: Bool) {
        self.line = line
        self.words = words
        lastQuantizedAlphas = []
        style = RubyAttributedString.Style(
            size: size,
            weight: weight.platform,
            color: color,
            rubyColor: color.withAlphaComponent(color.cgColor.alpha * 0.72),
            rubyScale: 0.5,
            alignment: alignment,
            rounded: rounded
        )
    }

    func attributed(at time: TimeInterval) -> NSAttributedString? {
        guard let line, let style else { return nil }
        let alphas = LyricMainText.alphas(for: line, words: words, at: time)
        return RubyAttributedString.make(segments(for: line), style: style, alphas: alphas)
    }

    /// Whether the wipe has visibly moved since the last redraw, judged in
    /// 1/64 alpha steps: the line holds still for whole seconds at a time, and
    /// there is no reason to rebuild the Core Text line on those frames.
    mutating func wipeHasMoved(at time: TimeInterval) -> Bool {
        guard let line, !words.isEmpty else { return false }
        let quantized = LyricMainText.alphas(for: line, words: words, at: time)
            .map { Int(($0 * 64).rounded()) }
        guard quantized != lastQuantizedAlphas else { return false }
        lastQuantizedAlphas = quantized
        return true
    }

    func fittedSize(width: CGFloat?) -> CGSize? {
        guard let line, let style else { return nil }
        let attributed = RubyAttributedString.make(segments(for: line), style: style)
        guard let proposed = width, proposed.isFinite, proposed > 0 else {
            let fitted = RubyAttributedString.fittedSize(attributed, width: .greatestFiniteMagnitude)
            return CGSize(width: ceil(fitted.width), height: ceil(fitted.height))
        }
        let fitted = RubyAttributedString.fittedSize(attributed, width: proposed)
        return CGSize(width: proposed, height: ceil(fitted.height))
    }

    /// The line's runs — the furigana segments when the reader has chosen
    /// them, else the plain text; the wipe rides either.
    private func segments(for line: LyricLine) -> [RubySegment] {
        if SettingsManager.shared.lyricsAnnotation == .furigana, let furigana = line.furigana {
            return furigana
        }
        return [RubySegment(line.text)]
    }
}

#if os(macOS)
/// The host for a karaoke line: draws the line, and runs a display link that
/// redraws it at up to 30 fps while the wipe is advancing.
final class KaraokeLineView: NSView {
    private var content = KaraokeLineContent()
    private var playing = false
    private var displayLink: CADisplayLink?
    private var lastDraw: CFTimeInterval = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(line: LyricLine, words: [LyricWord], size: CGFloat,
                weight: Font.Weight, color: Color, alignment: NSTextAlignment,
                rounded: Bool, playing: Bool) {
        content.update(line: line, words: words, size: size, weight: weight,
                       color: PlatformColor(color), alignment: alignment,
                       rounded: rounded)
        if playing != self.playing {
            self.playing = playing
            if playing {
                startDisplayLink()
            } else {
                stopDisplayLink()
            }
        }
        needsDisplay = true
    }

    static func fittedSize(line: LyricLine, size: CGFloat, weight: Font.Weight,
                           alignment: NSTextAlignment, rounded: Bool,
                           width: CGFloat?) -> CGSize? {
        var content = KaraokeLineContent()
        content.update(line: line, words: [], size: size, weight: weight,
                       color: .white, alignment: alignment, rounded: rounded)
        return content.fittedSize(width: width)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopDisplayLink()
        } else if playing {
            startDisplayLink()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext,
              let attributed = content.attributed(at: PlayerService.shared.livePlaybackTime)
        else { return }
        RubyAttributedString.draw(attributed, in: bounds, context: context)
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        lastDraw = 0
        let link = displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        // The wipe fades each character over a good fraction of a second;
        // 30 fps is indistinguishable, and frames whose opacities have not
        // moved are skipped outright.
        guard now - lastDraw >= 1.0 / 30 else { return }
        guard content.wipeHasMoved(at: PlayerService.shared.livePlaybackTime) else { return }
        lastDraw = now
        needsDisplay = true
    }
}
#else
/// The host for a karaoke line: draws the line, and runs a display link that
/// redraws it at up to 30 fps while the wipe is advancing.
final class KaraokeLineView: UIView {
    private var content = KaraokeLineContent()
    private var playing = false
    private var displayLink: CADisplayLink?
    private var lastDraw: CFTimeInterval = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(line: LyricLine, words: [LyricWord], size: CGFloat,
                weight: Font.Weight, color: Color, alignment: NSTextAlignment,
                rounded: Bool, playing: Bool) {
        content.update(line: line, words: words, size: size, weight: weight,
                       color: PlatformColor(color), alignment: alignment,
                       rounded: rounded)
        if playing != self.playing {
            self.playing = playing
            if playing {
                startDisplayLink()
            } else {
                stopDisplayLink()
            }
        }
        setNeedsDisplay()
    }

    static func fittedSize(line: LyricLine, size: CGFloat, weight: Font.Weight,
                           alignment: NSTextAlignment, rounded: Bool,
                           width: CGFloat?) -> CGSize? {
        var content = KaraokeLineContent()
        content.update(line: line, words: [], size: size, weight: weight,
                       color: .white, alignment: alignment, rounded: rounded)
        return content.fittedSize(width: width)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopDisplayLink()
        } else if playing {
            startDisplayLink()
        }
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(),
              let attributed = content.attributed(at: PlayerService.shared.livePlaybackTime)
        else { return }
        context.saveGState()
        context.textMatrix = .identity
        // Core Text draws bottom-up; UIKit hands over a top-down context.
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        RubyAttributedString.draw(attributed, in: bounds, context: context)
        context.restoreGState()
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        lastDraw = 0
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        guard now - lastDraw >= 1.0 / 30 else { return }
        guard content.wipeHasMoved(at: PlayerService.shared.livePlaybackTime) else { return }
        lastDraw = now
        setNeedsDisplay()
    }
}
#endif