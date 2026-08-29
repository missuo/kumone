import Foundation

// 转场即乐谱 — the data model. See docs/automix-score-predev.md §2.1.
//
// Everything the engine says about "when does what happen" is a continuous
// quantity: seconds and slopes. A club gesture is not. Cut-on-the-one is a
// *discrete event at a grid point*, and until there is a name for that, the
// vocabulary has only envelopes in it.
//
// A score is that name: a handful of typed events addressed in bars and beats
// around the seam, compiled against the final geometry (`ScoreCompiler`) into
// whole-mix gain lanes the offline renderer applies sample-accurately. It is a
// *marker*, exactly like `.vocalExchange` — the planner says what it wants, the
// compiler works out where that lands in seconds, and a compile that cannot
// land throws the whole score away rather than approximating it.

/// A position on the shared bar grid. `bar 0, beat 0` **is the seam** — "the
/// one" the incoming track's aim point lands on.
///
/// Negative bars are resolved on the **outgoing** track's (already bent) grid,
/// non-negative ones on the **incoming** track's. That asymmetry is the whole
/// point: before the seam the outgoing song is the thing keeping time, after it
/// the incoming one is, and a beat-matched pair agrees about the seam itself.
public struct GridPosition: Codable, Equatable, Sendable, Comparable {
    public var bar: Int
    /// 0..<`TransitionScore.beatsPerBar`. Fractional beats are allowed (0.5 is
    /// the off-beat) so a gesture can land between the quarter notes.
    public var beat: Double

    public init(bar: Int, beat: Double = 0) {
        self.bar = bar
        self.beat = beat
    }

    /// The seam.
    public static let seam = GridPosition(bar: 0, beat: 0)

    /// Beats from the seam, positive after it.
    public var beatsFromSeam: Double { Double(bar) * Double(TransitionScore.beatsPerBar) + beat }

    public static func < (a: GridPosition, b: GridPosition) -> Bool {
        a.beatsFromSeam < b.beatsFromSeam
    }
}

/// One club gesture, as an event rather than a curve.
///
/// The cases past P1 are named here on purpose: the model has to be able to
/// *express* the vocabulary before the compiler learns to realize it, or the
/// first extension rewrites the type. `ScoreCompiler` refuses the ones it
/// cannot yet perform, out loud, and the score is then not played at all.
public enum ScoreEvent: Codable, Equatable, Sendable {
    /// The outgoing track stops dead on this grid point (a ≤10 ms edge).
    /// The "cut" half of cut-on-the-one.
    case cutOut
    /// The incoming track arrives full-band on this grid point, no fade and no
    /// EQ split. The "in" half.
    case slamIn
    /// Everything goes quiet for this many beats — tension cut. **Not P1.**
    case silence(beats: Double)
    /// The outgoing track is thrown into a beat-synced delay from the previous
    /// lyric line end; the wet tail runs on past this grid point, where the dry
    /// signal is cut. `echoOut`'s gesture with a cut instead of a fade at the
    /// end of it.
    case echoThrow
    /// The incoming track enters as an accompaniment bed (its vocal lane held
    /// down) for this many bars. **Not P1**, and honestly not a drums break —
    /// see the predev's table.
    case bedIntro(bars: Int)

    /// Short name for reports, filenames and the debug panel.
    public var label: String {
        switch self {
        case .cutOut: return "cutOut"
        case .slamIn: return "slamIn"
        case .silence(let beats): return String(format: "silence(%.2f)", beats)
        case .echoThrow: return "echoThrow"
        case .bedIntro(let bars): return "bedIntro(\(bars))"
        }
    }

    /// Whether this event is the one that ends the outgoing side. Exactly one
    /// of these owns the seam in a valid score — two ways of stopping the same
    /// deck at the same instant is not a gesture, it is a bug.
    public var endsOutgoing: Bool {
        switch self {
        case .cutOut, .echoThrow: return true
        case .slamIn, .silence, .bedIntro: return false
        }
    }

    /// Realizable by today's compiler (P1: cut-on-one and echo throw).
    public var isSupportedInV1: Bool {
        switch self {
        case .cutOut, .slamIn, .echoThrow: return true
        case .silence, .bedIntro: return false
        }
    }
}

public struct ScoredEvent: Codable, Equatable, Sendable {
    public var at: GridPosition
    public var event: ScoreEvent

    public init(at: GridPosition, _ event: ScoreEvent) {
        self.at = at
        self.event = event
    }
}

/// A short typed score around one seam.
public struct TransitionScore: Codable, Equatable, Sendable {
    /// Four beats to the bar, everywhere. The same assumption
    /// `TransitionAutomation.Geometry` already makes when it derives a beat
    /// period from `overlapBars`.
    public static let beatsPerBar = 4

    /// v1 limits (predev §2.1): how many bars either side of the seam a score
    /// may reach into.
    public static let maxPreBars = 4
    public static let maxPostBars = 8

    /// Bars of the outgoing track before the seam this score reaches into.
    public var preBars: Int
    /// Bars of the incoming track after it.
    public var postBars: Int
    public var events: [ScoredEvent]

    public init(preBars: Int, postBars: Int, events: [ScoredEvent]) {
        self.preBars = preBars
        self.postBars = postBars
        self.events = events
    }

    // MARK: - The P1 score

