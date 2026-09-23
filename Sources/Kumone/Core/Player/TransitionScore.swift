#if os(macOS)
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

/// **What the seam is aimed at, in the incoming track** — the P2 layer
/// (predev §2.3).
///
/// P1 put a cut on the one and left *which* one to the geometry: the seam
/// started from the plan's own bass-swap point and was snapped onto the nearest
/// phrase line of the incoming song. That lands a clean edge — and the field
/// verdict on the first three scored seams was that it lands it *nowhere in
/// particular*, N phrase-lines past the in point, so the slam reads as abrupt
/// rather than as an arrival. A cut is only motivated if the thing it cuts to
/// is the thing the listener came for.
///
/// So the aim is chosen first and the entry is composed backwards from it: the
/// incoming deck is started however many bars before `time` the hand-over needs,
/// so that `time` — the drop, the chorus, or failing both the start of the song
/// proper — falls exactly on the seam. **Nothing else moves**: the out point,
/// the climax guard, the lyric snap and the candidate ordering are the outgoing
/// track's business and they are untouched, so aiming picks among geometries the
/// gates have already passed and can never authorize one they refused.
public struct TransitionAim: Codable, Equatable, Sendable {

    /// Which structural landmark the seam was aimed at, in priority order.
    public enum Target: String, Codable, Sendable {
        /// A `.drop` section's start — the electronic climax, and the one grid
        /// point a slam was invented for.
        case drop
        /// A chorus start: the pop equivalent of the same question.
        case chorus
        /// The first **core** section's start — `inPointChoice`'s own answer,
        /// which is to say "where the song proper begins". Aiming at it is
        /// still worth doing: today the in point is where the incoming deck
        /// *starts*, so the core start goes by unremarked in the middle of the
        /// overlap; aimed, the cut lands on it.
        case core
    }

    /// **Which instant of the hand-over the target is made to land on.**
    ///
    /// P1/P2 had only one answer, because only a score aimed: the seam. P3's
    /// `dropAlign` class aims a *blend*, and a blend's arrival is not its seam
    /// — it is the end of the overlap, with the outgoing tail lying over the
    /// incoming build and the hand-over completing on the drop (predev §2.3
    /// point 2). Two landings, one aiming machinery, and the gates below are
    /// re-run identically for both.
    public enum Landing: String, Codable, Sendable {
        /// The bass-swap point: the cut's "the one".
        case seam
        /// The end of the overlap: the blend's arrival.
        case overlapEnd

        public var label: String {
            switch self {
            case .seam: return "the seam"
            case .overlapEnd: return "the end of the overlap"
            }
        }
    }

    public var target: Target
    /// The instant on the **incoming track's own clock** the seam is aimed at.
    public var time: TimeInterval
    /// How many bars of the incoming track are played, silently under the
    /// outgoing one, before the landing point reaches `time`.
    public var leadBars: Int
    /// Defaulted to `.seam` so every P1/P2 call site, fixture and decoded
    /// sidecar means exactly what it meant before the case existed.
    public var landing: Landing = .seam

    public init(target: Target, time: TimeInterval, leadBars: Int,
                landing: Landing = .seam) {
        self.target = target
        self.time = time
        self.leadBars = leadBars
        self.landing = landing
    }

    /// `drop@84.00s` — how the console, the panel and the seam history name it.
    public var label: String {
        String(format: "%@@%.2fs", target.rawValue, time)
            + (landing == .seam ? "" : "→overlapEnd")
    }

    /// The one line a report prints, aimed or not. The unaimed case is spelled
    /// out rather than omitted: "we did not aim" is the interesting half of the
    /// A/B, and a missing row reads as a missing feature.
    public static func report(_ aim: TransitionAim?, reason: String? = nil) -> String {
        guard let aim else { return "aim=none" + (reason.map { " (\($0))" } ?? "") }
        return "aim=\(aim.label)" + " (\(aim.leadBars) bars of lead)"
    }
}

