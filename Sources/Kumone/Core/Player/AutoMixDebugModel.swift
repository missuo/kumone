#if os(macOS)
import Foundation

// Live read-out of the AutoMix pipeline, for the person running listening
// tests: what is armed, what the analyses say, what the pre-render is doing,
// and what the engine actually played at the last few seams — the things that
// otherwise only exist as log lines nobody reads while listening.
//
// The model is a mirror, never a source: PlayerService pushes small structs at
// the state-change points it already runs through, and nothing here ever reads
// back into the player or the engine. That is what keeps the panel free when
// it is closed (`isActive` is false, so a push writes one struct and stops)
// and what keeps it honest when it is open — every number shown is a number
// the player itself acted on.
//
// The view is macOS-only; the model is not, so PlayerService can push
// unconditionally instead of carrying `#if os(macOS)` at a dozen call sites.
// On iOS every plan is `.gapless` and nothing ever activates it, so the whole
// thing costs a Bool test per push.

/// One deck's rate and gain stages, as the panel prints them.
///
/// Both decks are shown, always. The watery-playback family of bugs is exactly
/// "a deck left off unity rate with nothing running", and it is invisible in a
/// read-out that only shows the deck currently carrying the song — the leak is
/// as often on the *other* one, waiting to be reused.
struct AutoMixDebugDeck: Equatable {
    var role = "idle"
    var rate: Float = 1
    var trimDB: Double = 0
    var rideDB: Double = 0
    var ratePadDB: Double = 0
    var inTransition = false

    /// A bent rate with no transition to explain it. This is the read-out the
    /// panel colours red: it is the bug, not a symptom of it.
    var rateIsSuspect: Bool { abs(rate - 1) > 0.001 && !inTransition }
}

/// The "Now" group: what is audible this instant.
struct AutoMixDebugNow: Equatable {
    var title: String?
    /// A player-level phase, not the engine's own `TransitionPhase` (which is
    /// private to the audio queue): idle / buffering / playing / paused, plus
    /// what the hand-over pipeline has reached.
    var phase = "idle"
    var deck = "—"
    var position: TimeInterval = 0
    var duration: TimeInterval = 0
    /// Loudness-compensation trim the current deck was loaded at.
    var trimDB: Double = 0
    /// The playing track has a full analysis in hand (so a real plan is possible).
    var analyzed = false
    /// Both decks as the engine has them this instant, read in one hop.
    var deckA = AutoMixDebugDeck()
    var deckB = AutoMixDebugDeck()
}

/// How far the prefetch pipeline has got with the auto-advance target.
enum AutoMixPrefetchStage: Equatable {
    case idle
    case resolving
    case downloading
    case downloaded
    case analyzing
    case analyzed
    /// The pipeline chose not to run — not an error, and not a state a retry
    /// would help (the same track is still streaming into the cache).
    case deferred(String)
    case failed(String)

    var label: String {
        switch self {
        case .idle: return "idle"
        case .resolving: return "resolving"
        case .downloading: return "downloading"
        case .downloaded: return "downloaded"
        case .analyzing: return "analyzing"
        case .analyzed: return "analyzed"
        case .deferred(let why): return "deferred — \(why)"
        case .failed(let reason): return "failed — \(reason)"
        }
    }
}

/// The "Next (prefetch)" group.
struct AutoMixDebugNext: Equatable {
    var title: String?
    var stage: AutoMixPrefetchStage = .idle
    var bpm: Double?
    var bpmConfidence: Double?
    /// Pre-formatted, because a pitch class plus a minor flag plus a confidence
    /// is three fields the panel would only ever print as one string.
    var key: String?
    var lufs: Double?
    var sectionCount: Int?
    var structureConfidence: Double?
    /// A `.lrc` sits next to the cached file — i.e. a `vocalExchange` has words
    /// to aim at when this track becomes the *outgoing* side, one seam later.
    var hasLyricSidecar = false
}

/// The "Plan (armed)" group: the hand-over PlayerService has handed the engine.
///
/// Everything here is derived from a `PlannedTransition` plus the two analyses
/// it was planned from — a pure mapping, so it can be built and asserted on
/// without a player.
struct AutoMixDebugPlan: Equatable {
    var kind = "gapless"
    var outPoint: TimeInterval?
    var inPoint: TimeInterval?
    var overlap: TimeInterval = 0
    var overlapBars: Int?
    var outgoingRate: Float?
    var incomingRate: Float?
    var outroEffect = "fade"
    var stagedEQ = false
    var stemTechnique: String?
    /// The transition score the plan carries, named the way the predev names
    /// it ("cutOnOne+echoThrow"). Nil on every shipped seam — a score only
    /// appears with the panel's own toggle on.
    var score: String?
    /// **What the seam was aimed at** (P2, predev §2.3) — `drop@84.00s`, or
    /// `aim=none` with the reason. Nil whenever the plan carries no score,
    /// because aiming only runs under one.
    var aim: String?
    /// **What this hand-over was for** (P3, predev §2.4) — the intent class and
    /// the sentences that chose it. Nil whenever the intent layer did not run,
    /// which is every shipped seam.
    var intent: String?
    /// Just the class, for a badge and for bucketing feedback lines later.
    var intentClass: String?
    var rideDB: Double = 0
    /// Which structural section the out point falls in, when the outgoing
    /// analysis has sections at all (it usually does not — see `TrackAnalysis`).
    var outSection: String?
    /// Where the in point looks like it came from, read back off the incoming
    /// analysis. The planner does not record its reasoning, so this is a
    /// best-effort match against the landmarks it chooses between.
    var inPointSource: String?
}

