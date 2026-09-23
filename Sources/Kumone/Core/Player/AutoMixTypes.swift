#if os(macOS)
import Foundation

// Shared contracts between the playback engine, the analyzer, and the
// transition planner. See docs/automix-spec.md.

/// One of the engine's two player decks. Tracks alternate decks so a
/// transition can overlap the outgoing and incoming songs.
enum Deck: String, Sendable {
    case a, b

    var other: Deck { self == .a ? .b : .a }
}

/// Per-track beat/energy analysis, computed once in the background and
/// persisted by `AnalysisStore`, keyed by track ID and outliving the cached
/// audio it was computed from (spec §3, §4).
struct TrackAnalysis: Codable, Sendable {
    /// Bump when the algorithm changes; stale records are re-analyzed.
    static let currentVersion = 7

    /// One structural span of the track — what a listener would call the intro,
    /// a verse, the chorus (predev §2.1). Produced by `StructureSegmenter` from
    /// a beat-synchronous self-similarity matrix; empty whenever the analyzer is
    /// not confident enough to be worth acting on, so every consumer must have a
    /// path that works without it.
    struct Section: Codable, Sendable, Equatable {
        enum Kind: String, Codable, Sendable {
            case intro, verse, chorus, bridge, drop, outro
        }

        /// Snapped to a downbeat (both ends), so a cue taken from a boundary
        /// lands on the bar line.
        var start: TimeInterval
        var end: TimeInterval
        var kind: Kind
        /// How many sections share this one's cluster — a chorus repeats, a
        /// bridge does not. 1 means "this passage happens once".
        var repetition: Int
        /// Section-mean RMS over the track's peak RMS.
        var energy: Float
        /// Section-mean `vocalActivity` over the whole-track mean; 1 is an
        /// average-density passage, 0 an instrumental one.
        var vocalDensity: Float
    }

    let version: Int
    let bpm: Double
    /// 0–1; below the planner's threshold the track never beat-matches.
    let bpmConfidence: Double
    let beats: [TimeInterval]
    let downbeats: [TimeInterval]
    /// Candidate mix points, best first (8/16-bar grid × energy shifts).
    let phraseBoundaries: [TimeInterval]
    /// RMS at 1s granularity over the whole track.
    let rmsEnvelope: [Float]
    /// Where a natural outro fade begins, if the track has one.
    let outroFadeStart: TimeInterval?
    /// First strong downbeat after any intro silence/buildup.
    let introEnd: TimeInterval
    let duration: TimeInterval
    /// Whole-track timbre fingerprint: the L2-normalized mean *level-removed*
    /// 40-band log-mel frame, averaged over the loud half of the track. Each
    /// frame has its own across-band mean (loudness) subtracted first, so the
    /// vector is pure spectral shape and sums to zero; cosine distance between
    /// two tracks' profiles is then a shape correlation, and is the planner's
    /// style-compatibility signal. Empty for very short input.
    let melProfile: [Float]
    /// Detected musical key as a pitch class 0–11 (C = 0), nil when the
    /// track has no stable tonal center.
    let keyPitchClass: Int?
    /// Whether the detected key is minor (only meaningful with a key).
    let keyIsMinor: Bool
    /// 0–1 confidence of the key estimate; below the planner's threshold
    /// the key never influences decisions.
    let keyConfidence: Double
    /// Vocal-presence likelihood 0–1 at 1s granularity (same grid as
    /// `rmsEnvelope`). Empty when not computed.
    let vocalActivity: [Float]
    /// Whole-track mastered loudness: BS.1770-4 K-weighted **gated integrated
    /// loudness in LUFS** (v6). This is the per-track "how loud is this master"
    /// number the cross-track gain compensation trims against; see
    /// `LoudnessMeter` for why LUFS and not an RMS proxy. Nil when the track is
    /// too short or effectively silent — the compensation then leaves the deck
    /// at unity rather than guessing.
    var referenceLoudness: Double? = nil
    /// Sample peak of the 22.05 kHz mono analysis signal, in dBFS. Only used to
    /// keep a compensation *boost* from clipping; nil for a silent track.
    var peakDBFS: Double? = nil
    /// Contiguous structural sections covering the track, in time order (v7).
    /// **Empty is the normal, expected state** for anything the segmenter is not
    /// sure about (see `structureConfidence`), for tracks under ~64 beats, and
    /// for every sidecar written before v7 — consumers fall back to the energy
    /// heuristics (`phraseBoundaries`, `introEnd`, `outroFadeStart`).
    var sections: [Section] = []
    /// 0–1 confidence in `sections`: novelty-peak significance blended with how
    /// far apart the section clusters ended up. Below the segmenter's own gate
    /// the sections are dropped entirely and this is what they were dropped for.
    var structureConfidence: Double = 0
}

