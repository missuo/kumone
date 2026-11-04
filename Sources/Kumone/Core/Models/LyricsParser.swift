import Foundation

/// One timed word (or short run) inside a lyric line: the service's own verbatim
/// (`yrc`) timing, or — when the song only has line (`lrc`) timing — a share
/// of the line spread across its characters, see `LyricsParser.spreadWords`.
struct LyricWord: Hashable {
    let text: String
    let start: TimeInterval
    let duration: TimeInterval
    var end: TimeInterval { start + duration }

    func replacingText(_ text: String) -> LyricWord {
        LyricWord(text: text, start: start, duration: duration)
    }
}

struct LyricLine: Identifiable, Hashable {
    let id: Int
    let time: TimeInterval
    /// When the line's singing ends: the `yrc` line duration, or for an
    /// `lrc` line the next line's start, capped at six seconds.
    let end: TimeInterval
    let text: String
    var translation: String?
    var romaji: String?
    /// Base text split so each reading sits over the kanji it belongs to.
    /// Nil when there is nothing to annotate.
    var furigana: [RubySegment]?
    /// Per-word timings for karaoke highlighting — measured for a `yrc`
    /// line, spread across the characters for an `lrc` one — whose text
    /// joined is exactly `text`, so the wipe maps one opacity to one
    /// character. Nil when the line has nothing to sing (no letters).
    var words: [LyricWord]?
}

struct ParsedLyrics: Hashable {
    var lines: [LyricLine] = []
    var isInstrumental = false
    var contributor: String?
    var translationContributor: String?

    var isEmpty: Bool { lines.isEmpty }

    /// Index of the active line for a playback position.
    func activeIndex(at time: TimeInterval) -> Int? {
        guard !lines.isEmpty else { return nil }
        var low = 0, high = lines.count - 1, result: Int? = nil
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].time <= time {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }
}

enum LyricsParser {
    /// Parses an LRC body into (time, text) pairs. Handles multiple timestamps
    /// per line and both `.` / `:` millisecond separators.
    static func parseLRC(_ lrc: String) -> [(time: TimeInterval, text: String)] {
        var result: [(TimeInterval, String)] = []
        let timeTag = #/\[(\d+):(\d+)(?:[.:](\d+))?\]/#

        for rawLine in lrc.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let matches = line.matches(of: timeTag)
            guard !matches.isEmpty else { continue }
            guard let lastMatch = matches.last else { continue }
            let content = String(line[lastMatch.range.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            for match in matches {
                let min = Double(match.output.1) ?? 0
                let sec = Double(match.output.2) ?? 0
                var frac = 0.0
                if let msStr = match.output.3, let ms = Double(msStr) {
                    frac = ms / pow(10, Double(msStr.count))
                }
                result.append((min * 60 + sec + frac, content))
            }
        }
        return result.sorted { $0.0 < $1.0 }
    }

    /// Parses the service's verbatim `yrc` lyrics: each content line is
    /// `[lineStartMs,lineDurMs](wStartMs,wDurMs,0)word(...)word…`. JSON metadata
    /// (credits) lines at the top don't match the `[num,num]` head and are
    /// skipped. A blank token — the gap between two words — rides on the word
    /// before it, so the words' text joined is the line's text.
    static func parseYRC(_ yrc: String) -> [LyricLine] {
        let lineTag = #/^\[(\d+),(\d+)\]/#
        let wordTag = #/\((\d+),(\d+),\d+\)([^(]*)/#
        var lines: [LyricLine] = []
        for raw in yrc.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let head = line.firstMatch(of: lineTag) else { continue }
            let lineStart = (Double(head.output.1) ?? 0) / 1000
            let lineDuration = (Double(head.output.2) ?? 0) / 1000
            var words: [LyricWord] = []
            for w in line.matches(of: wordTag) {
                let piece = String(w.output.3)
                if piece.allSatisfy(\.isWhitespace) {
                    if let last = words.indices.last {
                        words[last] = words[last].replacingText(words[last].text + piece)
                    }
                    continue
                }
                let start = (Double(w.output.1) ?? 0) / 1000
                let duration = (Double(w.output.2) ?? 0) / 1000
                words.append(LyricWord(text: piece, start: start, duration: duration))
            }
            if let first = words.indices.first {
                words[first] = words[first].replacingText(
                    String(words[first].text.drop(while: \.isWhitespace)))
            }
            if let last = words.indices.last {
                words[last] = words[last].replacingText(
                    trimmingTrailingWhitespace(words[last].text))
            }
            words.removeAll { $0.text.isEmpty }
            let text = words.map(\.text).joined()
            guard !text.isEmpty else { continue }
            let end = lineDuration > 0 ? lineStart + lineDuration : (words.last?.end ?? lineStart)
            lines.append(LyricLine(id: lines.count, time: lineStart, end: end, text: text, words: words))
        }
        return lines
    }

