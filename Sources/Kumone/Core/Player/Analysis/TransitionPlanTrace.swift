import Foundation

// A decision ledger for `TransitionPlanner.plan`.
//
// `beatMatched` is the conjunction of a dozen gates — the tier's own three
// signals, the key demotion, both tempo confidences, the folded BPM delta, the
// per-deck rate bend, an in point, and then a bar-length search with its own
// ceiling / out-point / steadiness / vocal rules. When a real corpus produces
// almost no beat-matched hand-overs, *which* of those gates did the killing is
// the only question worth asking first, and the plan alone cannot answer it.
//
// So the planner can be asked to keep a ledger while it decides. Two rules make
// this safe to have in production code:
//
//   * **Zero behaviour change.** Nothing here is read back by the planner. The
//     ledger is written by `note`, which returns the same Bool the `guard` it
//     wraps was already testing, so evaluation order and short-circuiting are
//     exactly what they were.
//   * **Zero cost when unasked.** The tracing parameter is an
//     `inout PlanTrace?`, and every recording site builds its numbers and its
//     text inside `@autoclosure`s that are never called while the trace is nil.
//     The product path calls the untraced overload and pays for one nil check
//     per gate.

/// One gate on the road to a beat-matched hand-over: what it measured, what it
/// was held to, and whether the pair got through.
public struct PlanGate: Sendable, Equatable {
    /// Where in the chain this gate sits. The order of the cases is the order
    /// the planner reaches them.
    public enum Stage: String, Sendable, Equatable, CaseIterable {
        /// Both tracks long enough to be worth a transition at all.
        case duration
        /// The three compatibility signals that pick the tier.
        case tier
        /// Harmony, which can demote `compatible` but never creates a clash.
        case key
        /// Where the out/in point *candidates* came from — sections, lyric
        /// line ends, the climax guard (predev §2.3). Like `.barUpgrade` these
        /// are never eliminations: they re-order and re-aim a search that then
        /// runs its own unchanged gates, so nothing recorded here can be the
        /// reason a pair lost its beat-match.
        ///
        /// `passed` on this stage therefore means "nothing went wrong", not
        /// "structure was used" — falling back to the energy heuristics is the
        /// designed path for most of the library, not a failure. Which source a
        /// point came from lives in `value` and `detail`.
        case structure
        /// The beat-match rule proper: tempo confidence through out point.
        case beatMatch
        /// The 16 / 8-bar upgrade search. These never cost a pair its
        /// beat-matched plan — failing them only shortens the overlap — so
        /// they are never blamed for an elimination.
        case barUpgrade
    }

    /// Stable machine name, unique within a trace outside `.barUpgrade`.
    public let id: String
    public let stage: Stage
    public let passed: Bool
    /// The number the gate measured, when it is a numeric comparison. Some
    /// gates ("a downbeat exists past the intro") have no meaningful value.
    public let value: Double?
    /// The line `value` was held to, in the same unit.
    public let threshold: Double?
    /// The comparison in words, quoting both numbers.
    public let detail: String

    public init(id: String, stage: Stage, passed: Bool,
                value: Double?, threshold: Double?, detail: String) {
        self.id = id
        self.stage = stage
        self.passed = passed
        self.value = value
        self.threshold = threshold
        self.detail = detail
    }

    /// Short human name for reports — the rule in three words.
    public var label: String {
        switch id {
        case "minDuration": return "track length"
        case "loudnessGap": return "loudness gap"
        case "timbreDistance": return "timbre distance"
        case "tempoClash": return "tempo clash line"
        case "keyDistance": return "key distance"
        case "bpmConfidence": return "tempo confidence"
        case "bpmDelta": return "folded BPM delta"
        case "rateDeviation": return "rate bend"
        case "inPoint": return "in point"
        case "overlapCeiling": return "overlap ceiling"
        case "outPoint": return "out point"
        case "incomingRoom": return "incoming room"
        case "structureCandidates": return "structural candidates"
        case "lyricSnap": return "lyric snap"
        case "climaxGuard": return "climax guard"
        case "inPointSource": return "in-point source"
        default: break
        }
        let parts = id.split(separator: ".")
        guard parts.count == 2 else { return id }
        switch parts[1] {
        case "ceiling": return "\(parts[0]) ceiling"
        case "outPoint": return "\(parts[0]) out point"
        case "incomingRoom": return "\(parts[0]) incoming room"
        case "stableOut": return "\(parts[0]) outgoing steadiness"
        case "stableIn": return "\(parts[0]) incoming steadiness"
        case "vocals": return "\(parts[0]) vocal clash"
        default: return id
        }
    }

    /// How far the measurement sat from its line, as a share of the line —
    /// so "0.06 over an 8 % window" and "0.9 dB over a 3 dB line" become
    /// comparable numbers. Nil when the gate is not numeric.
    public var margin: Double? {
        guard let value, let threshold, threshold != 0 else { return nil }
        return (value - threshold) / abs(threshold)
    }
}

/// The gates one `plan()` call walked, and which one ended the pair's chance of
/// a beat-matched hand-over.
public struct PlanTrace: Sendable {
    /// Every gate that actually took part in this decision, in the order the
    /// planner reached them.
    public private(set) var gates: [PlanGate] = []

    /// The first gate this pair failed, ignoring the bar-upgrade search.
    ///
    /// This is the *first-elimination* attribution a corpus histogram wants: a
    /// pair stopped by the loudness signal is counted there and nowhere else,
    /// rather than also being blamed on every later gate it never reached.
    /// Nil when the pair came out beat-matched.
    public private(set) var blocker: PlanGate?

    /// Gates the planner walked *after* the pair had already lost its
    /// beat-match at the tier or key gate — a side ledger, kept only while
    /// tracing, so a sweep can ask the counterfactual ("and would it have
    /// cleared the rest?") without disturbing the attribution above.
    public internal(set) var shadowGates: [PlanGate] = []

    /// Bars the beat-match search settled on, when it produced a plan.
    public internal(set) var chosenBars: Int?

    public init() {}

    /// Chain order for reports, so a histogram's rows read top-down the way
    /// the planner decides rather than by count.
    public static let gateOrder: [String] = [
        "minDuration",
        "loudnessGap", "timbreDistance", "tempoClash", "keyDistance",
        "bpmConfidence", "bpmDelta", "rateDeviation",
        "inPoint", "overlapCeiling", "outPoint", "incomingRoom",
    ]

    mutating func add(_ gate: PlanGate) {
        gates.append(gate)
        if !gate.passed, gate.stage != .barUpgrade, gate.stage != .structure,
           blocker == nil { blocker = gate }
    }

    /// Whether every gate outside the bar-upgrade search was cleared.
    public var clearedEveryGate: Bool { blocker == nil }

    /// The gate the shadow ledger says would have stopped this pair anyway,
    /// had the tier let it through. Nil when the shadow chain is clean (or
    /// was never run, i.e. the pair reached the beat-match rule for real).
    public var shadowBlocker: PlanGate? {
        shadowGates.first { !$0.passed && $0.stage != .barUpgrade && $0.stage != .structure }
    }
}
