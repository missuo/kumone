import Foundation

/// Persists Netease's timed lyrics as a plain `.lrc` next to the cached audio.
///
/// `Audition.VocalExchange.compile` decides where the vocal changes hands by
/// asking `Audition.Lyrics.load(for:)` where the outgoing line ends — and that
/// reads a `.lrc` sidecar off disk. The tuning corpus has those files; the app
/// never wrote one, so in the app a `vocalExchange` had no words to work with
/// and always degraded to the vocal-trough hand-over. The lyrics were already
/// being fetched for the lyrics panel; they just stayed in memory.
///
/// The raw LRC body goes to disk verbatim. `Audition.Lyrics.parse` already
/// knows about multi-timestamp lines and credit blocks, so re-serialising the
/// app's own `ParsedLyrics` would only lose information (and its instrumental
/// filtering has already rewritten the lines).
enum LyricsSidecar {

    /// Netease's stand-in body for a track with no words at all.
    private static let instrumentalMarker = "纯音乐，请欣赏"

    /// Write `lrc` as `<audio>.lrc`, unless there is nothing worth writing.
    ///
    /// Returns whether the sidecar is on disk afterwards — for tests; callers
    /// treat a failure as "no lyrics", which is the pre-existing behaviour.
    @discardableResult
    static func write(_ lrc: String?, for audio: URL) -> Bool {
        guard let lrc, !lrc.isEmpty,
              FileManager.default.fileExists(atPath: audio.path) else { return false }

        // Validate through the same parser the hand-over will use: an untimed
        // body, or one that survives only as credits, is worth no file.
        let lines = Audition.Lyrics.parse(lrc)
        guard !lines.isEmpty else { return false }
        // Instrumental: a marker line (plus at most a couple of credits) is all
        // that comes back. Mirrors `LyricsParser`'s test.
        guard !(lines.count <= 10 && lines.contains { $0.text.contains(instrumentalMarker) })
        else { return false }

        let url = Audition.Lyrics.sidecarURL(for: audio)
        guard let data = lrc.data(using: .utf8) else { return false }
        // The same track comes round again every session; re-writing identical
        // bytes only churns the cache directory's mtimes.
        if let existing = try? Data(contentsOf: url), existing == data { return true }

        // Temp file + rename, like `VocalStemCache.write`: a reader of a
        // half-written `.lrc` would parse a truncated last line as gospel.
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).lrc")
        do {
            try data.write(to: temporary)
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: temporary, to: url)
            return true
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
    }

    /// Fetch and persist in one go — the prefetch pipeline has a local file but
    /// has never asked for the words (only the *playing* track's lyrics are
    /// loaded). One small JSON call per prefetched track.
    static func fetchAndWrite(trackID: Int, for audio: URL) async {
        // A sidecar already on disk is this track's words from a previous
        // session — skip the network round-trip rather than re-fetching the
        // same body every prefetch. (Lyrics for a published track are as good
        // as immutable; an edit upstream is picked up whenever the audio is
        // re-cached.)
        guard !FileManager.default.fileExists(
            atPath: Audition.Lyrics.sidecarURL(for: audio).path) else { return }
        guard let response = try? await NeteaseAPI.lyric(id: trackID) else { return }
        write(response.lrc?.lyric, for: audio)
    }
}