/// One club gesture, as an event rather than a curve.
///
/// **Two shapes of event live in here, and the difference is load-bearing.**
/// `cutOut`, `slamIn` and `echoThrow` are *instants*: the grid point is where
/// they happen. `silence(beats:)` and `bedIntro(bars:)` are **spans that end at
/// their grid point** — a tension cut is the beat *before* the landing and a
/// bed is the bars *before* the vocals join. Addressing a span by its end is
/// what lets both of them be written at `bar 0` and mean "right before the
/// thing the listener came for", which is the only place either gesture is
/// musical; addressing them by their start would put them at a negative bar,
/// where the model resolves positions on the **outgoing** track's grid, and
/// both of these are the incoming track's business.
public enum ScoreEvent: Codable, Equatable, Sendable {
    /// The outgoing track stops dead on this grid point (a ≤10 ms edge).
    /// The "cut" half of cut-on-the-one.
    case cutOut
    /// The incoming track arrives full-band on this grid point, no fade and no
    /// EQ split. The "in" half.
    ///
    /// **P4 made this event mean something.** P1 wrote it into every score and
    /// the compiler ignored it: the incoming lane's rise was hard-wired to the
    /// seam, so `slamIn` was decoration on a decision taken elsewhere. It now
    /// *is* the decision — the lane rises with an 8 ms edge at this grid point
    /// and nowhere else — and a score without one gets a one-bar entry instead
    /// of an edge, which is the control arm the slam is A/B'd against.
    case slamIn
    /// Everything goes quiet for this many beats, ending on this grid point —
    /// tension cut. Both sides at −60 dB, sample-exact, on the whole-mix lanes.
    case silence(beats: Double)
    /// The outgoing track is thrown into a beat-synced delay from the previous
    /// lyric line end; the wet tail runs on past this grid point, where the dry
    /// signal is cut. `echoOut`'s gesture with a cut instead of a fade at the
    /// end of it.
    case echoThrow
    /// The incoming track enters as an accompaniment bed (its vocal lane held
    /// down) for this many bars, its singer joining **on** this grid point.
    /// Honestly not a drums break — see the predev's table.
    ///
    /// The one gesture in the library that needs a separator: the bed is the
    /// incoming track minus its vocal, and there is no way to have that without
    /// splitting the incoming deck. So a score carrying one pays a runway the
    /// other four do not (`TransitionScore.RunwayClass`).
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

    /// Realizable by today's compiler.
    ///
    /// P1 shipped this false for `silence` and `bedIntro`, and the compiler
    /// threw whole scores away on it. P4 built both, so every case in the
    /// vocabulary is now performable and this is uniformly true. The property
    /// and the compiler's guard stay: the model exists to be able to *name* a
    /// gesture before it can play one (spinback is the next one waiting), and
    /// the refusal path is the thing that keeps naming safe.
    public var isSupportedInV1: Bool {
        switch self {
        case .cutOut, .slamIn, .echoThrow, .silence, .bedIntro: return true
        }
    }

    /// Whether this gesture only makes sense next to an event that ends the
    /// outgoing side.
    ///
    /// A slam is the *in* half of a cut: an incoming track arriving full-band
    /// while the outgoing one is still blending is not a slam, it is a jump in
    /// level. A tension cut is the beat of nothing before that arrival, so it
    /// needs the same partner. A bed, by contrast, decorates a blend — it is
    /// the one gesture in the library with nothing to say about how the
    /// outgoing track leaves.
    public var needsSeamOwner: Bool {
        switch self {
        case .slamIn, .silence: return true
        case .cutOut, .echoThrow, .bedIntro: return false
        }
    }