/// One row of the queue-order candidate table: a track the selector scored,
/// with the score broken into the terms that produced it.
///
/// A bare total is not reviewable — "why did it pick that one" is answered by
/// seeing which term carried the decision, and whether the tier or the aging
/// did it.
struct AutoMixDebugCandidate: Identifiable, Equatable {
    /// The track ID: stable across ticks, so SwiftUI keeps rows in place while
    /// the scores move under them.
    let id: Int
    var title: String
    var tier: String
    var tempo: Double
    var key: Double
    var style: Double
    var energy: Double
    var aging: Double
    var samePenalty: Double
    /// How much of the pool this candidate would leave reachable, in `[0, 1]`.
    /// 0 when the future term is off — and 0 for every candidate outside the
    /// top `futureTopK`, which are never evaluated.
    var future: Double
    var total: Double
    /// The one the selector took (or would take right now, while it is still
    /// choosing).
    var chosen: Bool
}

/// The "Queue order" group: what the AutoMix order is choosing between.
struct AutoMixDebugOrder: Equatable {
    /// listed / shuffled / autoMix.
    var mode = "listed"
    /// "choosing", "decided", or why neither applies.
    var state = "off"
    /// How many tracks are still ahead in the queue, and how many of them the
    /// selector can already score for free.
    var poolSize = 0
    var analyzed = 0
    /// What this pick's escalation has cost so far: rounds opened and
    /// low-bitrate downloads started, against the per-pick budget (predev
    /// §2.2).
    var rounds = 0
    var downloads = 0
    var downloadBudget = 0
    /// The provisional chain past the decided next: "title — tier", in play
    /// order. **Nothing here is committed** — each of those picks is still made
    /// fresh at its own decision point.
    var lookahead: [String] = []
    /// Playback position by which the pick is made regardless.
    var deadline: TimeInterval?
    /// Best first.
    var candidates: [AutoMixDebugCandidate] = []
}

/// The stem pre-render's own little state machine, mirrored from
/// `PlayerService.updateStemPrerender`.
enum AutoMixPrerenderState: Equatable {
    case idle
    /// A hand-over is armed and there is simply nothing to pre-render for it:
    /// the plan carries neither a stem technique nor a score. Told apart from
    /// `.idle` (nothing armed at all) because the two answer different
    /// questions, and because this is the state a refused score leaves behind —
    /// a seam that will play today's blend, which is not a failure of anything.
    case notNeeded
    /// Separation + render running for this seam. The renderer is one call, so
    /// "separating" and "rendering" are not told apart here.
    case rendering(String)
    /// Finished and accepted by the engine: this seam will be spliced.
    case armed(String)
    /// Started and dropped before it could be used.
    case abandoned(String)
    /// Finished, but the engine would not take it.
    case refused(String)

    var label: String {
        switch self {
        case .idle: return "idle"
        case .notNeeded: return "nothing to pre-render"
        case .rendering(let s): return "rendering — \(s)"
        case .armed(let s): return "armed — \(s)"
        case .abandoned(let reason): return "abandoned — \(reason)"
        case .refused(let reason): return "refused — \(reason)"
        }
    }
}

/// One finished seam, frozen the moment it became audible.
struct AutoMixDebugSeam: Identifiable, Equatable {
    let id = UUID()
    var at = Date()
    var from: String?
    var to: String?
    /// The two tracks themselves, so the seam can be queued up and heard
    /// again. Both were cached files by the time this seam played, so a replay
    /// is a queue rebuild and a seek, not a download.
    var outgoingTrack: Track?
    var incomingTrack: Track?
    /// The stem gesture the plan asked for, kept out of `planned` because a
    /// feedback line is mostly a question about the gesture.
    var gesture: String?
    /// The debug overrides that were on when this seam played. A forced plan
    /// is not an organic one and a mark on it must never look like one.
    var overrides: [String] = []
    /// Fingerprint of the effective planner config, so two marks made weeks
    /// apart can be told apart by calibration.
    var configFingerprint: String = ""
    /// The plan PlayerService armed — possibly not the one that ran.
    var planned: AutoMixDebugPlan?
    /// splicedSegment / liveOverlap / gapless.
    var path: String
    /// The plan the engine actually executed.
    var executedKind: String
    var executedOutPoint: TimeInterval?
    var executedOverlap: TimeInterval
    /// Non-nil when the two differ — the engine could not reach the armed out
    /// point and anchored something shorter at the end of the track instead.
    var fallback: String?
    /// What the pre-render had come to by the time the seam played.
    var prerender: String
}

