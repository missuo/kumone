import CoreText
import SwiftUI

/// Builds the Core Text attributed string that carries the ruby annotations.
enum RubyAttributedString {
    struct Style {
        var size: CGFloat
        var weight: PlatformFont.Weight
        var color: PlatformColor
        var rubyColor: PlatformColor
        var rubyScale: CGFloat
        var alignment: NSTextAlignment
        var rounded: Bool
    }

    /// `alphas` carries one opacity per character of the base text, for the
    /// karaoke wipe. A reading follows the dimmest character it sits over, so
    /// it never lights up ahead of the kanji it belongs to.
    static func make(
        _ segments: [RubySegment], style: Style, alphas: [Double]? = nil
    ) -> NSAttributedString {
        let baseFont = font(style.size, style.weight, style.rounded)
        let rubyFont = font(style.size * style.rubyScale, .medium, style.rounded)

        // The framesetter measures the ruby: an annotated line reports a
        // taller box than the same text without it, and a wrapped line leaves
        // room for the ruby of the line below. Adding headroom on top of that
        // just leaves a dead band above the text.
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = style.alignment

        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: style.color,
            .paragraphStyle: paragraph,
        ]

        let output = NSMutableAttributedString()
        var cursor = 0
        for segment in segments {
            let start = cursor
            cursor += segment.text.count
            let span = alphas.map { a in (start..<cursor).map { $0 < a.count ? a[$0] : 1 } }

            guard let ruby = segment.ruby, !ruby.isEmpty else {
                output.append(tinted(segment.text, baseAttributes, span, style.color))
                continue
            }
            // An annotated run has to stay a *single* attribute run. Core Text
            // draws the annotation once per run, so colouring 気 and 分
            // separately as the wipe passes between them repeats きぶん over
            // each of them and prises the pair apart. The run fades as a whole
            // instead, on the mean of the characters it covers.
            let level = span.map { $0.reduce(0, +) / Double(max($0.count, 1)) } ?? 1

            // `.auto` alignment spreads the reading evenly across its base,
            // which at lyric sizes reads as loose tracking: あなた over 貴方
            // comes out あ な た. Centring keeps it together.
            //
            // A reading too wide for its base still has to go somewhere, and
            // overhanging the neighbouring kana is what Japanese typesetting
            // does. Scaling it down to fit instead would keep every line at its
            // unannotated width, but the reading size would then swing with the
            // ratio: なみだ over 涙 would render two thirds the size of あじ
            // over 味, in the same line. Ruby is set at one size.
            let annotation = CTRubyAnnotationCreateWithAttributes(
                .center, .auto, .before, ruby as CFString,
                [
                    kCTFontAttributeName: rubyFont,
                    kCTForegroundColorAttributeName: style.rubyColor.faded(to: level),
                ] as CFDictionary
            )
            var attributes = baseAttributes
            attributes[.foregroundColor] = style.color.faded(to: level)
            attributes[NSAttributedString.Key(kCTRubyAnnotationAttributeName as String)] = annotation
            output.append(NSAttributedString(string: segment.text, attributes: attributes))
        }
        return output
    }

    /// Unannotated text can be coloured character by character; splitting the
    /// run there costs nothing.
    private static func tinted(
        _ text: String, _ attributes: [NSAttributedString.Key: Any],
        _ alphas: [Double]?, _ color: PlatformColor
    ) -> NSAttributedString {
        let piece = NSMutableAttributedString(string: text, attributes: attributes)
        guard let alphas else { return piece }
        var location = 0
        for (index, character) in text.enumerated() {
            let length = (String(character) as NSString).length
            if index < alphas.count {
                piece.addAttribute(.foregroundColor, value: color.faded(to: alphas[index]),
                                   range: NSRange(location: location, length: length))
            }
            location += length
        }
        return piece
    }

    private static func font(
        _ size: CGFloat, _ weight: PlatformFont.Weight, _ rounded: Bool
    ) -> PlatformFont {
        let base = PlatformFont.systemFont(ofSize: size, weight: weight)
        guard rounded, let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        #if os(macOS)
        return PlatformFont(descriptor: descriptor, size: size) ?? base
        #else
        return PlatformFont(descriptor: descriptor, size: size)
        #endif
    }

    /// Size the text needs when laid out no wider than `width`.
    static func fittedSize(_ string: NSAttributedString, width: CGFloat) -> CGSize {
        guard width > 0, string.length > 0 else { return .zero }
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        return CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRangeMake(0, 0), nil,
            CGSize(width: width, height: .greatestFiniteMagnitude), nil
        )
    }

    /// Draws into a context whose origin is already bottom-left.
    ///
    /// The path is pinned to the top of `rect` and allowed to run past its
    /// bottom, because Core Text keeps whole lines or none: a rect a point too
    /// short for the text drops the line entirely instead of clipping it, and
    /// an empty line is a far worse answer than a trimmed one.
    static func draw(_ string: NSAttributedString, in rect: CGRect, context: CGContext) {
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let fitted = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRangeMake(0, 0), nil,
            CGSize(width: rect.width, height: .greatestFiniteMagnitude), nil
        )
        let height = max(rect.height, ceil(fitted.height))
        let path = CGRect(x: rect.minX, y: rect.maxY - height, width: rect.width, height: height)
        let frame = CTFramesetterCreateFrame(
            framesetter, CFRangeMake(0, 0), CGPath(rect: path, transform: nil), nil
        )
        CTFrameDraw(frame, context)
    }
}

