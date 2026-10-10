import SwiftUI

/// The lyric itself, with furigana over the kanji when the reader asked for it
/// and the line has kanji worth annotating.
///
/// The karaoke wipe draws through the same `Canvas` as the furigana lines:
/// concatenating a `Text` per character here instead made SwiftUI rebuild and
/// re-resolve the whole line — and re-lay-out the page around it — on every
/// display frame while the song played. Lines with neither furigana nor a
/// wipe stay a plain `Text`.
struct LyricText: View {
    let line: LyricLine
    let size: CGFloat
    var weight: Font.Weight = .regular
    var color: Color = .primary
    var alignment: NSTextAlignment = .left
    var rounded: Bool = false
    /// Per-character opacity for the karaoke wipe, when there is one.
    var alphas: [Double]?

    @EnvironmentObject private var settings: SettingsManager

    var body: some View {
        if settings.lyricsAnnotation == .furigana, let furigana = line.furigana {
            RubyText(
                segments: furigana,
                size: size,
                weight: weight,
                color: color,
                rubyColor: color.opacity(0.72),
                alignment: alignment,
                rounded: rounded,
                alphas: alphas
            )
            // The line is glyphs in a `Canvas`, which carries no text for
            // VoiceOver to read. Stand in the plain lyric; the readings are a
            // visual aid and would only clutter it spoken.
            .accessibilityRepresentation { Text(line.text.isEmpty ? "♪" : line.text) }
        } else if let alphas, !alphas.isEmpty {
            // The wipe used to be one `RubyText` per frame. Every frame that
            // view value changed, so SwiftUI re-measured it — and with it the
            // page's whole layout chain — while the karaoke line was up,
            // worth ~40% of a core. Laying the line out twice instead — dim
            // ink once, fixed, with the wiped ink as an overlay — keeps the
            // per-frame value inside the overlay: the row's layout inputs
            // never move, and only the overlay repaints.
            //
            // The overlay carries the wipe with the dim floor (0.28) removed,
            // so it composites *over* the base to exactly the intended
            // opacity: base 0.28 + overlay β reads 0.28 + 0.72β, which is the
            // wipe's own alpha when β = (α − 0.28) / 0.72. `Self.alphas` in
            // NowPlayingView is where that floor is defined.
            RubyText(
                segments: [RubySegment(line.text)],
                size: size,
                weight: weight,
                color: color.opacity(0.28),
                alignment: alignment,
                rounded: rounded
            )
            .overlay {
                RubyText(
                    segments: [RubySegment(line.text)],
                    size: size,
                    weight: weight,
                    color: color,
                    alignment: alignment,
                    rounded: rounded,
                    alphas: alphas.map { max(0, ($0 - 0.28) / 0.72) }
                )
            }
            // Keep the per-frame wipe inside this row's own geometry: without
            // it, every frame the overlay changes makes SwiftUI re-measure the
            // whole page above the line (#128 performance work).
            .geometryGroup()
            // The line is glyphs in a `Canvas`, which carries no text for
            // VoiceOver to read. Stand in the plain lyric.
            .accessibilityRepresentation { Text(line.text.isEmpty ? "♪" : line.text) }
        } else {
            Text(line.text.isEmpty ? "♪" : line.text)
                .font(.system(size: size, weight: weight, design: rounded ? .rounded : .default))
                .foregroundStyle(color)
        }
    }
}