/// Every debug override at once.
///
/// All-false is the shipped player, exactly: `AutoMixDebugOverrides` returns
/// the config it was handed and the pre-render runs as it always has. The
/// three feature switches are spelled as *disables* rather than as the knobs
/// they shadow, so "default off" and "byte-identical" are the same statement —
/// a switch that defaulted to the config's own `true` would have to be kept in
/// sync with it forever.
struct AutoMixOverrides: Equatable, Codable {
    var forceBeatMatch = false
    var disableTempoRamp = false
    var disableDominantDeckBlend = false
    var disableTwoClockExchange = false
    /// **Transition score (P1)**, and the one switch here spelled as an
    /// *enable*: the feature ships dark (`Config.scoreEnabled` is false), so
    /// "off" is already the config's own value and there is nothing to shadow.
    /// On, a qualifying seam is offered a cut-on-one — performed only if the
    /// pre-rendered segment arms, because the live path never approximates one.
    var enableScore = false
    /// **Intent layer (P3)** — material semantics decide which transition
    /// family a pair is even offered (rock → restraint, club → cut culture,
    /// default → blend). Off, an enabled score falls back to P1's raw rule —
    /// "any hard grid gets a cut" — which is exactly the combination the
    /// listening owner called 莫名其妙: gestures without the layer that gives
    /// them meaning. False here so the neutral struct still mirrors
    /// `Config.standard` (the invariant every override test pins); the
    /// listening machine gets it turned on by `restoredOverrides`'s fresh
    /// defaults, exactly like `enableScore`.
    var enableIntent = false
    /// **Verbose engine trace** — also not a planner knob, and the only switch
    /// here that changes nothing about what is played. On, the engine records
    /// every fader/rate/transport write into a ring, runs a stall watchdog, and
    /// judges two behavioural sentinels; each finished seam (and each alarm)
    /// spills the ring into `Application Support/Kumone/seamtraces`.
    ///
    /// False in the struct, like every other flag, so `AutoMixOverrides()` still
    /// mirrors `Config.standard` byte for byte — and true on the listening
    /// machine's fresh defaults, exactly like the score and the intent layer,
    /// because the bugs it exists to catch are the ones being hunted there.
    var verboseEngineTrace = false
    /// **Body level** — trim every track to −11 LUFS instead of −14.
    ///
    /// The half of the "everything sounds like it is underwater" fix that acts
    /// on the *song*: the shipped −14 target cut 142 of 157 tracks in the
    /// listening machine's cache by more than 3 dB (mean −4.94 dB), which is
    /// pure attenuation the ear reads as dullness. See
    /// `TransitionPlanner.Config.loudnessTargetLUFS` for the corpus table and
    /// why the target was raised rather than the curve compressed.
    ///
    /// False here so `AutoMixOverrides()` still mirrors `Config.standard`; true
    /// on the listening machine's fresh defaults, like the score and the intent
    /// layer. Note that flipping it moves the trim of the *next* track loaded:
    /// the trim is a load-time argument to the deck (deliberately — see
    /// `LoudnessCompensation`), so the song already playing keeps its own.
    var enableBodyLevel = false
    /// **Seam level** — the other half of the same complaint, one scale down:
    /// hold the transition gain ride to +1 dB up / −2 dB down instead of ±4, so
    /// a hand-over is never audibly louder than the bodies either side of it
    /// and a song never *opens* more than 2 dB under its own level. See
    /// `AutoMixDebugOverrides.seamRideMaxDB` for where the two numbers come
    /// from, and `TransitionPlanner.rideDB` for what the ride is.
    ///
    /// Independent of `enableBodyLevel` on purpose: they fix the same
    /// perception at two different time scales (the whole song, and the ten
    /// seconds around a seam), and an A/B that could not separate them could
    /// not say which one the listener was hearing.
    var enableSeamLevel = false
    /// **Master limiter** — a −1 dBFS peak limiter on the master path
    /// (`DeckChain.makeMasterLimiter`), and with it the retirement of the
    /// bent-rate headroom pad (`LoudnessCompensation.timePitchPadDB`).
    ///
    /// One switch for both halves because they are one decision: the pad exists
    /// only because nothing downstream could catch the time-pitch unit's
    /// overshoot, and the limiter is that something. Keeping them separable
    /// would offer two settings nobody wants — an unpadded deck with no limiter
    /// (which clips) and a padded deck behind a limiter (which pays twice, and
    /// is what "the song dies before the transition" sounds like).
    ///
    /// False here so `AutoMixOverrides()` still mirrors `Config.standard` and
    /// the pad player survives byte-identical for the A/B; true on the
    /// listening machine's fresh defaults, like the level pair — same
    /// complaint, same reasoning about which regime should be the one you have
    /// to *ask* for.
    var enableMasterLimiter = false
    /// Not a planner knob: skips the stem pre-render entirely so the seam is
    /// carried by the live two-deck path — which is the *approximation* of a
    /// stem hand-over, and the thing an A/B wants to compare against.
    var forceLivePath = false
    /// **Pin the splice head's latency compensation**, in milliseconds — the
    /// one override here that is a number rather than a switch, because the
    /// thing it shadows is a number the engine measures for itself.
    ///
    /// A spliced hand-over releases its pre-rendered segment this much *after*
    /// the outgoing deck's player clock reaches the splice, to cancel the live
    /// deck's engaged time-pitch latency (see `SeamLatencyCalibration`). Left
    /// nil — the shipped state — the engine uses its own running estimate,
    /// re-measured from the output tap at every seam. Set, it uses this and
    /// stops listening to itself, which is what an A/B of two compensations
    /// needs: a calibration that drifts under the comparison is not a control.
    ///
    /// Nil in the struct, like every flag is false, so `AutoMixOverrides()`
    /// still means "the shipped player" exactly.
    var headLatencyCompensationMS: Double?

    var isActive: Bool { self != AutoMixOverrides() }

    /// Short names for the panel's badges and for a feedback line.
    var badges: [String] {
        var names: [String] = []
        if forceBeatMatch { names.append("forceBeatMatch") }
        if disableTempoRamp { names.append("noTempoRamp") }
        if disableDominantDeckBlend { names.append("noDominantDeck") }
        if disableTwoClockExchange { names.append("noTwoClock") }
        if enableScore { names.append("score") }
        if enableIntent { names.append("intent") }
        if verboseEngineTrace { names.append("trace") }
        if enableBodyLevel { names.append("bodyLevel") }
        if enableSeamLevel { names.append("seamLevel") }
        if enableMasterLimiter { names.append("limiter") }
        if forceLivePath { names.append("forceLivePath") }
        if let pin = headLatencyCompensationMS {
            names.append(String(format: "headLatency=%.0fms", pin))
        }
        return names
    }