    static func parse(_ response: LyricResponse) -> ParsedLyrics {
        var out = ParsedLyrics()
        out.contributor = response.lyricUser?.nickname
        out.translationContributor = response.transUser?.nickname

        var main = parseLRC(response.lrc?.lyric ?? "")

        // Instrumental marker handling (mirrors YesPlayMusic).
        let instrumentalMarker = "纯音乐，请欣赏"
        if !main.isEmpty, main.count <= 10, main.contains(where: { $0.text.contains(instrumentalMarker) }) {
            out.isInstrumental = true
            main.removeAll { line in
                line.text.contains(instrumentalMarker)
                    || line.text.range(of: #"^作(词|曲)\s*[:：]"#, options: .regularExpression) != nil
            }
            if main.isEmpty {
                return out
            }
        }
        main.removeAll { $0.text.range(of: #"^作(词|曲)\s*[:：]\s*无$"#, options: .regularExpression) != nil }

        // Prefer verbatim (word-by-word) lines when the song has them — some
        // ship them without an lrc body. Otherwise each lrc line gets its
        // time spread across its characters, so the wipe runs there too.
        var lines = parseYRC(response.yrc?.lyric ?? "")
        if lines.isEmpty {
            lines = main.indices.map { index in
                let (time, text) = main[index]
                // A line is sung until the next one starts; the last line, or
                // one before a long break, for six seconds.
                let next = index + 1 < main.count ? main[index + 1].time : .infinity
                let end = min(max(next, time), time + 6)
                return LyricLine(id: index, time: time, end: end, text: text,
                                 words: spreadWords(text, from: time, to: end))
            }
        }
        guard !lines.isEmpty else { return out }

        func merge(_ body: String?, into keyPath: WritableKeyPath<LyricLine, String?>) {
            guard let body, !body.isEmpty else { return }
            let secondary = parseLRC(body).filter { !$0.text.isEmpty }
            guard !secondary.isEmpty else { return }
            // A line and a secondary line pair up when each is the other's
            // nearest in time, within 1.5 s. Verbatim (yrc) lines can start a
            // few hundred ms off the lrc grid a translation follows, so the
            // window is wide; the mutual check keeps a secondary line whose
            // own line is missing off a neighbour, and one from serving two.
            func nearest(to time: TimeInterval, in times: [TimeInterval]) -> Int? {
                var best: Int?
                for (index, candidate) in times.enumerated() {
                    if let current = best, abs(times[current] - time) <= abs(candidate - time) { continue }
                    best = index
                }
                return best
            }
            let lineTimes = lines.map(\.time)
            let secondaryTimes = secondary.map(\.time)
            let lineForSecondary = secondaryTimes.map { nearest(to: $0, in: lineTimes) }
            for (index, time) in lineTimes.enumerated() {
                guard let match = nearest(to: time, in: secondaryTimes),
                      lineForSecondary[match] == index,
                      abs(secondaryTimes[match] - time) < 1.5 else { continue }
                lines[index][keyPath: keyPath] = secondary[match].text
            }
        }

        merge(response.ytlrc?.lyric ?? response.tlyric?.lyric, into: \.translation)
        merge(response.yromalrc?.lyric ?? response.romalrc?.lyric, into: \.romaji)

        // Readings are only meaningful for Japanese lyrics: fill the romaji
        // gaps the service left, annotate the kanji, and drop stray annotations on
        // everything else. Both are done here rather than in the view so a line
        // is analysed once per track instead of once per frame.
        if RomajiTranscriber.isJapanese(lines.map(\.text)) {
            for i in lines.indices {
                if lines[i].romaji == nil {
                    lines[i].romaji = RomajiTranscriber.transcribe(lines[i].text)
                }
                lines[i].furigana = Furigana.segments(for: lines[i].text)
            }
        } else {
            for i in lines.indices {
                lines[i].romaji = nil
            }
        }

        out.lines = lines
        return out
    }

    /// Spreads a line's time across its characters for a song without word
    /// timing of its own, so the karaoke wipe still runs: each Chinese,
    /// Japanese or Korean character is a word of its own, anything else
    /// splits on whitespace (the gap rides on the word before it), and 85 %
    /// of the line — singing takes most of it, not the pause before the next
    /// line — is shared out by letter count. Nil when there is nothing to
    /// sing, or no time to sing it in.
    static func spreadWords(_ text: String, from start: TimeInterval, to end: TimeInterval) -> [LyricWord]? {
        var units: [String] = []
        var current = ""
        func flush() {
            guard !current.isEmpty else { return }
            units.append(current)
            current = ""
        }
        for character in text {
            if character.isWhitespace {
                if current.isEmpty, let last = units.indices.last {
                    units[last].append(character)
                } else {
                    current.append(character)
                    if !current.allSatisfy(\.isWhitespace) { flush() }
                }
            } else if isCJK(character) {
                flush()
                units.append(String(character))
            } else {
                current.append(character)
            }
        }
        flush()

        let weights = units.map { $0.filter { $0.isLetter || $0.isNumber }.count }
        let total = weights.reduce(0, +)
        guard total > 0, end > start else { return nil }
        let span = (end - start) * 0.85
        var at = start
        var words: [LyricWord] = []
        for (unit, weight) in zip(units, weights) {
            let duration = span * Double(weight) / Double(total)
            words.append(LyricWord(text: unit, start: at, duration: duration))
            at += duration
        }
        return words
    }

    /// Chinese, Japanese and Korean characters are each sung as a word of
    /// their own.
    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        if Kana.isKanji(scalar) || Kana.isKana(scalar) { return true }
        switch scalar.value {
        case 0x1100...0x11FF,   // hangul jamo
             0x3130...0x318F,   // hangul compatibility jamo
             0xA960...0xA97F,   // hangul jamo extended-A
             0xAC00...0xD7AF,   // hangul syllables
             0xD7B0...0xD7FF:   // hangul jamo extended-B
            return true
        default:
            return false
        }
    }

    private static func trimmingTrailingWhitespace(_ text: String) -> String {
        var trimmed = Substring(text)
        while let last = trimmed.last, last.isWhitespace { trimmed.removeLast() }
        return String(trimmed)
    }
}