    /// The gesture needs the **incoming** deck split into vocal and
    /// accompaniment. True for exactly one case, and that case pays for it.
    public var needsIncomingStems: Bool {
        if case .bedIntro = self { return true }
        return false
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
    /// Longest accompaniment bed a score may ask for — the same sixteen bars
    /// that is the planner's own longest overlap, because on an aimed
    /// hand-over the bed and the overlap are the same window.
    public static let maxBedIntroBars = 16

    /// The shipped sizes of the two spans, named here rather than only in
    /// `TransitionPlanner.Config` so the CLI — which lives outside the module
    /// and cannot see a planner config — asks for the same gesture the planner
    /// would have offered. One number, one place, two readers.
    public static let defaultTensionCutBeats: Double = 1
    /// **Eight bars, and the predev said four.** The deviation is P2's fault in
    /// the good way. The predev imagined a bed sliding in *under* an entry that
    /// happened somewhere else, so "four bars early" was a statement about how
    /// much earlier than usual the incoming deck started. Since aiming, the
    /// incoming deck's entry is already composed backwards from the landing —
    /// the overlap *is* the window between the entry and the drop — so the bed
    /// and the overlap are the same thing, and the number has to be sized like
    /// an overlap. The planner's own overlaps are eight or sixteen bars; a
    /// four-bar cap would refuse every plan it was ever offered, which is a
    /// gesture that ships dead rather than a gesture that ships careful.
    public static let defaultBedIntroBars = 8

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

    // MARK: - The scores

    /// Cut-on-the-one: the outgoing track stops on the seam and the incoming
    /// one arrives on the same beat, full-band.
    ///
    /// **This is where the slam lives, and why it is not a gesture of its own.**
    /// A slam alone — an incoming track arriving at full impact with the
    /// outgoing one still playing under it — is not a club move, it is two
    /// records at once. What a DJ means by "slam it in" is *this*: the cut and
    /// the arrival on the same frame, one hand off the fader and the other on.
    /// So `slamIn` is not offered as a free-floating event the planner may or
    /// may not add; it is a **decision the template makes** (`ScoreTemplate`),
    /// and the vocabulary made explicit is the pair `cutOnOne` / `cutOnly`.
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

    /// The cut without the slam: the outgoing track stops on the seam and the
    /// incoming one comes up over a bar instead of arriving on it.
    ///
    /// **The slam's control arm.** It exists so "does the slam earn its place"
    /// is a question with two renders behind it rather than a matter of taste,
    /// and the compiler treats the missing `slamIn` as an instruction rather
    /// than an omission: no edge on the incoming side, a one-bar raised cosine
    /// instead.
    public static func cutOnly(throwingEcho: Bool = false) -> TransitionScore {
        TransitionScore(preBars: 1, postBars: 1, events: [
            ScoredEvent(at: .seam, throwingEcho ? .echoThrow : .cutOut),
        ])
    }

    /// Tension cut: `beats` beats of full silence ending on the seam, then the
    /// slam.
    ///
    /// The silence is written at the seam because it is a **span ending
    /// there** (see `ScoreEvent`), which is also why it sorts before the cut at
    /// the same grid point — a reader of the event list sees the gesture in the
    /// order it is heard.
    public static func tensionCut(beats: Double) -> TransitionScore {
        TransitionScore(preBars: 1, postBars: 1, events: [
            ScoredEvent(at: .seam, .silence(beats: beats)),
            ScoredEvent(at: .seam, .cutOut),
            ScoredEvent(at: .seam, .slamIn),
        ])
    }

    /// Accompaniment bed: `bars` bars of the incoming track with its vocal lane
    /// held down, under the outgoing track's exit, the singer joining on the
    /// landing point.
    ///
    /// **A decorating score**, and the first one: it has no event that ends the
    /// outgoing side, so it does not own the gain law. The blend underneath it
    /// is the blend the planner already made — the same fader curves, the same
    /// staged EQ, the same aimed overlap end — with one lane of the incoming
    /// deck muted until the drop. Which is exactly what the gesture is: not a
    /// different hand-over, an entrance built for one.
    public static func bedIntro(bars: Int) -> TransitionScore {
        TransitionScore(preBars: 0, postBars: 1, events: [
            ScoredEvent(at: .seam, .bedIntro(bars: bars)),
        ])
    }

    // MARK: - What performing this costs

    /// **What kind of runway a score asks the pre-render for.**
    ///
    /// The whole cost story of the score model in one enum. Four of the five
    /// gestures are full-band — they are gain lanes on the two mixes and they
    /// separate nothing — so their segment is one render pass and the runway
    /// collapses to the margin. The fifth needs the incoming track's singer
    /// isolated, which is a separation pass on one side, and it pays the
    /// arithmetic `stemPrerenderRunway` already does for stem techniques with
    /// the side count halved.
    public enum RunwayClass: String, Sendable, Equatable {
        /// Whole-mix lanes only: ~1 s of rendering, no separator consulted.
        case scoreOnly
        /// One separation pass, on the incoming deck (`bedIntro`).
        case incomingStems
    }

    /// True when any gesture in this score needs the incoming deck split.
    public var needsIncomingStems: Bool { events.contains { $0.event.needsIncomingStems } }

    public var runwayClass: RunwayClass { needsIncomingStems ? .incomingStems : .scoreOnly }

    /// Whether this score is the one deciding how the outgoing track leaves.
    /// False for a decorating score (`bedIntro`), which sits on top of the
    /// blend rather than replacing it.
    public var ownsSeam: Bool { events.contains { $0.event.endsOutgoing } }

    /// How the panel and the console name this score: "cutOnOne",
    /// "cutOnOne+echoThrow", "tensionCut(1)+cutOnOne", "bedIntro(4)".
    ///
    /// Named after the **gestures**, not the events, because that is the
    /// vocabulary the listening notes are written in: nobody hears "a cutOut
    /// and a slamIn at the same grid point", they hear a cut on the one. The
    /// silence goes first because it is heard first.
    public var label: String {
        var parts: [String] = []
        for scored in events {
            if case .silence(let beats) = scored.event {
                parts.append(String(format: "tensionCut(%g)", beats))
            }
        }
        let owner = events.first { $0.event.endsOutgoing }?.event
        let slams = events.contains { $0.event == .slamIn }
        if let owner {
            parts.append((slams ? "cutOnOne" : "cutOnly")
                         + (owner == .echoThrow ? "+echoThrow" : ""))
        }
        for scored in events {
            if case .bedIntro = scored.event { parts.append(scored.event.label) }
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
        case gestureNeedsASeamOwner(event: String)
        case severalSeamOwners([String])
        case silenceOutOfRange(beats: Double)
        case bedIntroOutOfRange(bars: Int)
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
            case .gestureNeedsASeamOwner(let event):
                return "\(event) 需要一个结束出曲的事件（cutOut / echoThrow）陪着，"
                    + "否则它只是在一条还在响的 blend 上跳了一下音量。"
            case .severalSeamOwners(let names):
                return "这张乐谱有不止一个结束出曲的事件：\(names.joined(separator: "、"))。"
            case .silenceOutOfRange(let beats):
                return String(format: "静默 %.2f 拍不在 0–%d 拍（一小节）之间——"
                              + "更长的空白不是张力，是断电。", beats,
                              TransitionScore.beatsPerBar)
            case .bedIntroOutOfRange(let bars):
                return "伴奏垫 \(bars) 小节不在 1–\(TransitionScore.maxBedIntroBars) 小节之间。"
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
            switch scored.event {
            case .silence(let beats):
                guard beats.isFinite, beats > 0,
                      beats <= Double(Self.beatsPerBar)
                else { throw ValidationFailure.silenceOutOfRange(beats: beats) }
            case .bedIntro(let bars):
                guard bars >= 1, bars <= Self.maxBedIntroBars
                else { throw ValidationFailure.bedIntroOutOfRange(bars: bars) }
            case .cutOut, .slamIn, .echoThrow: break
            }
            previous = scored
        }

        // **A score either ends the outgoing track or decorates a blend.**
        //
        // P1 required a seam owner unconditionally, because every score it
        // could write was a cut. P4's `bedIntro` is the first gesture that has
        // no opinion about how the outgoing track leaves — it mutes one lane of
        // the incoming deck and lets the planner's blend run underneath — so
        // "no owner" became a legal shape rather than a malformed score.
        //
        // What did *not* become legal is a score with no owner and a gesture
        // that needs one. A slam with nothing cut is a level jump; a beat of
        // silence in the middle of a crossfade that then resumes is a dropout.
        // Both are the sound of a broken player, and neither is expressible
        // here.
        let owners = events.filter { $0.event.endsOutgoing }
        guard owners.count <= 1 else {
            throw ValidationFailure.severalSeamOwners(owners.map(\.event.label))
        }
        if let owner = owners.first {
            guard owner.at == .seam else {
                throw ValidationFailure.seamOwnerOffTheOne(
                    event: owner.event.label, bar: owner.at.bar, beat: owner.at.beat)
            }
        } else if let orphan = events.first(where: { $0.event.needsSeamOwner }) {
            throw ValidationFailure.gestureNeedsASeamOwner(event: orphan.event.label)
        }
    }
}
#endif
