import Foundation

// The listening-feedback corpus: one JSON object per line in
// `~/Library/Application Support/Kumone/automix-feedback.jsonl`.
//
// A listening test produces one durable thing — somebody's verdict on a
// particular hand-over — and until now that lived in a notebook, if anywhere.
// A line here pairs the verdict with everything needed to reproduce and
// re-judge the seam later: which two tracks, what was planned, what actually
// ran, which gesture, which path, which debug overrides were on, and a
// fingerprint of the calibration in force. That is the difference between "the
// vocal exchange sounded bad once" and a row a sweep can join against.
//
// **Schema stability matters more than schema beauty.** These lines outlive
// the code that wrote them, so every line carries `"v"`, fields are only ever
// added, and the encoder is pinned by a round-trip test. Anything that changes
// meaning gets a new version, never a re-used key.
//
// This file is the only thing the debug panel writes to disk. The overrides
// deliberately do not persist; a mark does.

/// One line of the feedback corpus.
struct AutoMixFeedbackEntry: Codable, Equatable {

    /// Bump only for a change that alters what an existing key *means*.
    static let currentVersion = 1

    struct TrackRef: Codable, Equatable {
        var id: Int
        var title: String
    }

    /// A plan flattened for the record. Deliberately a copy rather than a
    /// reference to `AutoMixDebugPlan`: that type follows the panel's needs,
    /// and the corpus must not move when the panel's layout does.
    struct PlanRef: Codable, Equatable {
        var kind: String
        var outPoint: TimeInterval?
        var inPoint: TimeInterval?
        var overlap: TimeInterval
        var overlapBars: Int?
        var outgoingRate: Float?
        var incomingRate: Float?
        var outroEffect: String?
        var stagedEQ: Bool?
        var rideDB: Double?

        init(_ plan: AutoMixDebugPlan) {
            kind = plan.kind
            outPoint = plan.outPoint
            inPoint = plan.inPoint
            overlap = plan.overlap
            overlapBars = plan.overlapBars
            outgoingRate = plan.outgoingRate
            incomingRate = plan.incomingRate
            outroEffect = plan.outroEffect
            stagedEQ = plan.stagedEQ
            rideDB = plan.rideDB
        }

        init(kind: String, outPoint: TimeInterval?, overlap: TimeInterval) {
            self.kind = kind
            self.outPoint = outPoint
            self.inPoint = nil
            self.overlap = overlap
        }
    }

    enum Verdict: String, Codable {
        case good, bad
    }

    var v: Int = AutoMixFeedbackEntry.currentVersion
    var at: Date
    var verdict: Verdict
    var note: String?
    var outgoing: TrackRef?
    var incoming: TrackRef?
    var planned: PlanRef?
    var executed: PlanRef?
    /// The stem technique the plan asked for, `nil` for a whole-mix hand-over.
    var gesture: String?
    /// splicedSegment / liveOverlap / gapless; nil when the seam has not run
    /// yet (a mark placed on the plan that is currently armed).
    var path: String?
    var overrides: [String]
    /// FNV-1a over the effective planner config — see `configFingerprint`.
    var config: String
}

enum AutoMixFeedbackLog {

    static var fileURL: URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kumone", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("automix-feedback.jsonl")
    }

    /// The encoder the corpus is written with. ISO-8601 dates and sorted keys,
    /// so a line is diffable and a round-trip is byte-stable.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// One entry as the single line it will occupy — no trailing newline, and
    /// guaranteed newline-free inside, because the file's whole contract is
    /// one object per line and a note is free text.
    static func line(_ entry: AutoMixFeedbackEntry) throws -> String {
        var sanitized = entry
        sanitized.note = entry.note.map {
            $0.replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
        }
        let data = try encoder().encode(sanitized)
        return String(decoding: data, as: UTF8.self)
    }

    /// Append one line.
    ///
    /// `O_APPEND` rather than seek-then-write: the kernel places the write at
    /// the end atomically, so a line can never land inside another one — which
    /// a corpus of one-object-per-line has no way to recover from. A single
    /// `write` of a line this size is not split in practice, and the file is
    /// only ever written from here.
    @discardableResult
    static func append(_ entry: AutoMixFeedbackEntry, to url: URL? = nil) -> Bool {
        let target = url ?? fileURL
        guard let payload = try? line(entry), let data = (payload + "\n").data(using: .utf8)
        else { return false }
        let fd = open(target.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            return write(fd, base, buffer.count) == buffer.count
        }
    }

    /// A stable digest of the effective planner config, so two marks made weeks
    /// apart can be told apart by calibration rather than by memory.
    ///
    /// Built by reflection over the struct's stored properties, which means a
    /// knob added later is picked up without anyone remembering to list it
    /// here — the failure mode of a hand-written list is a fingerprint that
    /// silently stops distinguishing. Deliberately not `Hashable`'s seeded
    /// hash, for the reason `StemEnvelope.signature` gives: that value changes
    /// per process, and a corpus keyed on it could never be joined.
    static func configFingerprint(_ config: TransitionPlanner.Config) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for child in Mirror(reflecting: config).children {
            let text = "\(child.label ?? "?")=\(child.value);"
            for byte in text.utf8 {
                hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
            }
        }
        return String(format: "%08x", UInt32(truncatingIfNeeded: hash))
    }
}