    /// Whether the change from `self` to `other` invalidates a pre-rendered
    /// segment the engine may already be holding. Turning the live path on is
    /// the whole point of that switch, and the engine has no un-arm call — so
    /// this asks for the heavier re-arm instead of a plain re-plan.
    /// The score is in here for a subtler reason: it does not move the *plan*
    /// at all (that is the point — a score decorates the style, so the fall-back
    /// is a complete blend), which means a segment rendered a moment ago still
    /// matches by signature and would keep playing the version the toggle just
    /// turned off. An A/B that plays the old take is worse than no A/B.
    /// `verboseEngineTrace` is deliberately absent: it is pure observation and
    /// moves nothing about the plan, so tearing a seam down to re-arm it would
    /// be a cut of audio for no gain — and, worse, would change the very
    /// behaviour the recorder was just switched on to watch.
    /// `enableBodyLevel` is in here for the same reason the score is: it does
    /// not move the *plan* — the trims are gain, not geometry, so a segment
    /// rendered a moment ago still matches by signature — but they are baked
    /// into the rendered audio (`OfflineTransitionRenderer.Options`), and an
    /// A/B that plays a segment mixed at the old target is not an A/B.
    /// `enableMasterLimiter` is in here for the third time for that same
    /// reason, and the most literally: the bent-rate pad it retires is *baked
    /// into* a rendered segment (`OfflineTransitionRenderer.Options`), sized
    /// and glided at render time. A segment rendered under the pad regime and
    /// played under the limiter one carries a duck the deck around it does not,
    /// which is not an A/B of anything.
    func needsReArm(comparedTo other: AutoMixOverrides) -> Bool {
        forceLivePath != other.forceLivePath || enableScore != other.enableScore
            || enableIntent != other.enableIntent
            || enableBodyLevel != other.enableBodyLevel
            || enableSeamLevel != other.enableSeamLevel
            || enableMasterLimiter != other.enableMasterLimiter
    }
}

struct AutoMixDebugSnapshot: Equatable {
    var now = AutoMixDebugNow()
    var next = AutoMixDebugNext()
    var plan: AutoMixDebugPlan?
    var order = AutoMixDebugOrder()
    /// **Why the armed plan carries no score**, in the compiler's own words.
    ///
    /// Its own field, and read by its own row in the Plan group, because a
    /// refusal is a *planning* verdict: the compiler was asked at arming time
    /// and said no, so the seam plays today's blend and no render was ever
    /// spawned. Parked in the pre-render's state row — where it used to go — it
    /// read as "the pre-render failed", which named neither the layer nor the
    /// outcome. Nil whenever the score compiled, and on every shipped seam.
    var scoreRefusal: String?
    var prerender = AutoMixPrerenderState.idle
    /// How well the last splice's two identity crossfades actually lined up,
    /// and what the engine is compensating the head by. See `SeamAlignment`.
    var seamLatency = SeamLatencyStore.Report()
    /// Newest first; the last three seams.
    var seams: [AutoMixDebugSeam] = []
    /// Why the force override did not get a beat-matched plan out of this pair,
    /// when it was asked to. Nil while the override is off, and nil when it
    /// worked — the badge says the rest.
    var forceNote: String?
}

extension AutoMixDebugSnapshot {
    /// **What the Plan group's `score` row prints**, in one place because it is
    /// the one row with three states and no view has any business deciding
    /// between them.
    ///
    /// The refusal wins when there is one: a plan whose score was stripped at
    /// arming time carries `score == nil`, so without this the row would print
    /// "none — today's blend" and swallow the reason it is a blend.
    var scoreRow: String {
        if let refusal = scoreRefusal { return "refused: \(refusal)" }
        if let score = plan?.score { return "score=\(score)" }
        return "none — today's blend"
    }
}

@MainActor
final class AutoMixDebugModel: ObservableObject {
    static let shared = AutoMixDebugModel()

    /// How many finished seams the panel keeps.
    static let seamHistoryLimit = 3

    /// The panel window is open. False is the normal case, and then every
    /// recorder below writes `live` and returns without touching the published
    /// snapshot — no observable change, so SwiftUI schedules nothing for a
    /// window nobody has opened, and no timer exists to stop.
    private(set) var isActive = false

    /// What the panel draws.
    @Published private(set) var snapshot = AutoMixDebugSnapshot()

    /// The copy the recorders write. Kept up to date even while closed, so
    /// opening the window shows the truth immediately rather than blank fields
    /// waiting for the next state change.
    private var live = AutoMixDebugSnapshot()

    /// The pre-render state as the panel prints it, readable whether or not the
    /// window is open — the seam recorder freezes it into its history row, and
    /// history has to be right even for seams heard before the panel opened.
    var currentPrerenderLabel: String { live.prerender.label }

    /// Test hook: the history as recorded, without opening a window to publish it.
    var currentSeamsForTesting: [AutoMixDebugSeam] { live.seams }

    // MARK: - Debug overrides

    /// **Force beat switch**: plan every following seam as if the pair had
    /// cleared the admission gates, so a listening test can hear a beat match
    /// on demand instead of hunting the library for a pair that passes.
    ///
    /// Published because these are controls, not mirrors — flipping one must
    /// move its checkbox and its badge.
    ///
    /// **Persisted across launches** (a reversal of the original design, at the
    /// listening owner's request 2026-08-31: a week of package swaps kept
    /// silently resetting the score toggle, and hours of listening were spent
    /// on a configuration nobody had chosen). The original worry — an override
    /// surviving a relaunch being mistaken for an organic result — is covered
    /// by the badges: every seam mark and every panel row names the overrides
    /// that were live when it was made.
    @Published private(set) var overrides = AutoMixDebugModel.restoredOverrides()