/// Draws a lyric line with furigana over the kanji.
///
/// SwiftUI's `Text` has no ruby support and TextKit ignores CTRubyAnnotation,
/// so the line is drawn with Core Text inside a `Canvas`. A `Layout` wrapper
/// asks the framesetter how tall the line will be at the proposed width, which
/// keeps the view participating in normal SwiftUI sizing and wrapping.
struct RubyText: View, Animatable {
    private var segments: [RubySegment]
    private var size: CGFloat
    private var weight: Font.Weight
    private var color: Color
    private var rubyColor: Color
    private var rubyScale: CGFloat
    private var alignment: NSTextAlignment
    private var rounded: Bool
    private var alphas: [Double]?

    init(
        segments: [RubySegment],
        size: CGFloat,
        weight: Font.Weight = .regular,
        color: Color = .primary,
        rubyColor: Color? = nil,
        rubyScale: CGFloat = 0.5,
        alignment: NSTextAlignment = .left,
        rounded: Bool = false,
        alphas: [Double]? = nil
    ) {
        self.segments = segments
        self.size = size
        self.weight = weight
        self.color = color
        self.rubyColor = rubyColor ?? color.opacity(0.75)
        self.rubyScale = rubyScale
        self.alignment = alignment
        self.rounded = rounded
        self.alphas = alphas
    }

    /// The glyphs are drawn by hand, so SwiftUI cannot interpolate them the way
    /// it does the ones inside a `Text`. Left to itself it animates the frame
    /// this view reports while the string jumps straight to its new size, and a
    /// frame shorter than one line of that string draws *nothing*: Core Text
    /// keeps whole lines or none. That is what makes a lyric blink out of
    /// existence for the length of the highlight animation. Animating the size
    /// instead rebuilds the string at every step, so the text and the space it
    /// was given are never out of step.
    var animatableData: CGFloat {
        get { size }
        set { size = newValue }
    }

    var body: some View {
        let style = RubyAttributedString.Style(
            size: size,
            weight: weight.platform,
            color: PlatformColor(color),
            rubyColor: PlatformColor(rubyColor),
            rubyScale: rubyScale,
            alignment: alignment,
            rounded: rounded
        )
        let attributed = RubyAttributedString.make(segments, style: style, alphas: alphas)

        return RubyTextLayout(attributed: attributed) {
            Canvas(rendersAsynchronously: false) { context, canvasSize in
                context.withCGContext { cgContext in
                    cgContext.saveGState()
                    cgContext.textMatrix = .identity
                    // Core Text draws bottom-up; SwiftUI hands over a top-down context.
                    cgContext.translateBy(x: 0, y: canvasSize.height)
                    cgContext.scaleBy(x: 1, y: -1)
                    RubyAttributedString.draw(
                        attributed,
                        in: CGRect(origin: .zero, size: canvasSize),
                        context: cgContext
                    )
                    cgContext.restoreGState()
                }
            }
        }
    }
}

/// `Layout` is `Sendable`, and `NSAttributedString` is not. The string is built
/// once and only ever read, so carrying it in a box is enough.
private final class AttributedBox: @unchecked Sendable {
    let string: NSAttributedString
    init(_ string: NSAttributedString) { self.string = string }
}

private struct RubyTextLayout: Layout {
    private let box: AttributedBox

    init(attributed: NSAttributedString) {
        box = AttributedBox(attributed)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        // No width offered means the caller wants the natural one — under
        // `fixedSize` the line must not stretch to some arbitrary default.
        guard let proposed = proposal.width, proposed.isFinite, proposed > 0 else {
            let fitted = RubyAttributedString.fittedSize(box.string, width: .greatestFiniteMagnitude)
            return CGSize(width: ceil(fitted.width), height: ceil(fitted.height))
        }
        let fitted = RubyAttributedString.fittedSize(box.string, width: proposed)
        return CGSize(width: proposed, height: ceil(fitted.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        for subview in subviews {
            subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }
}

extension Font.Weight {
    var platform: PlatformFont.Weight {
        switch self {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }
}

private extension PlatformColor {
    func faded(to level: Double) -> PlatformColor {
        withAlphaComponent(cgColor.alpha * CGFloat(level))
    }
}