/// Expressive styling for a transition — the technique vocabulary the
/// strategy layer draws from per song pair. Mechanics (timing, rates)
/// stay in `TransitionPlan`; this describes *how* the hand-over sounds.
struct TransitionStyle: Sendable, Equatable {
    enum OutroEffect: Sendable, Equatable {
        /// Plain volume fade.
        case fade
        /// A high-pass sweep hollows the outgoing track out as it leaves.
        case filterSweep
        /// The outgoing track stops on the boundary and a delay tail rings out.
        case echoOut
    }

    let outroEffect: OutroEffect
    /// Staged three-band EQ hand-over (lows last) instead of the single
    /// low-shelf bass swap.
    let stagedEQ: Bool
    /// Beat-synced delay time (seconds) for `.echoOut`, when the planner
    /// knows the outgoing tempo. Nil → the engine derives its own (beat
    /// grid on beat-matched plans, otherwise a fixed 250 ms).
    var echoDelayTime: TimeInterval? = nil

    /// **Dominant-deck fader law** for a staged beat-matched blend: one deck
    /// owns the floor at every instant, instead of both meeting at −3 dB in
    /// the middle. Read only when `stagedEQ` is on and the plan is
    /// `.beatMatched`; see `TransitionAutomation.frame`.
    ///
    /// Defaulted **off** on the struct rather than on the planner, so every
    /// hand-written style — `.plain`, the console's overrides, every fixture
    /// in the tests — keeps the symmetric curves it has always had, and only a
    /// plan the planner built with `dominantDeckBlend` on asks for the new law.
    var dominantDeck: Bool = false
    /// Where the incoming deck waits under the outgoing one before the swap,
    /// as a fader level. See `TransitionPlanner.Config.preSwapPlateau` for
    /// where the number comes from.
    var preSwapPlateau: Float = 0.85
    /// A technique that needs the outgoing track split into vocal and
    /// accompaniment stems. `nil` — the default, and everything the planner
    /// emits today — means the hand-over works on the whole mix, exactly as
    /// it always has. See `StemTechnique`.
    var stemTechnique: StemTechnique? = nil
    /// **How long the outgoing singer is still singing**, in seconds from the
    /// start of the overlap — the instant the outgoing vocal has finished
    /// leaving, i.e. the lyric line end L plus the hand-over cross.
    ///
    /// It exists because a `vocalExchange` splits the two clocks the hand-over
    /// runs on. The *floor* changes decks at the swap S; the *voice* does not
    /// leave until L, which a carryover puts past S. The outgoing vocal lane is
    /// fader-compensated at compile time, so the fader cannot take the voice
    /// down while it is still singing — but the staged EQ hand-over can, and
    /// did: it cuts the outgoing highs by 0.45·S and the mids by 0.85·S, both
    /// long before L, and the vocal lane is summed into the outgoing deck's
    /// source buffer *upstream* of that deck's EQ node (lanes → sum → player →
    /// timePitch → **eq** → delay → fader), so there is nothing the lane can do
    /// about it. The user's rule is that while the outgoing singer is singing
    /// the voice is never attenuated, so the two vocal-carrying stages are held
    /// until here; see `TransitionAutomation.applyEQHandover`.
    ///
    /// `nil` — the default, and every style that is not a compiled exchange —
    /// is today's behaviour byte-for-byte. Only the outgoing deck's high and
    /// mid stages read it; the low stage and the incoming mirror never do.
    var outgoingVocalHoldUntil: TimeInterval? = nil
    /// A **transition score**: a few typed events on the bar grid around the
    /// seam, to be compiled into audio by `ScoreCompiler` and performed by the
    /// pre-rendered segment path (`docs/automix-score-predev.md`).
    ///
    /// Mounted exactly like `stemTechnique`, and for the same reason: `nil` is
    /// the default and `nil` is everything today. A planner that does not write
    /// it leaves every decision, every curve and every rendered sample
    /// field-for-field what it was — the structural guarantee behind "the
    /// fall-back path is byte-identical to today", rather than a test's promise.
    ///
    /// The live path never performs one. Sample-accurate gestures need the
    /// segment renderer; a 20 ms automation tick cannot cut cleanly, and an
    /// approximated cut is worse than the blend it replaced (predev §1.2), so a
    /// segment that does not arm means the listener hears today's hand-over.
    var score: TransitionScore? = nil
    /// **What the seam was aimed at** (`TransitionAim`, predev §2.3). Written
    /// only alongside a `score`, and nil is again everything today.
    ///
    /// It is an *annotation*, not an instruction: the decision it records has
    /// already been made — the plan's `inPoint` was composed backwards from it,
    /// so a style stripped of this field still plays the aimed hand-over. What
    /// it buys is that the compiler can place the seam on the aim exactly
    /// rather than re-deriving it from the phrase grid, and that every report
    /// can say *what* the cut landed on rather than only where.
    var aim: TransitionAim? = nil
    /// Why `aim` is what it is — and, when it is nil, **why there was nothing
    /// to aim at**. One English sentence, carried rather than re-derived so the
    /// console, the panel and the seam history all print the same reason the
    /// planner actually acted on.
    ///
    /// Nil is "the aiming layer never ran", which is every unscored seam. A
    /// refusal is never silent: `aim=none (no structure)` is the interesting
    /// half of the A/B, and a bare `aim=none` reads as a missing feature.
    var aimDetail: String? = nil
    /// **What this hand-over was for** (`TransitionIntent`, P3, predev §2.4).
    ///
    /// An *annotation*, exactly like `aim`: by the time it is written the
    /// decision it records has already been taken — a `standDown` pair is
    /// already gapless, a `restrained` one already carries the short staged
    /// crossfade — so a style stripped of this field plays identically. What it
    /// buys is that the panel, the seam history, the journal and the feedback
    /// corpus can all say *which rule* produced the seam they are looking at,
    /// in the planner's own words, instead of guessing from the geometry.
    ///
    /// Nil is "the intent layer never ran", which is every shipped seam
    /// (`Config.intentEnabled` is false).
    var intent: TransitionIntent? = nil