    private static let overridesKey = "automix.debug.overrides"

    private static func restoredOverrides() -> AutoMixOverrides {
        #if DEBUG
        guard let data = UserDefaults.standard.data(forKey: overridesKey),
              let stored = try? JSONDecoder().decode(AutoMixOverrides.self, from: data)
        else {
            // First run (nothing stored): the listening machine wants the
            // score path audible by default — that is what the panel exists
            // to evaluate. Everything else starts off, as always.
            var fresh = AutoMixOverrides()
            fresh.enableScore = true
            fresh.enableIntent = true
            // Nothing about playback changes; what changes is whether the next
            // "the deck went quiet" report can be answered at all.
            fresh.verboseEngineTrace = true
            // The level pair ships on here for the same reason: the listening
            // machine is where "everything sounds underwater" was reported, so
            // it is where the fix has to be the default and the *old* behaviour
            // the thing you have to ask for.
            fresh.enableBodyLevel = true
            fresh.enableSeamLevel = true
            // Third of the level trio, and the one that gives the other two
            // back the headroom they spent: without it the deepened pads make
            // seams 3 dB quieter than the bodies the raised target just
            // brightened.
            fresh.enableMasterLimiter = true
            return fresh
        }
        return stored
        #else
        // Release builds have no panel to change these from, so a stored value
        // would be a setting nobody can reach: always start from the tuned
        // audible defaults, with the diagnostic trace (a ring spill per seam
        // and an output capture per track) off.
        var shipped = AutoMixOverrides()
        shipped.enableScore = true
        shipped.enableIntent = true
        shipped.enableBodyLevel = true
        shipped.enableSeamLevel = true
        shipped.enableMasterLimiter = true
        return shipped
        #endif
    }

    /// Go through `PlayerService.setOverrides` instead of calling this: the
    /// flags alone leave the seam that is *already* armed on its old plan, and
    /// the whole point of an override is to hear the next one.
    func writeOverrides(_ new: AutoMixOverrides) {
        guard overrides != new else { return }
        overrides = new
        if !new.forceBeatMatch { setForceNote(nil) }
        if let data = try? JSONEncoder().encode(new) {
            UserDefaults.standard.set(data, forKey: Self.overridesKey)
        }
    }

    /// How the seam a replay just re-planned differs from the one it was asked
    /// to reproduce. Nil when they match, which is the expected case — the
    /// analyses are cached, so the planner should decide identically.
    @Published private(set) var replayDiff: String?

    func setReplayDiff(_ diff: String?) { replayDiff = diff }

    /// Feedback lines written this session. Published so the count next to the
    /// mark buttons moves as they are pressed.
    @Published private(set) var markCount = 0

    func countMark() { markCount += 1 }

    /// Set by the planner path when the override was on. See `snapshot.forceNote`.
    func setForceNote(_ note: String?) {
        guard live.forceNote != note else { return }
        live.forceNote = note
        publish()
    }

    private init() {}

    func activate() {
        isActive = true
        snapshot = live
    }

    func deactivate() {
        isActive = false
    }

    private func publish() {
        guard isActive else { return }
        snapshot = live
    }

    // MARK: - Recorders

    func setNow(_ now: AutoMixDebugNow) {
        guard live.now != now else { return }
        live.now = now
        publish()
    }

    func setNextTitle(_ title: String?, stage: AutoMixPrefetchStage) {
        // A new target wipes whatever the previous one's analysis said; the
        // fields are only meaningful together with the title above them.
        if live.next.title != title { live.next = AutoMixDebugNext(title: title) }
        live.next.stage = stage
        publish()
    }

    func setOrder(_ order: AutoMixDebugOrder) {
        guard live.order != order else { return }
        live.order = order
        publish()
    }

    func setNextStage(_ stage: AutoMixPrefetchStage) {
        live.next.stage = stage
        publish()
    }

    func setNextAnalysis(_ analysis: TrackAnalysis?, localURL: URL?) {
        live.next.stage = analysis == nil
            ? .deferred("no analysis — AutoMix off, or the analyzer declined")
            : .analyzed
        live.next.bpm = analysis?.bpm
        live.next.bpmConfidence = analysis?.bpmConfidence
        live.next.key = analysis.flatMap(AutoMixDebugFormat.key)
        live.next.lufs = analysis?.referenceLoudness
        live.next.sectionCount = analysis?.sections.count
        live.next.structureConfidence = analysis?.structureConfidence
        live.next.hasLyricSidecar = localURL.map(AutoMixDebugFormat.hasLyricSidecar) ?? false
        publish()
    }

    func clearNext() {
        live.next = AutoMixDebugNext()
        publish()
    }

    func setPlan(_ plan: AutoMixDebugPlan?) {
        guard live.plan != plan else { return }
        live.plan = plan
        publish()
    }

    /// The arm-time score verdict. `nil` is "the score compiled", or "there was
    /// no score" — both of which the row prints from the plan instead.
    func setScoreRefusal(_ reason: String?) {
        guard live.scoreRefusal != reason else { return }
        live.scoreRefusal = reason
        publish()
    }

    /// The splice's alignment, mirrored from `SeamLatencyStore`. Pushed by
    /// `PlayerService`'s observer rather than pulled, because the numbers are
    /// produced on the engine's queue and a measurement hop, minutes apart,
    /// with nothing else ticking between them.
    func setSeamLatency(_ report: SeamLatencyStore.Report) {
        guard live.seamLatency != report else { return }
        live.seamLatency = report
        publish()
    }

    func setPrerender(_ state: AutoMixPrerenderState) {
        guard live.prerender != state else { return }
        live.prerender = state
        publish()
    }

