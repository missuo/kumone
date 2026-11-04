import Foundation

/// Romaji support for Japanese lyrics.
///
/// The service ships a hand-checked `romalrc` for popular tracks only, so anything
/// off the beaten path falls back to the system tokenizer's Latin
/// transcription — offline, dependency-free, and good enough for singing along
/// (personal names and unusual readings can still be wrong).
enum RomajiTranscriber {
    private static let kanaRanges: [ClosedRange<UInt32>] = [
        0x3040...0x309F,  // hiragana
        0x30A0...0x30FF,  // katakana
        0xFF66...0xFF9D,  // halfwidth katakana
    ]

    static func containsKana(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            kanaRanges.contains { $0.contains(scalar.value) }
        }
    }

    /// Whether a lyric body reads as Japanese. Requires more than an isolated
    /// katakana loanword so Chinese lyrics don't get spuriously annotated.
    static func isJapanese(_ texts: [String]) -> Bool {
        let candidates = texts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !candidates.isEmpty else { return false }
        let kanaLines = candidates.count(where: containsKana)
        return kanaLines >= 3 || Double(kanaLines) / Double(candidates.count) >= 0.2
    }

    /// Latin transcription via the system tokenizer. Returns nil when the input
    /// yields nothing beyond what it already was (pure Latin, punctuation).
    static func transcribe(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // The analyser answers with the dictionary reading, which for a
        // handful of words is not the one anybody sings: 私 comes back as
        // わたくし. Rewriting those to kana first is what turns `watakushi`
        // into `watashi`.
        let source = ReadingOverrides.applied(to: trimmed) as CFString
        let range = CFRangeMake(0, CFStringGetLength(source))
        let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault, source, range,
            kCFStringTokenizerUnitWordBoundary,
            Locale(identifier: "ja_JP") as CFLocale)

        var pieces: [String] = []
        var transcribedAny = false
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let tokenRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let original = CFStringCreateWithSubstring(kCFAllocatorDefault, source, tokenRange)
                as String? ?? ""
            if let latin = CFStringTokenizerCopyCurrentTokenAttribute(
                tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String,
                !latin.isEmpty
            {
                pieces.append(latin)
                transcribedAny = true
            } else if !original.trimmingCharacters(in: .whitespaces).isEmpty {
                pieces.append(original)
            }
        }

        guard transcribedAny else { return nil }
        let romaji = join(pieces)
        // Latin-only lines transcribe to themselves — don't echo the lyric.
        guard !romaji.isEmpty, !isEquivalent(romaji, trimmed) else { return nil }
        return romaji
    }

    /// The tokenizer breaks a word after its sokuon, and transcribes the
    /// trailing っ as `~tsu`: だった comes back as `da~tsu` + `ta`. Spelling
    /// that out as written gives `da~tsu ta`, so the marker is folded into the
    /// syllable it belongs to by doubling that syllable's first consonant.
    private static func join(_ pieces: [String]) -> String {
        let sokuon = "~tsu"
        var result: [String] = []
        var geminateNext = false

        for piece in pieces {
            var piece = piece
            let endsInSokuon = piece.hasSuffix(sokuon)
            if endsInSokuon { piece.removeLast(sokuon.count) }

            if geminateNext, let initial = piece.first, initial.isLetter, !result.isEmpty {
                result[result.count - 1] += String(initial) + piece
            } else if !piece.isEmpty {
                result.append(piece)
            }
            geminateNext = endsInSokuon
        }

        return result.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func isEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        func squash(_ s: String) -> String {
            s.lowercased().filter { !$0.isWhitespace }
        }
        return squash(lhs) == squash(rhs)
    }
}