    static let plain = TransitionStyle(outroEffect: .fade, stagedEQ: false)
}

/// Whether the caller can hand the renderer a vocal/accompaniment split of the
/// outgoing track's overlap window.
///
/// The planner takes this as an explicit input rather than sniffing for a
/// model, so it stays a pure function of its arguments — and so the product
/// path, which passes `.none` everywhere today, provably decides exactly what
/// it decided before stem techniques existed (`TransitionPlanner.plan`).
public enum StemAvailability: Sendable, Equatable {
    /// No separator. Every stem rule is skipped and every stem knob unread.
    case none
    /// A separator is available for this hand-over, so the planner may upgrade
    /// a transition to a `StemTechnique`.
    case ready
}

/// Techniques that only exist once the outgoing track can be split into a
/// vocal stem and its accompaniment (`mixture - vocals`).
///
/// These are *stem-layer* gestures: they rewrite what the outgoing deck is
/// fed, and everything downstream — the fader law, the EQ hand-over, the
/// outro effect — then runs unchanged on top. So `.vocalDuck` under
/// `.filterSweep` is a swept exit whose vocal sits 9 dB down, not a different
/// exit. Recipes and blind-test results: `docs/automix-stems-s1-report.md`.
///
/// `stagedStemSwap` (drums first, bass second) is deliberately absent: it
/// needs a 4-stem model, and StemKit ships a vocals/accompaniment one.
enum StemTechnique: Sendable, Equatable {
    /// The outgoing accompaniment drops out early and its vocal — high-passed,
    /// exempt from the outgoing fade — floats over the incoming full mix
    /// before retiring just before the cut.
    case acapellaOver
    /// The outgoing vocal is wiped at the top of the overlap, so the outgoing
    /// track leaves as an instrumental and the incoming vocal owns the window.
    case instrumentalOut
    /// The outgoing vocal is held `depthDB` down for the whole overlap, so two
    /// vocals stop fighting. S1's blind test liked −9 dB.
    case vocalDuck(depthDB: Float)

    /// **A request for the standard vocal hand-off, not a curve.**
    ///
    /// The planner can name this — it is a rule about two vocal-active windows —
    /// but it cannot *build* it: where the hand-over lands depends on where the
    /// outgoing singer finishes a line, and the planner is a pure function of
    /// two `TrackAnalysis` values with no idea what the words are. So this case
    /// is a marker that `Audition.decide` compiles into `.custom` once it can
    /// read the `.lrc` sidecar (`Audition.VocalExchange`), degrading to
    /// `.vocalDuck` — and saying so — when there is nothing to aim at.
    case vocalExchange
    /// A finished four-lane orchestration: an explicit gain curve per lane
    /// across the overlap. Everything above is a one-shot gesture; this is the
    /// general form, and what `vocalExchange` (and an AI's `stemEnvelope`)
    /// compile down to.
    case custom(StemEnvelope)

    /// Short name for reports and filenames.
    ///
    /// `.custom` carries a digest of its own curves, because the console names
    /// render files after this string: two different orchestrations of the same
    /// pair have to be two different files.
    var label: String {
        switch self {
        case .acapellaOver: return "acapellaOver"
        case .instrumentalOut: return "instrumentalOut"
        case .vocalDuck(let depth): return String(format: "vocalDuck(%.1fdB)", depth)
        case .vocalExchange: return "vocalExchange"
        case .custom(let envelope): return "custom(\(envelope.signature))"
        }
    }