    /// Cut-on-the-one: the outgoing track stops on the seam and the incoming
    /// one arrives on the same beat, full-band.
    ///
    /// `throwingEcho` swaps the plain cut for an echo throw — the same instant,
    /// with the outgoing track's last line thrown into a beat-synced delay that
    /// rings on over the new one. It needs an `.lrc` to aim at; the compiler
    /// degrades it to a plain cut (and says so) when there is nothing there.
    public static func cutOnOne(throwingEcho: Bool = false) -> TransitionScore {
        TransitionScore(preBars: 1, postBars: 1, events: [
            ScoredEvent(at: .seam, throwingEcho ? .echoThrow : .cutOut),
            ScoredEvent(at: .seam, .slamIn),
        ])
    }

    /// How the panel and the console name this score: "cutOnOne", or
    /// "cutOnOne+echoThrow".
    public var label: String {
        var parts: [String] = []
        if events.contains(where: { $0.event == .cutOut || $0.event == .echoThrow }),
           events.contains(where: { $0.event == .slamIn }) {
            parts.append("cutOnOne")
        }
        for scored in events {
            switch scored.event {
            case .cutOut, .slamIn: continue
            case .echoThrow, .silence, .bedIntro: parts.append(scored.event.label)
            }
        }
        return parts.isEmpty
            ? events.map(\.event.label).joined(separator: "+")
            : parts.joined(separator: "+")
    }

    /// The event that ends the outgoing side, and where.
    public var seamOwner: ScoredEvent? { events.first { $0.event.endsOutgoing } }

    // MARK: - Validation

    public enum ValidationFailure: LocalizedError, Equatable {
        case emptyScore
        case barsOutOfRange(preBars: Int, postBars: Int)
        case positionOutOfRange(event: String, bar: Int, preBars: Int, postBars: Int)
        case beatOutOfRange(event: String, beat: Double)
        case notFinite(event: String)
        case noSeamOwner
        case severalSeamOwners([String])
        case seamOwnerOffTheOne(event: String, bar: Int, beat: Double)
        case notMonotonic(previous: String, event: String)
        case duplicate(event: String)

        public var errorDescription: String? {
            switch self {
            case .emptyScore:
                return "这张乐谱一个事件都没有。"
            case .barsOutOfRange(let pre, let post):
                return "乐谱跨度 \(pre)/\(post) 小节超出 v1 的 "
                    + "\(TransitionScore.maxPreBars)/\(TransitionScore.maxPostBars) 上限。"
            case .positionOutOfRange(let event, let bar, let pre, let post):
                return "事件 \(event) 落在第 \(bar) 小节，不在 [−\(pre), \(post)) 的范围里。"
            case .beatOutOfRange(let event, let beat):
                return String(format: "事件 %@ 的拍位 %.2f 不在 0–%d 之间。",
                              event, beat, TransitionScore.beatsPerBar)
            case .notFinite(let event):
                return "事件 \(event) 的格点不是有限数字。"
            case .noSeamOwner:
                return "这张乐谱没有一个结束出曲的事件（cutOut / echoThrow）。"
            case .severalSeamOwners(let names):
                return "这张乐谱有不止一个结束出曲的事件：\(names.joined(separator: "、"))。"
            case .seamOwnerOffTheOne(let event, let bar, let beat):
                return String(format: "%@ 必须落在 seam（bar 0 beat 0）上，现在在 bar %d beat %.2f。",
                              event, bar, beat)
            case .notMonotonic(let previous, let event):
                return "乐谱事件必须按格点递增：\(previous) 之后又出现了更早的 \(event)。"
            case .duplicate(let event):
                return "同一个格点上出现了两次 \(event)。"
            }
        }
    }

    /// Structural checks — everything that can be decided without a beat grid.
    /// Whether the grid *reaches* the score's bars is the compiler's business
    /// (`ScoreCompiler`), because only it has the grids.
    public func validate() throws {
        guard !events.isEmpty else { throw ValidationFailure.emptyScore }
        guard preBars >= 0, postBars >= 0,
              preBars <= Self.maxPreBars, postBars <= Self.maxPostBars,
              preBars + postBars > 0
        else { throw ValidationFailure.barsOutOfRange(preBars: preBars, postBars: postBars) }

        var previous: ScoredEvent?
        var seen = Set<String>()
        for scored in events {
            let name = scored.event.label
            guard scored.at.beat.isFinite else { throw ValidationFailure.notFinite(event: name) }
            guard scored.at.bar >= -preBars, scored.at.bar < postBars || scored.at.bar == 0
            else {
                throw ValidationFailure.positionOutOfRange(
                    event: name, bar: scored.at.bar, preBars: preBars, postBars: postBars)
            }
            guard scored.at.beat >= 0, scored.at.beat < Double(Self.beatsPerBar) else {
                throw ValidationFailure.beatOutOfRange(event: name, beat: scored.at.beat)
            }
            if let previous, scored.at < previous.at {
                throw ValidationFailure.notMonotonic(previous: previous.event.label, event: name)
            }
            let key = "\(scored.at.bar):\(scored.at.beat):\(name)"
            guard seen.insert(key).inserted else { throw ValidationFailure.duplicate(event: name) }
            previous = scored
        }

        let owners = events.filter { $0.event.endsOutgoing }
        guard let owner = owners.first else { throw ValidationFailure.noSeamOwner }
        guard owners.count == 1 else {
            throw ValidationFailure.severalSeamOwners(owners.map(\.event.label))
        }
        guard owner.at == .seam else {
            throw ValidationFailure.seamOwnerOffTheOne(
                event: owner.event.label, bar: owner.at.bar, beat: owner.at.beat)
        }
    }
}
