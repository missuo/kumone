#if os(macOS)
import Foundation

/// Persistent, quality-independent home for `TrackAnalysis` (spec §3).
///
/// An analysis is ~17 KB of expensive work, so it deliberately does not live
/// in the audio LRU cache: it sits in **Application Support**, survives the
/// audio being evicted or cleared, and is keyed by track ID alone —
/// `<trackID>.json`.
///
/// Keying by ID rather than by playback key matters twice over. A track
/// analyzed at `standard` for queue scoring and later played at `exhigh`
/// would otherwise be analyzed twice, and an exact-key lookup would miss the
/// other level's perfectly good result. Each file records which level and
/// source it was computed from, and a higher-quality analysis replaces a
/// lower-quality one — never the other way round. A caller playing at `hires`
/// is welcome to a `standard` analysis (it is good enough to plan with) and
/// may re-analyze and store, which upgrades the file for everyone after it.
actor AnalysisStore {
    static let shared = AnalysisStore()

    /// One track's analysis plus the provenance the precedence rule needs.
    ///
    /// `TrackAnalysis` is nested rather than flattened so its own `Codable`
    /// keeps working unchanged, and a future field added here cannot collide
    /// with one added there.
    struct Record: Codable, Sendable {
        var analysis: TrackAnalysis
        /// Served quality level the audio was analyzed at, e.g. "exhigh".
        var level: String
        /// "netease" or "unblock:<source>", as in `EngineAudioCache.Key`.
        var source: String
    }

    /// Quality levels cheapest first. Unknown names sort last, so a level this
    /// build has never heard of is treated as the best thing on disk rather
    /// than silently preferred against.
    private static let levelLadder = ["standard", "higher", "exhigh", "lossless", "hires"]

    static func levelRank(_ level: String) -> Int {
        levelLadder.firstIndex(of: level) ?? levelLadder.count
    }

    private let directory: URL
    /// One codec pair for the actor's lifetime: every record shares the same
    /// (default) configuration, so per-call instances were pure allocation.
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private init() {
        directory = KumoneDirectories.applicationSupport("Analysis")
    }

    /// Test seam: an isolated store over a temporary directory.
    init(directory: URL) {
        self.directory = directory
        ensureDirectory()
    }

    // MARK: - Lookup

    /// The analysis for this track at **any** quality level, or nil on a miss
    /// (absent, unreadable, or written by an older analyzer version).
    func loadAnalysis(forTrackID id: Int) -> TrackAnalysis? {
        record(forTrackID: id)?.analysis
    }

    /// Convenience for the playback path, which already holds an
    /// `EngineAudioCache.Key`. Only the track ID of the key is used — see the type
    /// note above on why the level is deliberately ignored.
    func loadAnalysis(for key: EngineAudioCache.Key) -> TrackAnalysis? {
        loadAnalysis(forTrackID: key.trackID)
    }

    /// Every stored analysis for the given tracks in one directory walk.
    ///
    /// This is the free half of the queue-order candidate pool (predev §2.2):
    /// a track heard before has an analysis on disk, and asking for it costs
    /// no network call, no download and no analyzer pass.
    func analyses(forTrackIDs ids: Set<Int>) -> [Int: TrackAnalysis] {
        guard !ids.isEmpty else { return [:] }
        var found: [Int: TrackAnalysis] = [:]
        for id in ids {
            if let record = record(forTrackID: id) { found[id] = record.analysis }
        }
        return found
    }

    // MARK: - Writing

    /// Persists an analysis, keeping whichever of the two was computed from
    /// better audio. A stale-version file on disk always loses.
    func storeAnalysis(_ analysis: TrackAnalysis, forTrackID id: Int,
                       level: String, source: String) {
        write(Record(analysis: analysis, level: level, source: source), forTrackID: id)
    }

    func storeAnalysis(_ analysis: TrackAnalysis, for key: EngineAudioCache.Key) {
        storeAnalysis(analysis, forTrackID: key.trackID,
                      level: key.level, source: key.source)
    }

    // MARK: - Maintenance

    /// Total bytes on disk. No limit is enforced: ~17 KB per track means even
    /// a library of thousands costs less than one lossless album.
    func totalUsageBytes() -> Int64 {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return urls.reduce(0) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    /// Throws away every analysis. Deliberately separate from the audio cache's
    /// `removeAll()`: clearing playback bytes must not cost the expensive part.
    func clear() {
        try? FileManager.default.removeItem(at: directory)
        ensureDirectory()
    }

    // MARK: - Storage

    private func recordURL(forTrackID id: Int) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    private func record(forTrackID id: Int) -> Record? {
        guard let data = try? Data(contentsOf: recordURL(forTrackID: id)),
              let record = try? decoder.decode(Record.self, from: data),
              record.analysis.version == TrackAnalysis.currentVersion else { return nil }
        return record
    }

    /// Just the fields the precedence check reads, so deciding whether to
    /// write does not pay for decoding a ~17 KB `TrackAnalysis` it throws away.
    private struct Head: Decodable {
        struct Analysis: Decodable { var version: Int }
        var analysis: Analysis
        var level: String
    }

    private func head(forTrackID id: Int) -> Head? {
        guard let data = try? Data(contentsOf: recordURL(forTrackID: id)),
              let head = try? decoder.decode(Head.self, from: data),
              head.analysis.version == TrackAnalysis.currentVersion else { return nil }
        return head
    }

    /// The precedence rule, in one place: a record only lands if nothing
    /// usable is already there from equal-or-better audio.
    private func write(_ record: Record, forTrackID id: Int) {
        if let existing = head(forTrackID: id),
           Self.levelRank(existing.level) > Self.levelRank(record.level) { return }
        ensureDirectory()
        guard let data = try? encoder.encode(record) else { return }
        try? data.write(to: recordURL(forTrackID: id), options: .atomic)
    }

    private nonisolated func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
#endif