    /// Whether this technique needs a stem split of the *incoming* track too.
    /// Only `.custom` ever can: every older gesture rewrites the outgoing deck
    /// alone, which is why the renderer used to separate one side.
    var needsIncomingStems: Bool {
        guard case .custom(let envelope) = self else { return false }
        return !envelope.isPassThrough(.incomingVocal) || !envelope.isPassThrough(.incomingBed)
            || envelope.hasIncomingBedSplit
    }
}

/// A four-lane gain orchestration across one overlap.
///
/// The older `StemTechnique` cases are single gestures: hold the outgoing vocal
/// 9 dB down, wipe it, float it. A long hand-over between two songs that are
/// both singing needs more than a gesture — it needs *scheduling*, so that at
/// every instant exactly one vocal is in front and the two accompaniments form
/// one continuous bed. That is four independent curves, and this is them.
///
/// **Semantics.** Each lane is a breakpoint list `(t, gainDB)` with `t` measured
/// in seconds from the start of the overlap. Between breakpoints the gain is
/// linear *in dB*; outside the first/last breakpoint it is clamped to that
/// endpoint's value. An **empty lane is pass-through (0 dB)**, not silence.
///
/// The gains are applied where `StemTechniqueLayer` already works: on the two
/// decks' *source buffers*, before a sample is pulled through the graph. So an
/// envelope stacks **on top of** the fader, EQ hand-over and outro effect the
/// automation is already writing — a lane at 0 dB is not "unity at the mixer",
/// it is "whatever the crossfade was going to do here, unchanged". A curve that
/// wants a lane to hold a constant *audible* level across a fade has to bake
/// the inverse of that fade into itself; `Audition.VocalExchange` does exactly
/// that, at compile time, where the fader law is known.
public struct StemEnvelope: Sendable, Codable, Equatable {

    public struct Breakpoint: Sendable, Codable, Equatable {
        /// Seconds from the start of the overlap.
        public var t: TimeInterval
        public var gainDB: Float

        public init(t: TimeInterval, gainDB: Float) {
            self.t = t
            self.gainDB = gainDB
        }
    }

    public enum Lane: String, Sendable, Codable, CaseIterable {
        case outgoingVocal, outgoingBed, incomingVocal, incomingBed

        /// The short spelling the AI reply and the console use.
        public var jsonKey: String {
            switch self {
            case .outgoingVocal: return "outVocal"
            case .outgoingBed: return "outBed"
            case .incomingVocal: return "inVocal"
            case .incomingBed: return "inBed"
            }
        }

        public var chineseLabel: String {
            switch self {
            case .outgoingVocal: return "出曲人声"
            case .outgoingBed: return "出曲伴奏"
            case .incomingVocal: return "入曲人声"
            case .incomingBed: return "入曲伴奏"
            }
        }

        public static func named(_ key: String) -> Lane? {
            allCases.first { $0.jsonKey == key || $0.rawValue == key }
        }
    }

    /// **The incoming bed, taken apart.**
    ///
    /// A bed lane says how loud "everything that is not the singer" is. That is
    /// the right vocabulary for a two-stem separator and the wrong one for a
    /// DJ: an accompaniment is not one instrument, and the three things inside
    /// it behave completely differently when you lay them over another record.
    /// Drums layer freely — two beat-matched kits reinforce. Bass does not:
    /// two basslines at once is the single worst-sounding layering error there
    /// is, and it is precisely why a hand-over has a bass-swap point at all.
    /// Harmony is the part that can clash in *key*, so it is the part you hold
    /// back until it is meant to arrive.
    ///
    /// These three curves are **multiplied into** the bed lane, so all-empty
    /// (the default, and every envelope written before this existed) is
    /// bit-identical to the undivided bed: `d·1 + b·1 + o·1 == bed`. Non-nil is
    /// what makes a segment ask for a four-lane separation instead of a
    /// two-lane one, and a machine with no four-stem checkpoint plays the
    /// undivided bed and says so rather than refusing the gesture.
    public struct BedSplit: Sendable, Codable, Equatable {
        public var drums: [Breakpoint]
        public var bass: [Breakpoint]
        public var other: [Breakpoint]

        public init(drums: [Breakpoint] = [], bass: [Breakpoint] = [],
                    other: [Breakpoint] = []) {
            self.drums = drums
            self.bass = bass
            self.other = other
        }

        public subscript(lane: StemLane) -> [Breakpoint] {
            switch lane {
            case .drums: return drums
            case .bass: return bass
            case .other: return other
            case .vocals: return []
            }
        }

