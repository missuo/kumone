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
            // The wipe rides the same `Canvas` pipeline as the furigana
            // lines: `RubyAttributedString` already bakes one foreground
            // colour per character, and Core Text can restyle a run without
            // SwiftUI having to resolve the text anew every frame.
            RubyText(
                segments: [RubySegment(line.text)],
                size: size,
                weight: weight,
                color: color,
                alignment: alignment,
                rounded: rounded,
                alphas: alphas
            )
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
