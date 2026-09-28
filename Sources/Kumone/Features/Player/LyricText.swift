import SwiftUI

/// The lyric itself, with furigana over the kanji when the reader asked for it
/// and the line has kanji worth annotating.
///
/// Every other case falls through to a plain `Text`, so lyrics that are not
/// Japanese, and the two annotation modes that are not furigana, keep exactly
/// the rendering they had.
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
        if #available(iOS 16.0, *), settings.lyricsAnnotation == .furigana, let furigana = line.furigana {
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
            wiped(alphas)
                .font(.system(size: size, weight: weight, design: rounded ? .rounded : .default))
        } else {
            Text(line.text.isEmpty ? "♪" : line.text)
                .font(.system(size: size, weight: weight, design: rounded ? .rounded : .default))
                .foregroundStyle(color)
        }
    }

    /// One concatenated `Text`, so the line still wraps, with the wipe applied
    /// per character.
    private func wiped(_ alphas: [Double]) -> Text {
        var out = Text(verbatim: "")
        for (index, character) in line.text.enumerated() {
            let alpha = index < alphas.count ? alphas[index] : 1
            out = out + Text(verbatim: String(character)).foregroundColor(color.opacity(alpha))
        }
        return out
    }
}