        /// The three sub-lanes, in the order a report should read them.
        public static let lanes: [StemLane] = [.drums, .bass, .other]

        public var isPassThrough: Bool {
            Self.lanes.allSatisfy { self[$0].allSatisfy { $0.gainDB == 0 } }
        }

        /// Gain multiplier for one sub-lane at `t`, by the same interpolation
        /// rule as a top-level lane.
        public func gain(_ lane: StemLane, at t: TimeInterval) -> Float {
            let points = self[lane]
            guard let first = points.first, let last = points.last else { return 1 }
            let db: Float
            if t <= first.t { db = first.gainDB }
            else if t >= last.t { db = last.gainDB }
            else {
                var value = last.gainDB
                for i in 1..<points.count where points[i].t >= t {
                    let a = points[i - 1], b = points[i]
                    let span = b.t - a.t
                    value = span > 1e-9
                        ? a.gainDB + (b.gainDB - a.gainDB) * Float((t - a.t) / span)
                        : b.gainDB
                    break
                }
                db = value
            }
            return LoudnessCompensation.linearGain(db)
        }
    }

    public var outgoingVocal: [Breakpoint]
    public var outgoingBed: [Breakpoint]
    public var incomingVocal: [Breakpoint]
    public var incomingBed: [Breakpoint]
    /// Nil — the default and every envelope decoded from before this existed —
    /// means the incoming bed is one thing, which is what a two-stem separator
    /// can offer.
    public var incomingBedSplit: BedSplit?

    /// **This envelope's lanes carry fader compensation.**
    ///
    /// Set only by a compiler that knows the automation curve its lanes will be
    /// multiplied onto — today `Audition.VocalExchange` — and it buys exactly
    /// one thing: the lanes are validated against
    /// `maxCompensatedGainDB` instead of `maxGainDB`. It is not encoded,
    /// because it is a fact about who wrote the curve rather than part of the
    /// curve: an envelope that arrives as JSON was authored, by definition, and
    /// is held to the authored ceiling.
    public var compensated: Bool = false

    /// Below this the outgoing vocal lane is not carrying a voice any more —
    /// −20 dB under whatever the fade was going to do is inaudible against a
    /// dominant incoming deck, and every lane the exchange template writes
    /// either sits at (or above) its compensated plateau or drops to
    /// `exchangeDB`-deep silence, so the threshold has an order of magnitude of
    /// slack either side of it.
    public static let vocalHoldFloorDB: Float = -20

    /// **When the outgoing singer has finished**, in seconds from the start of
    /// the overlap — the last breakpoint at which the outgoing vocal lane is
    /// still asking for an audible voice.
    ///
    /// A pure read of the curve, and the fallback behind
    /// `TransitionStyle.outgoingVocalHoldUntil` for a `compensated` `.custom`
    /// envelope that did not come from the exchange compiler (a score's, an
    /// AI's): such a lane holds a voice up over a fade for exactly as long as
    /// the author meant the voice to be heard, and the staged EQ has to be told
    /// the same thing the fader compensation was told.
    ///
    /// Nil when the lane is empty, or is silent from the top of the overlap —
    /// both of which mean there is nothing to hold for.
    public var outgoingVocalHoldUntil: TimeInterval? {
        guard let last = outgoingVocal.last(where: { $0.gainDB >= Self.vocalHoldFloorDB }),
              last.t > 0
        else { return nil }
        return last.t
    }

    private enum CodingKeys: String, CodingKey {
        case outgoingVocal, outgoingBed, incomingVocal, incomingBed, incomingBedSplit
    }

    public init(outgoingVocal: [Breakpoint] = [], outgoingBed: [Breakpoint] = [],
                incomingVocal: [Breakpoint] = [], incomingBed: [Breakpoint] = [],
                compensated: Bool = false) {
        self.outgoingVocal = outgoingVocal
        self.outgoingBed = outgoingBed
        self.incomingVocal = incomingVocal
        self.incomingBed = incomingBed
        self.compensated = compensated
    }

    public subscript(lane: Lane) -> [Breakpoint] {
        get {
            switch lane {
            case .outgoingVocal: return outgoingVocal
            case .outgoingBed: return outgoingBed
            case .incomingVocal: return incomingVocal
            case .incomingBed: return incomingBed
            }
        }
        set {
            switch lane {
            case .outgoingVocal: outgoingVocal = newValue
            case .outgoingBed: outgoingBed = newValue
            case .incomingVocal: incomingVocal = newValue
            case .incomingBed: incomingBed = newValue
            }
        }
    }

    // MARK: - Limits