    func recordSeam(_ seam: AutoMixDebugSeam) {
        live.seams.insert(seam, at: 0)
        if live.seams.count > Self.seamHistoryLimit {
            live.seams.removeLast(live.seams.count - Self.seamHistoryLimit)
        }
        publish()
    }
}

/// The planner configuration the debug overrides derive.
///
/// It lives here, next to the panel that switches it on, rather than as an
/// extension on `TransitionPlanner.Config` — the `Audition` facade and the
/// offline renderer build their own configs and must never reach a forcing one
/// by accident. `PlayerService.plannerConfig` is the single caller.
enum AutoMixDebugOverrides {

    // Non-binding sentinels, chosen so each is provably past the top of its
    // own signal's range rather than merely large: a reader can check that the
    // gate cannot fire without knowing the corpus.

    /// A dB gap wider than any two masters can differ by.
    static let unreachableLoudnessDB: Double = 240
    /// Cosine distance is bounded by 2 for any pair of vectors.
    static let unreachableTimbreDistance: Double = 2
    /// A folded tempo ratio is at most 0.5 by construction (past that the fold
    /// picks the other octave), so 1 can never be exceeded.
    static let unreachableTempoRatio: Double = 1
    /// Confidences are 0–1, so a 2.0 gate makes `keyDistance` always abstain
    /// and harmony can never demote the tier.
    static let unreachableKeyConfidence: Double = 2
    /// Vocal scores are a window's density over the track's own mean; 1000
    /// is far past anything a real contour produces, so the clash never fires.
    static let unreachableVocalRatio: Double = 1000

    /// **How far the beat-match window opens under the override.** A quarter
    /// of the outgoing tempo, after double/half-time folding — wide enough
    /// that essentially any pair in the library is offered a match.
    static let forcedBPMDeltaCap: Double = 0.25
    /// **And how far it does not.** The decks still meet in the middle, and a
    /// time-pitch unit bending more than ±8 % stops sounding like a tempo and
    /// starts sounding like a fault, which would make the listening note about
    /// the artifact instead of about the transition. So the bend stays capped,
    /// and a pair further apart than roughly 13.8 % is honestly refused at the
    /// `rateDeviation` gate rather than mangled.
    static let forcedRateCap: Double = 0.08

    /// **The house level `enableBodyLevel` moves the trim to**, in LUFS.
    ///
    /// Chosen from the 157 analyses cached on the listening machine, where −11
    /// is the highest target that still lands the whole p10…p90 of the library
    /// exactly on it: 142 tracks matched to the dB, 15 quiet ones (down to
    /// −13.3 LUFS) left at their own level because the clip guard has no
    /// headroom to lift them with. Worth a median +3.0 dB of body loudness
    /// against the shipped −14. The reasoning, the alternatives and the table
    /// are on `TransitionPlanner.Config.loudnessTargetLUFS`.
    static let bodyLevelTargetLUFS: Double = -11

    /// **How far `enableSeamLevel` still lets the ride lift the incoming deck.**
    ///
    /// The shipped cap is 4 dB, and the field journal shows it being spent:
    /// `+2.26`, `+1.72`, `+1.12`, `+0.97` dB on consecutive seams. Every one of
    /// those makes the hand-over *louder than either song*, which is the second
    /// half of "the music wakes up at the transition and the next song sounds
    /// dull" — the bodies were not only quiet, the seams between them were the
    /// loudest thing in the session. 1 dB is the just-noticeable step for a
    /// slow level change, so a lift held to it can close a gap without the
    /// seam ever announcing itself as the loud part.
    ///
    /// What the cap refuses is not lost: the tier gate measures the residual
    /// (`TransitionPlanner.signals`), so a pair whose seam really is 4 dB apart
    /// is now honestly demoted to a shorter, more conservative hand-over
    /// instead of being papered over with gain.
    static let seamRideMaxDB: Double = 1

    /// **…and how far it may still hold the incoming deck down.**
    ///
    /// This is the number that decides how far under its own level a new song
    /// *starts*: the cut goes on before the fader opens and is released at
    /// `TransitionAutomation.rideReleaseCutDBPerSecond` while the new track is
    /// the only thing playing. At the shipped 4 dB the field's `restrained`
    /// seams opened songs at −4.00 dB and took 3.33 s to climb out — a pit deep
    /// enough to be heard as the arrival being muffled, which is precisely the
    /// complaint. 2 dB keeps the gesture (a DJ does hold a hot intro back) and
    /// bounds the pit at roughly the ~1–2 dB a listener can notice at all,
    /// unwinding in 1.67 s — inside the first bar rather than the first phrase.
    ///
    /// Still deeper than the boost cap, for the reason it always was: a cut
    /// costs no headroom and steps on nothing. It is no longer *twice* as deep,
    /// because the asymmetry was buying depth in the one direction the listener
    /// had complained about.
    static let seamRideMaxCutDB: Double = 2

