import Foundation

// Timed lyrics, read from the `.lrc` sidecar sitting next to a corpus track.
//
// The console's AI bundle is otherwise blind to *words*: it can say the
// outgoing track's vocal curve is hot at 3:12 but not that the singer is two
// lines from the end of the final chorus. A phrase hand-over is a decision
// about words, so the words go in the bundle.
//
// Nothing in playback reads this — it exists for the tuning surface.

extension Audition {

    public struct LyricLine: Encodable, Sendable, Equatable {
        public let time: TimeInterval
        public let text: String
    }

    public enum Lyrics {

        /// `<track>.lrc` next to the audio file, whatever its extension.
        public static func sidecarURL(for track: URL) -> URL {
            track.deletingPathExtension().appendingPathExtension("lrc")
        }

        /// Parse LRC text into time-sorted lines.
        ///
        /// Handles the two things real `.lrc` files do that a naive split does
        /// not: several timestamps on one line (a repeated chorus), and the
        /// `[ar:...]` / `[00:00.00] 作词 : …` credits, which are dropped — they
        /// are not lyrics, and they bracket the file at both ends (an opening
        /// header, often a rolling credit list on real timestamps at the close),
        /// which is exactly where the AI bundle quotes from.
        public static func parse(_ text: String) -> [LyricLine] {
            var out: [LyricLine] = []
            for raw in text.split(whereSeparator: \.isNewline) {
                var stamps: [TimeInterval] = []
                var rest = Substring(raw)
                while rest.first == "[" {
                    guard let close = rest.firstIndex(of: "]") else { break }
                    let tag = rest[rest.index(after: rest.startIndex)..<close]
                    rest = rest[rest.index(after: close)...]
                    guard let t = timestamp(tag) else { continue }   // `[ar:…]` etc.
                    stamps.append(t)
                }
                let body = rest.trimmingCharacters(in: .whitespaces)
                guard !stamps.isEmpty, !body.isEmpty, !isCredit(body) else { continue }
                for t in stamps { out.append(LyricLine(time: t, text: body)) }
            }
            return out.sorted { $0.time < $1.time }
        }

        /// Nil for a non-timestamp tag, so `[ti:…]` falls through as metadata.
        private static func timestamp(_ tag: Substring) -> TimeInterval? {
            let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, let minutes = Double(parts[0]),
                  let seconds = Double(parts[1]), minutes >= 0, seconds >= 0, seconds < 60
            else { return nil }
            return minutes * 60 + seconds
        }

        /// "作词 : X" / "厂牌 : Y" credit lines. A Netease-sourced `.lrc` opens
        /// with a block of these and often closes with a whole rolling credit
        /// list on real timestamps — which is exactly the window the bundle
        /// quotes, so they have to go.
        ///
        /// The test is structural rather than a keyword list, because the roles
        /// are unbounded (经纪人, EP文案, OP/SP, 封面设计…): a short label, a
        /// colon, a name. Sung lines essentially never contain a colon, so the
        /// false-positive risk is a line of quoted dialogue — noise either way.
        /// Roles, for the credit lines whose label is too long for the length
        /// test alone ("录音工程& MIDI制作：…").
        private static let creditRoles = [
            "作词", "作曲", "编曲", "制作", "混音", "母带", "录音", "和声", "主唱",
            "吉他", "贝斯", "鼓", "键盘", "弦乐", "监制", "出品", "发行", "宣传",
            "策划", "统筹", "经纪", "文案", "助理", "厂牌", "设计", "编辑", "OP", "SP",
        ]

        private static func isCredit(_ line: String) -> Bool {
            guard let colon = line.firstIndex(where: { $0 == ":" || $0 == "：" })
            else { return false }
            let head = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            let name = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !head.isEmpty, !name.isEmpty else { return false }
            return head.count <= 10 || creditRoles.contains { head.contains($0) }
        }

        /// The lines for `track`, or nil when it has no `.lrc` sidecar.
        public static func load(for track: URL) -> [LyricLine]? {
            let url = sidecarURL(for: track)
            guard let data = try? Data(contentsOf: url) else { return nil }
            let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
            guard let text else { return nil }
            let lines = parse(text)
            return lines.isEmpty ? nil : lines
        }

        /// A line is assumed to stop being sung no later than this multiple of
        /// the track's own median line spacing. Without the cap, the line before
        /// an instrumental break would "end" only when the singer comes back,
        /// and the whole break would read as one held line — the opposite of
        /// what a snap target is for.
        private static let maxLineLengthFactor: TimeInterval = 2

        /// When each line **stops** being sung: the next line's timestamp,
        /// capped at `maxLineLengthFactor` × the median spacing, and for the
        /// last line its own timestamp plus that median.
        ///
        /// This is the planner's out-point snap grid (predev §2.2): a cut that
        /// lands here lands on a full stop rather than in the middle of a word.
        /// Ascending, one entry per line, so a caller can binary-search it.
        public static func lineEnds(_ lines: [LyricLine]) -> [TimeInterval] {
            guard let last = lines.last else { return [] }
            var gaps: [TimeInterval] = []
            for (a, b) in zip(lines, lines.dropFirst()) where b.time > a.time {
                gaps.append(b.time - a.time)
            }
            // Median, not mean: one 40 s instrumental gap would otherwise set
            // the length of every line in the song.
            let median = gaps.isEmpty ? 4 : gaps.sorted()[gaps.count / 2]
            let cap = maxLineLengthFactor * median
            var ends = zip(lines, lines.dropFirst()).map { min($1.time, $0.time + cap) }
            ends.append(last.time + median)
            return ends
        }

        /// The same grid straight off a track's `.lrc`; empty when it has none.
        public static func lineEnds(for track: URL) -> [TimeInterval] {
            load(for: track).map(lineEnds) ?? []
        }

        /// The last `count` lines — what the outgoing track is still singing
        /// when the hand-over starts.
        public static func tail(_ lines: [LyricLine], count: Int) -> [LyricLine] {
            Array(lines.suffix(count))
        }

        /// The first `count` lines — what the incoming track opens with.
        public static func head(_ lines: [LyricLine], count: Int) -> [LyricLine] {
            Array(lines.prefix(count))
        }
    }
}
