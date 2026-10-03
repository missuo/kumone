import Foundation

/// One timed word (or short run) inside a verbatim (yrc) lyric line.
struct LyricWord: Hashable {
    let text: String
    let start: TimeInterval
    let duration: TimeInterval
    var end: TimeInterval { start + duration }
}

struct LyricLine: Identifiable, Hashable {
    let id: Int
    let time: TimeInterval
    let text: String
    var translation: String?
    var romaji: String?
    /// Base text split so each reading sits over the kanji it belongs to.
    /// Nil when there is nothing to annotate.
    var furigana: [RubySegment]?
    /// Per-word timings for karaoke highlighting; nil when only line-level
    /// (lrc) timing is available.
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
    // Fixed, valid patterns: cache their compilation and use UTF-16 ranges throughout.
    private static let timeTag = try! NSRegularExpression(pattern: #"\[(\d+):(\d+)(?:[.:](\d+))?\]"#)
    private static let lineTag = try! NSRegularExpression(pattern: #"^\[(\d+),(\d+)\]"#)
    private static let wordTag = try! NSRegularExpression(pattern: #"\((\d+),(\d+),\d+\)([^(]*)"#)

    /// Parses an LRC body into (time, text) pairs. Handles multiple timestamps
    /// per line and both `.` / `:` millisecond separators.
    static func parseLRCBackport(_ lrc: String) -> [(time: TimeInterval, text: String)] {
        var result: [(TimeInterval, String)] = []

        for rawLine in lrc.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let source = line as NSString
            let matches = timeTag.matches(in: line, range: NSRange(location: 0, length: source.length))
            guard !matches.isEmpty else { continue }
            guard let lastMatch = matches.last else { continue }
            let content = source.substring(from: NSMaxRange(lastMatch.range))
                .trimmingCharacters(in: .whitespaces)
            for match in matches {
                let min = Double(source.substring(with: match.range(at: 1))) ?? 0
                let sec = Double(source.substring(with: match.range(at: 2))) ?? 0
                var frac = 0.0
                if match.range(at: 3).location != NSNotFound {
                    let msStr = source.substring(with: match.range(at: 3))
                    frac = (Double(msStr) ?? 0) / pow(10, Double(msStr.count))
                }
                result.append((min * 60 + sec + frac, content))
            }
        }
        return result.sorted { $0.0 < $1.0 }
    }

    /// Parses NetEase verbatim `yrc` lyrics: each content line is
    /// `[lineStartMs,lineDurMs](wStartMs,wDurMs,0)word(...)word…`. JSON metadata
    /// (credits) lines at the top don't match the `[num,num]` head and are
    /// skipped.
    static func parseYRCBackport(_ yrc: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        var idx = 0
        for raw in yrc.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let source = line as NSString
            let range = NSRange(location: 0, length: source.length)
            guard let head = lineTag.firstMatch(in: line, range: range) else { continue }
            let lineStart = (Double(source.substring(with: head.range(at: 1))) ?? 0) / 1000
            var words: [LyricWord] = []
            var text = ""
            for w in wordTag.matches(in: line, range: range) {
                let start = (Double(source.substring(with: w.range(at: 1))) ?? 0) / 1000
                let duration = (Double(source.substring(with: w.range(at: 2))) ?? 0) / 1000
                let piece = source.substring(with: w.range(at: 3))
                words.append(LyricWord(text: piece, start: start, duration: duration))
                text += piece
            }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !words.isEmpty else { continue }
            lines.append(LyricLine(id: idx, time: lineStart, text: trimmed, words: words))
            idx += 1
        }
        return lines
    }

    // Keep the existing parser on supported systems; only iOS 15 uses ICU.
    static func parseLRC(_ lrc: String) -> [(time: TimeInterval, text: String)] {
        if #available(iOS 16.0, *) { return parseLRCNative(lrc) }
        return parseLRCBackport(lrc)
    }

    static func parseYRC(_ yrc: String) -> [LyricLine] {
        if #available(iOS 16.0, *) { return parseYRCNative(yrc) }
        return parseYRCBackport(yrc)
    }

    @available(iOS 16.0, *)
    private static func parseLRCNative(_ lrc: String) -> [(time: TimeInterval, text: String)] {
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

    /// Parses NetEase verbatim `yrc` lyrics: each content line is
    /// `[lineStartMs,lineDurMs](wStartMs,wDurMs,0)word(...)word…`. JSON metadata
    /// (credits) lines at the top don't match the `[num,num]` head and are
    /// skipped.
    @available(iOS 16.0, *)
    private static func parseYRCNative(_ yrc: String) -> [LyricLine] {
        let lineTag = #/^\[(\d+),(\d+)\]/#
        let wordTag = #/\((\d+),(\d+),\d+\)([^(]*)/#
        var lines: [LyricLine] = []
        var idx = 0
        for raw in yrc.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let head = line.firstMatch(of: lineTag) else { continue }
            let lineStart = (Double(head.output.1) ?? 0) / 1000
            var words: [LyricWord] = []
            var text = ""
            for w in line.matches(of: wordTag) {
                let start = (Double(w.output.1) ?? 0) / 1000
                let duration = (Double(w.output.2) ?? 0) / 1000
                let piece = String(w.output.3)
                words.append(LyricWord(text: piece, start: start, duration: duration))
                text += piece
            }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !words.isEmpty else { continue }
            lines.append(LyricLine(id: idx, time: lineStart, text: trimmed, words: words))
            idx += 1
        }
        return lines
    }

    static func parse(_ response: LyricResponse) -> ParsedLyrics {
        var out = ParsedLyrics()
        out.contributor = response.lyricUser?.nickname
        out.translationContributor = response.transUser?.nickname

        guard let raw = response.lrc?.lyric, !raw.isEmpty else { return out }
        var main = parseLRC(raw)

        // Instrumental marker handling (mirrors YesPlayMusic).
        let instrumentalMarker = "纯音乐，请欣赏"
        if main.count <= 10, main.contains(where: { $0.text.contains(instrumentalMarker) }) {
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

        var lines = main.enumerated().map { idx, pair in
            LyricLine(id: idx, time: pair.time, text: pair.text)
        }
        // Prefer verbatim (word-by-word) lines when the song has them.
        if let yrcRaw = response.yrc?.lyric, !yrcRaw.isEmpty {
            let yrcLines = parseYRC(yrcRaw)
            if !yrcLines.isEmpty { lines = yrcLines }
        }

        func merge(_ body: String?, into keyPath: WritableKeyPath<LyricLine, String?>) {
            guard let body, !body.isEmpty else { return }
            let secondary = parseLRC(body).filter { !$0.text.isEmpty }
            guard !secondary.isEmpty else { return }
            for i in lines.indices {
                // Nearest secondary line within 0.3s: verbatim (yrc) line times
                // can differ from the lrc-based translation/romaji by a few ms.
                var best: (delta: TimeInterval, text: String)?
                for (time, text) in secondary {
                    let delta = abs(time - lines[i].time)
                    if best == nil || delta < best!.delta { best = (delta, text) }
                }
                if let best, best.delta < 0.3 {
                    lines[i][keyPath: keyPath] = best.text
                }
            }
        }

        merge(response.ytlrc?.lyric ?? response.tlyric?.lyric, into: \.translation)
        merge(response.yromalrc?.lyric ?? response.romalrc?.lyric, into: \.romaji)

        // Readings are only meaningful for Japanese lyrics: fill the romaji
        // gaps Netease left, annotate the kanji, and drop stray annotations on
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
}