    /// `base`, unchanged, unless an override asks otherwise.
    ///
    /// With **force beat switch** on, every *admission* gate is made
    /// non-binding and the beat-match window is widened. The **physical**
    /// requirements are left exactly as they are: both sides analyzed, tempo
    /// confident enough to be worth aligning to, a downbeat to come in on, and
    /// an out point with room for the overlap. Those are not opinions the panel
    /// may overrule — without them there is no grid to match, and a "forced"
    /// plan would be a lie.
    ///
    /// The three feature switches turn one gesture off each, which is how an
    /// in-place A/B is run: flip, replay the same seam, listen to the pair.
    static func plannerConfig(_ base: TransitionPlanner.Config,
                              overrides: AutoMixOverrides) -> TransitionPlanner.Config {
        guard overrides.isActive else { return base }
        var config = base

        if overrides.forceBeatMatch {
            // Tier: loudness, timbre, tempo clash. All three now abstain, so
            // the pair reaches the beat-match rule as `.compatible`.
            config.neutralLoudnessDB = unreachableLoudnessDB
            config.clashLoudnessDB = unreachableLoudnessDB
            config.neutralTimbreDistance = unreachableTimbreDistance
            config.clashTimbreDistance = unreachableTimbreDistance
            config.clashTempoRatio = unreachableTempoRatio
            // Harmony can only demote, and now never gets a key to demote on.
            config.keyConfidenceThreshold = unreachableKeyConfidence
            // Two vocals at once is the one thing a DJ never allows — which is
            // exactly why someone testing wants to hear it happen on purpose.
            config.vocalClashRatio = unreachableVocalRatio

            // Both regimes' caps, so the result does not depend on whether the
            // tempo ramp happens to be on.
            config.maxBPMDeltaRatio = forcedBPMDeltaCap
            config.rampMaxBPMDeltaRatio = forcedBPMDeltaCap
            config.maxRateDeviation = forcedRateCap
            config.rampMaxRateDeviation = forcedRateCap
        }

        // Applied after the force block on purpose: with the ramp off, the
        // *stepped* caps are what the beat-match rule reads, and the force
        // block set both pairs precisely so this composition works.
        if overrides.disableTempoRamp { config.tempoRampEnabled = false }
        if overrides.disableDominantDeckBlend { config.dominantDeckBlend = false }
        if overrides.disableTwoClockExchange { config.twoClockExchange = false }
        // Enables: `scoreEnabled` and `intentEnabled` both ship false in
        // `Config.standard`, so these switches are spelled as enables.
        if overrides.enableScore { config.scoreEnabled = true }
        if overrides.enableIntent { config.intentEnabled = true }
        if overrides.enableBodyLevel { config.loudnessTargetLUFS = bodyLevelTargetLUFS }
        if overrides.enableSeamLevel {
            config.rideMaxDB = seamRideMaxDB
            config.rideMaxCutDB = seamRideMaxCutDB
        }
        return config
    }
}

/// Where a "jump to seam" lands, and why.
///
/// The naive answer — a few seconds before the out point — breaks the very
/// thing it is trying to audition: the seam is not an instant, it is a gesture
/// with a run-up. A beat-matched hand-over glides the outgoing deck onto its
/// matched tempo for thirteen seconds first, and pads its headroom before
/// that; a stem hand-over is a background render that starts a minute out.
/// Landing inside either produces a *different* transition from the one the
/// listener meant to judge, and — worse — one that looks the same in the panel.
///
/// So the lead is the widest run-up any stage still needs, and the panel says
/// which stage set it.
enum AutoMixSeamJump {

    /// Never land closer than this however little the plan needs: a listening
    /// test needs the outgoing track in its ears before the hand-over to have
    /// an opinion about the hand-over.
    static let floorLead: TimeInterval = 30

    struct Inputs: Equatable {
        var outPoint: TimeInterval
        var isBeatMatched = false
        /// The plan's own glide length; 0 when it carries no ramp.
        var rampLeadSeconds: TimeInterval = 0
        /// The outgoing deck's headroom pad, in dB (≤ 0). Its glide-on is part
        /// of the gesture and finishes exactly where the ramp begins.
        var padDB: Double = 0
        /// A stem technique is planned…
        var needsStemPrerender = false
        /// …and the engine has already been handed a segment for it.
        var segmentArmed = false
        /// How far ahead of the splice the orchestration starts a render job.
        var prerenderLead: TimeInterval = 0
        /// How far before the out point the splice itself begins.
        var prerenderHandoff: TimeInterval = 0
    }

    struct Result: Equatable {
        var lead: TimeInterval
        /// Where to seek to. Never negative.
        var target: TimeInterval
        var reason: String
        /// The jump lands inside the pre-render's runway with nothing armed, so
        /// this seam will be carried by the live fallback rather than a splice.
        /// Only ever true when the track is too short to hold the full runway.
        var losesPrerender: Bool
    }

    static func compute(_ i: Inputs) -> Result {
        var candidates: [(TimeInterval, String)] = [(floorLead, "floor")]
        let rampLead = i.rampLeadSeconds
            + TransitionAutomation.ratePadLeadSeconds(i.padDB)
        if i.isBeatMatched, rampLead > 0 {
            candidates.append((rampLead, String(
                format: "tempo ramp %.0fs + pad lead-in %.0fs", i.rampLeadSeconds,
                TransitionAutomation.ratePadLeadSeconds(i.padDB))))
        }
        let prerenderNeed = i.prerenderLead + i.prerenderHandoff
        if i.needsStemPrerender, !i.segmentArmed {
            candidates.append((prerenderNeed, String(
                format: "stem pre-render runway %.0fs", prerenderNeed)))
        }
        let winner = candidates.max { $0.0 < $1.0 }!
        // A short track cannot hold the run-up the plan wants; land at the top
        // rather than refusing, and say what that costs.
        let target = max(0, i.outPoint - winner.0)
        let lead = i.outPoint - target
        return Result(
            lead: lead, target: target,
            reason: lead < winner.0
                ? "\(winner.1) — clamped to the start of the track"
                : winner.1,
            losesPrerender: i.needsStemPrerender && !i.segmentArmed
                && lead < prerenderNeed)
    }
}

/// Pure formatting/derivation used by both the recorders and the view. Split
/// out so the mapping can be exercised without a player or a window.
enum AutoMixDebugFormat {