    /// −60 dB is inaudible under any bed; +6 dB is the most an *authored* lane
    /// may ask for. (`StemTechniqueLayer.acapellaGainCeiling` is not the same
    /// number wearing different units — it is a linear 6×, ≈ +15.6 dB, applied
    /// to a curve that has retired by 96 % of the overlap and so never reaches
    /// it. The old comment here claimed they were one ceiling; they never were.)
    public static let minGainDB: Float = -60
    public static let maxGainDB: Float = 6

    /// The ceiling for a lane that is **fade compensation** rather than a
    /// level choice.
    ///
    /// A hand-written envelope says "make the singer 4 dB louder", and 6 dB is
    /// the right bound on that: past it an author is no longer balancing, they
    /// are trying to fix a mix with a fader. A *compiled* lane can say
    /// something else entirely — "hold this voice exactly where it was while
    /// the deck it rides on is faded out from under it" — and that number is
    /// not a taste at all, it is `1/fader`, dictated by an automation curve the
    /// compiler can read. On a plain equal-power exit at the latest hand-over
    /// the template allows (0.85 of the overlap) the fader is −12.6 dB, so a
    /// 6 dB ceiling clips the last third of the carried line and the singer
    /// audibly recedes mid-phrase — the one artefact `vocalExchange` exists to
    /// remove.
    ///
    /// 40 dB is chosen as "past any fader a hand-over will ever reach": it
    /// covers a fader down to 0.01, and `Audition.VocalExchange` guards the
    /// division below that so the number can never run away. It applies only to
    /// an envelope marked `compensated`; everything an author or an AI writes
    /// is still judged against `maxGainDB`.
    public static let maxCompensatedGainDB: Float = 40
    /// A curve, not a sample-accurate automation track. Sixteen points is more
    /// than the templates need and few enough that a hand-written one stays
    /// readable in a JSON reply.
    public static let maxBreakpoints = 16

    // MARK: - Reading

    /// A lane with nothing in it, or nothing but 0 dB, changes no audio — so
    /// the renderer can skip separating that whole side.
    public func isPassThrough(_ lane: Lane) -> Bool {
        self[lane].allSatisfy { $0.gainDB == 0 }
    }

    public var isPassThrough: Bool {
        Lane.allCases.allSatisfy(isPassThrough) && (incomingBedSplit?.isPassThrough ?? true)
    }

    /// The incoming bed is orchestrated as three lanes rather than one, so this
    /// envelope wants a four-lane separation of the incoming deck.
    public var hasIncomingBedSplit: Bool {
        guard let split = incomingBedSplit else { return false }
        return !split.isPassThrough
    }

    /// Gain in dB at `t`, linearly interpolated, clamped to the endpoints
    /// outside the breakpoint range. 0 dB for an empty lane.
    public func gainDB(_ lane: Lane, at t: TimeInterval) -> Float {
        let points = self[lane]
        guard let first = points.first, let last = points.last else { return 0 }
        if t <= first.t { return first.gainDB }
        if t >= last.t { return last.gainDB }
        for i in 1..<points.count where points[i].t >= t {
            let a = points[i - 1], b = points[i]
            let span = b.t - a.t
            guard span > 1e-9 else { return b.gainDB }
            let u = Float((t - a.t) / span)
            return a.gainDB + (b.gainDB - a.gainDB) * u
        }
        return last.gainDB
    }

    /// The same value as a linear amplitude multiplier.
    public func gain(_ lane: Lane, at t: TimeInterval) -> Float {
        LoudnessCompensation.linearGain(gainDB(lane, at: t))
    }

    /// A short stable digest of every breakpoint, for render filenames and
    /// report labels. See `fnv1a` for why it is not `Hashable`'s seeded hash.
    public var signature: String {
        var hash = fnv1aOffsetBasis
        for lane in Lane.allCases {
            for point in self[lane] {
                for value in [point.t, Double(point.gainDB)] {
                    let bits = UInt64(bitPattern: Int64((value * 1000).rounded()))
                    hash = fnv1a(littleEndian: bits, from: hash)
                }
            }
            hash = fnv1a(0xff, from: hash)
        }
        // Folded in only when it changes audio, so every envelope written
        // before the bed could be split — and every one whose split is
        // pass-through, which renders identically — keeps the signature, and
        // therefore the render filename, it already had.
        if hasIncomingBedSplit, let split = incomingBedSplit {
            for lane in BedSplit.lanes {
                for point in split[lane] {
                    for value in [point.t, Double(point.gainDB)] {
                        let bits = UInt64(bitPattern: Int64((value * 1000).rounded()))
                        hash = fnv1a(littleEndian: bits, from: hash)
                    }
                }
                hash = fnv1a(0xfe, from: hash)
            }
        }
        return String(format: "%08x", UInt32(truncatingIfNeeded: hash))
    }

    // MARK: - Validation

    public enum ValidationFailure: LocalizedError, Equatable {
        case tooManyBreakpoints(lane: String, count: Int)
        case timeOutOfRange(lane: String, t: TimeInterval, overlap: TimeInterval)
        case timeNotMonotonic(lane: String, previous: TimeInterval, t: TimeInterval)
        case gainOutOfRange(lane: String, gainDB: Float)
        case notFinite(lane: String)

        public var errorDescription: String? {
            switch self {
            case .tooManyBreakpoints(let lane, let count):
                return "stemEnvelope.\(lane) 有 \(count) 个点，超过 "
                    + "\(StemEnvelope.maxBreakpoints) 个的上限。"
            case .timeOutOfRange(let lane, let t, let overlap):
                return String(format: "stemEnvelope.%@ 里的时间 %.2f 秒不在 0–%.2f 秒"
                              + "（这次叠加的长度）之内。", lane, t, overlap)
            case .timeNotMonotonic(let lane, let previous, let t):
                return String(format: "stemEnvelope.%@ 的时间必须递增：%.2f 之后又出现了 %.2f。",
                              lane, previous, t)
            case .gainOutOfRange(let lane, let gainDB):
                return String(format: "stemEnvelope.%@ 里的增益 %.1f dB 超出 %.0f–%.0f dB 的范围。",
                              lane, gainDB, StemEnvelope.minGainDB, StemEnvelope.maxGainDB)
            case .notFinite(let lane):
                return "stemEnvelope.\(lane) 里有不是有限数字的取值。"
            }
        }
    }

    /// Check one lane against the contract: monotonic times inside
    /// `[0, overlap]`, gains inside `[minGainDB, ceilingDB]`, at most
    /// `maxBreakpoints` of them.
    ///
    /// `ceilingDB` defaults to the authored ceiling, so every existing caller —
    /// the AI reply parser above all — keeps judging 6 dB the way it always
    /// did. A compiled, `compensated` envelope passes the wider one.
    public static func validate(_ points: [Breakpoint], lane: String,
                                overlap: TimeInterval,
                                ceilingDB: Float = maxGainDB) throws {
        guard points.count <= maxBreakpoints else {
            throw ValidationFailure.tooManyBreakpoints(lane: lane, count: points.count)
        }
        var previous: TimeInterval?
        for point in points {
            guard point.t.isFinite, point.gainDB.isFinite else {
                throw ValidationFailure.notFinite(lane: lane)
            }
            // A hair of slack so a curve generated at the overlap's exact end
            // is not rejected by a rounding error in the caller's arithmetic.
            guard point.t >= -1e-6, point.t <= overlap + 1e-6 else {
                throw ValidationFailure.timeOutOfRange(lane: lane, t: point.t, overlap: overlap)
            }
            guard point.gainDB >= minGainDB - 1e-4, point.gainDB <= ceilingDB + 1e-4 else {
                throw ValidationFailure.gainOutOfRange(lane: lane, gainDB: point.gainDB)
            }
            if let previous, point.t < previous - 1e-6 {
                throw ValidationFailure.timeNotMonotonic(lane: lane, previous: previous, t: point.t)
            }
            previous = point.t
        }
    }

    /// The same check across all four lanes, against whichever ceiling this
    /// envelope's provenance earns it.
    public func validate(overlap: TimeInterval) throws {
        let ceiling = compensated ? Self.maxCompensatedGainDB : Self.maxGainDB
        for lane in Lane.allCases {
            try Self.validate(self[lane], lane: lane.jsonKey, overlap: overlap,
                              ceilingDB: ceiling)
        }
        if let split = incomingBedSplit {
            // Sub-lanes are multipliers *into* the bed, never compensation, so
            // they keep the authored ceiling whatever the envelope is.
            for lane in BedSplit.lanes {
                try Self.validate(split[lane], lane: "inBed." + lane.rawValue, overlap: overlap)
            }
        }
    }

    /// The loudest breakpoint in any top-level lane, or 0 for an empty
    /// envelope — what a plot has to be tall enough to show.
    public var peakGainDB: Float {
        Lane.allCases.reduce(Float(0)) { peak, lane in
            self[lane].reduce(peak) { Swift.max($0, $1.gainDB) }
        }
    }
}

/// What the strategy layer hands the engine: mechanics plus chosen styling.
struct PlannedTransition: Sendable {
    let plan: TransitionPlan
    let style: TransitionStyle
    /// **Transition gain ride**, in dB, for the *incoming* deck: held for the
    /// whole overlap and then released back to unity at
    /// `TransitionAutomation.rideReleaseDBPerSecond`. Negative holds the
    /// incoming track down, positive lifts it; see `TransitionPlanner.rideDB`
    /// for how it is derived and why only one deck rides.
    ///
    /// It lives here rather than in `TransitionPlan` (pure mechanics: when and
    /// how long) or `TransitionStyle` (how the hand-over *sounds*) because it
    /// is neither — it is a gain decision about one deck, of a piece with the
    /// load-time trim the engine already carries. Defaulted to 0 so
    /// `PlannedTransition(plan:style:)` and `.plain` keep every existing
    /// caller, and the whole gain path, bit-identical.
    var rideDB: Double = 0