    static let pitchNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]

    static func key(_ analysis: TrackAnalysis) -> String? {
        guard let pitch = analysis.keyPitchClass, (0..<12).contains(pitch) else { return nil }
        return String(format: "%@ %@ (%.2f)", pitchNames[pitch],
                      analysis.keyIsMinor ? "min" : "maj", analysis.keyConfidence)
    }

    static func hasLyricSidecar(_ audio: URL) -> Bool {
        FileManager.default.fileExists(atPath: Audition.Lyrics.sidecarURL(for: audio).path)
    }

    static func planKind(_ plan: TransitionPlan) -> String {
        switch plan {
        case .beatMatched: return "beatMatched"
        case .crossfade: return "crossfade"
        case .gapless: return "gapless"
        }
    }

    static func overlap(_ plan: TransitionPlan) -> TimeInterval {
        switch plan {
        case .beatMatched(let p): return p.overlapDuration
        case .crossfade(let duration, _, _): return duration
        case .gapless: return 0
        }
    }

    static func inPoint(_ plan: TransitionPlan) -> TimeInterval? {
        switch plan {
        case .beatMatched(let p): return p.inPoint
        case .crossfade(_, _, let point): return point
        case .gapless: return nil
        }
    }

    static func outroEffect(_ effect: TransitionStyle.OutroEffect) -> String {
        switch effect {
        case .fade: return "fade"
        case .filterSweep: return "filterSweep"
        case .echoOut: return "echoOut"
        }
    }

    /// mm:ss, or "—" for a value that is not a time yet.
    static func clock(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite else { return "—" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, abs(total % 60))
    }

    /// The structural section a cue point falls in, named the way the panel
    /// prints it. Nil when the analysis has no sections (the common case) or
    /// the point is outside them.
    static func section(at time: TimeInterval, in analysis: TrackAnalysis?) -> String? {
        guard let analysis, !analysis.sections.isEmpty else { return nil }
        guard let hit = analysis.sections.first(where: { time >= $0.start && time < $0.end })
        else { return nil }
        return String(format: "%@ %@–%@ ×%d", hit.kind.rawValue,
                      clock(hit.start), clock(hit.end), hit.repetition)
    }

    /// Best-effort provenance for an in point: match it against the landmarks
    /// the planner picks between. Matching, not recording — the planner is a
    /// pure function that keeps no trace of which one it used.
    static func inPointSource(_ inPoint: TimeInterval, incoming: TrackAnalysis?) -> String? {
        guard let incoming else { return nil }
        let slack: TimeInterval = 0.05
        if inPoint < slack { return "track start" }
        if abs(inPoint - incoming.introEnd) < slack { return "introEnd" }
        if let hit = incoming.sections.first(where: { abs($0.start - inPoint) < slack }) {
            return "section start (\(hit.kind.rawValue))"
        }
        if incoming.phraseBoundaries.contains(where: { abs($0 - inPoint) < slack }) {
            return "phrase boundary"
        }
        if incoming.downbeats.contains(where: { abs($0 - inPoint) < slack }) {
            return "downbeat"
        }
        return "free"
    }

    /// How the engine's executed plan differs from the armed one, or nil when
    /// it ran exactly what it was handed. This is the fallback the engine takes
    /// when a seek (or a late arm) has put the out point behind the playhead —
    /// see `PlaybackEngine.resolvePlanLocked`.
    static func fallback(planned: AutoMixDebugPlan?, executed: TransitionPlan) -> String? {
        guard let planned else { return nil }
        let kind = planKind(executed)
        let overlap = overlap(executed)
        if planned.kind != kind {
            return "\(planned.kind) → \(kind) (out point unreachable)"
        }
        guard abs(planned.overlap - overlap) > 0.01
                || abs((planned.outPoint ?? 0) - (executed.outPoint ?? 0)) > 0.01
        else { return nil }
        return String(format: "re-anchored: overlap %.2fs → %.2fs, out %@ → %@",
                      planned.overlap, overlap,
                      clock(planned.outPoint), clock(executed.outPoint))
    }
}

extension AutoMixDebugPlan {
    /// Flatten a planned hand-over plus the analyses it was planned from into
    /// what the panel prints.
    init(planned: PlannedTransition, outgoing: TrackAnalysis?, incoming: TrackAnalysis?) {
        self.init()
        kind = AutoMixDebugFormat.planKind(planned.plan)
        outPoint = planned.plan.outPoint
        inPoint = AutoMixDebugFormat.inPoint(planned.plan)
        overlap = AutoMixDebugFormat.overlap(planned.plan)
        if case .beatMatched(let p) = planned.plan {
            overlapBars = p.overlapBars
            outgoingRate = p.outgoingRate
            incomingRate = p.incomingRate
        }
        outroEffect = AutoMixDebugFormat.outroEffect(planned.style.outroEffect)
        stagedEQ = planned.style.stagedEQ
        stemTechnique = planned.style.stemTechnique?.label
        score = planned.style.score?.label
        // Shown whenever the aiming layer ran — which is whenever it left a
        // sentence behind — rather than only when a score survived to arming.
        // A seam whose score was refused still has an aimed entry, and that is
        // exactly the seam whose row must not go blank.
        aim = planned.style.aimDetail.map {
            TransitionAim.report(planned.style.aim, reason: $0)
        }
        intent = planned.style.intent?.label
        intentClass = planned.style.intent?.class.rawValue
        rideDB = planned.rideDB
        outSection = outPoint.flatMap { AutoMixDebugFormat.section(at: $0, in: outgoing) }
        inPointSource = inPoint.flatMap {
            AutoMixDebugFormat.inPointSource($0, incoming: incoming)
        }
    }
}
#endif