    static func plain(_ plan: TransitionPlan) -> PlannedTransition {
        PlannedTransition(plan: plan, style: .plain)
    }
}

/// How to hand over from the current track to the next (spec §5).
enum TransitionPlan: Sendable {
    case beatMatched(BeatMatchedPlan)
    case crossfade(duration: TimeInterval, outPoint: TimeInterval, inPoint: TimeInterval)
    /// Tail-to-head, no overlap.
    case gapless
}

struct BeatMatchedPlan: Sendable {
    /// Phrase boundary in the outgoing track where the overlap starts.
    let outPoint: TimeInterval
    /// First downbeat of the incoming track to align to `outPoint`.
    let inPoint: TimeInterval
    let overlapBars: Int
    /// Playback-rate nudges so the grids line up; the incoming deck is let
    /// back to 1.0 after the overlap. How far each may bend is the planner's
    /// `maxRateDeviation` (step) or `rampMaxRateDeviation` (glide).
    let outgoingRate: Float
    let incomingRate: Float
    /// Seconds into the overlap where the low end swaps decks.
    let bassSwapOffset: TimeInterval
    /// Total overlap length in seconds at the blended tempo.
    let overlapDuration: TimeInterval

    // --- Tempo ramp (`TransitionPlanner.Config.tempoRampEnabled`). Both are 0
    // on a plan made with the ramp off, and 0 is what every path reads as "the
    // old step behaviour" — so a plan built before these fields existed, or by
    // a config with the knob down, decides and sounds exactly as it did.

    /// Seconds of the **outgoing track's own timeline** over which its deck
    /// glides 1.0 → `outgoingRate` before the seam. The glide is anchored so
    /// that it *finishes* one `TransitionAutomation.segmentHandoff` before
    /// `outPoint`; see `TransitionAutomation.tempoRamp`.
    var rampLeadSeconds: TimeInterval = 0
    /// Seconds over which the incoming deck is let back from `incomingRate` to
    /// 1.0 once it is the only thing audible. 0 → the legacy
    /// `TransitionAutomation.rateRestoreDuration`. Under
    /// `rampGlideBackFromSwap` this is only a *floor* on the glide's length,
    /// which normally runs longer; see `TransitionAutomation.incomingGlide`.
    var rampReleaseSeconds: TimeInterval = 0
    /// Whether the incoming deck starts walking back to unity **at the bass
    /// swap** rather than after the overlap — moving the phase-vocoder artifact
    /// off the deck that is about to be alone and onto the stretch where the
    /// outgoing track still masks it. False, the default, is the old
    /// hold-then-release and is what every plan built before the glide existed
    /// reads as. See `TransitionAutomation.incomingGlide`.
    var rampGlideBackFromSwap: Bool = false

    /// The same hand-over, entered at a different point of the **incoming**
    /// track — the one thing the aiming layer (predev §2.3) changes about a
    /// plan.
    ///
    /// Field-for-field a copy but for `inPoint`, deliberately written out
    /// rather than made a `var`: the plan is what the armed-plan comparison and
    /// the segment signature are keyed on, and every other field staying put is
    /// the promise that aiming moved the entry and nothing else. The out point,
    /// the bar count, both rates and the whole ramp are the outgoing track's
    /// and the gates' business, and aiming has no vote on any of them.
    func enteringIncoming(at inPoint: TimeInterval) -> BeatMatchedPlan {
        var moved = BeatMatchedPlan(
            outPoint: outPoint, inPoint: inPoint, overlapBars: overlapBars,
            outgoingRate: outgoingRate, incomingRate: incomingRate,
            bassSwapOffset: bassSwapOffset, overlapDuration: overlapDuration)
        moved.rampLeadSeconds = rampLeadSeconds
        moved.rampReleaseSeconds = rampReleaseSeconds
        moved.rampGlideBackFromSwap = rampGlideBackFromSwap
        return moved
    }
}

extension TransitionPlan {
    /// Seconds before the outgoing track's out point at which the incoming
    /// deck must already be loaded and scheduled.
    var outPoint: TimeInterval? {
        switch self {
        case .beatMatched(let plan): return plan.outPoint
        case .crossfade(_, let outPoint, _): return outPoint
        case .gapless: return nil
        }
    }
}
#endif
