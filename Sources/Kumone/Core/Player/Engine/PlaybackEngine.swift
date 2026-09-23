#if os(macOS)
import Accelerate
import AudioToolbox
import AVFoundation
import Foundation
import KumoneObjC
import os

/// 引擎实际怎么把一次接歌放出来的。
///
/// 计划本身也在里面，而且是**引擎跑的那一份**：`resolvePlanLocked` 可能在调度
/// 时把够不着的计划降级成尾部淡出或 gapless，调用方手上留着的却是降级*前*的，
/// 所以「刚才到底放了什么」只有引擎说得清。AutoMix 调试面板拿它回看刚听到的
/// 那一秒；除此之外没有别的消费者。
struct TransitionOutcome: Sendable {
    enum Path: String, Sendable {
        /// 预渲染切片顶掉了实时叠加。
        case splicedSegment
        /// 实时双 deck 叠加（crossfade / beatMatched）。
        case liveOverlap
        /// 尾接尾，没有叠加。
        case gapless
    }

    let path: Path
    let plan: TransitionPlan
}

enum PlaybackEngineEvent: Sendable {
    /// Deck 播完了所有已调度音频（自然结束，非 stop/seek 引起）。
    case deckFinished(Deck)
    /// 过渡中点已过（crossfade 中点 / beatMatched 的 bass swap 点）——
    /// PlayerService 以此为界切换 currentTrack/歌词/scrobble。
    case transitionMidpoint(from: Deck, to: Deck, via: TransitionOutcome)
    /// 过渡完成，出曲 deck 已停止并复位。
    case transitionCompleted(from: Deck, to: Deck)
    case streamStalled(Deck)      // 渐进流 underrun，正在缓冲
    case streamResumed(Deck)
    case streamFailed(Deck, Error)
    /// 渐进流全部字节已落盘（.part 写完），调用方可 commit 缓存。
    case streamDownloadCompleted(Deck)
}

/// Dual-deck AVAudioEngine playback engine (spec §2).
///
/// Graph, per deck:
///   AVAudioPlayerNode → AVAudioUnitTimePitch → AVAudioUnitEQ (low shelf +
///   parametric mid + high shelf + a high-pass band) → AVAudioUnitDelay →
///   mainMixerNode
///
/// …and once, on the master path shared by both decks and the segment:
///   mainMixerNode → AVAudioUnitEffect (peak limiter, −1 dBFS) → masterMixer
///   (the user's volume) → outputNode. See `connectMasterChainLocked`.
///
/// Every effect node is attached and wired at init with neutral parameters
/// (all EQ gains 0, the high-pass band bypassed, the delay 100% dry), because
/// reconnecting the graph while the other deck renders throws an NSException.
/// `TransitionStyle` is executed purely by moving those parameters.
///
/// The user-facing volume lives on `masterMixer.outputVolume`, behind the
/// limiter; transition fades use each deck's `playerNode.volume`.
///
/// Concurrency invariants (`@unchecked Sendable`):
/// - Every piece of mutable state — deck state, the audio graph, transition
///   bookkeeping, the loaders — is only touched on `queue`, a private serial
///   DispatchQueue. Public methods hop onto it (`sync` for getters, `async`
///   for commands) and never call out to the caller while on it.
/// - AVAudioPlayerNode completion handlers re-enter through `queue.async`.
///   ProgressiveLoader does its network/decode work on its own queue and
///   delivers results onto `queue` — decode bursts never occupy this queue,
///   which the main thread queries synchronously.
/// - `events` is a single-consumer AsyncStream; the continuation is only
///   yielded to from `queue`.
/// - `queue` never blocks on the main thread, so `queue.sync` from
///   @MainActor callers (PlayerService) cannot deadlock.
final class PlaybackEngine: @unchecked Sendable {

    let events: AsyncStream<PlaybackEngineEvent>

    /// The user's volume. Lives on `masterMixer` — *after* the limiter — see
    /// `connectMasterChainLocked` for why that side of it.
    var outputVolume: Float {
        get { queue.sync { userOutputVolume } }
        set {
            queue.async {
                self.userOutputVolume = newValue
                self.applyMasterVolumeLocked()
            }
        }
    }

    // MARK: - Private state (all confined to `queue`)

    private let queue = DispatchQueue(label: "app.kumone.playback-engine")
    private let engine = AVAudioEngine()
    private let eventContinuation: AsyncStream<PlaybackEngineEvent>.Continuation

    /// **The master peak limiter** (`DeckChain.makeMasterLimiter`), and the
    /// mixer that carries the user's volume behind it.
    ///
    /// Both are attached and wired for the life of the engine whether or not
    /// the limiter is switched on, for exactly the reason every deck effect is:
    /// reconnecting a running graph throws while the other deck renders. The
    /// override flips `AVAudioUnitEffect.bypass`, never the topology.
    private let masterLimiter = DeckChain.makeMasterLimiter()
    private let masterMixer = AVAudioMixerNode()
    /// Whether the limiter is doing anything. Off, the node is bypassed *and*
    /// the ceiling's −1 dB compensation comes off with it, so the whole master
    /// path is byte-identical to the pre-limiter player.
    private var masterLimiterActive = false
    /// The user's volume as the user set it, before the ceiling compensation
    /// is folded in. Kept separately so `outputVolume`'s getter answers what
    /// was asked for rather than what the mixer happens to hold.
    private var userOutputVolume: Float = 1

    /// The one format every deck chain is wired with, fixed at init.
    /// Reconnecting a running engine's graph (to adopt a per-file format)
    /// throws NSException while the other deck renders — so the graph never
    /// changes; sources that don't match are converted into it instead
    /// (ProgressiveLoader for streams, FileFeeder for local files).
    private let graphFormat = DeckChain.format

    /// Everything one deck needs: nodes, source, clock offsets, stream flags.
    private final class DeckState {
        /// Which chain this is, for the trace ring — a stored tag rather than a
        /// reverse lookup, because it is read on every knob write.
        let traceDeck: TraceDeck
        init(_ traceDeck: TraceDeck) { self.traceDeck = traceDeck }

        let player = AVAudioPlayerNode()
        /// The fader, written through here so a render-side reader can see it
        /// without asking the node: `AVAudioNode.volume`'s getter takes the
        /// engine lock, which `AVAudioPlayerNode.stop()` holds while it waits
        /// for pending tap callbacks — a tap that reads the node deadlocks
        /// against a stop on the engine queue.
        var fader: Float {
            get { faderMirror.withLock { $0 } }
            set {
                player.volume = newValue
                faderMirror.withLock { $0 = newValue }
            }
        }
        private let faderMirror = OSAllocatedUnfairLock<Float>(initialState: 1)
        let timePitch = AVAudioUnitTimePitch()
        /// Band layout — fixed at init, see `EQBand`.
        let eq = AVAudioUnitEQ(numberOfBands: DeckChain.bandCount)
        /// Tail effect for `.echoOut`; 100% dry (transparent) at rest.
        let delay = AVAudioUnitDelay()

        enum Source {
            case none
            /// Format matches the graph: sample-accurate scheduleSegment.
            case file(AVAudioFile)
            /// Local file in a different format, converted in chunks.
            case convertedFile(FileFeeder)
            case stream(ProgressiveLoader)
        }

        var source: Source = .none
        var format: AVAudioFormat?
        var isConnected = false
        /// Media time (seconds) of player sample 0 for the current schedule;
        /// position = startOffset + playerTime. Reset by every (re)schedule.
        var startOffset: TimeInterval = 0
        /// Wall seconds this node's timeline counted while the engine was
        /// paused and it rendered nothing — subtracted from every position
        /// read. See `PausedClockSkew`: an `AVAudioPlayerNode` resumes its
        /// *audio* where it left off but its *clock* where the wall clock got
        /// to, and nothing but this closes the gap. Zeroed wherever a fresh
        /// anchor is written, because the skew only describes the distance
        /// between this `startOffset` and a node clock still counting from it.
        var pauseSkew: TimeInterval = 0
        /// This deck's anchor was (re)written while the engine was paused — a
        /// graph rebuild is the path that does it — so the pause still running
        /// is not this schedule's to pay for. Cleared by the resume that
        /// forgives it. See `clearPauseSkewLocked`.
        var anchoredWhilePaused = false
        /// Last position we could compute; the fallback when the node clock
        /// is unavailable (paused engine, configuration change).
        var lastKnownPosition: TimeInterval = 0
        /// Bumped by every stop/seek/reload. Completion handlers capture the
        /// generation they were scheduled under; stale ones are ignored —
        /// AVAudioPlayerNode fires completions on stop() too, and this is how
        /// natural end is told apart from interruption.
        var generation = 0
        /// Logical intent: the deck should be sounding (modulo global pause).
        var isPlaying = false
        /// This deck's node is (or is about to be) started by a `play(at:)` on
        /// the host clock, so nobody else may start it.
        ///
        /// Only the splice's tail sets this, and only for a converted-file
        /// deck: that deck is cued by pre-rolling its feeder, whose chunks
        /// arrive on this queue and would otherwise call
        /// `startNodeIfNeededLocked` and open the hand-back early. Guarding the
        /// one function every start goes through is what makes the pre-roll
        /// safe against every caller rather than against the one we thought of.
        var hostScheduledStart = false
        /// The host time a `play(at:)` released this deck's node at, kept until
        /// something stops or re-cues the node.
        ///
        /// Bookkeeping for the watchdog only, and it exists because of the one
        /// question a stalled deck could not answer: a deck whose playhead sits
        /// at its start offset looks identical whether `play(at:)` has not
        /// fired yet, has fired and the node's timeline never started, or
        /// `playerTime(forNodeTime:)` is simply returning nil. Knowing *when*
        /// the start was supposed to happen splits "not yet" from "twenty-two
        /// seconds ago", which is the difference between waiting and broken.
        var scheduledStartHostTime: UInt64?
        /// A host-clock start whose *actual* instant has not been measured yet.
        /// Armed by `playOnHostClockLocked` and consumed by the first engine
        /// tick that runs `PlaybackStartErrorCheck.settleDelay` past the
        /// scheduled release; see `checkStartErrorsLocked`.
        var startCheck: PendingStartCheck?

        /// Everything the start-error line needs that the deck would otherwise
        /// have forgotten by the time the check runs: when the call was made
        /// (the origin both leads are printed against), which release it is
        /// about, and who asked for it.
        struct PendingStartCheck {
            var requestedAt: UInt64
            var scheduled: UInt64
            var reason: TraceReason
            /// Bumped by a check that could not read the node clock. One retry,
            /// then the line goes out saying so.
            var attempts = 0
        }
        /// Non-nil while a re-schedule (seek) flush window is open: the fader
        /// level to hand back once the stale audio still inside the effect
        /// chain has been pushed out. See `beginFaderFlushLocked`.
        var pendingFaderRestore: Float?
        /// Per-track loudness compensation, as a **linear multiplier on every
        /// fader write** (`setFaderLocked`). 1 = unity, and every path is then
        /// bit-identical to the player before compensation existed.
        ///
        /// It is a property of the material on the deck, set once when the deck
        /// is loaded and never touched again while that track plays: a trim
        /// that moved mid-song would be a level jump, which is the very thing
        /// it exists to remove. It multiplies the transition automation's 0–1
        /// curves rather than replacing them, so curve semantics are untouched;
        /// and it lives below the user's volume (`masterMixer.outputVolume`),
        /// which it never reads or writes.
        var trim: Float = 1

        /// The last level a caller asked this deck's fader for, in 0–1 fader
        /// terms — i.e. `setFaderLocked`'s argument, before `trim` and `ride`.
        /// Remembered so a *gain* change can be re-applied without a caller:
        /// the ride glide re-writes the fader between automation ticks, and
        /// the only correct thing to re-write is whatever the last curve (or
        /// transport call) asked for.
        var faderRequest: Float = 1

        /// Transition gain ride: the **second** time-varying multiplier on
        /// every fader write, stacked on `trim` (`PlaybackEngine.rideDB` /
        /// `TransitionPlanner.rideDB`). 1 = unity, and every path is then
        /// bit-identical to the player before the ride existed.
        ///
        /// Unlike `trim` — a property of the material, fixed for as long as
        /// the track plays — this is a property of the *hand-over*: it is set
        /// on the incoming deck when its overlap begins (where the fader is at
        /// 0, so introducing it is inaudible by construction), held for the
        /// whole overlap, and then released back to unity at
        /// `TransitionAutomation.rideReleaseDBPerSecond` while the deck is the
        /// only thing playing.
        var ride: Float = 1
        /// The ride in dB, and where it is heading. Equal = settled.
        var rideDB: Double = 0
        var rideTargetDB: Double = 0
        /// The ride the release started from, and how far into the release we
        /// are — so the glide is `TransitionAutomation.rideDB`, the very
        /// function the offline renderer steps, rather than an accumulator
        /// that could drift from it.
        var rideReleaseFromDB: Double = 0
        var rideReleaseElapsed: TimeInterval = 0

        /// **Bent-rate headroom pad**: the *third* multiplier on every fader
        /// write, and the only one that exists for a reason that is not
        /// musical. `AVAudioUnitTimePitch` at a non-unity rate can push a
        /// signal several dB above its own input peak
        /// (`LoudnessCompensation.timePitchOvershootDB`), so a hot master
        /// played bent clips — which the tempo ramp made much worse by holding
        /// the outgoing deck bent at *full fader* for the whole glide, where
        /// the bend used to happen only inside an overlap under a falling one.
        ///
        /// It is a property of the material *and* of the moment: sized once
        /// from the track's own peak (`padCeilingDB`), then engaged and
        /// released as the deck's rate leaves and returns to unity. 1 for every
        /// deck with headroom to spare, which is most of them, and every path
        /// is then bit-identical to the player before it existed.
        var ratePad: Float = 1
        var ratePadDB: Double = 0
        /// Where the pad is heading. Equal to `ratePadDB` = settled. Released
        /// on the deck's own glide timer, not the transition's, for exactly the
        /// reason the ride is: it has to survive the transition being torn down
        /// underneath it, and a cancel mid-release must not strand it.
        var ratePadTargetDB: Double = 0
        /// How far this deck would have to come down while bent, in dB (≤ 0).
        /// Computed at load from the track's peak and trim; 0 means the track
        /// absorbs the overshoot on its own and is never padded.
        var padCeilingDB: Double = 0
        /// The trim this deck was loaded at, in dB — kept because the pad is
        /// derived from it and `trim` is already a linear multiplier.
        var trimDB: Double = 0

        // Progressive-stream bookkeeping.
        var pendingStreamBuffers = 0
        var streamStalled = false
        var streamEnded = false
        /// A converted-file deck has been reported starved and no chunk has
        /// been queued on its node since. One episode is one line; see
        /// `checkFeederStarvationLocked`.
        var feederStarved = false

        // MARK: - Observation (verbose trace only)

        /// **The deck has been taken out of service** — hard-silenced or reset —
        /// and nothing has legitimately re-cued it since. Any fader write above
        /// zero while this is true is the resurrection bug, and the sentinel in
        /// `setFaderLocked` says so. Cleared by every path that genuinely puts a
        /// track back on this deck (load, play, seek, re-schedule, pre-roll).
        var outOfService = false
        /// Watchdog bookkeeping: where the playhead was at the last look, when
        /// that was, and whether a stall has already been reported (so one
        /// stall is one line, not one every two seconds).
        /// What the last *recorded* rate and fader write on this deck said, and
        /// who made it — the whole memory `EngineTraceCoalesce` needs to know
        /// whether the next one is worth a slot.
        var lastTracedRate: Double?
        var lastTracedRateReason: TraceReason?
        var lastTracedLevel: Double?
        var lastTracedLevelReason: TraceReason?
        var watchPosition: TimeInterval = 0
        var watchAt: Double = 0
        var watchStalled = false
        /// Whether the watchdog has already re-cued this deck during the
        /// current stall episode. One restart per episode: if cueing the deck
        /// again did not revive it, doing so every two seconds will not either,
        /// and the retry would flush the fader and shred the journal forever.
        /// Cleared when the deck resumes, is reset, or is re-armed.
        var stallRestarted = false

        func band(_ band: EQBand) -> AVAudioUnitEQFilterParameters {
            eq.bands[band.rawValue]
        }
    }

    /// Fixed band assignment of every deck's 4-band EQ; see `DeckChain`, which
    /// the offline `OfflineTransitionRenderer` builds its decks from too.
    private typealias EQBand = DeckChain.Band

    private let deckStates: [Deck: DeckState]

    /// The third player: a pre-rendered hand-over (`TransitionSegment`) plays
    /// here while both decks are silent.
    ///
    /// It is a full `DeckChain` rather than a bare player wired to the mixer,
    /// and that is the whole trick of the splice: an identical chain has
    /// identical latency, so audio scheduled on the shared render clock to
    /// start where a deck's audio stops actually *lands* there. Its knobs are
    /// never automated — it plays what was rendered, at unity — and its source
    /// is always `.none`, which keeps it out of every loop that walks
    /// `deckStates` (the ride glide, the flush window, configuration changes).
    private let segmentState = DeckState(.segment)

    private var isPaused = false
    /// How many times the output device has reported a render-deadline miss
    /// (`kAudioDeviceProcessorOverload`) this session. Journalled with every
    /// overload and printed on the master AU readback line, so a session that
    /// sounded rough can be told apart from one that merely felt rough.
    private var overloadCount = 0
    #if os(macOS)
    private var overloadListener: AudioObjectPropertyListenerBlock?
    private var overloadListenerDevice: AudioDeviceID?
    /// Uptime seconds of the last trace dump the overload sentinel spent.
    private var lastOverloadDumpAt: Double?
    #endif

    /// Host time `pause()` stopped the engine at, cleared by the resume that
    /// hands the paused seconds to every node still holding its schedule.
    /// See `applyPauseSkewLocked`.
    private var pausedAtHostTime: UInt64?
    private var sessionConfigured = false

    // Stream backpressure: pause the download when this many ~0.5s buffers
    // are scheduled but unplayed, resume below the low mark.
    private let streamHighWater = 40  // ≈ 20s of decoded PCM
    private let streamLowWater = 10

    // The transition's parameter curves — and the constants that shape them —
    // live in `TransitionAutomation`, so `OfflineTransitionRenderer` drives
    // an identical node graph from exactly the same numbers. Only the values
    // this file still needs outside the overlap tick are aliased here.
    private static let bassCutDB = TransitionAutomation.bassCutDB
    private static let midCutDB = TransitionAutomation.midCutDB
    private static let highCutDB = TransitionAutomation.highCutDB
    private static let sweepStartHz = TransitionAutomation.sweepStartHz
    private static let echoDefaultDelayTime = TransitionAutomation.echoDefaultDelayTime

    /// How much *new* audio the player node has to emit before a re-scheduled
    /// (seeked) deck may be heard again — i.e. the depth of the effect chain
    /// downstream of the player. `AVAudioPlayerNode.stop()` does not empty
    /// timePitch/EQ/delay, so without this window a seek leaks ~200 ms of the
    /// old position at full level. Measured on this graph; counted on the
    /// player's own clock rather than wall time, so it survives a pause (a
    /// stopped engine renders nothing, and the stale audio is still in there).
    private static let faderFlushDuration: TimeInterval = 0.25
    /// Tick of the flush-window watcher; only runs while a window is open.
    private static let faderFlushTick: TimeInterval = 0.01

    /// A transition may only fire when the outgoing track *plays into* its out
    /// point, so a plan counts as reachable while the playhead is still short
    /// of it. This slack only absorbs "effectively on top of it" (clock jitter,
    /// one render buffer): it must stay small, because arming a plan a fraction
    /// of a second before its out point is perfectly legitimate — the prefetch
    /// can land late. See `resolvePlanLocked`.
    private static let transitionArrivalGuard: TimeInterval = 0.05
    /// How far ahead of the splice a pre-rendered segment is put on the render
    /// clock. `play(at:)` needs a host time in the future, and the wait tick
    /// runs at 50 Hz — a quarter second is an order of magnitude more slack
    /// than either needs, and the segment simply idles until its moment.
    private static let segmentArmLead: TimeInterval = 0.25
    /// How far ahead of the splice's hand-back a converted-file incoming deck
    /// has its feeder re-cued.
    ///
    /// Unlike a `.file` deck — cued by one synchronous `scheduleSegment` at the
    /// arm lead — a feeder opens the file, seeks and converts on its own queue,
    /// so it needs real time rather than clock slack. A second and a half is two
    /// orders of magnitude more than a chunk takes and still lands inside every
    /// segment we render (head + overlap + tail is never under three seconds);
    /// the pre-rolled chunks simply queue up on the stopped node until the tail
    /// releases them.
    private static let segmentTailPreroll: TimeInterval = 1.5
    /// Longest crossfade a degraded plan falls back to.
    private static let fallbackCrossfadeDuration: TimeInterval = 4
    /// Slack the fallback crossfade needs beyond its own length; below this
    /// the fallback is `.gapless` instead.
    private static let fallbackCrossfadeHeadroom: TimeInterval = 3

    // MARK: - Transition state

    private enum TransitionPhase {
        case waiting        // watching the from deck approach the out point
        case armed          // gapless: incoming play(at:) is scheduled
        /// A pre-rendered segment is scheduled on the render clock; the
        /// outgoing deck is still playing normally into the splice point.
        case segmentArmed
        /// The pre-rendered segment is what the listener hears.
        case segmentPlaying
        case overlapping    // crossfade/beatMatched ramp in progress
        /// After the overlap: ramp a beat-matched rate back to 1.0 and/or let
        /// an `.echoOut` tail ring out before the decks go neutral.
        case settling
    }

    private final class TransitionState {
        let plan: TransitionPlan
        let style: TransitionStyle
        /// Gain ride for the incoming deck; see `PlannedTransition.rideDB`.
        let rideDB: Double
        let from: Deck
        let to: Deck
        var phase: TransitionPhase = .waiting
        /// Time spent inside the overlap; advanced per tick and frozen while
        /// paused, so a pause mid-transition does not fast-forward the ramps.
        var elapsed: TimeInterval = 0
        var restoreElapsed: TimeInterval = 0
        /// When the transition timer last fired. The overlap and the settle
        /// advance by the time that actually passed rather than by the nominal
        /// interval: a busy machine delays and coalesces timer fires, and
        /// counted in ticks the automation fell behind the audio it shapes.
        var lastTickUptime: TimeInterval?
        var midpointSent = false
        /// A pre-rendered stem hand-over for exactly this plan, if one was
        /// finished in time. Nil is the ordinary case and means the live
        /// two-deck overlap below runs, unchanged.
        var segment: TransitionSegment?
        /// A converted-file incoming deck has had its feeder re-cued to the
        /// segment's hand-back position and is holding converted chunks on a
        /// stopped node, waiting for the tail's `play(at:)`. Always false for a
        /// `.file` incoming deck, which is cued in one call at the tail itself.
        var tailPrerolled = false
        /// The tail-end output-tap capture has been started. Its own flag
        /// rather than `tailPrerolled`'s, because a `.file` incoming deck is
        /// never pre-rolled and the capture has to cover that hand-back too.
        var tailCaptured = false
        /// `.echoOut`: the delay has been thrown and the outgoing deck is
        /// being cut; set once, at `echoStopOffset`.
        var echoThrown = false
        /// `.echoOut`: the overlap ended with a tail still ringing, which the
        /// settling phase decays.
        var echoTailRinging = false
        var restoringRate = false
        /// The pre-seam tempo glide has started bending the outgoing deck.
        /// The one thing a `.waiting` transition ever writes to a deck, and
        /// therefore the one thing every path that drops a `.waiting` plan has
        /// to take back — see `endTempoRampLocked`.
        var rampActive = false
        /// Outgoing source position the glide actually started from.
        ///
        /// Normally within a tick of the plan's `TempoRamp.start`. It is
        /// captured rather than assumed so that a plan armed *late* — the
        /// playhead already inside the ramp window, which a seek or a
        /// just-in-time re-plan can do — glides from wherever it really is
        /// instead of stepping onto the middle of the curve. Arming later
        /// simply makes the glide steeper, and arming at the very end makes it
        /// the step it always used to be.
        var rampFrom: TimeInterval?

        /// Timing landmarks of the plan (overlap length, swap point, echo stop
        /// point); computed once, shared with the offline renderer.
        let geometry: TransitionAutomation.Geometry

        init(plan: TransitionPlan, style: TransitionStyle, rideDB: Double = 0,
             from: Deck, to: Deck) {
            self.plan = plan
            self.style = style
            self.rideDB = rideDB
            self.from = from
            self.to = to
            self.geometry = TransitionAutomation.Geometry(plan: plan)
        }

        var overlapDuration: TimeInterval { geometry.overlapDuration }
        /// Seconds into the overlap where the low end changes decks — the
        /// staged hand-over's last stage, and the audible midpoint.
        var swapOffset: TimeInterval { geometry.swapOffset }
    }

    /// The pending or running hand-over.
    ///
    /// Written through a setter, not stored bare, for one reason: **a deck the
    /// tempo glide has bent must never outlive the plan that bent it.** A
    /// time-pitch unit off unity is not a subtle colour — it is the phasey,
    /// watery artifact a listener calls "underwater", and unlike a stuck fader
    /// or a ducked EQ band nothing in the system ever resolves it on its own.
    /// The music just stays like that until the track ends.
    ///
    /// There are a dozen places that drop or swap a transition, and one of them
    /// (`beginOverlapLocked`'s contract-violation exit) shipped without the
    /// un-bend and stranded the outgoing deck permanently. Rather than add the
    /// call there and wait for the next one, the invariant is enforced where it
    /// cannot be forgotten: losing the plan *is* handing the rate back.
    ///
    /// **A hand-over bends two different decks at two different times, and the
    /// invariant owes both.** Before the seam the pre-seam glide bends
    /// `tr.from`, taken back by `endTempoRampLocked`. After it, the `.settling`
    /// rate release bends `tr.to` — the deck that *is* the music by then —
    /// taken back by `endRateRestoreLocked`. Only the first was covered here for
    /// a while, because `endTempoRampLocked` addresses `tr.from` and only while
    /// `rampActive`, which `beginOverlapLocked` clears at the seam; the second
    /// strand was held by a single hand-written pair of calls in
    /// `cancelTransitionLocked`'s `.settling` case. Deleting that pair to see
    /// what happened left the live deck at ×1.05 with its pad 6.5 dB down for
    /// the rest of the track — one un-mirrored teardown path away from shipping.
    private var transition: TransitionState? {
        get { storedTransition }
        set {
            if let old = storedTransition, old !== newValue {
                // The single chokepoint every teardown path goes through, so
                // it is also the only place that can honestly say a plan was
                // dropped and from which phase — which is the first question
                // asked of a deck found stuck off unity.
                PlaybackJournal.note(
                    "plan dropped phase=\(old.phase) \(newValue == nil ? "cleared" : "replaced") "
                        + "from=\(old.from.rawValue) to=\(old.to.rawValue) \(journalRates)")
                endTempoRampLocked(old)
                endRateRestoreLocked(old)
            }
            storedTransition = newValue
        }
    }

    /// Both decks' rates, for a journal line. Cheap enough to build on any
    /// lifecycle event; never called per tick.
    private var journalRates: String {
        PlaybackJournal.rates(deckStates[.a]!.timePitch.rate, deckStates[.b]!.timePitch.rate)
    }

    private var storedTransition: TransitionState?
    private var transitionTimer: DispatchSourceTimer?
    /// Fast tick for ramps; the slow tick carries the (possibly minutes-long)
    /// wait for the out point without burning 50 wakeups a second.
    private let tickInterval: TimeInterval = 1.0 / 50.0
    private let slowTickInterval: TimeInterval = 0.25
    private var transitionTimerInterval: TimeInterval = 0

    private var clockTimer: DispatchSourceTimer?
    private var faderFlushTimer: DispatchSourceTimer?
    /// Deck-level gain glide: the transition ride's release. Independent of
    /// the transition timer on purpose — the release outlives the transition.
    private var rideTimer: DispatchSourceTimer?
    /// When the glide timer last fired: the glides advance by the time that
    /// actually passed, not by the nominal tick, because a busy machine
    /// coalesces and delays timer fires — counted in ticks, a release under
    /// load ran ~30% slow (seen on CI) and kept the new track under its own
    /// level for that much longer.
    private var lastRideTickUptime: TimeInterval?
    private var configObserver: NSObjectProtocol?
    /// Set through `setOutputSampleSink`; kept so the tap can be put back after
    /// a configuration change rebuilds the graph.
    private var outputSampleSink: (@Sendable (AVAudioPCMBuffer) -> Void)?

    // MARK: - Init

    init() {
        var continuation: AsyncStream<PlaybackEngineEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        eventContinuation = continuation

        var states: [Deck: DeckState] = [:]
        for deck in [Deck.a, .b] {
            let state = DeckState(TraceDeck(deck))
            DeckChain.configureBands(state.eq)
            DeckChain.configureDelay(state.delay)
            // Born at unity, so born bypassed — see `DeckChain.syncBypass`.
            DeckChain.syncBypass(state.timePitch)

            engine.attach(state.player)
            engine.attach(state.timePitch)
            engine.attach(state.eq)
            engine.attach(state.delay)
            states[deck] = state
        }
        deckStates = states

        DeckChain.configureBands(segmentState.eq)
        DeckChain.configureDelay(segmentState.delay)
        // The splice deck plays pre-rendered material at unity and nothing ever
        // bends it, so its time-pitch unit is bypassed for its whole life.
        DeckChain.syncBypass(segmentState.timePitch)
        engine.attach(segmentState.player)
        engine.attach(segmentState.timePitch)
        engine.attach(segmentState.eq)
        engine.attach(segmentState.delay)

        // Touch the mixer so it is wired to the output before first start.
        engine.mainMixerNode.outputVolume = 1
        engine.attach(masterLimiter)
        engine.attach(masterMixer)

        // Wire all three chains once, before the engine ever starts — the graph
        // is immutable from here on (see graphFormat).
        for state in deckStates.values {
            connectChainLocked(state, format: graphFormat)
        }
        connectChainLocked(segmentState, format: graphFormat)
        segmentState.fader = 0
        connectMasterChainLocked()

        // Output device / route changes stop the engine and wipe every player
        // node's schedule — on macOS this fires when switching audio devices,
        // on iOS on route changes. Rebuild and resume from the cached
        // positions, or playback dies the moment headphones are plugged in.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.handleConfigurationChangeNotificationLocked() }
        }
    }

    deinit {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
        transitionTimer?.cancel()
        clockTimer?.cancel()
        faderFlushTimer?.cancel()
        rideTimer?.cancel()
        watchdogTimer?.cancel()
        #if os(macOS)
        removeOverloadListenerLocked()
        #endif
        eventContinuation.finish()
    }

    // MARK: - Loading

    /// Load a complete local file (cache-hit path); returns its duration.
    /// Does not start playback.
    ///
    /// `trimDB` is this track's loudness compensation (`LoudnessCompensation`),
    /// taken here rather than through a setter so it is fixed for the whole
    /// time the track is on the deck: an analysis that lands mid-song cannot
    /// move it, and the next load is the earliest it can change.
    /// `peakDBFS` is the loaded track's sample peak (`TrackAnalysis.peakDBFS`),
    /// used only to size this deck's bent-rate headroom pad. Nil — no analysis
    /// yet — means no pad: see `LoudnessCompensation.timePitchPadDB` for why
    /// the unknown case errs the opposite way from the boost guard.
    func loadFile(at url: URL, on deck: Deck, trimDB: Double = 0,
                  peakDBFS: Double? = nil) throws -> TimeInterval {
        try queue.sync {
            let file = try AVAudioFile(forReading: url)
            let state = deckStates[deck]!
            // Re-loading a deck invalidates any plan that involves it: the
            // plan's timeline belongs to the material being replaced. Cancel
            // before the reset, so the cancel's own knob writes land first and
            // the reset has the last word on this deck.
            invalidateTransitionLocked(touching: deck)
            resetDeckLocked(state)
            state.trim = LoudnessCompensation.gain(fromDB: trimDB)
            state.trimDB = trimDB
            // Sized once, here, from the material — like the trim, and for the
            // same reason: a pad that moved mid-song would be a level jump.
            // *Applying* it is a separate decision, made when the deck is bent.
            state.padCeilingDB = LoudnessCompensation.timePitchPadDB(
                forPeakDBFS: peakDBFS, afterTrimDB: trimDB,
                masterLimiterActive: masterLimiterActive)
            journalRetiredPadLocked(state, deck: deck, peakDBFS: peakDBFS, trimDB: trimDB)
            let fileFormat = file.processingFormat
            if fileFormat.sampleRate == graphFormat.sampleRate,
               fileFormat.channelCount == graphFormat.channelCount {
                state.source = .file(file)
            } else {
                // Hi-Res / mono: convert in chunks instead of reconnecting
                // the graph (which would throw while the other deck renders).
                let feeder = FileFeeder(file: file, output: graphFormat, queue: queue)
                state.source = .convertedFile(feeder)
                wireFeederLocked(feeder, deck: deck)
                wireFeederTraceLocked(feeder, state: state)
            }
            state.format = graphFormat
            returnToServiceLocked(state)
            trace.record(.scheduleSegment, state.traceDeck, .loadFile,
                         0, Double(state.generation))
            return Double(file.length) / fileFormat.sampleRate
        }
    }

    /// Hook a feeder's chunk delivery into the deck's buffer bookkeeping —
    /// the same path streamed audio uses.
    private func wireFeederLocked(_ feeder: FileFeeder, deck: Deck) {
        feeder.onBuffer = { [weak self, weak feeder] buffer in
            guard let self, let feeder,
                  let state = self.deckStates[deck],
                  case .convertedFile(let current) = state.source, current === feeder else { return }
            state.pendingStreamBuffers += 1
            // The node has audio in hand again, so whatever starvation episode
            // was open is over. Cleared here rather than on a timer: the only
            // thing that ends a starvation is a chunk.
            state.feederStarved = false
            let generation = state.generation
            self.trace.record(.scheduleBuffer, state.traceDeck, .feederChunk,
                              Double(buffer.frameLength), Double(generation),
                              Double(state.pendingStreamBuffers))
            state.player.scheduleBuffer(buffer, at: nil, options: [],
                                        completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard let self else { return }
                self.queue.async {
                    feeder.bufferPlayed()
                    self.streamBufferPlayedLocked(deck: deck, generation: generation)
                }
            }
            self.startNodeIfNeededLocked(state)
        }
        feeder.onEnded = { [weak self, weak feeder] in
            guard let self, let feeder,
                  let state = self.deckStates[deck],
                  case .convertedFile(let current) = state.source, current === feeder else { return }
            state.streamEnded = true
            if state.pendingStreamBuffers <= 0, state.isPlaying {
                self.handleDeckDrainedLocked(deck, generation: state.generation)
            }
        }
    }

    /// Progressive streaming: play while downloading, mirroring raw bytes
    /// into `partURL`. `formatHint` is the file extension ("mp3"/"flac"/"m4a")
    /// used as the AudioFileStream type hint.
    ///
    /// `trimDB` is 0 in practice: a track being streamed for the first time has
    /// no analysis yet, so it has no measured loudness to compensate. The
    /// parameter exists so the stream path cannot silently diverge from the
    /// file path if that ever changes.
    func startStreaming(from remote: URL, formatHint: String?, writingTo partURL: URL,
                        on deck: Deck, trimDB: Double = 0) {
        queue.async {
            let state = self.deckStates[deck]!
            self.invalidateTransitionLocked(touching: deck)
            self.resetDeckLocked(state)
            state.trim = LoudnessCompensation.gain(fromDB: trimDB)
            let loader = ProgressiveLoader(remoteURL: remote, formatHint: formatHint,
                                           partURL: partURL, output: self.graphFormat,
                                           queue: self.queue)
            state.source = .stream(loader)
            self.returnToServiceLocked(state)
            self.trace.record(.scheduleBuffer, state.traceDeck, .startStream,
                              0, Double(state.generation))
            // Start in the stalled state so the first scheduled buffer emits
            // streamResumed — that's the caller's "initial buffering done".
            state.streamStalled = true

            // All loader callbacks arrive on `queue`; each one re-checks that
            // this loader is still the deck's source before touching it.
            loader.onFormat = { [weak self, weak loader] format in
                guard let self, let loader,
                      let state = self.deckStates[deck],
                      case .stream(let current) = state.source, current === loader else { return }
                // The loader converts into the fixed graph format; the graph
                // itself never reconfigures.
                state.format = format
                self.startNodeIfNeededLocked(state)
            }
            loader.onBuffer = { [weak self, weak loader] buffer in
                guard let self, let loader else { return }
                self.scheduleStreamBufferLocked(deck: deck, loader: loader, buffer: buffer)
            }
            loader.onMirrorCompleted = { [weak self, weak loader] bytes in
                guard let self, let loader,
                      let state = self.deckStates[deck],
                      case .stream(let current) = state.source, current === loader else { return }
                // The file is complete on disk while the deck is still playing
                // it from the stream: the cache commit, the analysis and the
                // AutoMix pick can all start now, not when the parse catches up
                // near the end of the song.
                PlaybackJournal.note(String(
                    format: "stream mirror complete deck=%@ bytes=%lld",
                    self.journalDeckName(state), bytes))
                self.eventContinuation.yield(.streamDownloadCompleted(deck))
            }
            loader.onCompleted = { [weak self, weak loader] in
                guard let self, let loader,
                      let state = self.deckStates[deck],
                      case .stream(let current) = state.source, current === loader else { return }
                state.streamEnded = true
                // The cache half of "completed" was already reported by
                // `onMirrorCompleted`, when the last byte arrived.
                // The stream may already be drained (stalled at the tail).
                if state.pendingStreamBuffers <= 0, state.isPlaying {
                    state.streamStalled = false
                    self.handleDeckDrainedLocked(deck, generation: state.generation)
                }
            }
            loader.onError = { [weak self, weak loader] error in
                guard let self, let loader,
                      let state = self.deckStates[deck],
                      case .stream(let current) = state.source, current === loader else { return }
                self.eventContinuation.yield(.streamFailed(deck, error))
            }
            loader.start()
        }
    }

    // MARK: - Transport

    func play(deck: Deck, from seconds: TimeInterval) {
        queue.async {
            let state = self.deckStates[deck]!
            self.isPaused = false
            // This deck is being handed a track to carry. Decks are reused as
            // they are found, so unless a live transition owns its knobs
            // (its ramps rewrite them every tick), start from a transparent
            // chain — a band left ducked by a hand-over that ended some other
            // way would colour everything played here from now on.
            if !self.deckIsInLiveTransitionLocked(deck) {
                self.neutralizeEffectsLocked(state)
            }
            // A deck parked by resetDeckLocked is silent at the mixer; this is
            // the explicit "make this deck sound" entry point, so it is here
            // that the fader comes back up (see resetDeckLocked). Routed
            // through setFaderLocked so a seek's flush window still holds the
            // mute until the chain has drained.
            // Re-aiming the playhead ends any hand-over the ride was unwinding
            // from; settle it here, before the fader is written, so this deck
            // comes back at one definite level. See `settleRideLocked`.
            self.settleRideLocked(state)
            self.returnToServiceLocked(state)
            self.setFaderLocked(state, 1, .play)
            self.ensureEngineRunningLocked()
            switch state.source {
            case .none:
                break
            case .file(let file):
                state.isPlaying = true
                self.scheduleSegmentLocked(state, file: file, from: seconds, deck: deck, .play)
                self.startNodeIfNeededLocked(state)
            case .convertedFile(let feeder):
                state.isPlaying = true
                self.seekFeederLocked(state, feeder: feeder, to: seconds, .play)
                self.startNodeIfNeededLocked(state)
            case .stream(let loader):
                state.isPlaying = true
                if seconds > 0.25, abs(seconds - self.livePositionLocked(state)) > 0.5, loader.canSeek {
                    self.seekStreamLocked(state, deck: deck, to: seconds, .play)
                }
                self.startNodeIfNeededLocked(state)
            }
            self.revalidateTransitionAfterSeekLocked(deck)
        }
    }

    /// Global pause: `engine.pause()`, keeping every schedule intact.
    func pause() {
        queue.async {
            guard !self.isPaused else { return }
            // Snapshot positions first — the node clocks freeze with the engine.
            for state in self.deckStates.values where state.isPlaying {
                state.lastKnownPosition = self.livePositionLocked(state)
            }
            // A gapless hand-over armed via play(at:) fires on the host
            // clock, which keeps running while paused — the incoming track
            // would blast in the moment playback resumes. Disarm; the wait
            // tick re-arms after resume.
            self.disarmGaplessLocked()
            // A pre-rendered segment is armed on the same host clock, and the
            // incoming deck's hand-back inside one is too. Both are undone
            // here and re-armed by the tick after playback resumes; a segment
            // that is already sounding needs nothing, because it freezes with
            // the engine exactly like the decks do.
            self.disarmSegmentLocked()
            self.disarmSegmentTailLocked()
            // An echo tail cannot decay while the engine is stopped, and a
            // frozen wet delay would blare back on resume — end it now.
            if let tr = self.transition, tr.phase == .settling, tr.echoTailRinging {
                tr.echoTailRinging = false
                self.silenceDeckLocked(self.deckStates[tr.from]!)
            }
            // A gain ride cannot glide while nothing renders, and resuming
            // into a half-released one would just make the drift longer than
            // it was designed to be. Settle it while the engine is silent —
            // a ride still inside its overlap is at its target already, so a
            // pause mid-crossfade moves nothing.
            for state in self.deckStates.values { self.settleRideLocked(state) }
            self.isPaused = true
            self.engine.pause()
            // After the pause, not before: the wall clock that has to be
            // discounted is the one the *stopped* engine spends, and taking
            // the stamp on the far side of the call cannot over-count it.
            self.pausedAtHostTime = mach_absolute_time()
        }
    }

    func resume() {
        queue.async {
            guard self.isPaused else { return }
            self.isPaused = false
            self.applyPauseSkewLocked()
            self.ensureEngineRunningLocked()
            for state in self.deckStates.values where state.isPlaying {
                self.startNodeIfNeededLocked(state)
            }
        }
    }

    /// **Hand the paused wall clock to every node that kept its schedule.**
    ///
    /// A paused `AVAudioPlayerNode` resumes its audio exactly where it left off
    /// and its *clock* wherever the wall clock got to — see `PausedClockSkew`
    /// for the measurement and the field incident. So every deck whose player
    /// still holds the schedule it had before the pause owes that many seconds
    /// back, and the ones that do not are precisely the ones a fresh anchor is
    /// about to be written for (`disarmGaplessLocked` has already stopped the
    /// armed hand-over; `startNodeIfNeededLocked` cannot resurrect a node that
    /// was re-cued without going through a site that zeroes the skew).
    ///
    /// The segment player is the third chain and needs the same treatment, but
    /// only while it is *sounding*: an armed-but-unreleased segment was taken
    /// off the clock by `disarmSegmentLocked` on the way into the pause.
    ///
    /// Runs before `ensureEngineRunningLocked`, so no position read can land
    /// between the engine restarting and the correction being in place.
    private func applyPauseSkewLocked() {
        guard let pausedAt = pausedAtHostTime else { return }
        pausedAtHostTime = nil
        let paused = AVAudioTime.seconds(forHostTime: mach_absolute_time() &- pausedAt)
        for (deck, state) in deckStates {
            defer { state.anchoredWhilePaused = false }
            guard state.isPlaying, !state.anchoredWhilePaused, paused > 0 else { continue }
            state.pauseSkew = PausedClockSkew.skew(after: paused, existing: state.pauseSkew)
            PlaybackJournal.note(PausedClockSkew.line(
                deck: deck.rawValue, paused: paused, total: state.pauseSkew))
        }
        let segmentSounding = transition?.phase == .segmentPlaying
        if segmentSounding, !segmentState.anchoredWhilePaused, paused > 0 {
            segmentState.pauseSkew = PausedClockSkew.skew(
                after: paused, existing: segmentState.pauseSkew)
            PlaybackJournal.note(PausedClockSkew.line(
                deck: "segment", paused: paused, total: segmentState.pauseSkew))
        }
        segmentState.anchoredWhilePaused = false
    }

    /// A fresh anchor: the node clock this deck's position is derived from
    /// starts counting from here, so whatever it counted through earlier pauses
    /// is no longer part of the sum. Every `startOffset` write goes through
    /// this, which is what keeps the two in step.
    private func clearPauseSkewLocked(_ state: DeckState) {
        state.pauseSkew = 0
        // Written *during* a pause (the graph rebuild re-cues every deck from
        // its cached position, paused or not): the pause still running belongs
        // to the schedule this one replaced, not to this one.
        state.anchoredWhilePaused = isPaused
    }

    /// File decks seek sample-accurately. Stream decks restart the transfer
    /// from a CBR byte estimate; if the stream cannot seek yet (bitrate still
    /// unknown), the request is ignored — see ProgressiveLoader.seek.
    func seek(deck: Deck, to seconds: TimeInterval) {
        queue.async {
            let state = self.deckStates[deck]!
            // The seek's flush window mutes this deck while the chain drains,
            // so settling the ride now is inaudible — and the level it comes
            // back at is the one the new position deserves.
            self.settleRideLocked(state)
            switch state.source {
            case .none:
                break
            case .file(let file):
                self.scheduleSegmentLocked(state, file: file, from: seconds, deck: deck, .seek)
                self.startNodeIfNeededLocked(state)
            case .convertedFile(let feeder):
                self.seekFeederLocked(state, feeder: feeder, to: seconds, .seek)
                self.startNodeIfNeededLocked(state)
            case .stream(let loader):
                guard loader.canSeek else { return }
                self.seekStreamLocked(state, deck: deck, to: seconds, .seek)
                self.startNodeIfNeededLocked(state)
            }
            // The playhead moved: a pending hand-over must be re-derived from
            // the new position rather than fired because the seek landed on
            // top of its out point.
            self.revalidateTransitionAfterSeekLocked(deck)
        }
    }

    func position(of deck: Deck) -> TimeInterval {
        queue.sync { reportedPositionLocked(deck) }
    }

    func duration(of deck: Deck) -> TimeInterval? {
        queue.sync { durationLocked(deckStates[deck]!) }
    }

    /// Stop and fully reset the deck (volume, rate, EQ back to neutral).
    func stop(deck: Deck) {
        queue.async {
            if let tr = self.transition, tr.from == deck || tr.to == deck {
                self.cancelTransitionLocked()
            }
            self.resetDeckLocked(self.deckStates[deck]!)
        }
    }

    func stopAll() {
        queue.async {
            self.cancelTransitionLocked()
            for state in self.deckStates.values {
                self.resetDeckLocked(state)
            }
            // Keep the engine running (cheap, and restart is not free).
        }
    }

    // MARK: - Transitions

    /// Pre-arm a transition: the `to` deck must already be loaded via
    /// `loadFile`. The engine watches the `from` deck and, at the plan's out
    /// point, starts the `to` deck and runs the volume/rate/EQ ramps,
    /// emitting `transitionMidpoint` / `transitionCompleted` along the way.
    /// A `.gapless` plan starts the incoming deck at the exact moment the
    /// outgoing one ends.
    func scheduleTransition(_ planned: PlannedTransition, from: Deck, to: Deck) {
        queue.async {
            self.cancelTransitionLocked()
            guard from != to else { return }
            // A plan whose out point the playhead has already passed (the
            // caller re-armed right after a seek) is degraded here, never
            // fired on the spot — see resolvePlanLocked.
            let resolved = self.resolvePlanLocked(planned, from: self.deckStates[from]!)
            self.transition = TransitionState(plan: resolved.plan, style: resolved.style,
                                              rideDB: resolved.rideDB, from: from, to: to)
            PlaybackJournal.note(
                "plan armed \(from.rawValue)→\(to.rawValue) "
                    + "\(Self.journalPlan(resolved.plan)) "
                    + String(format: "ride=%+.2fdB ", resolved.rideDB)
                    + "stem=\(resolved.style.stemTechnique?.label ?? "none") "
                    // Only when the intent layer ran at all: an `intent=off`
                    // on every line of a shipped journal would be noise, and
                    // its absence already says the layer is dark.
                    + (resolved.style.intent.map { "\($0.label) " } ?? "")
                    + "\(self.journalRates)")
            self.startTransitionTimerLocked(interval: self.slowTickInterval)
        }
    }

    /// Why an offered `TransitionSegment` was not taken.
    ///
    /// The offer is fire-and-forget by design — the pre-render hands the engine
    /// a suggestion and the live hand-over is always still armed behind it — so
    /// the *reason* used to be unrecoverable, and the caller reported a guess.
    /// Field journals then read `engine declined — seam moved or splice passed`
    /// for renders that finished half a minute early onto a seam nothing had
    /// touched, which is the opposite of what had happened. Each case below is
    /// one guard in `acceptSegmentLocked`, and nothing else declines.
    enum SegmentDecline: String, Sendable {
        /// No plan is waiting, or the hand-over has already started running.
        case wrongPhase
        /// This seam already holds a segment.
        case alreadyArmed
        /// The segment was cut for different geometry than the armed plan's —
        /// a seek degraded the plan, or a late re-plan moved the seam.
        case signatureMismatch
        /// The incoming deck has nothing a splice can hand back to: a
        /// progressive stream (no frame-accurate resume) or no source at all.
        case unsupportedSource
        /// The outgoing deck is already at or past the splice point — the
        /// render finished too late to be used.
        case splicePassed

        /// One clause, for the debug panel.
        var explanation: String {
            switch self {
            case .wrongPhase: return "no seam is waiting"
            case .alreadyArmed: return "this seam already holds a segment"
            case .signatureMismatch: return "the seam moved under the render"
            case .unsupportedSource: return "the incoming deck cannot be spliced onto"
            case .splicePassed: return "the splice point had already passed"
            }
        }
    }

    /// Why the last offered segment was declined; nil when it was taken. Read
    /// back the same way `hasArmedSegment` is — one queue hop, once per seam.
    private var segmentDecline: SegmentDecline?

    /// Hand the engine a pre-rendered hand-over to play in place of the live
    /// overlap of the transition it currently has waiting.
    ///
    /// Rejected — leaving the live path armed — unless the segment belongs to
    /// *this* plan and the outgoing deck has not yet reached the splice point.
    /// Both are the same rule: a segment is audio cut for one exact seam, so
    /// anything that has moved the seam (a seek that degraded the plan, a late
    /// re-plan, a pre-render that finished too late) makes it the wrong audio,
    /// and the live path is always still there.
    ///
    /// A rejection is no longer silent: it names itself in the journal at the
    /// moment it happens and stays readable in `lastSegmentDecline`.
    func armTransitionSegment(_ segment: TransitionSegment) {
        queue.async {
            let decline = self.acceptSegmentLocked(segment)
            self.segmentDecline = decline
            guard let decline else { return }
            PlaybackJournal.note(String(
                format: "splice declined reason=%@ spliceStart=%.3f ",
                decline.rawValue, segment.spliceStart) + self.journalRates)
        }
    }

    /// The arming rules, one guard each, so the caller can be told which one
    /// said no. Returns nil when the segment was taken.
    private func acceptSegmentLocked(_ segment: TransitionSegment) -> SegmentDecline? {
        guard let tr = transition, tr.phase == .waiting else { return .wrongPhase }
        guard tr.segment == nil else { return .alreadyArmed }
        guard let signature = TransitionSegment.Signature(plan: tr.plan),
              signature == segment.signature else { return .signatureMismatch }
        switch deckStates[tr.to]!.source {
        case .file, .convertedFile:
            // Both can be cued to an exact source frame and released on the
            // render clock — see `startIncomingFromSegmentLocked`.
            break
        case .stream, .none:
            return .unsupportedSource
        }
        let position = livePositionLocked(deckStates[tr.from]!)
        guard position < segment.spliceStart - Self.segmentArmLead else { return .splicePassed }
        tr.segment = segment
        return nil
    }

    /// Test hook: is a pre-rendered segment armed for the pending transition?
    var hasArmedSegment: Bool { queue.sync { transition?.segment != nil } }

    /// Why the last `armTransitionSegment` offer was declined, or nil if it was
    /// taken. Same read-back shape as `hasArmedSegment`.
    var lastSegmentDecline: SegmentDecline? { queue.sync { segmentDecline } }

    /// Test hook: is a pre-rendered segment currently carrying the hand-over?
    /// The phase a test has to wait for before it can say anything about the
    /// deck the segment replaced — `retireOutgoingForSegmentLocked` runs inside
    /// it, and that is the one window where a deck is stopped, still loaded and
    /// not yet reset.
    var segmentIsPlaying: Bool { queue.sync { transition?.phase == .segmentPlaying } }

    /// Snapshot of one deck's fader + effect parameters. Test hook: the only
    /// way to assert that a transition left the reused deck neutral.
    struct DeckEffectSnapshot: Sendable, Equatable {
        /// `player.volume` as written — i.e. the fader level already scaled by
        /// `trim`, which is what actually reaches the mixer.
        var volume: Float
        /// The deck's loudness-compensation multiplier; 1 = no compensation.
        var trim: Float = 1
        /// The transition gain ride currently on this deck, in dB, and the
        /// value it is gliding towards (equal = settled). 0/0 = no ride.
        var rideDB: Double = 0
        var rideTargetDB: Double = 0
        /// The bent-rate headroom pad currently on this deck, in dB (≤ 0),
        /// and the value it is gliding towards (equal = settled).
        var ratePadDB: Double = 0
        var ratePadTargetDB: Double = 0
        var rate: Float
        var eqGlobalGain: Float = 0
        var lowGain: Float
        var midGain: Float
        var highGain: Float
        var highPassBypassed: Bool
        var highPassFrequency: Float
        var delayWetDryMix: Float
        var delayFeedback: Float

        /// Every effect transparent — the fader is judged separately, because
        /// a spent deck is parked silent while a live one sits at 1.
        var effectsAreNeutral: Bool {
            abs(rate - 1) < 0.001 && abs(eqGlobalGain) < 0.001
                && abs(lowGain) < 0.001 && abs(midGain) < 0.001 && abs(highGain) < 0.001
                && highPassBypassed
                && abs(delayWetDryMix) < 0.001 && abs(delayFeedback) < 0.001
        }

        /// The pose of a deck that is carrying (or about to carry) a track:
        /// transparent chain, fader open.
        /// "Fader fully open" means the deck's own gains, not literally 1 — a
        /// compensated deck at full fade sits at its trim by construction, and
        /// one still unwinding a hand-over's gain ride sits at trim × ride.
        var isNeutral: Bool {
            effectsAreNeutral && abs(ratePadTargetDB) < 0.001
                && abs(volume - trim * LoudnessCompensation.gain(fromDB: rideDB)
                       * LoudnessCompensation.gain(fromDB: ratePadDB)) < 0.001
        }

        /// The pose `resetDeckLocked` parks a spent deck in: transparent chain
        /// *and* silent, so nothing still draining out of the chain can be
        /// heard. `play(deck:from:)` reopens the fader.
        var isParked: Bool { effectsAreNeutral && abs(volume) < 0.001 }
    }

    func effectSnapshot(of deck: Deck) -> DeckEffectSnapshot {
        queue.sync {
            let state = deckStates[deck]!
            return DeckEffectSnapshot(
                volume: state.player.volume,
                trim: state.trim,
                rideDB: state.rideDB,
                rideTargetDB: state.rideTargetDB,
                ratePadDB: state.ratePadDB,
                ratePadTargetDB: state.ratePadTargetDB,
                rate: state.timePitch.rate,
                eqGlobalGain: state.eq.globalGain,
                lowGain: state.band(.low).gain,
                midGain: state.band(.mid).gain,
                highGain: state.band(.high).gain,
                highPassBypassed: state.band(.highPass).bypass,
                highPassFrequency: state.band(.highPass).frequency,
                delayWetDryMix: state.delay.wetDryMix,
                delayFeedback: state.delay.feedback
            )
        }
    }

    /// Both decks' rate and gain stages, read in **one** queue hop.
    ///
    /// The watery-playback bug is always a deck left off unity rate with no
    /// transition running, and the only way to see it while it is happening is
    /// to read both decks at the same instant — two `effectSnapshot` calls are
    /// two hops and can straddle a tick, which is exactly the moment in
    /// question. Everything here is a plain load; the caller (the AutoMix debug
    /// panel, only while its window is open) polls it at 5 Hz, and nothing
    /// polls it otherwise.
    struct DeckGainSnapshot: Sendable, Equatable {
        var rate: Float = 1
        /// Where a glide is heading, when the rate is being ramped or released.
        var trimDB: Double = 0
        var rideDB: Double = 0
        var ratePadDB: Double = 0
        /// The pad this deck *would* take while bent, sized at load from the
        /// track's own peak. Read by the debug panel's jump-to-seam, which has
        /// to know how much lead-in the pad's glide will want.
        var padCeilingDB: Double = 0
        /// A transition is running on this deck right now, so a rate off unity
        /// is expected rather than a leak.
        var inTransition = false
    }

    func deckGains() -> (a: DeckGainSnapshot, b: DeckGainSnapshot) {
        queue.sync {
            let live = transition
            func snapshot(_ deck: Deck) -> DeckGainSnapshot {
                let state = deckStates[deck]!
                return DeckGainSnapshot(
                    rate: state.timePitch.rate,
                    // The deck stores the trim as the multiplier it applies;
                    // dB is what the panel reads and what the sidecar quoted.
                    trimDB: state.trim > 0 ? 20 * log10(Double(state.trim)) : 0,
                    rideDB: state.rideDB,
                    ratePadDB: state.ratePadDB,
                    padCeilingDB: state.padCeilingDB,
                    inTransition: live.map { $0.from == deck || $0.to == deck } ?? false)
            }
            return (snapshot(.a), snapshot(.b))
        }
    }

    /// One deck's gains, for a caller that only needs the one.
    func deckGains(of deck: Deck) -> DeckGainSnapshot {
        let both = deckGains()
        return deck == .a ? both.a : both.b
    }

    /// Test hook: whether any transition is still scheduled or running.
    var hasPendingTransition: Bool { queue.sync { transition != nil } }

    /// Hand every buffer of the engine's final mixed output to `block`, for a
    /// meter or an analyzer. Pass nil to stop.
    ///
    /// The tap sits on `masterMixer`'s output — the **last** node before the
    /// output device — so it hears both decks, the pre-rendered segment, the
    /// master limiter and the user's volume: whatever a listener hears, with no
    /// dependence on which deck is live or how a hand-over is running.
    ///
    /// Post-limiter deliberately, and it is the only position that can answer
    /// the question the limiter was built for. A tap on `mainMixerNode` would
    /// show the *unlimited* sum, so every capture would go on reporting the
    /// overshoot the master path now removes, and the acceptance evidence
    /// (`tapLevelDescription`'s `peak=`) would be measuring the wrong signal.
    /// A tap does not touch the graph's connections, so this is safe at any
    /// time; it is reinstalled after a configuration change, where the mixer's
    /// format can move under it.
    ///
    /// `block` runs on a real-time audio thread: it must not allocate, lock or
    /// hop actors, and it must not call back into the engine.
    func setOutputSampleSink(_ block: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        queue.sync {
            outputSampleSink = block
            installOutputSampleSinkLocked()
        }
    }

    /// An AVAudioNode allows **one** tap per bus — installing a second raises
    /// an NSException and takes the process down, which is exactly the crash
    /// 0179744 shipped: the underwater-hunt capture installed its own tap on
    /// the mixer while the spectrum's sink already held the bus. So there is
    /// one tap, here, and both consumers ride it: the spectrum sink on every
    /// buffer, and the capture tee while a capture file is open.
    private func installOutputSampleSinkLocked() {
        let mixer = outputTapNode
        if mixerTapInstalled { mixer.removeTap(onBus: 0); mixerTapInstalled = false }
        let sink = outputSampleSink
        let capture = tapCapture
        let capturing = capture.withLock { $0.file != nil }
        guard sink != nil || capturing else { return }
        mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, when in
            sink?(buffer)
            capture.tee(buffer, at: when)
        }
        mixerTapInstalled = true
    }

    /// Test hook: report the peak magnitude one deck contributes to the mixer,
    /// once per render buffer.
    ///
    /// The tap sits on the last node of the deck's chain (the delay), which is
    /// everything *except* the fader: `player.volume` is an `AVAudioMixing`
    /// property applied at the mixer's input bus, downstream of this point, so
    /// it is folded in by hand here. Installing a tap does not reconfigure the
    /// graph, so this is safe while the engine runs. Pass nil to remove.
    func setOutputMonitor(on deck: Deck, _ block: (@Sendable (Float) -> Void)?) {
        queue.sync { installMonitorLocked(deckStates[deck]!, block) }
    }

    /// Test hook: the same tap on the pre-rendered segment's chain, so a
    /// splice can be judged on what all three sources contributed.
    func setSegmentOutputMonitor(_ block: (@Sendable (Float) -> Void)?) {
        queue.sync { installMonitorLocked(segmentState, block) }
    }

    private func installMonitorLocked(_ state: DeckState,
                                      _ block: (@Sendable (Float) -> Void)?) {
        state.delay.removeTap(onBus: 0)
        guard let block else { return }
        state.delay.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            var peak: Float = 0
            if let data = buffer.floatChannelData {
                for channel in 0..<Int(buffer.format.channelCount) {
                    let samples = data[channel]
                    for frame in 0..<Int(buffer.frameLength) {
                        peak = max(peak, abs(samples[frame]))
                    }
                }
            }
            block(peak * state.fader)
        }
    }

    /// Call on seek / manual track change.
    func cancelScheduledTransition() {
        queue.async { self.cancelTransitionLocked() }
    }

    /// Swap the plan of a scheduled transition that has not started yet
    /// (phase .waiting). No-op once the hand-over is armed or overlapping,
    /// so a late re-plan can never cut audio that is already sounding.
    func replaceTransitionPlan(_ planned: PlannedTransition) {
        queue.async {
            guard let tr = self.transition, tr.phase == .waiting else {
                PlaybackJournal.note(
                    "plan replace ignored phase="
                        + "\(self.transition.map { "\($0.phase)" } ?? "none") "
                        + "\(self.journalRates)")
                return
            }
            // The new plan carries its own glide (or none); installing it hands
            // the old one's back rather than letting a state that was not built
            // for it inherit a bent deck.
            let resolved = self.resolvePlanLocked(planned, from: self.deckStates[tr.from]!)
            let state = TransitionState(plan: resolved.plan, style: resolved.style,
                                        from: tr.from, to: tr.to)
            // A pre-rendered segment survives a re-plan that did not move the
            // seam — an upgraded plan is usually the same geometry with better
            // provenance, and re-rendering would cost another minute we may
            // not have.
            if let segment = tr.segment,
               let signature = TransitionSegment.Signature(plan: resolved.plan),
               signature == segment.signature {
                state.segment = segment
            }
            self.transition = state
            PlaybackJournal.note(
                "plan replaced \(tr.from.rawValue)→\(tr.to.rawValue) "
                    + "\(Self.journalPlan(resolved.plan)) "
                    + "segment=\(state.segment != nil ? "kept" : "dropped") "
                    + "\(self.journalRates)")
        }
    }

    /// Whether the pending hand-over has left the waiting phase — armed on the
    /// host clock, playing a pre-rendered splice, overlapping, or settling. In
    /// other words: whether the seam is already audible, or committed to a
    /// clock time nothing can politely take back. Same read-back shape as
    /// `hasPendingTransition`.
    var handOverStarted: Bool {
        queue.sync { transition.map { $0.phase != .waiting } ?? false }
    }

    /// Bring a still-waiting hand-over forward to *now*.
    ///
    /// For the listener who pressed next: both decks are already loaded and a
    /// seam is already planned, so the two tracks can simply meet here instead
    /// of one being torn down and the other restarted from silence. The styled
    /// mechanics do not come along — a beat-matched geometry is a claim about
    /// one bar line in the outgoing song and that bar line is not here — so
    /// what is left is a plain crossfade, exactly as `resolvePlanLocked`
    /// degrades a plan whose out point has gone out of reach.
    ///
    /// Returns false, changing nothing, when there is nothing to bring
    /// forward: no plan, one that has already started, or a track with less
    /// runway left than the guard. The caller then does whatever it would have
    /// done without this.
    @discardableResult
    func startHandOverNow(fade: TimeInterval = 1.2) -> Bool {
        queue.sync {
            guard let tr = transition, tr.phase == .waiting else { return false }
            let from = deckStates[tr.from]!
            guard let duration = durationLocked(from) else { return false }
            let position = livePositionLocked(from)
            // Far enough ahead that the wait tick sees the deck *arrive* at the
            // out point rather than having passed it (`planIsReachableLocked`
            // is the same guard, and a plan behind the playhead never fires);
            // close enough that it reads as "now".
            let outPoint = position + Self.transitionArrivalGuard * 2
            guard outPoint < duration else { return false }
            // The overlap may run past the end of the outgoing track when next
            // is pressed in its last second; clamp so the fade is over audio
            // that exists.
            let overlap = min(fade, duration - outPoint)
            guard overlap > 0 else { return false }
            // The ride survives, for the same reason it survives a
            // degradation: it is a property of the two tracks meeting.
            transition = TransitionState(
                plan: .crossfade(duration: overlap, outPoint: outPoint, inPoint: 0),
                style: .plain, rideDB: tr.rideDB, from: tr.from, to: tr.to)
            PlaybackJournal.note(String(
                format: "plan pulled forward %@→%@ at=%.3f out=%.3f overlap=%.3f ",
                tr.from.rawValue, tr.to.rawValue, position, outPoint, overlap)
                + journalRates)
            startTransitionTimerLocked(interval: tickInterval)
            return true
        }
    }

    /// A plan in one field-per-number line, the same shape everywhere so the
    /// journal can be grepped and diffed across two runs of the same seam.
    private static func journalPlan(_ plan: TransitionPlan) -> String {
        switch plan {
        case .gapless:
            return "kind=gapless"
        case .crossfade(let duration, let outPoint, let inPoint):
            return String(format: "kind=crossfade out=%.3f in=%.3f overlap=%.3f",
                          outPoint, inPoint, duration)
        case .beatMatched(let p):
            return String(format: "kind=beatMatched out=%.3f in=%.3f overlap=%.3f bars=%d "
                          + "rateOut=%.4f rateIn=%.4f swap=%.3f",
                          p.outPoint, p.inPoint, p.overlapDuration, p.overlapBars,
                          p.outgoingRate, p.incomingRate, p.bassSwapOffset)
        }
    }

    // MARK: - Engine lifecycle (locked)

    private func ensureEngineRunningLocked() {
        guard !engine.isRunning else { return }
        #if os(iOS)
        if !sessionConfigured {
            sessionConfigured = true
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
            try? AVAudioSession.sharedInstance().setActive(true)
        }
        #endif
        engine.prepare()
        do {
            try engine.start()
            startClockTimerLocked()
            #if os(macOS)
            // The output unit only settles on a device once it has started;
            // this is the first moment there is one to listen to.
            refreshOverloadListenerLocked()
            #endif
        } catch {
            // Surface as a stream failure on whichever deck wanted to play.
            for (deck, state) in deckStates where state.isPlaying {
                eventContinuation.yield(.streamFailed(deck, error))
            }
        }
    }

    private func connectChainLocked(_ state: DeckState, format: AVAudioFormat) {
        engine.connect(state.player, to: state.timePitch, format: format)
        engine.connect(state.timePitch, to: state.eq, format: format)
        engine.connect(state.eq, to: state.delay, format: format)
        engine.connect(state.delay, to: engine.mainMixerNode, format: format)
        state.isConnected = true
    }

    /// **The master path: `mainMixerNode → limiter → masterMixer → output`.**
    ///
    /// Two decisions are written into that order, and both are about where the
    /// user's volume sits relative to the limiter.
    ///
    /// *The limiter sees the sum at unity.* `mainMixerNode.outputVolume` used
    /// to be the user's volume; it is pinned at 1 here and the volume moves to
    /// `masterMixer`. That is what makes the limiter's behaviour a property of
    /// the **mix** rather than of the listening level: a gain in front of it
    /// would mean a hand-over limits at full volume and does not at half, i.e.
    /// the transition would sound *different* depending on where the slider is.
    /// Nobody can A/B a seam whose dynamics move with the volume.
    ///
    /// *The ceiling is the last word.* Everything downstream of the limiter is
    /// a cut — the user's 0…1 volume, and the fixed −1 dB half of the ceiling
    /// pair (`DeckChain.masterCeilingTrimGain`) — so the −1 dBFS the limiter
    /// enforces is an upper bound on what leaves the engine, at every setting.
    /// Folding the master gain *into* the limiter's output stage would have
    /// done as well; a mixer does it with a node that already exists and that
    /// the output tap can sit on.
    ///
    /// Connected with `nil` formats deliberately: the mixer sum has always
    /// been rendered at the output device's format, and naming `graphFormat`
    /// here would move the sample-rate conversion from `mainMixerNode` to
    /// `masterMixer` for no reason at all.
    ///
    /// Re-run by `rebuildGraphLocked`, because a configuration change can drop
    /// `mainMixerNode`'s own connection to the output node and quietly restore
    /// the pre-limiter topology underneath us.
    private func connectMasterChainLocked() {
        engine.mainMixerNode.outputVolume = 1
        engine.connect(engine.mainMixerNode, to: masterLimiter, format: nil)
        engine.connect(masterLimiter, to: masterMixer, format: nil)
        engine.connect(masterMixer, to: engine.outputNode, format: nil)
        masterLimiter.bypass = !masterLimiterActive
        applyMasterVolumeLocked()
        journalMasterTopologyLocked("masterChain")
    }

    /// The panel's "capture now": the master-path state and eight seconds of
    /// what is leaving the engine, for the moment a listener hears something
    /// the scheduled captures did not cover — plus every playing deck's chain,
    /// stage by stage, so a signal that leaves the engine wrong can be blamed
    /// on the node that made it wrong rather than on "the deck".
    func captureOutputNow() {
        queue.async {
            self.journalAudioUnitReadbackLocked("manual")
            self.captureOutputTapLocked(seconds: 8, label: "manual")
            for (deck, state) in self.deckStates where state.isPlaying {
                self.captureDeckChainLocked(deck, seconds: 4)
            }
        }
    }

    /// One short tap on each node of a deck's chain at once — player,
    /// time-pitch, EQ, delay — written to four files with the same stamp.
    ///
    /// The output tap answers "is what leaves the engine right?"; this answers
    /// "which unit was the first to make it wrong?". A field capture that was
    /// bass-only and near-mono while every parameter read back neutral could
    /// not be attributed to a unit from the outside; four files of the same
    /// four seconds can. One tap per bus is the rule, and none of these nodes
    /// carries one otherwise; the taps are removed from the engine queue once
    /// each has its frames.
    private func captureDeckChainLocked(_ deck: Deck, seconds: Double) {
        guard engine.isRunning, let state = deckStates[deck] else { return }
        let stages: [(String, AVAudioNode)] = [
            ("player", state.player), ("timePitch", state.timePitch),
            ("eq", state.eq), ("delay", state.delay),
        ]
        let (dir, stamp) = Self.tapCaptureDirectoryAndStamp()
        var opened: [(String, URL)] = []
        let pending = ChainCaptureSet()
        for (stage, node) in stages {
            let format = node.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else { continue }
            let url = dir.appendingPathComponent("\(stamp)-chain-\(deck.rawValue)-\(stage).caf")
            guard let file = try? AVAudioFile(forWriting: url,
                                              settings: Self.captureFileSettings(format),
                                              commonFormat: .pcmFormatFloat32,
                                              interleaved: true) else { continue }
            let want = AVAudioFramePosition(seconds * format.sampleRate)
            pending.add(stage, url: url)
            opened.append((stage, url))
            let capture = NodeCapture(file: file, want: want) { [weak self] in
                // On this capture's writer queue: the tap block did nothing
                // but copy, and reading four files back is far too slow to do
                // on either the tap thread or the engine queue.
                self?.queue.async { node.removeTap(onBus: 0) }
                // The last writer queue to finish carries the summary, and it
                // is not necessarily the last stage opened — so the set hands
                // back every file rather than the closure capturing a list
                // that was still growing when it was made.
                guard let files = pending.finish(stage) else { return }
                Self.tapAnalysisQueue.async {
                    // All four are on disk: one line, the stages in chain order.
                    // The timePitch stage carries one extra number, because a
                    // corrupt phase vocoder passes every per-stage test (see
                    // `ChainCoherence`): how well its output still correlates
                    // with the player's, which is its own input.
                    let coherence = Self.playerToTimePitchCoherence(files)
                    let summary = files.map { stage, url in
                        var stats = Self.chainStageSummary(of: url)
                        if stage == "timePitch", let coherence {
                            stats += String(format: " coh=%.2f", coherence)
                        }
                        return "\(stage): \(stats)"
                    }.joined(separator: " | ")
                    self?.queue.async {
                        PlaybackJournal.note(
                            "deck chain captured deck=\(deck.rawValue) \(stamp) \(summary)")
                    }
                }
            }
            node.installTap(onBus: 0, bufferSize: 1024, format: nil) { [capture] buffer, _ in
                capture.tee(buffer)
            }
        }
        if opened.isEmpty { return }
        PlaybackJournal.note("deck chain capture started deck=\(deck.rawValue) "
            + "stages=\(opened.map(\.0).joined(separator: ","))")
    }

    /// A tap-side file writer for one node: writes until it has its frames,
    /// then reports done exactly once.
    /// A tap-side file writer for one node: writes until it has its frames,
    /// then reports done exactly once — from its **writer queue**, never from
    /// the tap block. Same rule and same reason as `TapCapture`: work inside a
    /// tap block is time `AVAudioPlayerNode.stop()` spends blocked on another
    /// node of the same engine, and a chain capture is taken while a hand-over
    /// may be arming.
    final class NodeCapture: @unchecked Sendable {
        private let lock = NSLock()
        private let file: AVAudioFile
        private let done: @Sendable () -> Void
        private let writerQueue = DispatchQueue(label: "app.kumone.chain-writer",
                                                qos: .utility)
        private var ledger: TapWriteLedger
        private var scratch: AVAudioPCMBuffer?

        init(file: AVAudioFile, want: AVAudioFramePosition,
             done: @escaping @Sendable () -> Void) {
            self.file = file
            self.ledger = TapWriteLedger(want: Int64(want))
            self.done = done
        }

        /// From the tap block: copy and enqueue, nothing else.
        func tee(_ buffer: AVAudioPCMBuffer) {
            lock.lock()
            let finished = ledger.isComplete
            lock.unlock()
            guard !finished, buffer.frameLength > 0,
                  let copy = TapCapture.copy(buffer) else { return }
            // Strong: the capture must outlive the tap that is being removed
            // around the same instant, or the buffer that completes it — and
            // therefore `done` — could be dropped.
            writerQueue.async { self.drain(copy) }
        }

        private func drain(_ buffer: AVAudioPCMBuffer) {
            lock.lock()
            let complete = ledger.accept(frames: Int64(buffer.frameLength),
                                         hostTime: nil)
            lock.unlock()
            TapCapture.write(buffer, to: file, scratch: &scratch)
            guard complete else { return }
            scratch = nil
            done()
        }
    }

    /// Which stages of a chain capture are still writing.
    final class ChainCaptureSet: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining = Set<String>()
        private var files: [(String, URL)] = []
        func add(_ stage: String, url: URL) {
            lock.lock(); remaining.insert(stage); files.append((stage, url)); lock.unlock()
        }
        /// Every stage's file when this was the last one outstanding, nil
        /// otherwise — the caller that gets the list is the one that writes
        /// the summary line, whichever writer queue it happens to be on.
        func finish(_ stage: String) -> [(String, URL)]? {
            lock.lock(); defer { lock.unlock() }
            remaining.remove(stage)
            return remaining.isEmpty ? files : nil
        }
    }

    /// Level and *shape* of one stage's capture: RMS, and how much of the
    /// energy sits above ~300 Hz (`hi/lo`), which is the one number that
    /// separates "bass only" from "music" without a reference file — a
    /// normal body reads around −5…+5 dB, the field's underwater deck read
    /// about −25 dB.
    private static func chainStageSummary(of url: URL) -> String {
        guard let file = try? AVAudioFile(forReading: url),
              let channels = readChannels(from: file), let x = channels.first,
              let rms = LoudnessMeter.rmsDBFS(x) else { return "?" }
        let sr = file.processingFormat.sampleRate
        // One-pole split at ~300 Hz: low = smoothed, high = the rest.
        let alpha = Float(1 - exp(-2 * Double.pi * 300 / sr))
        var low: Float = 0, eLow: Double = 0, eHigh: Double = 0
        for v in x {
            low += alpha * (v - low)
            eLow += Double(low * low)
            eHigh += Double((v - low) * (v - low))
        }
        let ratio = 10 * log10(max(eHigh, 1e-30) / max(eLow, 1e-30))
        let stereo: String
        if channels.count > 1 {
            let y = channels[1]
            var dot: Float = 0, xx: Float = 0, yy: Float = 0
            vDSP_dotpr(x, 1, y, 1, &dot, vDSP_Length(x.count))
            vDSP_svesq(x, 1, &xx, vDSP_Length(x.count))
            vDSP_svesq(y, 1, &yy, vDSP_Length(y.count))
            stereo = String(format: " L/R=%.2f", dot / max(sqrt(xx * yy), 1e-9))
        } else {
            stereo = ""
        }
        return String(format: "rms=%.1fdBFS hi/lo=%+.1fdB%@", rms, ratio, stereo)
    }

    /// The user's volume and the ceiling's compensation, in the one write.
    ///
    /// The −1 dB comes off **only while the limiter is on**: bypassed, the
    /// +1 dB `PreGain` inside the AU is bypassed with it, and keeping the trim
    /// would quietly take a dB off the whole library in the regime that is
    /// supposed to be the old behaviour exactly.
    private func applyMasterVolumeLocked() {
        masterMixer.outputVolume = masterLimiterActive
            ? userOutputVolume * DeckChain.masterCeilingTrimGain
            : userOutputVolume
    }

    /// Turn the master limiter on or off (`AutoMixOverrides.enableMasterLimiter`).
    ///
    /// Bypass, not surgery: the node stays wired (see `masterLimiter`), so this
    /// is safe under a running graph and mid-song. What it costs when it moves
    /// is a step of at most 1 dB on the master — the ceiling compensation going
    /// on or off — which is why it is a debug override written between songs
    /// and not something automation touches.
    func setMasterLimiter(_ enabled: Bool) {
        queue.async {
            guard self.masterLimiterActive != enabled else { return }
            self.masterLimiterActive = enabled
            self.masterLimiter.bypass = !enabled
            self.applyMasterVolumeLocked()
            PlaybackJournal.note(String(
                format: "master limiter %@ ceiling=%+.1fdBFS attack=%.1fms decay=%.1fms "
                    + "preGain=%+.1fdB latency=%.2fms",
                enabled ? "on" : "off", DeckChain.masterCeilingDBFS,
                DeckChain.masterLimiterAttackSeconds * 1000,
                DeckChain.masterLimiterDecaySeconds * 1000,
                -DeckChain.masterCeilingDBFS,
                self.masterLimiter.auAudioUnit.latency * 1000))
        }
    }

    /// **Pin the head compensation**, overriding the self-calibrating estimate
    /// (`AutoMixOverrides.headLatencyCompensationMS`). Nil hands the seam back
    /// to what the machine has measured.
    ///
    /// Its own engine call rather than a read of the debug model, for the same
    /// reason `setMasterLimiter` is: the engine has no business knowing the
    /// panel exists, and a value pushed at it can be logged at the moment it
    /// changes rather than sampled at some later arm.
    private var headLatencyPinMS: Double?

    func setHeadLatencyPin(_ milliseconds: Double?) {
        queue.async {
            guard self.headLatencyPinMS != milliseconds else { return }
            self.headLatencyPinMS = milliseconds
            PlaybackJournal.note(milliseconds.map {
                String(format: "head latency pinned=%+.1fms", $0)
            } ?? String(format: "head latency unpinned, calibration=%+.1fms",
                        SeamLatencyStore.shared.current.calibration.headMilliseconds))
        }
    }

    /// **The one place a deck's node is released on the host clock.** Every
    /// `play(at:)` in the engine goes through here so that the intended start
    /// is *written down* rather than handed to CoreAudio and forgotten.
    ///
    /// The field incident that asked for this: a `.file` deck released at the
    /// segment's hand-back whose playhead then sat at its start offset for
    /// twenty-two seconds. Nothing we had recorded could say whether the node
    /// had been started late or whether the clock query was failing — both look
    /// exactly the same from `livePositionLocked`. The stored host time turns
    /// that into an arithmetic question the watchdog can answer.
    private func playOnHostClockLocked(_ state: DeckState, at time: AVAudioTime,
                                       from position: TimeInterval,
                                       _ reason: TraceReason) {
        let now = mach_absolute_time()
        let lead = time.isHostTimeValid
            ? Self.hostLeadSeconds(from: now, to: time.hostTime)
            : 0
        state.scheduledStartHostTime = time.isHostTimeValid ? time.hostTime : nil
        state.startCheck = time.isHostTimeValid
            ? DeckState.PendingStartCheck(requestedAt: now, scheduled: time.hostTime,
                                          reason: reason)
            : nil
        state.stallRestarted = false
        trace.record(.play, state.traceDeck, reason, position, lead)
        // Host time only. Every release here was computed on *another* node's
        // clock (`nodeTime(forPlayerTime:)` of the deck or segment being handed
        // from), and `play(at:)` prefers a valid sample time over the host time
        // — but player nodes do not share a sample timeline: a node that has
        // been stopped and restarted counts from its own origin. Handing the
        // sample time across put the splice tail 0.88 s late on one seam and
        // 22 s late on another (`deck START ERROR … error=+876.6ms`), while
        // the one path that already stripped to host time (the rate-corrected
        // segment arm) measured 0.0 ms every time.
        let release = time.isHostTimeValid ? AVAudioTime(hostTime: time.hostTime) : time
        // See `startNodeIfNeededLocked` for the exception. A release on the
        // host clock cannot be retried at the same instant, so fall back to a
        // plain start: late beats a crash, and the start check journals it.
        if let exception = KumoneCatchException({ state.player.play(at: release) }) {
            PlaybackJournal.note("deck host-clock start raised deck=\(journalDeckName(state)) "
                + "(\(exception.reason ?? exception.name.rawValue)); starting unscheduled")
            state.hostScheduledStart = false
            state.scheduledStartHostTime = nil
            state.startCheck = nil
            startNodeIfNeededLocked(state)
        }
    }

    /// **Did the node start when we told it to?** — the measurement every
    /// host-clock release now owes the journal.
    ///
    /// Driven from the engine's existing ticks rather than a timer of its own
    /// (the transition tick at 50 Hz through a seam, the keepalive clock at
    /// 2 Hz, the watchdog at 0.5 Hz), so the answer lands within a tick of
    /// `settleDelay` while a hand-over is running and still arrives for an
    /// ordinary gapless arm with no transition on the books.
    ///
    /// The check identifies its release by host time, not by a flag: a deck
    /// re-cued between the `play(at:)` and the tick has had
    /// `scheduledStartHostTime` cleared or replaced by whichever path took it
    /// over, and a start that never happened must not be measured as if it had.
    /// That makes every re-cue site clear this without knowing it exists.
    private func checkStartErrorsLocked() {
        guard trace.isEnabled else { return }
        let now = mach_absolute_time()
        for state in deckStates.values { checkStartErrorLocked(state, now: now) }
        checkStartErrorLocked(segmentState, now: now)
    }

    private func checkStartErrorLocked(_ state: DeckState, now: UInt64) {
        guard let check = state.startCheck else { return }
        guard state.scheduledStartHostTime == check.scheduled else {
            // Re-cued out from under us; there is no start left to measure.
            state.startCheck = nil
            return
        }
        let ticks = Self.hostTicksPerSecond
        guard PlaybackStartErrorCheck.isDue(now: now, scheduled: check.scheduled,
                                            ticksPerSecond: ticks) else { return }
        let measured = Self.renderedNodeTime(state.player).flatMap { nodeTime in
            state.player.playerTime(forNodeTime: nodeTime).flatMap { playerTime in
                PlaybackStartErrorCheck.measure(
                    requestedAt: check.requestedAt, scheduled: check.scheduled,
                    renderHostTime: nodeTime.hostTime,
                    playerSampleTime: playerTime.sampleTime,
                    sampleRate: playerTime.sampleRate, ticksPerSecond: ticks)
            }
        }
        guard let measured else {
            // One nil is ordinary — the node may not have rendered yet. A nil
            // that outlives a tick is the finding, and gets said out loud.
            guard check.attempts > 0 else {
                state.startCheck?.attempts = check.attempts + 1
                return
            }
            state.startCheck = nil
            PlaybackJournal.note(PlaybackStartErrorCheck.unmeasuredLine(
                deck: state.traceDeck.name, reason: check.reason.rawValue,
                scheduledLead: PlaybackStartErrorCheck.signedSeconds(
                    from: check.requestedAt, to: check.scheduled, ticksPerSecond: ticks)))
            return
        }
        state.startCheck = nil
        trace.record(.startError, state.traceDeck, check.reason,
                     measured.errorMilliseconds, measured.scheduledLead, measured.actualLead)
        PlaybackJournal.note(PlaybackStartErrorCheck.line(
            deck: state.traceDeck.name, reason: check.reason.rawValue, measured))
    }

    /// Host clock ticks per second, read once. `mach_timebase_info` does not
    /// change while the machine is up, and this is on a 50 Hz path.
    private static let hostTicksPerSecond = Double(AVAudioTime.hostTime(forSeconds: 1))

    /// Signed seconds from `now` to `host`. Host times are unsigned and the
    /// interesting case here is a start that is already in the past, so the
    /// subtraction has to be done in the right order and the sign put back by
    /// hand — `&-` on a past instant wraps to roughly three hundred years.
    private static func hostLeadSeconds(from now: UInt64, to host: UInt64) -> Double {
        host >= now
            ? AVAudioTime.seconds(forHostTime: host &- now)
            : -AVAudioTime.seconds(forHostTime: now &- host)
    }

    private func startNodeIfNeededLocked(_ state: DeckState, attempt: Int = 0) {
        guard !state.hostScheduledStart else { return }
        guard state.isPlaying, !isPaused, state.isConnected, engine.isRunning else { return }
        guard !state.player.isPlaying else { return }
        trace.record(.play, state.traceDeck, .play, state.lastKnownPosition)
        // `play()` can raise "player did not see an IO cycle" — an NSException,
        // so uncaught a crash — in a window after the engine (re)starts that no
        // public property reveals: `isRunning` and every render time already
        // read valid (seen on CI with two engines starting at once; the same
        // window follows a restart after a device switch). Catch it and try
        // again shortly; every guard above is re-checked on retry.
        guard let exception = KumoneCatchException({ state.player.play() }) else { return }
        if attempt < Self.playRetries {
            queue.asyncAfter(deadline: .now() + Self.playRetryInterval) { [weak self] in
                self?.startNodeIfNeededLocked(state, attempt: attempt + 1)
            }
        } else {
            PlaybackJournal.note("deck start failed deck=\(journalDeckName(state)) "
                + "after \(attempt + 1) tries: \(exception.reason ?? exception.name.rawValue)")
        }
    }
    private static let playRetries = 40
    private static let playRetryInterval: TimeInterval = 0.025

    /// Every effect parameter back to transparent. The single place that
    /// knows the neutral pose of a deck's chain — every transition exit path
    /// (completed / cancelled / interrupted) must reach it, because decks are
    /// reused and a stuck high-pass or delay would poison the next track.
    ///
    /// Deliberately does NOT touch the fader: raising a deck's gain while its
    /// chain may still be sounding is what `resetDeckLocked` exists to avoid.
    private func neutralizeEffectsLocked(_ state: DeckState) {
        // The rate before the snap, because this is the one call that *silently
        // fixes* a stuck bend — a journal that only showed the after would make
        // the bug look like it never happened.
        if abs(state.timePitch.rate - 1) > 0.001 {
            PlaybackJournal.note(String(
                format: "deck neutralize deck=%@ rate=×%.4f → ×1.0000 pad=%+.2fdB eq=%@",
                journalDeckName(state), state.timePitch.rate, state.ratePadDB,
                journalEQ(state)))
        }
        traceRateLocked(state, 1, .deckReset)
        if DeckChain.neutralize(timePitch: state.timePitch, eq: state.eq,
                                delay: state.delay) {
            traceBypassLocked(state, .deckReset)
        }
        resetChainDSPLocked(state, .deckReset)
    }

    /// **Clear the effect chain's internal DSP state**, which neutralizing its
    /// parameters does not.
    ///
    /// See `DeckChain.shouldResetDSPState` for the field incident: a
    /// `AVAudioUnitTimePitch` whose phase-vocoder state went bad across a
    /// mid-glide stop and came back "underwater" on the next pre-roll, with
    /// every parameter reading correct. `AVAudioNode.reset()` is the only call
    /// that touches that state, and nothing in the engine used to make it.
    ///
    /// All three units, not just the one that broke: an EQ's filter memory and
    /// a delay line still holding the last track's echo are the same class of
    /// leak into the next track, and the deck is silent here so none of it
    /// costs anything. The predicate is what keeps it silent — a sounding deck
    /// (including one deliberately ringing an `.echoOut` tail) is never reset.
    private func resetChainDSPLocked(_ state: DeckState, _ by: TraceReason,
                                     keepingEchoTail: Bool = false) {
        guard DeckChain.shouldResetDSPState(playerIsPlaying: state.player.isPlaying,
                                            keepingEchoTail: keepingEchoTail) else { return }
        trace.record(.neutralize, state.traceDeck, .auReset, Double(state.timePitch.rate))
        state.timePitch.reset()
        state.eq.reset()
        state.delay.reset()
        PlaybackJournal.note("deck AU reset deck=\(journalDeckName(state)) by=\(by.rawValue)")
    }

    /// Which deck a state belongs to, for a journal line. Linear over two
    /// entries, and only ever on a lifecycle event.
    private func journalDeckName(_ state: DeckState) -> String {
        if state === segmentState { return "segment" }
        return deckStates.first { $0.value === state }?.key.rawValue ?? "?"
    }

    // MARK: - Output tap capture (underwater hunt)

    /// Record a few seconds of the main mixer's output to a file, so a "this
    /// sounds underwater" report can be answered by comparing the *captured
    /// signal* across the muffled and recovered phases of the same song. Every
    /// parameter surface has now measured neutral while the field still hears
    /// muffle; this is the instrument that says whether the muffle exists in
    /// the graph at all (tap dull → in-graph, before the output node) or only
    /// past it (tap clean → device SRC or perception).
    ///
    /// One capture at a time; a second request while one runs is dropped —
    /// the point is a specimen, not coverage. The capture never owns a tap of
    /// its own (see `installOutputSampleSinkLocked`): it opens a file in the
    /// shared tee and the one mixer tap fills it.
    ///
    /// **Nothing heavy happens in the tap block.** While a tap block runs,
    /// `AVAudioPlayerNode.stop()` on any node of the same engine blocks until
    /// it returns — measured at 1683 ms against a 2 s tap. The old capture
    /// wrote the file, asked the file how long it was, and then ran the level
    /// analysis (integrated LUFS, oversampled true peak, comb autocorrelation:
    /// 2.4 s in the field) all on the tap thread, and a splice that armed in
    /// that window sat 1.93 s inside `stop()` and left a 1.19 s hole of exact
    /// zeros in the output. So `tee` now only copies the buffer and hands it
    /// to `writerQueue`; the writes, the bookkeeping and `done` all happen
    /// there, and `done`'s own analysis hops once more (see
    /// `captureOutputTapLocked`). The tap block allocates one buffer and
    /// enqueues it — tens of microseconds — and `teeCost` reports the worst
    /// one it has seen so a recurrence is visible on the readback line.
    final class TapCapture: @unchecked Sendable {
        struct State {
            var file: AVAudioFile?
            /// Frames wanted / written / the first buffer's host time, off the
            /// file: see `TapWriteLedger`. Render host time of the capture's
            /// **first** sample is what turns a `.caf` into a measurement —
            /// without it a window of the capture can be placed against the
            /// songs only to within however late the queue got around to
            /// opening the file, and the seam-offset search would have to be
            /// widened until it started finding the wrong bar.
            var ledger = TapWriteLedger(want: 0)
            var done: (@Sendable (AVAudioFile, UInt64?) -> Void)?

            /// Frames this capture was asked for; 0 when none is open.
            var want: AVAudioFramePosition { AVAudioFramePosition(ledger.want) }

            /// Claim the one capture slot.
            mutating func open(file: AVAudioFile, want: AVAudioFramePosition,
                               done: @escaping @Sendable (AVAudioFile, UInt64?) -> Void) {
                self.file = file
                self.ledger = TapWriteLedger(want: Int64(want))
                self.done = done
            }
        }
        private let lock = NSLock()
        private var state = State()
        /// The one place the `AVAudioFile` is written, and the only thread
        /// that touches `scratch`. Utility: nothing is waiting on a capture.
        private let writerQueue = DispatchQueue(label: "app.kumone.tap-writer",
                                                qos: .utility)
        /// Reused interleaved staging buffer, so the writer never allocates
        /// and `AVAudioFile` never has to build a converter (see `write`).
        private var scratch: AVAudioPCMBuffer?
        private var maxTeeTicks: UInt64 = 0
        private var slowTees = 0

        func withLock<T>(_ body: (inout State) -> T) -> T {
            lock.lock(); defer { lock.unlock() }
            return body(&state)
        }

        /// The worst `tee` seen since the last read, and how many ran over
        /// 2 ms. Reading clears them, so each readback line covers its own
        /// window rather than the session's high-water mark for ever.
        func takeTeeCost() -> (maxMilliseconds: Double, slow: Int) {
            lock.lock(); defer { lock.unlock() }
            let ms = Double(Self.nanoseconds(maxTeeTicks)) / 1e6
            let slow = slowTees
            maxTeeTicks = 0
            slowTees = 0
            return (ms, slow)
        }

        /// Called from the tap block: an internal audio-delivery thread. It
        /// must do **only** this — a lock, a memcpy and an enqueue — because
        /// everything it does is time another node's `stop()` may spend
        /// blocked. No file, no analysis, no callback.
        func tee(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime?) {
            let started = mach_absolute_time()
            defer { noteTee(since: started) }
            lock.lock()
            let capturing = state.file != nil
            lock.unlock()
            guard capturing, buffer.frameLength > 0,
                  let copy = Self.copy(buffer) else { return }
            let host: UInt64? = (when?.isHostTimeValid ?? false) ? when?.hostTime : nil
            writerQueue.async { [weak self] in self?.drain(copy, hostTime: host) }
        }

        /// On `writerQueue`: one buffer to disk, and the last one hands over.
        ///
        /// `done` runs here, never on the tap thread, and the state is torn
        /// down before it is called — so a capture request that arrives while
        /// the analysis runs finds the slot free.
        private func drain(_ buffer: AVAudioPCMBuffer, hostTime: UInt64?) {
            lock.lock()
            guard let file = state.file else { lock.unlock(); return }
            let complete = state.ledger.accept(frames: Int64(buffer.frameLength),
                                               hostTime: hostTime)
            lock.unlock()
            write(buffer, to: file)
            guard complete else { return }
            lock.lock()
            let done = state.done
            let start = state.ledger.startHostTime
            state = State()
            scratch = nil
            lock.unlock()
            done?(file, start)
        }

        /// A file is always interleaved on disk (`AVAudioFile` says so out
        /// loud: "Audio files cannot be non-interleaved"), and a tap buffer
        /// never is. Handing the deinterleaved buffer straight to
        /// `write(from:)` makes AVAudioFile build a converter; interleaving
        /// into a reused buffer whose format *is* the file's processing
        /// format means it builds none — measured: zero
        /// `Created a new in process converter` lines for 300 writes, against
        /// one plus a per-write conversion path before.
        private func write(_ buffer: AVAudioPCMBuffer, to file: AVAudioFile) {
            Self.write(buffer, to: file, scratch: &scratch)
        }

        /// The shared writer, so the chain captures interleave the same way.
        /// `scratch` belongs to the calling writer queue and nothing else.
        static func write(_ buffer: AVAudioPCMBuffer, to file: AVAudioFile,
                          scratch: inout AVAudioPCMBuffer?) {
            let format = file.processingFormat
            let channels = Int(format.channelCount)
            guard format.isInterleaved, format.commonFormat == .pcmFormatFloat32,
                  Int(buffer.format.channelCount) == channels,
                  !buffer.format.isInterleaved, let source = buffer.floatChannelData
            else { try? file.write(from: buffer); return }
            if scratch == nil || scratch!.frameCapacity < buffer.frameLength {
                scratch = AVAudioPCMBuffer(pcmFormat: format,
                                           frameCapacity: max(buffer.frameLength, 4096))
            }
            guard let out = scratch, let destination = out.floatChannelData?[0] else {
                try? file.write(from: buffer); return
            }
            out.frameLength = buffer.frameLength
            let frames = Int32(buffer.frameLength)
            for channel in 0..<channels {
                cblas_scopy(frames, source[channel], 1,
                            destination + channel, Int32(channels))
            }
            try? file.write(from: out)
        }

        /// A fresh buffer with the same frames. The tap's buffer is only
        /// valid for the duration of the block, so the writer needs its own.
        static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
            guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                              frameCapacity: buffer.frameLength),
                  let source = buffer.floatChannelData,
                  let destination = copy.floatChannelData else { return nil }
            copy.frameLength = buffer.frameLength
            let interleaved = buffer.format.isInterleaved
            let planes = interleaved ? 1 : Int(buffer.format.channelCount)
            let perPlane = Int(buffer.frameLength) * MemoryLayout<Float>.size
                * (interleaved ? Int(buffer.format.channelCount) : 1)
            for plane in 0..<planes {
                memcpy(destination[plane], source[plane], perPlane)
            }
            return copy
        }

        private func noteTee(since started: UInt64) {
            let ticks = mach_absolute_time() &- started
            lock.lock()
            if ticks > maxTeeTicks { maxTeeTicks = ticks }
            if Self.nanoseconds(ticks) > 2_000_000 { slowTees += 1 }
            lock.unlock()
        }

        private nonisolated(unsafe) static var timebase: mach_timebase_info_data_t = {
            var info = mach_timebase_info_data_t()
            mach_timebase_info(&info)
            return info
        }()

        static func nanoseconds(_ ticks: UInt64) -> UInt64 {
            ticks &* UInt64(timebase.numer) / UInt64(max(timebase.denom, 1))
        }
    }
    private let tapCapture = TapCapture()
    private var mixerTapInstalled = false

    /// Where a finished capture is *read back* — integrated LUFS, oversampled
    /// true peak, the chain-stage summaries. Seconds of work per capture, and
    /// the one thing it must never share a thread with is either a tap block
    /// or a writer queue that still has buffers coming. Utility, because
    /// nothing is waiting: the answer is a journal line.
    static let tapAnalysisQueue = DispatchQueue(label: "app.kumone.tap-analysis",
                                                qos: .utility)

    /// File settings for a capture, from the node's format.
    ///
    /// Explicitly **interleaved**: an audio file always is (AVAudioFile says
    /// so on every open — "Audio files cannot be non-interleaved. Ignoring
    /// setting AVLinearPCMIsNonInterleaved YES"), and carrying the node's
    /// deinterleaved flag into the settings only bought a converter between
    /// the processing format and the file. The captures are opened with an
    /// interleaved processing format to match, and the writer interleaves.
    static func captureFileSettings(_ format: AVAudioFormat) -> [String: Any] {
        var settings = format.settings
        settings[AVFormatIDKey] = kAudioFormatLinearPCM
        settings[AVLinearPCMIsNonInterleaved] = false
        return settings
    }

    /// The taps folder and one ISO-8601 stamp for a capture. Separate from
    /// `tapCaptureURL` because a chain capture writes four files that must
    /// share a prefix (and puts the stamp in its journal line), so it takes
    /// the stamp once and spells the names itself.
    ///
    /// The colons come out: they are legal in a POSIX name but read as path
    /// separators to anything that still thinks in HFS paths.
    private static func tapCaptureDirectoryAndStamp() -> (dir: URL, stamp: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        return (KumoneDirectories.applicationSupport("taps"), stamp)
    }

    /// `~/Library/Application Support/Kumone/taps/<stamp>-<label>.caf`.
    private static func tapCaptureURL(label: String) -> URL {
        let (dir, stamp) = tapCaptureDirectoryAndStamp()
        return dir.appendingPathComponent("\(stamp)-\(label).caf")
    }

    /// Where the one output tap lives. `masterMixer`, not `mainMixerNode`:
    /// see `setOutputSampleSink`.
    private var outputTapNode: AVAudioNode { masterMixer }

    func captureOutputTap(seconds: Double, label: String) {
        queue.async { self.captureOutputTapLocked(seconds: seconds, label: label) }
    }

    /// Returns whether a capture was actually opened — false for a graph that
    /// is not rendering, or because one is already running. A caller that has a
    /// window rather than an instant (the splice tail, which is asked for on
    /// every 50 Hz tick until it takes) can use that to try again.
    @discardableResult
    private func captureOutputTapLocked(seconds: Double, label: String) -> Bool {
        guard engine.isRunning else { return false }
        let format = outputTapNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return false }
        let url = Self.tapCaptureURL(label: label)
        let dir = url.deletingLastPathComponent()
        guard let file = try? AVAudioFile(forWriting: url,
                                          settings: Self.captureFileSettings(format),
                                          commonFormat: .pcmFormatFloat32,
                                          interleaved: true) else { return false }
        let want = AVAudioFramePosition(seconds * format.sampleRate)
        let opened = tapCapture.withLock { state -> Bool in
            guard state.file == nil else { return false }
            state.open(file: file, want: want) { [weak self] finished, startHostTime in
                // Runs on the capture's writer queue, never on the tap thread
                // (see `TapCapture`). Reading the file back is seconds of work,
                // so it hops once more rather than holding the writer: the
                // capture slot is already free here, and the next capture's
                // buffers must not queue behind this analysis.
                let seconds = Double(finished.length) / finished.processingFormat.sampleRate
                let rate = finished.processingFormat.sampleRate
                Self.tapAnalysisQueue.async {
                    let level = Self.tapLevelDescription(of: url)
                    // Keep the newest 40 captures; the hunt needs specimens,
                    // not an archive.
                    EngineTrace.prune(dir, keeping: 40)
                    self?.queue.async {
                        // The regime goes on the same line as the numbers: a
                        // session's captures are read as a table, and "seams are
                        // 3 dB under the bodies" is only an argument about the
                        // limiter if each row says whether it was in circuit.
                        PlaybackJournal.note(String(
                            format: "output tap captured %@ (%.1fs @%.0fHz) %@ limiter=%@",
                            url.lastPathComponent, seconds, rate, level,
                            (self?.masterLimiterActive ?? false) ? "on" : "off"))
                        // The same capture, read for *where* rather than how
                        // loud. After the level line because it is the slower
                        // of the two and hops off the queue for its file work.
                        self?.measureSeamOffsetLocked(label: label, capture: url,
                                                      startHostTime: startHostTime)
                        // With no spectrum sink there is nothing left for the
                        // tap to do; the shared installer removes it then.
                        if self?.outputSampleSink == nil {
                            self?.installOutputSampleSinkLocked()
                        }
                    }
                }
            }
            return true
        }
        guard opened else {
            try? FileManager.default.removeItem(at: url)
            return false
        }
        // The tap is usually already up for the spectrum sink; this makes the
        // capture work on a build where it is not.
        if !mixerTapInstalled { installOutputSampleSinkLocked() }
        return true
    }

    /// **How loud a finished capture actually is** — the acceptance instrument
    /// for the level work, in the one place a field session can read it without
    /// having the files.
    ///
    /// The taps are already labelled by what they are (`t25-<trackid>` is a
    /// body, 25 s into a song and past every release the seam left running;
    /// `overlap` is a seam, taken at overlap begin), so a session that journals
    /// a level next to each label proves the thing the whole "underwater"
    /// complaint is about — *seam minus body*, in dB — from the journal alone.
    /// Before this, answering that needed the .caf files off the machine and an
    /// offline analysis per pair, which is why it had never been answered.
    ///
    /// Two numbers, because they answer two questions:
    ///
    ///   - `rms` is plain unweighted RMS in dBFS over the whole eight seconds.
    ///     It is the honest measure of *this signal chain's gain*: no gate, no
    ///     weighting, nothing that moves when the music changes rather than
    ///     when the faders do.
    ///   - `lufs` is the gated K-weighted figure — the same meter, the same
    ///     mono-downmix convention, that produced the `referenceLoudness` every
    ///     trim is computed from. So a body tap can be read straight against
    ///     `loudness + trim` to check the trim landed where it was asked to.
    ///
    /// Best-effort and never fatal: a capture that cannot be re-read is still a
    /// capture, and the line degrades to `level=?` rather than disappearing.
    /// Runs on the tap's delivery thread, which is an ordinary audio-delivery
    /// thread and not the render thread — the same place the file writes and
    /// the directory trim already happen.
    ///   - `peak` / `truePeak` are the **acceptance test for the master
    ///     limiter**, and the reason they are here rather than in an offline
    ///     analysis of the .caf: the tap sits on the last node before the
    ///     device (see `setOutputSampleSink`), so these are the numbers that
    ///     actually leave the engine. A session in which every seam capture
    ///     reads `peak` at or under `DeckChain.masterCeilingDBFS` is a session
    ///     in which the ceiling held while the pad was retired, which is the
    ///     whole claim. They are measured **per channel**, not on the mono
    ///     downmix the two level figures use: a downmix can hide a clip that
    ///     only one side is committing.
    ///
    ///     `truePeak` sitting a few tenths over the ceiling while `peak` sits
    ///     on it is a limiter working — a flat-topped run reconstructs above
    ///     its samples. `peak` itself over the ceiling is a limiter that is
    ///     not in circuit.
    ///
    /// The limiter's own view of the same event — how many dB of reduction it
    /// applied — is **not** available: `kAudioUnitSubType_PeakLimiter` publishes
    /// attack, decay and pre-gain and no metering parameter, so there is no
    /// gain-reduction figure to journal (see `DeckChain.makeMasterLimiter`).
    /// The captured peak answers the question from the other end.
    static func tapLevelDescription(of url: URL) -> String {
        guard let file = try? AVAudioFile(forReading: url),
              let channels = readChannels(from: file), !channels.isEmpty else {
            return "level=?"
        }
        let mono = LoudnessMeter.monoDownmix(channels)
        guard !mono.isEmpty, let rms = LoudnessMeter.rmsDBFS(mono) else { return "level=?" }
        let lufs = LoudnessMeter.integratedLUFS(
            mono, sampleRate: file.processingFormat.sampleRate)
        let weighted = lufs.map { String(format: "%.1f", $0) } ?? "?"
        let peak = channels.compactMap { LoudnessMeter.peakDBFS($0) }.max()
        let truePeak = channels.compactMap { LoudnessMeter.truePeakDBTP($0) }.max()
        // Doubling detector: see `LoudnessMeter.combPeak`. Above ~0.3 the
        // capture is the same audio twice, and the delay says which two paths.
        let comb = LoudnessMeter.combPeak(channels[0],
                                          sampleRate: file.processingFormat.sampleRate)
        return String(format: "rms=%.1fdBFS lufs=%@ peak=%@dBFS truePeak=%@dBTP comb=%@",
                      rms, weighted,
                      peak.map { String(format: "%.1f", $0) } ?? "?",
                      truePeak.map { String(format: "%.1f", $0) } ?? "?",
                      comb.map { String(format: "%.2f@%.2fms", $0.value, $0.delayMilliseconds) } ?? "?")
    }

    /// **The one-number verdict on a chain capture**: peak normalized
    /// cross-correlation between the player stage and the timePitch stage,
    /// mono-summed, over ±2048 samples of lag.
    ///
    /// Healthy the number is ≈1 — the unit is passing the player's music
    /// through, whatever it did to the timebase. The field's underwater deck
    /// read below 0.2 at every lag while its RMS, its hi/lo balance and its
    /// L/R correlation all looked perfectly ordinary. Nil when either capture
    /// is missing, too short or silent.
    private static func playerToTimePitchCoherence(_ files: [(String, URL)]) -> Float? {
        func mono(_ stage: String) -> [Float]? {
            guard let url = files.first(where: { $0.0 == stage })?.1,
                  let file = try? AVAudioFile(forReading: url),
                  let channels = readChannels(from: file) else { return nil }
            let summed = ChainCoherence.monoSum(channels)
            return summed.isEmpty ? nil : summed
        }
        guard let player = mono("player"), let timePitch = mono("timePitch") else { return nil }
        return ChainCoherence.peakCorrelation(player, timePitch)
    }

    /// The whole of a (short, known-length) capture, one array per channel.
    private static func readChannels(from file: AVAudioFile) -> [[Float]]? {
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: frames),
              (try? file.read(into: buffer)) != nil,
              let data = buffer.floatChannelData else { return nil }
        let length = Int(buffer.frameLength)
        guard length > 0 else { return nil }
        return (0..<Int(buffer.format.channelCount)).map {
            Array(UnsafeBufferPointer(start: data[$0], count: length))
        }
    }

    // MARK: - Seam offset (is the identity crossfade an identity?)

    /// Everything a finished head/tail capture needs to say where its two
    /// windows sit on the two songs — kept on the engine rather than on the
    /// `TransitionState`, because the tail's six seconds outlive the transition
    /// that asked for them: the segment ends half a second after the hand-back
    /// and `finishSegmentLocked` clears `transition` there, while the capture
    /// runs on for another four.
    private struct SeamOffsetContext {
        var segment: TransitionSegment
        /// Nil for a deck fed by a stream, which has no file to correlate
        /// against; the measurement then reports `unmeasured(stream)` rather
        /// than quietly not happening.
        var outgoingURL: URL?
        var incomingURL: URL?
        /// Host time the outgoing deck's **player clock** reaches `spliceStart`.
        var deckSpliceHost: UInt64
        /// Host time the segment's first sample was actually released at. The
        /// two differ by exactly the compensation, which is the whole point of
        /// storing both: the measurement stays a measurement of the *residual*
        /// once a compensation is being applied.
        var segmentStartHost: UInt64
        var deckRate: Double
        /// Head compensation applied at this arm, in milliseconds.
        var appliedMilliseconds: Double
        /// Host time the incoming deck was released at, filled in by the tail.
        var tailStartHost: UInt64?
    }
    private var seamOffsetContext: SeamOffsetContext?

    /// Off the engine queue: two 0.3 s windows out of a `.caf` and two out of a
    /// source file, plus a few million multiply-accumulates. Utility QoS
    /// because nothing is waiting for it — the answer is a journal line and a
    /// panel row, both of which can arrive a second late.
    private let seamOffsetQueue = DispatchQueue(label: "app.kumone.seam-offset",
                                                qos: .utility)

    /// The file a deck's audio can be correlated against, if it has one.
    private static func seamSourceURL(of source: DeckState.Source) -> URL? {
        switch source {
        case .file(let file): return file.url
        case .convertedFile(let feeder): return feeder.fileURL
        case .stream, .none: return nil
        }
    }

    /// Local slope of one of a segment's rendered-time → source-time maps: how
    /// many seconds of song a second of segment covers there. One for an
    /// unramped hand-over; `outgoingRate` at the head of a ramped one.
    private static func mapSlope(_ map: (TimeInterval) -> TimeInterval,
                                 at offset: TimeInterval) -> Double {
        let step = 0.05
        let low = max(0, offset - step)
        let high = offset + step
        guard high > low else { return 1 }
        let slope = (map(high) - map(low)) / (high - low)
        // A map that is missing, flat or reversed there is a map this
        // measurement cannot use; unity keeps the search honest and the
        // correlation will say if it was wrong.
        return slope.isFinite && slope > 0.5 && slope < 2 ? slope : 1
    }

    /// **Did the two copies of the identity window line up?**
    ///
    /// Called on the engine queue when a `head` or `tail` capture finishes. It
    /// only computes the two windows here — where they sit in the capture, and
    /// where the engine believed each was on its song — and hands the audio
    /// work to `seamOffsetQueue`.
    ///
    /// Every window is placed against the capture's *own* first-sample
    /// timestamp rather than against when the queue got round to opening the
    /// file, and the reported offset is the difference of the two windows'
    /// residuals, so the capture's timestamp cancels out of the answer. See
    /// `SeamAlignment`.
    private func measureSeamOffsetLocked(label: String, capture: URL,
                                         startHostTime: UInt64?) {
        guard label == "head" || label == "tail", let context = seamOffsetContext else {
            return
        }
        guard let captureHost = startHostTime else {
            noteSeamOffsetLocked(label, "unmeasured(clock)")
            return
        }
        let source = label == "head" ? context.outgoingURL : context.incomingURL
        guard let source else {
            noteSeamOffsetLocked(label, "unmeasured(stream)")
            return
        }
        guard let windows = label == "head"
                ? headWindows(context, captureHost: captureHost)
                : tailWindows(context, captureHost: captureHost)
        else { return }

        let applied = context.appliedMilliseconds
        seamOffsetQueue.async { [weak self] in
            let measured = SeamOffsetMeter.measure(
                capture: capture, source: source,
                before: windows.before, after: windows.after)
            self?.queue.async {
                guard let measured else {
                    self?.noteSeamOffsetLocked(label, "unmeasured(align)")
                    return
                }
                self?.recordSeamOffsetLocked(label: label, measured: measured,
                                             applied: applied)
            }
        }
    }

    /// The head's two windows: the live outgoing deck alone in the run-up to
    /// the splice, and the segment alone once the crossfade has closed.
    ///
    /// The first is short by construction — the arm happens at most
    /// `segmentArmLead` (0.25 s) before the segment's release — so it is taken
    /// as long as it can be and the whole measurement is refused when that is
    /// under `SeamOffsetMeter.minimumWindow`.
    private func headWindows(_ context: SeamOffsetContext, captureHost: UInt64)
        -> (before: SeamOffsetWindow, after: SeamOffsetWindow)? {
        let segment = context.segment
        let toSegment = Self.hostLeadSeconds(from: captureHost,
                                             to: context.segmentStartHost)
        // A tenth of the lead each side: the first buffer of a capture and the
        // last instant before the crossfade opens are both places where the
        // window would be measuring something other than the deck alone.
        let beforeStart = 0.01
        let beforeDuration = min(0.30, toSegment - 0.02 - beforeStart)
        guard beforeDuration >= SeamOffsetMeter.minimumWindow else {
            noteSeamOffsetLocked("head", "unmeasured(short)")
            return nil
        }
        // Seconds from the deck's splice instant to the capture's first sample —
        // negative, since the capture starts first.
        let deckOrigin = Self.hostLeadSeconds(from: context.deckSpliceHost, to: captureHost)
        let before = SeamOffsetWindow(
            captureStart: beforeStart,
            duration: beforeDuration,
            expectedSource: segment.spliceStart
                + context.deckRate * (deckOrigin + beforeStart),
            sourceRate: context.deckRate)

        // Past the identity crossfade, where the segment is the only thing
        // sounding: 0.8 s into a segment whose head window is the usual 0.5.
        let afterOffset = segment.handoffIn + 0.30
        let after = SeamOffsetWindow(
            captureStart: toSegment + afterOffset,
            duration: 0.30,
            expectedSource: segment.outgoingTime(at: afterOffset),
            sourceRate: Self.mapSlope({ segment.outgoingTime(at: $0) }, at: afterOffset))
        guard before.expectedSource > 1, after.expectedSource > 1 else {
            noteSeamOffsetLocked("head", "unmeasured(edge)")
            return nil
        }
        return (before, after)
    }

    /// The tail's, mirrored: the segment alone before the hand-back opens, the
    /// live incoming deck alone once the crossfade has closed. Both against the
    /// **incoming** track.
    private func tailWindows(_ context: SeamOffsetContext, captureHost: UInt64)
        -> (before: SeamOffsetWindow, after: SeamOffsetWindow)? {
        let segment = context.segment
        guard let tailHost = context.tailStartHost else {
            // The hand-back never went out on the render clock (the fall-back
            // in `finishSegmentLocked` started the deck instead), so there is
            // no instant to measure against.
            noteSeamOffsetLocked("tail", "unmeasured(nohandback)")
            return nil
        }
        let toTail = Self.hostLeadSeconds(from: captureHost, to: tailHost)
        let beforeEnd = toTail - 0.15
        let beforeDuration = min(0.30, beforeEnd - 0.01)
        guard beforeDuration >= SeamOffsetMeter.minimumWindow else {
            noteSeamOffsetLocked("tail", "unmeasured(short)")
            return nil
        }
        let beforeStart = beforeEnd - beforeDuration
        // Where the segment's own clock is at that point: it reaches
        // `handoffOutStart` exactly at `tailHost`.
        let beforeOffset = segment.handoffOutStart - (toTail - beforeStart)
        guard beforeOffset > 0 else {
            noteSeamOffsetLocked("tail", "unmeasured(short)")
            return nil
        }
        let before = SeamOffsetWindow(
            captureStart: beforeStart,
            duration: beforeDuration,
            expectedSource: segment.incomingTime(at: beforeOffset),
            sourceRate: Self.mapSlope({ segment.incomingTime(at: $0) }, at: beforeOffset))

        // The incoming deck is at unity here by construction — the segment
        // rendered the rate release, so the deck picks the track up unbent
        // (`finishSegmentLocked`) — hence `sourceRate` 1.
        let afterStart = toTail + segment.handoffOut + 0.20
        let after = SeamOffsetWindow(
            captureStart: afterStart,
            duration: 0.30,
            expectedSource: segment.incomingResume + (afterStart - toTail),
            sourceRate: 1)
        guard before.expectedSource > 1, after.expectedSource > 1 else {
            noteSeamOffsetLocked("tail", "unmeasured(edge)")
            return nil
        }
        return (before, after)
    }

    /// One finished measurement: journalled, mirrored for the panel, and — when
    /// both correlations clear the gate — folded into the calibration the next
    /// seam will use.
    private func recordSeamOffsetLocked(label: String, measured: SeamOffsetMeasurement,
                                        applied: Double) {
        let head = label == "head"
        // The head line carries what it was *already* compensated by, because
        // after the compensation ships the raw offset reads ~0 and a reader
        // needs to know whether that is a seam that never had a problem or a
        // seam whose problem is being held down.
        let line = head ? measured.summary + String(format: " comp=%+.1fms", applied)
                        : measured.summary
        noteSeamOffsetLocked(label, line)
        guard measured.isTrusted else { return }
        if head {
            // Implied total latency, not the residual: see
            // `SeamLatencyCalibration.foldHead`.
            let implied = applied + measured.offsetMilliseconds
            let calibration = SeamLatencyStore.shared.foldHead(impliedMilliseconds: implied)
            PlaybackJournal.note(String(
                format: "head latency calibrated=%+.1fms (from %+.1fms, n=%d)",
                calibration.headMilliseconds, implied, calibration.headCount))
        } else {
            let calibration = SeamLatencyStore.shared.foldTail(
                impliedMilliseconds: measured.offsetMilliseconds)
            PlaybackJournal.note(String(
                format: "tail latency observed=%+.1fms (from %+.1fms, n=%d)%@",
                calibration.tailMilliseconds, measured.offsetMilliseconds,
                calibration.tailCount,
                abs(calibration.tailMilliseconds) > SeamLatencyCalibration.tailConcern
                    ? String(format: " outside ±%.0fms — not compensated",
                             SeamLatencyCalibration.tailConcern)
                    : ""))
        }
    }

    private func noteSeamOffsetLocked(_ label: String, _ description: String) {
        PlaybackJournal.note("seam offset \(label)=\(description)")
        if label == "head" {
            SeamLatencyStore.shared.noteHead(description)
        } else {
            SeamLatencyStore.shared.noteTail(description)
        }
    }

    /// Journal what the audio units **actually hold**, read back from the AUs
    /// themselves rather than from our bookkeeping. Every line the journal has
    /// ever written recorded intent — what some code path set — and the watery
    /// hunt has now measured every intended state transparent (rate at unity
    /// nulls at 141 dB, EQ shelves at gain 0, delay wet at 0). If the field
    /// still sounds underwater while this line says all-neutral, the fault is
    /// below the AU parameter surface; if any number here disagrees with the
    /// deck-reset lines, that number is the bug.
    func journalAudioUnitReadback(_ context: String) {
        queue.async { self.journalAudioUnitReadbackLocked(context) }
    }

    private func journalAudioUnitReadbackLocked(_ context: String) {
        for (deck, state) in deckStates.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let eqDesc = state.eq.bands.map { b in
                String(format: "%@%@%.0f%+.1f",
                       b.bypass ? "·" : "", Self.filterTypeTag(b.filterType),
                       b.frequency, b.gain)
            }.joined(separator: " ")
            let sourceTag: String
            switch state.source {
            case .none: sourceTag = "none"
            case .file: sourceTag = "file"
            case .convertedFile: sourceTag = "feeder"
            case .stream: sourceTag = "stream"
            }
            PlaybackJournal.note(String(
                format: "AU readback(%@) deck=%@ src=%@ rate=×%.4f pitch=%+.0f¢ "
                    + "overlap=%.1f tp=%@ eq[%@] delay wet=%.1f%% fb=%.1f%% t=%.3fs lp=%.0fHz "
                    + "vol=%.3f (req=%.2f trim=%.3f ride=%.3f pad=%.3f) playing=%@",
                context, deck.rawValue, sourceTag,
                state.timePitch.rate, state.timePitch.pitch, state.timePitch.overlap,
                // Bypassed is the *neutral* pose here, not a fault: the unit is
                // only engaged while a deck is bent (`DeckChain.syncBypass`).
                // `on` on a deck reading ×1.0000 is the stuck state to hunt.
                state.timePitch.bypass ? "byp" : "on",
                eqDesc,
                state.delay.wetDryMix, state.delay.feedback, state.delay.delayTime,
                state.delay.lowPassCutoff,
                state.player.volume, state.faderRequest, state.trim, state.ride,
                state.ratePad, state.isPlaying ? "yes" : "no"))
            // The same units read *through AudioToolbox*, not through the
            // AVFoundation mirrors the line above prints. A mirror that says
            // "flat" while the AU is cutting is exactly the case the line above
            // cannot see; this one puts the two side by side.
            PlaybackJournal.note("AU readback(\(context)) truth deck=\(deck.rawValue) "
                + Self.audioUnitTruth(state))
        }
        let mixer = engine.mainMixerNode
        PlaybackJournal.note(String(
            format: "AU readback(%@) graph mixer out=%.0fHz output in=%.0fHz "
                + "out=%.0fHz vol=%.3f",
            context,
            mixer.outputFormat(forBus: 0).sampleRate,
            engine.outputNode.inputFormat(forBus: 0).sampleRate,
            engine.outputNode.outputFormat(forBus: 0).sampleRate,
            mixer.outputVolume))
        // The master path, read off the AU rather than off our constants — a
        // parameter the unit declined (see `DeckChain.configureMasterLimiter`)
        // is invisible any other way, and would be the whole explanation for a
        // ceiling that did not hold.
        let limiter = DeckChain.masterLimiterReadback(masterLimiter)
        // `tapMax` is the guard on the bug this file's capture path was
        // rebuilt for: everything a tap block does is time another node's
        // `stop()` can spend blocked, so the worst `tee` since the last
        // readback rides along with the master numbers. Tens of microseconds
        // is the copy-and-enqueue it should be; milliseconds means something
        // heavy has crept back in, and `slowTee` counts those over 2 ms.
        let tap = tapCapture.takeTeeCost()
        PlaybackJournal.note(String(
            format: "AU readback(%@) master limiter=%@ ceiling=%+.1fdBFS attack=%.2fms "
                + "decay=%.2fms preGain=%+.2fdB latency=%.2fms out=%.0fHz "
                + "vol=%.3f (user=%.3f) overloads=%d tapMax=%.2fms slowTee=%d",
            context, masterLimiterActive ? "on" : "bypassed", DeckChain.masterCeilingDBFS,
            limiter.attack * 1000, limiter.decay * 1000, limiter.preGain,
            masterLimiter.auAudioUnit.latency * 1000,
            masterMixer.outputFormat(forBus: 0).sampleRate,
            masterMixer.outputVolume, userOutputVolume, overloadCount,
            tap.maxMilliseconds, tap.slow))
        journalMasterTopologyLocked(context)
    }

    /// The master path as the engine actually has it wired, not as we
    /// connected it: every node's output format and where its output goes,
    /// and what each input bus of the two mixers is fed by. A configuration
    /// change rebuilds this part of the graph, and a stray second route from
    /// the sum to the output (the same audio twice, a fraction of a
    /// millisecond apart) is inaudible to every other readback — it just
    /// sounds "underwater".
    private func journalMasterTopologyLocked(_ context: String) {
        func name(_ node: AVAudioNode?) -> String {
            guard let node else { return "nil" }
            if node === engine.mainMixerNode { return "mainMixer" }
            if node === masterLimiter { return "limiter" }
            if node === masterMixer { return "masterMixer" }
            if node === engine.outputNode { return "output" }
            if node === segmentState.player { return "segPlayer" }
            for (deck, state) in deckStates {
                if node === state.player { return "\(deck.rawValue)Player" }
                if node === state.delay { return "\(deck.rawValue)Delay" }
                if node === state.eq { return "\(deck.rawValue)EQ" }
                if node === state.timePitch { return "\(deck.rawValue)TimePitch" }
            }
            return String(describing: type(of: node))
        }
        func fmt(_ f: AVAudioFormat) -> String {
            String(format: "%.0fHz/%dch", f.sampleRate, f.channelCount)
        }
        func outs(_ node: AVAudioNode) -> String {
            let points = engine.outputConnectionPoints(for: node, outputBus: 0)
            guard !points.isEmpty else { return "(none)" }
            return points.map { "\(name($0.node)):\($0.bus)" }.joined(separator: "+")
        }
        func ins(_ mixer: AVAudioNode, limit: Int) -> String {
            var parts: [String] = []
            for bus in 0..<min(limit, mixer.numberOfInputs) {
                if let p = engine.inputConnectionPoint(for: mixer, inputBus: bus) {
                    parts.append("\(bus)=\(name(p.node))@\(fmt(mixer.inputFormat(forBus: bus)))")
                }
            }
            return parts.isEmpty ? "(none)" : parts.joined(separator: " ")
        }
        PlaybackJournal.note(String(
            format: "AU readback(%@) topology mainMixer[%@ → %@; in: %@] limiter[%@ → %@] "
                + "masterMixer[%@ → %@; in: %@] output[in %@ out %@] running=%@",
            context,
            fmt(engine.mainMixerNode.outputFormat(forBus: 0)), outs(engine.mainMixerNode),
            ins(engine.mainMixerNode, limit: 8),
            fmt(masterLimiter.outputFormat(forBus: 0)), outs(masterLimiter),
            fmt(masterMixer.outputFormat(forBus: 0)), outs(masterMixer),
            ins(masterMixer, limit: 8),
            fmt(engine.outputNode.inputFormat(forBus: 0)),
            fmt(engine.outputNode.outputFormat(forBus: 0)),
            engine.isRunning ? "yes" : "no"))
    }

    /// Every parameter of a deck's three units as the AU itself reports it.
    /// Bands print `gain/bypass/type/freq`; anything that disagrees with the
    /// AVFoundation mirror by more than a rounding error is flagged `≠`.
    private static func audioUnitTruth(_ state: DeckState) -> String {
        func param(_ unit: AVAudioUnit, _ id: AudioUnitParameterID) -> Float {
            var v: AudioUnitParameterValue = 0
            AudioUnitGetParameter(unit.audioUnit, id, kAudioUnitScope_Global, 0, &v)
            return v
        }
        var parts: [String] = []
        var bands: [String] = []
        for i in 0..<state.eq.bands.count {
            let b = AudioUnitParameterID(i)
            let gain = param(state.eq, AudioUnitParameterID(kAUNBandEQParam_Gain) + b)
            let bypass = param(state.eq, AudioUnitParameterID(kAUNBandEQParam_BypassBand) + b)
            let type = param(state.eq, AudioUnitParameterID(kAUNBandEQParam_FilterType) + b)
            let freq = param(state.eq, AudioUnitParameterID(kAUNBandEQParam_Frequency) + b)
            let mirror = state.eq.bands[i]
            let flag = (abs(gain - mirror.gain) > 0.05
                        || (bypass > 0.5) != mirror.bypass
                        || abs(freq - mirror.frequency) > 1) ? "≠" : ""
            bands.append(String(format: "%@%+.1f/%@/%.0f/%.0f", flag, gain,
                                bypass > 0.5 ? "byp" : "on", type, freq))
        }
        parts.append("eq[" + bands.joined(separator: " ") + "]")
        let wet = param(state.delay, kDelayParam_WetDryMix)
        let time = param(state.delay, kDelayParam_DelayTime)
        let fb = param(state.delay, kDelayParam_Feedback)
        let lp = param(state.delay, kDelayParam_LopassCutoff)
        let delayFlag = abs(wet - state.delay.wetDryMix) > 0.5 ? "≠" : ""
        parts.append(String(format: "delay[%@wet=%.1f%% t=%.3fs fb=%.1f%% lp=%.0fHz]",
                            delayFlag, wet, time, fb, lp))
        let rate = param(state.timePitch, kNewTimePitchParam_Rate)
        let pitch = param(state.timePitch, kNewTimePitchParam_Pitch)
        let overlap = param(state.timePitch, kNewTimePitchParam_Overlap)
        // Read off the AU, not off `AVAudioUnitTimePitch.bypass` the line above
        // prints: `shouldBypassEffect` is the flag the render actually honours,
        // and a mirror that disagrees with it is the whole bug class this
        // readback exists for.
        let bypass = state.timePitch.auAudioUnit.shouldBypassEffect
        let tpFlag = (abs(rate - state.timePitch.rate) > 0.0005
                      || bypass != state.timePitch.bypass) ? "≠" : ""
        parts.append(String(format: "timePitch[%@rate=%.4f pitch=%+.0f overlap=%.1f %@]",
                            tpFlag, rate, pitch, overlap, bypass ? "byp" : "on"))
        return parts.joined(separator: " ")
    }

    private static func filterTypeTag(_ t: AVAudioUnitEQFilterType) -> String {
        switch t {
        case .parametric: return "pk"
        case .lowPass: return "lp"
        case .highPass: return "hp"
        case .resonantLowPass: return "rlp"
        case .resonantHighPass: return "rhp"
        case .bandPass: return "bp"
        case .bandStop: return "bs"
        case .lowShelf: return "ls"
        case .highShelf: return "hs"
        case .resonantLowShelf: return "rls"
        case .resonantHighShelf: return "rhs"
        @unknown default: return "?\(t.rawValue)"
        }
    }

    /// The deck's EQ band gains for a journal line — "flat" when nothing is
    /// engaged, else the four gains with `·` for a bypassed band. Every
    /// watery/muffled field incident so far was chased through rate and pad
    /// because those were the only numbers the journal carried; a band left
    /// down is the one stuck state this makes visible.
    private func journalEQ(_ state: DeckState) -> String {
        let bands = state.eq.bands
        guard bands.contains(where: { !$0.bypass && abs($0.gain) > 0.1 }) else {
            return "flat"
        }
        return bands.map {
            $0.bypass ? "·" : String(format: "%+.1f", $0.gain)
        }.joined(separator: ",")
    }

    // MARK: - Engine trace (verbose debug instrument)

    /// The knob-write flight recorder. See `EngineTrace.swift` for why it is a
    /// ring in memory rather than more journal lines.
    private let trace = EngineTraceRing()
    private var watchdogTimer: DispatchSourceTimer?

    /// Turn the recorder on or off. Off — the shipping default — the ring
    /// records nothing, the watchdog does not run, the sentinels do not judge,
    /// and no feeder carries a trace hook: the whole instrument costs one
    /// `guard isEnabled` per knob write and nothing else.
    func setVerboseTrace(_ on: Bool) {
        queue.async { self.setVerboseTraceLocked(on) }
    }

    private func setVerboseTraceLocked(_ on: Bool) {
        guard trace.isEnabled != on else { return }
        trace.isEnabled = on
        PlaybackJournal.note("engine trace \(on ? "on" : "off")")
        for state in deckStates.values {
            if case .convertedFile(let feeder) = state.source {
                wireFeederTraceLocked(feeder, state: state)
            }
            state.watchStalled = false
            state.stallRestarted = false
            state.watchAt = 0
            // The coalescer must not suppress the first write of a fresh
            // session against something recorded into a ring that is gone.
            state.lastTracedRate = nil
            state.lastTracedRateReason = nil
            state.lastTracedLevel = nil
            state.lastTracedLevelReason = nil
        }
        segmentState.lastTracedRate = nil
        segmentState.lastTracedRateReason = nil
        segmentState.lastTracedLevel = nil
        segmentState.lastTracedLevelReason = nil
        if on {
            startWatchdogTimerLocked()
        } else {
            watchdogTimer?.cancel()
            watchdogTimer = nil
            trace.clear()
        }
    }

    /// Spell the ring out into a file and name it in the journal. The ring keeps
    /// rolling: a dump is a photograph, not a hand-over, so the next one still
    /// carries the run-up to this one.
    func dumpEngineTrace(reason: String) {
        queue.async { self.dumpEngineTraceLocked(reason: reason) }
    }

    private func dumpEngineTraceLocked(reason: String) {
        guard trace.isEnabled else { return }
        let entries = trace.snapshot()
        guard !entries.isEmpty else { return }
        guard let name = EngineTrace.write(entries, reason: reason, total: trace.total) else {
            PlaybackJournal.note("engine trace dump FAILED reason=\(reason)")
            return
        }
        PlaybackJournal.note("engine trace dumped \(name) reason=\(reason)")
    }

    /// Test hook: how many entries the ring has taken, ever. The assertion it
    /// exists for is the one about the *off* state — "nothing was recorded" has
    /// no other observable form.
    var traceEntryCountForTesting: Int { queue.sync { trace.total } }

    /// Test hook: write a deck's fader through the real writer, so the
    /// resurrection sentinel can be exercised on a deck the tests have taken
    /// out of service without standing up an audio graph and a hand-over to
    /// reach the same state. Synchronous, so the journal lines are in hand when
    /// it returns.
    func writeFaderForTesting(_ deck: Deck, _ value: Float, _ reason: TraceReason) {
        queue.sync { setFaderLocked(deckStates[deck]!, value, reason) }
    }

    private func wireFeederTraceLocked(_ feeder: FileFeeder, state: DeckState) {
        guard trace.isEnabled else {
            feeder.onTrace = nil
            return
        }
        let deck = state.traceDeck
        feeder.onTrace = { [weak self] kind, health in
            // Already on the engine queue — the feeder posts these to its
            // callbackQueue, which is this one. Its own workQueue never touches
            // the ring.
            guard let self else { return }
            let reason: TraceReason
            switch kind {
            case .started: reason = .feederStart
            case .stopped: reason = .feederStop
            case .cancelled: reason = .feederCancel
            case .chunks: reason = .feederChunk
            case .ended: reason = .feederEnded
            }
            self.trace.record(.feeder, deck, reason, Double(health.inFlight),
                              Double(health.delivered), Double(health.generation))
        }
    }

    /// Record a rate write, next to the write rather than in place of it: the
    /// writes stay exactly where they were so nothing about the audio moves.
    /// Call before the assignment — the entry carries old → new.
    private func traceRateLocked(_ state: DeckState, _ new: Float, _ reason: TraceReason) {
        guard trace.isEnabled else { return }
        // Most of these are `×1.0000 → ×1.0000` from the 50 Hz automation on a
        // deck nothing is bending; see `EngineTraceCoalesce` for why they are
        // dropped and why the first one after a reason change never is.
        guard EngineTraceCoalesce.shouldRecord(
            value: Double(new), reason: reason,
            lastValue: state.lastTracedRate, lastReason: state.lastTracedRateReason)
        else { return }
        state.lastTracedRate = Double(new)
        state.lastTracedRateReason = reason
        trace.record(.rate, state.traceDeck, reason,
                     Double(state.timePitch.rate), Double(new))
    }

    /// **The one way a live deck's time-pitch rate is written.** Traces the
    /// write (old → new, coalesced) and hands the assignment to
    /// `DeckChain.setRate`, which is what keeps the unit bypassed while it is
    /// at unity — the fix for the fast-path desync documented on
    /// `DeckChain.syncBypass`. The offline renderer writes through the same
    /// helper, so live and auditioned seams engage the AU at the same instants.
    private func setRateLocked(_ state: DeckState, _ rate: Float, _ reason: TraceReason) {
        traceRateLocked(state, rate, reason)
        if DeckChain.setRate(rate, on: state.timePitch) {
            traceBypassLocked(state, reason)
        }
    }

    /// Record one bypass **edge**. Only ever called when the state actually
    /// changed, which is what keeps this out of the way of the 50 Hz automation:
    /// a glide is a monotone walk between unity and its target, so it crosses
    /// the edge once on the way out and once on the way home — two lines per
    /// seam per deck, not a hundred. (A glide that passed *through* unity would
    /// cross twice more; none does — every bend runs unity ↔ target.)
    private func traceBypassLocked(_ state: DeckState, _ by: TraceReason) {
        let bypassed = state.timePitch.bypass
        trace.record(.rate, state.traceDeck, .auBypass,
                     bypassed ? 1 : 0, Double(state.timePitch.rate))
        PlaybackJournal.note(String(
            format: "deck timePitch %@ deck=%@ rate=×%.4f by=%@",
            bypassed ? "BYPASSED" : "ENGAGED", journalDeckName(state),
            state.timePitch.rate, by.rawValue))
    }

    // MARK: - Sentinels (locked)

    /// **The resurrection sentinel.** A deck that has been reset or
    /// hard-silenced is out of service until something legitimately puts a
    /// track back on it; a fader write above zero in between is the
    /// "faded-out deck comes back" bug, caught at the instant it happens and
    /// with the call site that did it named.
    ///
    /// It cannot fire on the ordinary re-write paths (the ride glide and the
    /// pad glide re-apply `faderRequest`, which `hardSilenceFaderLocked` sets to
    /// 0), which is exactly why those paths were made to work that way.
    private func checkResurrectionLocked(_ state: DeckState, _ value: Float,
                                         _ reason: TraceReason) {
        guard trace.isEnabled, state.outOfService, value > 0 else { return }
        trace.record(.alarm, state.traceDeck, .resurrected, Double(value))
        PlaybackJournal.note(String(
            format: "deck RESURRECTED deck=%@ level=%.4f by=%@",
            state.traceDeck.name, value, reason.rawValue))
        // The ring is what says *which writes led here*, and during an overlap
        // 512 entries is only a few seconds — waiting for the seam's own dump
        // would roll the evidence away.
        dumpEngineTraceLocked(reason: "resurrected")
    }

    /// **The mid-transition re-schedule sentinel.** Deliberately conservative in
    /// the noisy direction: a user seek during a hand-over is a legitimate
    /// action *and* the most likely way to reach the stutter, so it is reported
    /// with its context rather than filtered out.
    ///
    /// *Which* re-cues are by design is `PlaybackRescheduleCheck`'s to say, and
    /// answering it takes more than the call site. `.overlapBegin` cueing the
    /// **incoming** deck to its in-point is the design — that deck was loaded
    /// from 0 at arm time and has not started sounding, so re-cueing it moves
    /// silence — while the same call landing on a deck that is already playing
    /// is the stutter this sentinel was written for. The remote session's
    /// thirteen `phase=waiting by=overlapBegin` lines were every one of them
    /// the first kind, which is thirteen dumps spent on the engine doing
    /// exactly what it was told.
    ///
    /// The deck's state is read here, before the schedule touches anything, so
    /// `isPlaying` still describes the deck the re-cue *arrived at* rather than
    /// the one it is about to leave behind.
    private func checkRescheduleLocked(_ state: DeckState, at seconds: TimeInterval,
                                       _ reason: TraceReason) {
        guard trace.isEnabled, let tr = transition else { return }
        let deck: Deck
        switch state.traceDeck {
        case .a: deck = .a
        case .b: deck = .b
        case .segment, .output: return
        }
        guard tr.from == deck || tr.to == deck,
              tr.phase == .waiting || tr.phase == .overlapping || tr.phase == .segmentPlaying
        else { return }
        guard !PlaybackRescheduleCheck.isLegitimate(reason: reason,
                                                    isIncomingDeck: tr.to == deck,
                                                    deckIsPlaying: state.isPlaying)
        else { return }
        trace.record(.alarm, state.traceDeck, .rescheduled, seconds)
        PlaybackJournal.note(String(
            format: "deck RESCHEDULED mid-transition deck=%@ at=%.3f phase=%@ by=%@",
            deck.rawValue, seconds, "\(tr.phase)", reason.rawValue))
        dumpEngineTraceLocked(reason: "rescheduled")
    }

    /// **The feeder starvation sentinel.** A `.convertedFile` deck that is
    /// playing has just seen its last queued chunk finish: the node has nothing
    /// left to render, and whatever it emits from here is not the song.
    ///
    /// This is a different failure from the progressive stream's underrun,
    /// which `streamStalled` and the `.streamStalled` event already cover with
    /// a UI state and a resume path — that deck is waiting on a network and is
    /// *expected* to run dry. A converted local file is not: its chunks come
    /// off a disk through a resampler on the feeder's own queue, so an empty
    /// node means the conversion fell behind the playhead, and nothing in the
    /// engine notices. The watchdog eventually calls it a stall, two seconds
    /// and one dead deck later; this says it at the instant the queue empties,
    /// with the feeder's own counters next to it so the next question — did
    /// delivery stop, or was it never fast enough — is already answered.
    ///
    /// One episode is one line. A deck that has starved keeps starving on every
    /// completion until chunks arrive again, and the flag is cleared where they
    /// do (`wireFeederLocked`), not on a timer.
    ///
    /// The natural end of a track is not starvation: `streamEnded` says the
    /// feeder has delivered everything there is, and an empty node then means
    /// the song is over.
    private func checkFeederStarvationLocked(_ deck: Deck, _ state: DeckState,
                                             feeder: FileFeeder) {
        guard trace.isEnabled, !state.feederStarved,
              state.pendingStreamBuffers <= 0, state.isPlaying,
              !state.streamEnded, !isPaused else { return }
        state.feederStarved = true
        let health = feeder.health
        trace.record(.alarm, state.traceDeck, .starved,
                     0, Double(health.delivered), Double(health.inFlight))
        PlaybackJournal.note("deck STARVED deck=\(deck.rawValue) pending=0 "
            + "delivered=\(health.delivered) inFlight=\(health.inFlight)")
        dumpEngineTraceLocked(reason: "starved")
    }

    // MARK: - Stall watchdog (locked)

    private func startWatchdogTimerLocked() {
        guard watchdogTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + PlaybackStallCheck.interval,
                       repeating: PlaybackStallCheck.interval, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.watchdogTickLocked() }
        timer.resume()
        watchdogTimer = timer
    }

    /// "This deck says it is playing; is its playhead moving like one?"
    ///
    /// The comparison is against wall clock rather than against any of our own
    /// bookkeeping on purpose — every number the engine keeps about a deck is
    /// exactly what a stall would leave stale, so the only honest reference is
    /// the one outside the engine.
    private func watchdogTickLocked() {
        guard trace.isEnabled else { return }
        checkStartErrorsLocked()
        let now = EngineTraceRing.now()
        // A spliced hand-over parks both decks while the segment carries the
        // song; neither is stalled, they are waiting their turn.
        let spliceRunning = transition.map {
            $0.phase == .segmentPlaying || $0.phase == .segmentArmed
        } ?? false
        for (deck, state) in deckStates {
            guard state.isPlaying, !isPaused, !spliceRunning, !state.hostScheduledStart else {
                // Not a comparable window; start a fresh one next time.
                state.watchAt = 0
                continue
            }
            let position = livePositionLocked(state)
            guard state.watchAt > 0 else {
                state.watchPosition = position
                state.watchAt = now
                continue
            }
            let wall = now - state.watchAt
            let advanced = position - state.watchPosition
            state.watchPosition = position
            state.watchAt = now
            if PlaybackStallCheck.isStalled(advanced: advanced, over: wall) {
                // One stall is one line: a deck that has died stays dead, and a
                // report every two seconds would bury the moment it happened.
                guard !state.watchStalled else { continue }
                state.watchStalled = true
                // Read once, printed twice: the STALLED line and the RESTARTED
                // line have to describe the *same* instant, and re-reading the
                // node clock between them would let the two disagree about the
                // very thing they are evidence for.
                let health = sourceHealthLocked(state)
                trace.record(.alarm, state.traceDeck, .stalled, position, advanced, wall)
                PlaybackJournal.note("deck STALLED deck=\(deck.rawValue) "
                    + String(format: "pos=%.3f advanced=%.3fs/%.3fs ",
                             position, advanced, wall)
                    + health)
                dumpEngineTraceLocked(reason: "stall")
                restartStalledDeckLocked(deck, state, at: position, health: health)
            } else if state.watchStalled {
                state.watchStalled = false
                state.stallRestarted = false
                trace.record(.alarm, state.traceDeck, .resumed, position, advanced, wall)
                PlaybackJournal.note("deck resumed deck=\(deck.rawValue) "
                    + String(format: "pos=%.3f advanced=%.3fs/%.3fs",
                             position, advanced, wall))
            }
        }
    }

    /// What the deck's source has to say about why it might not be advancing —
    /// the difference between "starved" and "the node stopped underneath us".
    ///
    /// The three clauses every source now carries are the ones the twenty-two
    /// second `.file` stall could not be diagnosed without. `livePositionLocked`
    /// answers a nil `playerTime` and a negative sample time with the *same*
    /// number — the deck's start offset — so a stalled position on its own
    /// cannot tell "the clock will not talk to us" from "the node's timeline
    /// has not begun". Printing the raw player time, whether the node calls
    /// itself playing, and how the scheduled host release stands relative to
    /// now separates all three, on one line, at the instant it happened.
    private func sourceHealthLocked(_ state: DeckState) -> String {
        let source: String
        switch state.source {
        case .convertedFile(let feeder):
            let health = feeder.health
            source = "src=feeder inFlight=\(health.inFlight) delivered=\(health.delivered) "
                + "ended=\(health.ended) gen=\(health.generation) "
                + "pending=\(state.pendingStreamBuffers)"
        case .stream:
            source = "src=stream pending=\(state.pendingStreamBuffers) "
                + "stalled=\(state.streamStalled) ended=\(state.streamEnded)"
        case .file(let file):
            let clock = Self.renderedNodeTime(state.player) != nil ? "ok" : "unavailable"
            source = "src=file lastRenderTime=\(clock) "
                + "file=\(file.framePosition)/\(file.length)"
        case .none:
            source = "src=none"
        }
        return source
            + " node=\(state.player.isPlaying ? "playing" : "STOPPED")"
            + " playerTime=\(playerTimeHealthLocked(state))"
            + " hostStart=\(hostStartHealthLocked(state))"
    }

    /// The node clock exactly as it answers, with no fallback applied: `nil`
    /// (and which of the two queries returned it) or the raw sample time and
    /// rate. The whole point is to show the number `livePositionLocked` threw
    /// away on its way to returning the start offset.
    private func playerTimeHealthLocked(_ state: DeckState) -> String {
        guard let nodeTime = Self.renderedNodeTime(state.player) else { return "nil(noRenderTime)" }
        guard let playerTime = state.player.playerTime(forNodeTime: nodeTime) else {
            return "nil"
        }
        return String(format: "sample=%lld@%.0fHz", playerTime.sampleTime, playerTime.sampleRate)
    }

    /// Where the deck's scheduled `play(at:)` release sits relative to now:
    /// still ahead (`+1.2s`), already gone by (`-21.0s passed`), or never
    /// scheduled at all (`none`, an ordinary immediate start).
    private func hostStartHealthLocked(_ state: DeckState) -> String {
        guard let host = state.scheduledStartHostTime else { return "none" }
        let lead = Self.hostLeadSeconds(from: mach_absolute_time(), to: host)
        return lead >= 0
            ? String(format: "+%.1fs", lead)
            : String(format: "%.1fs passed", lead)
    }

    /// **The stall self-heal.** A `.file` deck whose node was released on the
    /// host clock and never started is the one stall we know how to fix from
    /// here: the audio is a local file, the deck is not part of anything that
    /// parks it (the watchdog's own `spliceRunning` guard has already said so),
    /// and the fix is simply to cue it again from where it thinks it is and
    /// start it with an ordinary `play()`.
    ///
    /// Deliberately narrow — see `PlaybackStallCheck.shouldRestartStalledDeck`,
    /// which holds the whole rule as a pure function. A feeder or a stream
    /// stalls for reasons that live somewhere else entirely (an underrun, a
    /// download that stopped), and restarting one would destroy the evidence
    /// and re-run the work that is already failing.
    ///
    /// `scheduleSegmentLocked` opens a fader flush window on the way through,
    /// so the ~200 ms of stale audio sitting in the effect chain is muted out
    /// rather than replayed — the same courtesy a seek gets, for the same
    /// reason.
    ///
    /// And it only ever touches a graph that is actually rendering.
    /// `AVAudioPlayerNode.play()` on a node whose engine is stopped raises an
    /// NSException, which out of a timer handler is a crash — so a stall the
    /// watchdog cannot tell from a device switch would become the very thing
    /// self-healing exists to avoid. `PlaybackStallCheck.restartRefusal` holds
    /// that rule, and when it refuses the deck says so in the journal once and
    /// waits for the rebuild path, which puts it back itself.
    private func restartStalledDeckLocked(_ deck: Deck, _ state: DeckState,
                                          at position: TimeInterval, health: String) {
        guard case .file(let file) = state.source else { return }
        let lead = state.scheduledStartHostTime.map {
            Self.hostLeadSeconds(from: mach_absolute_time(), to: $0)
        }
        guard PlaybackStallCheck.shouldRestartStalledDeck(
            sourceIsFile: true, isPaused: isPaused,
            alreadyRestarted: state.stallRestarted, hostStartLead: lead) else { return }
        // Set before the refusal, not after: a withheld restart is a decision
        // taken for this episode, and repeating the line every two seconds
        // would bury the stall it is about.
        state.stallRestarted = true
        if let refusal = PlaybackStallCheck.restartRefusal(
            engineIsRunning: engine.isRunning,
            isConnected: state.isConnected,
            hasRenderTime: Self.renderedNodeTime(state.player) != nil) {
            PlaybackJournal.note(
                "deck stall restart withheld deck=\(deck.rawValue) (\(refusal.rawValue))")
            return
        }
        // `livePositionLocked` already floors at the start offset, so this is
        // "wherever the deck got to, and never behind where it was cued".
        let resume = max(position, state.startOffset)
        scheduleSegmentLocked(state, file: file, from: resume, deck: deck, .stallRestart)
        trace.record(.play, state.traceDeck, .stallRestart, resume)
        if let exception = KumoneCatchException({ state.player.play() }) {
            PlaybackJournal.note("deck stall restart raised deck=\(deck.rawValue) "
                + "(\(exception.reason ?? exception.name.rawValue))")
            return
        }
        PlaybackJournal.note(String(format: "deck RESTARTED after stall deck=%@ at=%.3f ",
                                    deck.rawValue, resume) + health)
        dumpEngineTraceLocked(reason: "stall-restart")
    }

    // MARK: - Fader (locked)

    /// The single writer for a deck's fader on every "make this deck sound at
    /// level X" path. While a seek flush window is open the deck must stay
    /// silent, so the requested level is only remembered — `faderFlushTick`
    /// applies it once the stale audio has drained out of the chain.
    ///
    /// The hard-silence paths (`resetDeckLocked`, `silenceDeckLocked`, the
    /// cancel paths) deliberately bypass this and write 0 directly: a deck
    /// that is being taken out of service must go quiet *now*.
    ///
    /// Every requested level is scaled by the deck's two gain multipliers —
    /// the loudness-compensation `trim` and the transition `ride` — here, and
    /// only here. Callers keep speaking in 0–1 fader terms
    /// (`TransitionAutomation` included) and never see either gain.
    ///
    /// `reason` names the call site and has **no default**, deliberately: the
    /// trace ring exists to say who wrote, and a defaulted parameter would let
    /// the next call site join anonymously. It changes no behaviour — with the
    /// verbose trace off, it is an unused enum case.
    private func setFaderLocked(_ state: DeckState, _ value: Float, _ reason: TraceReason) {
        checkResurrectionLocked(state, value, reason)
        state.faderRequest = value
        let gain = state.trim * state.ride * state.ratePad
        let level = value * gain
        // The *level* is what the listener hears, so it is what decides whether
        // this write is news: a ride glide re-applying a settled request at an
        // unchanged gain lands the same number fifty times a second.
        if trace.isEnabled, EngineTraceCoalesce.shouldRecord(
            value: Double(level), reason: reason,
            lastValue: state.lastTracedLevel, lastReason: state.lastTracedLevelReason) {
            state.lastTracedLevel = Double(level)
            state.lastTracedLevelReason = reason
            trace.record(.fader, state.traceDeck, reason,
                         Double(value), Double(level), Double(gain))
        }
        if state.pendingFaderRestore != nil {
            state.pendingFaderRestore = level
        } else {
            state.fader = level
        }
    }

    /// Close any open flush window and drop the fader to 0 immediately.
    /// The *request* goes to 0 too: a deck taken out of service must not be
    /// resurrected by the ride glide re-applying a stale level.
    private func hardSilenceFaderLocked(_ state: DeckState) {
        state.pendingFaderRestore = nil
        state.faderRequest = 0
        state.fader = 0
        // From here the deck is out of service: the resurrection sentinel
        // watches for anything that raises it again before a legitimate re-cue.
        state.outOfService = true
        state.lastTracedLevel = 0
        state.lastTracedLevelReason = .hardSilence
        trace.record(.fader, state.traceDeck, .hardSilence, 0, 0, 0)
    }

    /// A track has legitimately been put (back) on this deck, so the
    /// resurrection sentinel stands down. Called by every path that cues audio:
    /// load, play, seek, re-schedule, splice pre-roll.
    private func returnToServiceLocked(_ state: DeckState) {
        state.outOfService = false
    }

    // MARK: - Transition gain ride (locked)

    /// Tick of the ride glide. Deliberately slow: at 0.3 dB/s a 20 Hz glide
    /// moves 0.015 dB a step, which is three orders of magnitude under
    /// audibility, and the release can run for 13 s — this is not something to
    /// burn the 50 Hz ramp tick on.
    private static let rideTick: TimeInterval = 0.05
    /// The most one glide step may cover; see `lastRideTickUptime`.
    private static let rideTickMaxStep: TimeInterval = 0.25
    /// The most one overlap / settle step may cover; see
    /// `TransitionState.lastTickUptime`.
    private static let transitionTickMaxStep: TimeInterval = 0.25

    /// Put the deck's ride at `db` **now**, with no glide, and re-write the
    /// fader through it.
    private func setRideLocked(_ state: DeckState, db: Double) {
        state.rideDB = db
        state.rideTargetDB = db
        state.rideReleaseFromDB = db
        state.rideReleaseElapsed = 0
        state.ride = LoudnessCompensation.gain(fromDB: db)
        setFaderLocked(state, state.faderRequest, .rideWrite)
    }

    // MARK: - Bent-rate headroom pad (locked)

    /// Put the deck's pad at `db` now and re-write its fader at the new gain.
    /// Only ever called where the move is inaudible — under a fader at 0, or
    /// spread across the tempo glide by the caller.
    private func setRatePadLocked(_ state: DeckState, db: Double) {
        state.ratePadTargetDB = db
        guard abs(state.ratePadDB - db) > 0.0001 else { return }
        state.ratePadDB = db
        state.ratePad = LoudnessCompensation.gain(fromDB: db)
        setFaderLocked(state, state.faderRequest, .padWrite)
    }

    /// Start letting go of the deck's pad: unity is the target, reached at
    /// `TransitionAutomation.ratePadGlideDBPerSecond`.
    ///
    /// Like `releaseRideLocked`, this deliberately lives on the *deck*. The pad
    /// goes on for a hand-over but it is let go of long after one — and a
    /// cancel, a re-arm or a seek mid-release must not strand a deck several dB
    /// down for the rest of its song. The deck's glide timer outlives every
    /// transition, so it is the only owner that can promise that.
    private func releaseRatePadLocked(_ state: DeckState) {
        guard abs(state.ratePadDB) > 0.0001 else {
            state.ratePadTargetDB = 0
            return
        }
        PlaybackJournal.note(String(
            format: "pad release from=%+.2fdB rate=×%.4f", state.ratePadDB, state.timePitch.rate))
        state.ratePadTargetDB = 0
        startRideTimerLocked()
    }

    /// The pad this deck owes while bent — 0 for anything with headroom to
    /// spare, which is most of the library, and 0 for *everything* while the
    /// master limiter is in circuit (`LoudnessCompensation.timePitchPadDB`).
    private func padTargetLocked(_ state: DeckState) -> Double { state.padCeilingDB }

    /// **Which headroom regime this track is playing under**, said once per
    /// load and only when it is news.
    ///
    /// The pad regime announces itself: `pad engage` / `pad release` bracket
    /// every bend, and their absence is what "the limiter is doing it" looks
    /// like in a journal. Absence is a terrible piece of evidence, though —
    /// indistinguishable from a track the analyzer never reached, or a master
    /// cool enough to owe nothing — so a retirement that actually cost the old
    /// player something says so, with the number it would have cost: a field
    /// session grepping `pad ` gets either a duck or the duck it was spared.
    private func journalRetiredPadLocked(_ state: DeckState, deck: Deck,
                                         peakDBFS: Double?, trimDB: Double) {
        guard masterLimiterActive else { return }
        let would = LoudnessCompensation.timePitchPadDB(
            forPeakDBFS: peakDBFS, afterTrimDB: trimDB)
        guard would != 0 else { return }
        PlaybackJournal.note(String(
            format: "pad retired deck=%@ would=%+.2fdB lead=%.2fs by=masterLimiter",
            deck.rawValue, would, TransitionAutomation.ratePadLeadSeconds(would)))
    }

    /// Clear the ride bookkeeping without touching the fader — for a deck
    /// being taken out of service, where the fader is separately silenced (or,
    /// for an echo tail, deliberately left exactly where the overlap left it).
    /// Mirrors how `trim` is reset in `resetDeckLocked`.
    private func clearRideStateLocked(_ state: DeckState) {
        state.rideDB = 0
        state.rideTargetDB = 0
        state.rideReleaseFromDB = 0
        state.rideReleaseElapsed = 0
        state.ride = 1
        // The pad belongs to a bend that is over too. Cleared without a fader
        // write for the same reason as the ride: this deck has just been
        // silenced, or is deliberately holding an echo tail's level.
        //
        // **The target goes with the value, and that is the whole point.**
        // Zeroing `ratePadDB` alone leaves the deck reset but still *aiming* at
        // the spent hand-over's pad, and the 20 Hz glide is a function of the
        // gap between the two: it skips a sourceless deck, so a parked deck
        // looks perfect — and then the next `loadFile` hands it a source and the
        // very next tick starts walking the *new* track down to the *old*
        // bend's headroom, 0.3 dB/s, for the rest of the song. Nothing ever
        // takes it back either, because `resetDeckLocked` does not clear it: the
        // deck stays that way for every track it is handed from then on, which
        // in a two-deck rotation is every other track.
        state.ratePadDB = 0
        state.ratePadTargetDB = 0
        state.ratePad = 1
    }

    /// Start letting go of the deck's ride: unity is the target, reached at
    /// `TransitionAutomation.rideReleaseDBPerSecond`.
    ///
    /// This deliberately lives on the deck rather than in the transition's
    /// settling phase. The release runs for up to 13 s — an order of magnitude
    /// longer than a rate restore or an echo tail — and holding the transition
    /// state machine open for it would delay every cleanup that keys off
    /// `transition == nil`. By the time it finishes the hand-over is long over
    /// and this deck simply *is* the current track.
    private func releaseRideLocked(_ state: DeckState) {
        // Deliberately silent for a deck that is not riding: `releaseRide` is
        // called on every completion path, and most hand-overs carry no ride at
        // all — a line here would be one per seam saying nothing happened, and
        // would bury the ones that mean something.
        guard abs(state.rideDB) > 0.0001 else {
            setRideLocked(state, db: 0)
            return
        }
        state.rideTargetDB = 0
        state.rideReleaseFromDB = state.rideDB
        state.rideReleaseElapsed = 0
        PlaybackJournal.note(String(
            format: "ride release start deck=%@ from=%+.2fdB slope=%.2fdB/s over=%.2fs",
            journalDeckName(state), state.rideDB,
            TransitionAutomation.rideReleaseDBPerSecond(for: state.rideDB),
            TransitionAutomation.rideReleaseDuration(state.rideDB)))
        startRideTimerLocked()
    }

    /// Settle a running ride glide to wherever it was heading, immediately.
    ///
    /// Called on pause, seek and any re-`play` — the three moments the user
    /// interrupts the deck. Each is inaudible by construction, which is why a
    /// jump of up to 4 dB is acceptable here: a paused engine renders nothing,
    /// and a seek or re-play mutes the deck through `beginFaderFlushLocked`
    /// while the chain drains and hands back the *new* level afterwards. What
    /// would not be acceptable is the alternative — a glide left running under
    /// a track the listener has just re-aimed, drifting its level for another
    /// ten seconds for a hand-over that no longer exists.
    ///
    /// A ride still inside its overlap has target == current, so this is a
    /// no-op there: pausing mid-crossfade must not move the level.
    private func settleRideLocked(_ state: DeckState) {
        guard abs(state.rideDB - state.rideTargetDB) > 0.0001 else { return }
        setRideLocked(state, db: state.rideTargetDB)
    }

    private func startRideTimerLocked() {
        guard rideTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.rideTick, repeating: Self.rideTick,
                       leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.rideTickLocked() }
        timer.resume()
        rideTimer = timer
        lastRideTickUptime = ProcessInfo.processInfo.systemUptime
    }

    /// One tick of the deck-level gain glides — the ride's release, and the
    /// bent-rate pad's. Two independent multipliers on the same fader, both
    /// owned by the deck rather than by any transition, both let go of at
    /// 0.3 dB/s because that is the slope at which a level change stops being
    /// an event. A deck can be unwinding both at once (a hand-over that both
    /// rode the incoming level and padded it for the bend), which is exactly
    /// why they are separate numbers and one fader write.
    private func rideTickLocked() {
        let now = ProcessInfo.processInfo.systemUptime
        // Capped so a long stall of the engine queue resumes the glide rather
        // than landing it in one audible jump; paused time is dropped below.
        let dt = Swift.min(now - (lastRideTickUptime ?? now - Self.rideTick), Self.rideTickMaxStep)
        lastRideTickUptime = now
        var anyGliding = false
        for state in deckStates.values {
            let ridingHome = abs(state.rideDB - state.rideTargetDB) > 0.0001
            let paddingHome = abs(state.ratePadDB - state.ratePadTargetDB) > 0.0001
            guard ridingHome || paddingHome else { continue }
            // A sourceless deck is out of service (or ringing an echo tail
            // whose level is already written into player.volume) — never write
            // its fader. `resetDeckLocked` has already cleared both, so this is
            // belt and braces.
            if case .none = state.source { continue }
            anyGliding = true
            guard !isPaused else { continue }
            if ridingHome {
                state.rideReleaseElapsed += dt
                let db = TransitionAutomation.rideDB(
                    state.rideReleaseFromDB, secondsAfterOverlap: state.rideReleaseElapsed)
                state.rideDB = db
                state.ride = LoudnessCompensation.gain(fromDB: db)
                // The release is over the moment it lands, not when the timer
                // next fires: the pair of lines is what makes "how long did the
                // new track spend under its own level" greppable out of a
                // journal, which is the number this whole release exists to
                // keep small.
                if abs(db - state.rideTargetDB) <= 0.0001 {
                    PlaybackJournal.note(String(
                        format: "ride release DONE deck=%@ from=%+.2fdB after=%.2fs "
                            + "slope=%.2fdB/s",
                        journalDeckName(state), state.rideReleaseFromDB,
                        state.rideReleaseElapsed,
                        TransitionAutomation.rideReleaseDBPerSecond(
                            for: state.rideReleaseFromDB)))
                }
            }
            if paddingHome {
                // A plain constant-slope walk towards the target, in dB. The
                // pad has no "release from" bookkeeping because, unlike the
                // ride, it is only ever released *to* unity.
                let step = TransitionAutomation.ratePadGlideDBPerSecond * dt
                let remaining = state.ratePadTargetDB - state.ratePadDB
                state.ratePadDB += remaining > 0
                    ? Swift.min(step, remaining) : Swift.max(-step, remaining)
                state.ratePad = LoudnessCompensation.gain(fromDB: state.ratePadDB)
            }
            setFaderLocked(state, state.faderRequest, .rideGlide)
        }
        if !anyGliding {
            rideTimer?.cancel()
            rideTimer = nil
            lastRideTickUptime = nil
        }
    }

    /// Open a flush window around a re-schedule of a *sounding* deck.
    ///
    /// `player.stop()` only stops the source: timePitch → EQ → delay still
    /// hold roughly `faderFlushDuration` of already-rendered audio from the
    /// old position, and they push it out at whatever the fader happens to be
    /// — which is how a manual seek used to leak ~200 ms of the pre-seek
    /// position. `player.volume` sits at the mixer *input*, downstream of the
    /// whole chain, so it is the one knob that can silence audio already in
    /// flight (the same reasoning as `resetDeckLocked`). Drop it to 0 before
    /// the stop and hand it back when the player's own clock says the chain
    /// has been refilled with post-seek audio.
    ///
    /// Only called when the node is actually rendering: a parked/stopped deck
    /// has nothing in its chain (the engine keeps pulling it, so it drains
    /// within a few buffers), and muting it here would put a hole at the start
    /// of every gapless hand-over.
    private func beginFaderFlushLocked(_ state: DeckState) {
        guard state.player.isPlaying else { return }
        if state.pendingFaderRestore == nil {
            state.pendingFaderRestore = state.player.volume
        }
        state.fader = 0
        startFaderFlushTimerLocked()
    }

    private func startFaderFlushTimerLocked() {
        guard faderFlushTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.faderFlushTick,
                       repeating: Self.faderFlushTick, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.faderFlushTickLocked() }
        timer.resume()
        faderFlushTimer = timer
    }

    private func faderFlushTickLocked() {
        var anyOpen = false
        for state in deckStates.values {
            guard let target = state.pendingFaderRestore else { continue }
            anyOpen = true
            // Frozen engine: nothing is being rendered, so the chain is not
            // draining either — hold the mute until playback resumes.
            guard !isPaused else { continue }
            // Frames the player has emitted under the current schedule; the
            // chain has flushed once that exceeds its own depth.
            let played = livePositionLocked(state) - state.startOffset
            guard played >= Self.faderFlushDuration else { continue }
            state.pendingFaderRestore = nil
            trace.record(.fader, state.traceDeck, .flushRestore,
                         Double(state.faderRequest), Double(target), played)
            state.fader = target
        }
        if !anyOpen {
            faderFlushTimer?.cancel()
            faderFlushTimer = nil
        }
    }

    /// Stop the deck and return every knob to neutral; clears the source.
    /// `keepingEchoTail` leaves the delay wet (and the EQ's global gain cut,
    /// so nothing new feeds it) for a thrown `.echoOut` tail to ring out after
    /// the outgoing player has stopped — the settling phase decays it and then
    /// neutralizes properly.
    ///
    /// The deck is left SILENT: `player.volume` goes to 0 before the stop and
    /// is not raised again here. `AVAudioPlayerNode.stop()` is not
    /// instantaneous — the chain keeps emitting the outgoing track for ~200 ms
    /// afterwards (measured; the residue is largest on the buffer-fed sources,
    /// streams and converted files). Because a deck's `volume` is an
    /// `AVAudioMixing` property applied at the *mixer input*, downstream of
    /// player → timePitch → EQ → delay, it is also the only knob that can
    /// silence audio already in flight. Restoring it to 1 here — as this used
    /// to — replayed those 200 ms at full level right after the crossfade had
    /// faded them out, and flattening the EQ on top un-ducked them as well:
    /// the "fade reached silence, then the old track jumped back for a
    /// moment" glitch. Whoever makes the deck sound again raises the fader:
    /// `play(deck:from:)`, `armGaplessLocked`, `beginOverlapLocked`'s ramp,
    /// the gapless drain fallback, and the cancel paths all set it explicitly.
    private func resetDeckLocked(_ state: DeckState, keepingEchoTail: Bool = false) {
        PlaybackJournal.note(String(
            format: "deck reset deck=%@ rate=×%.4f pad=%+.2fdB ride=%+.2fdB echoTail=%@ eq=%@",
            journalDeckName(state), state.timePitch.rate, state.ratePadDB, state.rideDB,
            keepingEchoTail ? "kept" : "no", journalEQ(state)))
        state.generation += 1
        trace.record(.reset, state.traceDeck, .deckReset,
                     Double(state.timePitch.rate), state.ratePadDB, state.rideDB)
        if keepingEchoTail {
            // The tail owns the fader; a pending flush restore must not fire
            // underneath it either.
            state.pendingFaderRestore = nil
        } else {
            hardSilenceFaderLocked(state)
        }
        switch state.source {
        case .stream(let loader): loader.cancel()
        case .convertedFile(let feeder): feeder.cancel()
        case .file, .none: break
        }
        trace.record(.stop, state.traceDeck, .deckReset,
                     state.lastKnownPosition, Double(state.generation))
        state.player.stop()
        if keepingEchoTail {
            // The fader stays where `.echoOut` left it — pulling it down would
            // mute the tail, which reaches the mixer through this same deck.
            // The dry residue is already silenced by the EQ's global gain.
            setRateLocked(state, 1, .deckReset)
            state.band(.low).gain = 0
            state.band(.mid).gain = 0
            state.band(.high).gain = 0
            state.band(.highPass).bypass = true
            state.band(.highPass).frequency = Self.sweepStartHz
        } else {
            neutralizeEffectsLocked(state)
        }
        state.source = .none
        // The trim belongs to the material that just left; a deck out of
        // service is at unity until its next load says otherwise. (An echo
        // tail is unaffected: its level is already written into player.volume,
        // and nothing calls setFaderLocked on a sourceless deck.)
        state.trim = 1
        // And for the pad's *ceiling*, which is sized from the outgoing
        // material's peak: `loadFile` writes the new one immediately after this
        // call, but `startStreaming` has no analysis to write, and a stream must
        // not inherit the headroom budget of whatever file this deck held last.
        state.padCeilingDB = 0
        // Same story for the hand-over's gain ride: it belonged to a transition
        // into material that is no longer here. Cleared without a fader write —
        // the deck has just been silenced above (or, for an echo tail,
        // deliberately left at the level the overlap ended on).
        clearRideStateLocked(state)
        state.isPlaying = false
        state.hostScheduledStart = false
        state.scheduledStartHostTime = nil
        state.startOffset = 0
        clearPauseSkewLocked(state)
        state.lastKnownPosition = 0
        state.pendingStreamBuffers = 0
        state.streamStalled = false
        state.feederStarved = false
        state.streamEnded = false
        // Including the echo-tail path, which keeps the fader where the overlap
        // left it: nothing may *raise* it from here either.
        state.outOfService = true
        state.watchAt = 0
        state.watchStalled = false
        state.stallRestarted = false
    }

    // MARK: - Clock (locked)

    /// `lastRenderTime` as something `playerTime(forNodeTime:)` will accept.
    ///
    /// In the first milliseconds after a node is (re)started its render time
    /// exists but carries neither a valid sample time nor a valid host time,
    /// and `playerTime(forNodeTime:)` **raises** on such a value rather than
    /// returning nil — an uncaught NSException on the engine queue, i.e. the
    /// whole app. Every clock read goes through here so that window reads as
    /// "no clock yet", the same as a node that has never rendered.
    private static func renderedNodeTime(_ player: AVAudioPlayerNode) -> AVAudioTime? {
        guard let time = player.lastRenderTime,
              time.isSampleTimeValid || time.isHostTimeValid else { return nil }
        return time
    }

    /// Sample-accurate position: schedule-start offset + frames the node has
    /// actually rendered. Falls back to the cached value when the node clock
    /// is unavailable (engine paused/stopped).
    private func livePositionLocked(_ state: DeckState) -> TimeInterval {
        guard let nodeTime = Self.renderedNodeTime(state.player),
              let playerTime = state.player.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0 else {
            return state.lastKnownPosition
        }
        let raw = state.startOffset + Double(playerTime.sampleTime) / playerTime.sampleRate
        // The node's timeline kept counting through every global pause this
        // schedule survived; the song did not. See `PausedClockSkew`.
        let position = PausedClockSkew.position(raw: raw, startOffset: state.startOffset,
                                                skew: state.pauseSkew)
        guard position > state.startOffset else {
            // sampleTime can be briefly negative right after play(at:), and a
            // skew never walks the playhead behind where the deck was cued.
            return state.startOffset
        }
        state.lastKnownPosition = position
        return position
    }

    /// The position to *report* for a deck, which is only ever different from
    /// its own clock while a pre-rendered segment is playing.
    ///
    /// There, neither deck is sounding: the outgoing one has stopped and the
    /// incoming one has not started, yet the hand-over takes ten to twenty
    /// seconds and the progress bar has to keep moving through it. The segment
    /// knows where it is on both songs' clocks, so each deck is reported at the
    /// position the segment is playing of *its* track. Because `PlayerService`
    /// swaps which deck it asks about at `transitionMidpoint`, what the user
    /// sees is the outgoing track running out and then the incoming one
    /// starting — the same story the live overlap tells.
    private func reportedPositionLocked(_ deck: Deck) -> TimeInterval {
        let state = deckStates[deck]!
        guard let tr = transition, tr.phase == .segmentPlaying, let segment = tr.segment,
              let elapsed = segmentElapsedLocked() else {
            return livePositionLocked(state)
        }
        if deck == tr.from {
            state.lastKnownPosition = segment.outgoingTime(at: elapsed)
            return state.lastKnownPosition
        }
        if deck == tr.to, !state.isPlaying {
            state.lastKnownPosition = segment.incomingTime(at: elapsed)
            return state.lastKnownPosition
        }
        return livePositionLocked(state)
    }

    private func durationLocked(_ state: DeckState) -> TimeInterval? {
        switch state.source {
        case .file(let file):
            return Double(file.length) / file.processingFormat.sampleRate
        case .convertedFile(let feeder):
            return feeder.duration
        case .stream(let loader):
            return loader.estimatedDuration
        case .none:
            return nil
        }
    }

    /// Low-frequency keepalive so `lastKnownPosition` is fresh enough to
    /// recover from a configuration change (which wipes the node clocks).
    private func startClockTimerLocked() {
        guard clockTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // Ahead of the pause guard: a gapless arm outside any transition
            // has no faster tick to be measured from, and a release scheduled
            // on the host clock lands whether we are paused or not.
            self.checkStartErrorsLocked()
            guard !self.isPaused else { return }
            for state in self.deckStates.values where state.isPlaying {
                _ = self.livePositionLocked(state)
            }
        }
        timer.resume()
        clockTimer = timer
    }

    // MARK: - File scheduling (locked)

    private func scheduleSegmentLocked(_ state: DeckState, file: AVAudioFile,
                                       from seconds: TimeInterval, deck: Deck,
                                       _ reason: TraceReason) {
        checkRescheduleLocked(state, at: seconds, reason)
        returnToServiceLocked(state)
        state.hostScheduledStart = false
        // A fresh schedule replaces whatever release the old one was waiting
        // for; the caller sets a new one if it releases this deck on the clock.
        state.scheduledStartHostTime = nil
        state.generation += 1
        let generation = state.generation
        trace.record(.scheduleSegment, state.traceDeck, reason,
                     seconds, Double(generation))
        beginFaderFlushLocked(state)
        trace.record(.stop, state.traceDeck, reason, seconds, Double(generation))
        state.player.stop()
        // Same reasoning as the feeder pre-roll: this is the other door a
        // stopped deck comes back through, and the node is silent right here.
        resetChainDSPLocked(state, reason)
        let sampleRate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition((max(0, seconds) * sampleRate).rounded())
        state.startOffset = Double(startFrame) / sampleRate
        clearPauseSkewLocked(state)
        state.lastKnownPosition = state.startOffset
        let remaining = file.length - startFrame
        guard remaining > 0 else {
            // Seek at/past the end: report a natural finish.
            queue.async { [weak self] in
                self?.handleDeckDrainedLocked(deck, generation: generation)
            }
            return
        }
        state.player.scheduleSegment(
            file, startingFrame: startFrame, frameCount: AVAudioFrameCount(remaining),
            at: nil, completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            // Fires on stop()/interruption too; the generation check filters those.
            guard let self else { return }
            self.queue.async { self.handleDeckDrainedLocked(deck, generation: generation) }
        }
    }

    /// A deck ran out of scheduled audio under its current generation —
    /// the only path that may emit `deckFinished` (natural end).
    private func handleDeckDrainedLocked(_ deck: Deck, generation: Int) {
        let state = deckStates[deck]!
        guard generation == state.generation, state.isPlaying else { return }
        if let tr = transition, tr.from == deck {
            handleFromDeckDrainedLocked(tr)
            return
        }
        state.isPlaying = false
        if let duration = durationLocked(state) {
            state.lastKnownPosition = duration
        }
        eventContinuation.yield(.deckFinished(deck))
    }

    // MARK: - Stream scheduling (locked)

    private func scheduleStreamBufferLocked(deck: Deck, loader: ProgressiveLoader,
                                            buffer: AVAudioPCMBuffer) {
        let state = deckStates[deck]!
        guard case .stream(let current) = state.source, current === loader else { return }
        state.pendingStreamBuffers += 1
        let generation = state.generation
        trace.record(.scheduleBuffer, state.traceDeck, .streamChunk,
                     Double(buffer.frameLength), Double(generation),
                     Double(state.pendingStreamBuffers))
        state.player.scheduleBuffer(buffer, at: nil, options: [],
                                    completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.streamBufferPlayedLocked(deck: deck, generation: generation) }
        }
        if state.streamStalled {
            state.streamStalled = false
            eventContinuation.yield(.streamResumed(deck))
            startNodeIfNeededLocked(state)
        }
        if state.pendingStreamBuffers >= streamHighWater {
            loader.setDownloadSuspended(true)
        }
    }

    private func streamBufferPlayedLocked(deck: Deck, generation: Int) {
        let state = deckStates[deck]!
        guard generation == state.generation else { return }
        state.pendingStreamBuffers -= 1
        _ = livePositionLocked(state)
        if case .convertedFile(let feeder) = state.source {
            checkFeederStarvationLocked(deck, state, feeder: feeder)
        }
        if case .stream(let loader) = state.source,
           state.pendingStreamBuffers <= streamLowWater {
            loader.setDownloadSuspended(false)
        }
        guard state.pendingStreamBuffers <= 0, state.isPlaying else { return }
        if state.streamEnded {
            handleDeckDrainedLocked(deck, generation: generation)
        } else if !state.streamStalled {
            // Underrun: playback outran the network.
            state.streamStalled = true
            eventContinuation.yield(.streamStalled(deck))
        }
    }

    /// Restart a converted-file deck's chunk delivery from `seconds`.
    private func seekFeederLocked(_ state: DeckState, feeder: FileFeeder,
                                  to seconds: TimeInterval, _ reason: TraceReason) {
        checkRescheduleLocked(state, at: seconds, reason)
        returnToServiceLocked(state)
        // An explicit re-cue takes the deck back from whatever host-clock start
        // was waiting on it (a splice tail pre-roll is the only one).
        state.hostScheduledStart = false
        state.scheduledStartHostTime = nil
        state.generation += 1
        trace.record(.scheduleBuffer, state.traceDeck, reason,
                     seconds, Double(state.generation))
        beginFaderFlushLocked(state)
        state.player.stop()
        state.pendingStreamBuffers = 0
        state.streamEnded = false
        state.streamStalled = false
        state.feederStarved = false
        state.startOffset = seconds
        clearPauseSkewLocked(state)
        state.lastKnownPosition = seconds
        feeder.start(from: seconds)
    }

    private func seekStreamLocked(_ state: DeckState, deck: Deck, to seconds: TimeInterval,
                                  _ reason: TraceReason) {
        guard case .stream(let loader) = state.source else { return }
        checkRescheduleLocked(state, at: seconds, reason)
        returnToServiceLocked(state)
        state.generation += 1
        trace.record(.scheduleBuffer, state.traceDeck, reason,
                     seconds, Double(state.generation))
        beginFaderFlushLocked(state)
        state.player.stop()
        state.pendingStreamBuffers = 0
        state.streamEnded = false
        state.startOffset = seconds
        clearPauseSkewLocked(state)
        state.lastKnownPosition = seconds
        if !state.streamStalled {
            // Buffering until the range request lands.
            state.streamStalled = true
            eventContinuation.yield(.streamStalled(deck))
        }
        loader.seek(to: seconds)
    }

    // MARK: - Transition machinery (locked)

    // MARK: - Plan reachability / fall back (locked)

    /// Overlap length a plan asks for; 0 for `.gapless`.
    private func overlapDurationLocked(_ plan: TransitionPlan) -> TimeInterval {
        switch plan {
        case .beatMatched(let p): return p.overlapDuration
        case .crossfade(let duration, _, _): return duration
        case .gapless: return 0
        }
    }

    /// Can the deck still *play into* this plan's out point from where it is
    /// now? `.gapless` is anchored to the end of the track, so it always can.
    private func planIsReachableLocked(_ plan: TransitionPlan, from state: DeckState) -> Bool {
        guard let outPoint = plan.outPoint else { return true }
        return livePositionLocked(state) < outPoint - Self.transitionArrivalGuard
    }

    /// The semantics of a hand-over, in one place:
    ///
    /// **A transition fires only when the outgoing track plays into its out
    /// point. A seek that lands inside — or past — the planned window does not
    /// count as arriving there.** Otherwise dropping the playhead near the end
    /// of a song (the out point is typically the last 10–20 s) would slam
    /// straight into the next track, which is what a user reported.
    ///
    /// A plan that can no longer be reached is not fired and not dropped
    /// either; it falls back to something anchored at the end of the track,
    /// so the remainder still plays and the queue still moves:
    ///
    /// - enough runway left → a plain crossfade of at most
    ///   `fallbackCrossfadeDuration`, ending at the end of the track. The
    ///   original mix point is gone, so the beat-matched / styled mechanics
    ///   (which were computed for *that* point) go with it.
    /// - not enough → `.gapless`: play out and hand over at the tail.
    ///
    /// Idempotent: applied on every (re)arm and re-plan, and after a seek on
    /// the outgoing deck.
    private func resolvePlanLocked(_ planned: PlannedTransition,
                                   from state: DeckState) -> PlannedTransition {
        guard !planIsReachableLocked(planned.plan, from: state) else { return planned }
        guard let duration = durationLocked(state) else { return .plain(.gapless) }
        let remaining = duration - livePositionLocked(state)
        let fade = min(overlapDurationLocked(planned.plan), Self.fallbackCrossfadeDuration)
        guard fade > 0, remaining >= fade + Self.fallbackCrossfadeHeadroom else {
            // No overlap left to ride over; the ride goes with the plan.
            return .plain(.gapless)
        }
        // The gain ride survives the degradation: it is a property of the two
        // tracks meeting, not of the geometry they meet with, and this is
        // still the same seam — only shorter.
        return PlannedTransition(
            plan: .crossfade(duration: fade, outPoint: duration - fade, inPoint: 0),
            style: .plain, rideDB: planned.rideDB)
    }

    /// A seek moved the outgoing deck's playhead, so the pending plan's out
    /// point may now be behind it (or its armed host-clock start point wrong).
    /// Re-resolve against the new position; the hand-over stays pending, only
    /// its mechanics are re-derived. Overlapping/settling transitions are left
    /// alone — audible audio is never re-planned (callers cancel instead).
    private func revalidateTransitionAfterSeekLocked(_ deck: Deck) {
        guard let tr = transition, tr.from == deck else { return }
        if tr.phase == .armed {
            // The gapless hand-over is pinned to a host time computed from the
            // pre-seek position; undo it and let the wait tick re-arm.
            disarmGaplessLocked()
        }
        if tr.phase == .segmentArmed {
            // Same story: the segment is pinned to a render time derived from
            // where the playhead was. Re-armed by the wait tick if the plan
            // survives the seek below.
            disarmSegmentLocked()
        }
        guard tr.phase == .waiting else { return }
        // The glide is a function of where the playhead is, and the playhead
        // just moved — so the old curve is void. Installing the fresh state
        // below hands the rate back; if the new position is still inside the
        // ramp window the fresh state re-enters the glide from there on its
        // next tick, and if it is not, the deck stays at unity where it
        // belongs.
        let resolved = resolvePlanLocked(
            PlannedTransition(plan: tr.plan, style: tr.style, rideDB: tr.rideDB),
            from: deckStates[deck]!)
        let state = TransitionState(plan: resolved.plan, style: resolved.style,
                                    rideDB: resolved.rideDB, from: tr.from, to: tr.to)
        // A segment is audio cut for one seam: it survives the seek only if the
        // seam did, and only if the playhead is still short of the splice.
        if let segment = tr.segment,
           let signature = TransitionSegment.Signature(plan: resolved.plan),
           signature == segment.signature,
           livePositionLocked(deckStates[deck]!) < segment.spliceStart - Self.segmentArmLead {
            state.segment = segment
        }
        transition = state
        startTransitionTimerLocked(interval: slowTickInterval)
    }

    private func startTransitionTimerLocked(interval: TimeInterval) {
        if transitionTimer != nil, transitionTimerInterval == interval { return }
        transitionTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval,
                       leeway: .milliseconds(interval < 0.1 ? 2 : 50))
        timer.setEventHandler { [weak self] in self?.transitionTickLocked() }
        timer.resume()
        transitionTimer = timer
        transitionTimerInterval = interval
    }

    private func stopTransitionTimerLocked() {
        transitionTimer?.cancel()
        transitionTimer = nil
        transitionTimerInterval = 0
    }

    private func transitionTickLocked() {
        // Before anything the tick might change: a seam's host-clock releases
        // are what this measures, and at 50 Hz this is where it lands soonest.
        checkStartErrorsLocked()
        guard let tr = transition else {
            stopTransitionTimerLocked()
            return
        }
        // Stamped before the pause guard so paused time is never counted, and
        // capped so a stalled queue resumes the curve rather than jumps it.
        let now = ProcessInfo.processInfo.systemUptime
        let dt = Swift.min(now - (tr.lastTickUptime ?? now - transitionTimerInterval),
                           Self.transitionTickMaxStep)
        tr.lastTickUptime = now
        guard !isPaused else { return }
        switch tr.phase {
        case .waiting:
            transitionWaitTickLocked(tr)
        case .armed:
            break // gapless: waiting for the outgoing deck's completion
        case .segmentArmed:
            segmentArmedTickLocked(tr)
        case .segmentPlaying:
            updateSegmentLocked(tr)
        case .overlapping:
            tr.elapsed += dt
            updateOverlapLocked(tr)
        case .settling:
            tr.restoreElapsed += dt
            settleTickLocked(tr)
        }
    }

    private func transitionWaitTickLocked(_ tr: TransitionState) {
        let from = deckStates[tr.from]!
        switch tr.plan {
        case .gapless:
            // Arm the incoming deck shortly before the outgoing one ends.
            // scheduleSegment completion callbacks are not sample-accurate,
            // so the handover uses play(at:) on the shared host clock.
            // Streamed decks only have a CBR byte-estimate duration (off by
            // seconds on VBR) — never arm from it; the drain fallback in
            // handleFromDeckDrainedLocked covers them with a tiny gap.
            guard case .file = from.source else { return }
            guard let duration = durationLocked(from) else { return }
            let position = livePositionLocked(from)
            let rate = Double(max(from.timePitch.rate, 0.01))
            let remaining = (duration - position) / rate
            adjustWaitTimerLocked(remaining: remaining)
            if remaining <= 1.0 {
                armGaplessLocked(tr, startingIn: max(remaining, 0))
            }
        case .crossfade, .beatMatched:
            guard let outPoint = tr.plan.outPoint else { return }
            let position = livePositionLocked(from)
            // Before anything else reads the rate: the glide owns it from here
            // to the seam, and everything below converts source seconds to wall
            // seconds with it.
            updateTempoRampLocked(tr, position: position)
            let rate = Double(max(from.timePitch.rate, 0.01))
            if let segment = tr.segment {
                // A pre-rendered hand-over starts one head window early, and on
                // the render clock rather than on this tick.
                if position < segment.spliceStart - Self.segmentArmLead {
                    adjustWaitTimerLocked(
                        remaining: (segment.spliceStart - position) / rate)
                    return
                }
                if armSegmentLocked(tr, segment: segment) { return }
                // The clock was unavailable: drop the segment and let the live
                // overlap below carry this hand-over.
                tr.segment = nil
            }
            adjustWaitTimerLocked(remaining: (outPoint - position) / rate,
                                  ramping: tr.rampActive)
            if position + transitionTimerInterval * rate / 2 >= outPoint {
                beginOverlapLocked(tr)
            }
        }
    }

    // MARK: - Pre-seam tempo ramp (locked)

    /// Glide the outgoing deck onto its matched rate before the seam.
    ///
    /// **Why this cannot move the seam.** The overlap fires on
    /// `livePositionLocked(from) >= outPoint`, and that position is the
    /// outgoing deck's *source* time — the player node sits upstream of the
    /// time-pitch unit, so its sample clock counts source frames pulled, not
    /// wall time. `outPoint` is a downbeat in the outgoing song's own timeline
    /// and `inPoint` a downbeat in the incoming one; bending the speed at which
    /// the deck walks its timeline changes when in the *room* it arrives, never
    /// where in the *song*. So the incoming downbeat still lands on the
    /// outgoing downbeat, exactly as it did, and the glide needs no correction
    /// term at all. `TransitionAutomation.TempoRamp` is a function of the same
    /// source position for the same reason.
    ///
    /// What the ramp *does* fix is a phase error that was already there: the
    /// deck used to arrive at the seam at rate 1 and ease onto its matched rate
    /// over the overlap's first second, i.e. play the first bar at the wrong
    /// tempo. Now it arrives already bent, a `segmentHandoff` early.
    private func updateTempoRampLocked(_ tr: TransitionState, position: TimeInterval) {
        guard let ramp = TransitionAutomation.tempoRamp(for: tr.plan) else { return }
        let from = deckStates[tr.from]!

        // The headroom pad goes on **before** the bend, not with it. The
        // time-pitch overshoot does not scale with the rate — the phase
        // vocoder is either engaged or it is not, and a 0.65 % bend already
        // costs the full several dB — so a pad that faded in alongside the
        // glide would be covering a fraction of the overshoot for the whole
        // first half of it, which is exactly the clipping this exists to stop.
        // It gets its own lead-in instead, at the ride's inaudible 0.3 dB/s,
        // timed to land precisely where the rate leaves unity.
        let padTarget = padTargetLocked(from)
        let padStart = ramp.start - TransitionAutomation.ratePadLeadSeconds(padTarget)
        if padTarget != 0, position >= padStart {
            if !tr.rampActive {
                PlaybackJournal.note(String(
                    format: "pad engage deck=%@ target=%+.2fdB at=%.3f lead=%.2fs",
                    tr.from.rawValue, padTarget, position, ramp.start - padStart))
            }
            tr.rampActive = true      // so every teardown path hands it back
            setRatePadLocked(from, db: padTarget * Double(
                TransitionAutomation.ramp(position, from: padStart, to: ramp.start)))
        }

        guard position >= ramp.start else { return }
        // Anchor on first entry, and never past the end — a glide with no room
        // left is a step, which is exactly what this seam used to be.
        let anchor = tr.rampFrom ?? Swift.min(position, ramp.end)
        if tr.rampFrom == nil {
            PlaybackJournal.note(String(
                format: "ramp glide start deck=%@ from=%.3f end=%.3f target=×%.4f rate=×%.4f",
                tr.from.rawValue, anchor, ramp.end, ramp.target, from.timePitch.rate))
        }
        tr.rampFrom = anchor
        tr.rampActive = true
        let bent = TransitionAutomation.TempoRamp(
            start: anchor, end: ramp.end, target: ramp.target)

        // The pad is already fully on by here (see above); hold it.
        setRateLocked(from, bent.rate(at: position), .rampGlide)
    }

    /// Put the outgoing deck back at unity if the glide had started bending it.
    ///
    /// A `.waiting` transition touches exactly one parameter of one deck, so
    /// this is the whole of "undo a pending hand-over". **Do not call it from
    /// the teardown paths** — the `transition` setter does, for every one of
    /// them at once, which is the only way this stays true as paths are added.
    /// `beginOverlapLocked` is the sole other caller, and it clears the flag
    /// rather than the rate: there the overlap automation takes the rate over
    /// on its very first tick.
    private func endTempoRampLocked(_ tr: TransitionState) {
        guard tr.rampActive else { return }
        tr.rampActive = false
        tr.rampFrom = nil
        guard let from = deckStates[tr.from] else { return }
        PlaybackJournal.note(String(
            format: "ramp glide end deck=%@ was=×%.4f → ×1.0000 (plan lost or overlap took over)",
            tr.from.rawValue, from.timePitch.rate))
        setRateLocked(from, 1, .rampEnd)
        // The pad exists only to cover the bend; the bend is gone, so it goes
        // with it — but *glided*, not snapped. This deck is still playing, and
        // it is the same several dB going back up that went carefully down.
        releaseRatePadLocked(from)
    }

    /// Put the *incoming* deck back at unity if the post-seam rate release was
    /// still gliding it. `endTempoRampLocked`'s mirror image, for the other
    /// deck and the other half of the hand-over.
    ///
    /// The two are deliberately separate rather than one function taking a
    /// deck, because the thing being undone is different: the pre-seam glide is
    /// a plan the deck has not yet paid for, while this is a release already in
    /// progress on the deck that is carrying the music. Snapped rather than
    /// glided for exactly that reason — the glide it was on lived in
    /// `settleTickLocked`, which stops the moment the transition is gone, so
    /// there is no longer anything that *could* finish the walk. A step at up to
    /// 6 % is audible, and it is the price of the alternative being a deck left
    /// there permanently.
    ///
    /// Guarded on `restoringRate`, the same way its twin is guarded on
    /// `rampActive`: `settleTickLocked` clears the flag the instant the release
    /// lands, so a hand-over that finished normally reaches this and does
    /// nothing. **Do not call it from the teardown paths** — the `transition`
    /// setter does, for all of them at once.
    private func endRateRestoreLocked(_ tr: TransitionState) {
        guard tr.restoringRate else { return }
        tr.restoringRate = false
        guard let to = deckStates[tr.to] else { return }
        PlaybackJournal.note(String(
            format: "rate release cut short deck=%@ was=×%.4f → ×1.0000 (plan lost mid-settle)",
            tr.to.rawValue, to.timePitch.rate))
        setRateLocked(to, 1, .rateRestoreEnd)
        // And the pad that was covering the bend goes with it — glided, not
        // snapped, for the same reason as the ramp's: this deck is still
        // playing, so it is the deck's own timer that walks the gain home.
        releaseRatePadLocked(to)
    }

    /// The wait can span minutes; idle at the slow tick and only switch to
    /// the 50 Hz ramp tick for the final approach.
    ///
    /// A running tempo glide also demands the fast tick, for the whole of its
    /// lead rather than the last two seconds: at the slow tick a 0.5 %/s glide
    /// would advance in 0.125 % steps, about 2 cents each, which on a sustained
    /// note is a staircase rather than a drift. At 50 Hz the step is 0.01 %.
    private func adjustWaitTimerLocked(remaining: TimeInterval, ramping: Bool = false) {
        startTransitionTimerLocked(
            interval: (ramping || remaining <= 2) ? tickInterval : slowTickInterval)
    }

    /// Undo an armed gapless hand-over (incoming deck scheduled on the host
    /// clock) without touching its loaded file; the wait tick re-arms later.
    private func disarmGaplessLocked() {
        guard let tr = transition, tr.phase == .armed else { return }
        let to = deckStates[tr.to]!
        to.generation += 1
        to.player.stop()
        to.isPlaying = false
        to.scheduledStartHostTime = nil
        to.startOffset = 0
        clearPauseSkewLocked(to)
        to.lastKnownPosition = 0
        tr.phase = .waiting
    }

    private func armGaplessLocked(_ tr: TransitionState, startingIn seconds: TimeInterval) {
        let to = deckStates[tr.to]!
        guard case .file(let file) = to.source else {
            // Contract violation: the to deck was not loaded. Drop the plan;
            // the from deck will finish naturally and emit deckFinished.
            transition = nil
            stopTransitionTimerLocked()
            return
        }
        scheduleSegmentLocked(to, file: file, from: 0, deck: tr.to, .gaplessArm)
        setFaderLocked(to, 1, .gaplessArm)
        to.isPlaying = true
        let startHost = mach_absolute_time() &+ AVAudioTime.hostTime(forSeconds: seconds)
        playOnHostClockLocked(to, at: AVAudioTime(hostTime: startHost), from: 0, .gaplessArm)
        tr.phase = .armed
    }

    private func beginOverlapLocked(_ tr: TransitionState) {
        let to = deckStates[tr.to]!
        ensureEngineRunningLocked()
        let inPoint: TimeInterval
        switch tr.plan {
        case .crossfade(_, _, let point):
            inPoint = point
        case .beatMatched(let plan):
            inPoint = plan.inPoint
        case .gapless:
            return
        }

        // Start the incoming source FIRST, and only prime the deck (matched
        // rate, staged EQ cut) once the overlap is certain to run.
        //
        // Priming first is how a dropped plan used to strand the incoming deck
        // at -24/-18/-24 dB: nothing releases those bands except the ramps
        // that then never ran, `play(deck:from:)` reuses a deck exactly as it
        // finds it, and the whole next song came out muffled.
        switch to.source {
        case .file(let file):
            scheduleSegmentLocked(to, file: file, from: inPoint, deck: tr.to, .overlapBegin)
        case .convertedFile(let feeder):
            seekFeederLocked(to, feeder: feeder, to: inPoint, .overlapBegin)
        case .stream, .none:
            // Contract violation: the incoming deck was never loaded, or was
            // reloaded as a stream under a plan that was still waiting. Drop
            // the plan and leave the deck as neutral as we found it.
            neutralizeEffectsLocked(to)
            transition = nil
            stopTransitionTimerLocked()
            return
        }

        if case .beatMatched(let plan) = tr.plan {
            setRateLocked(to, plan.incomingRate, .overlapBegin)
            // The incoming deck is bent from its very first sample, so its pad
            // goes on at full value right here — the same argument the gain
            // ride makes a few lines below: the fader is about to be written to
            // 0, so there is nothing audible for the step to land on.
            setRatePadLocked(to, db: padTargetLocked(to))
            if !tr.style.stagedEQ { to.band(.low).gain = Self.bassCutDB }
        }
        if tr.style.stagedEQ {
            // The incoming track is held back on all three bands and is let
            // in stage by stage (highs first, lows at the swap).
            to.band(.low).gain = Self.bassCutDB
            to.band(.mid).gain = Self.midCutDB
            to.band(.high).gain = Self.highCutDB
        }
        // The gain ride goes on here, at full value and with no ramp: the
        // incoming fader is about to be written to 0, so there is nothing
        // audible for the step to land on. From this instant every fader write
        // for this deck — the whole overlap curve — is scaled by it.
        setRideLocked(to, db: tr.rideDB)
        setFaderLocked(to, 0, .overlapBegin)
        to.isPlaying = true
        startNodeIfNeededLocked(to)
        PlaybackJournal.note(
            "overlap begin \(tr.from.rawValue)→\(tr.to.rawValue) "
                + String(format: "in=%.3f overlap=%.3f swap=%.3f stagedEQ=%@ ",
                         inPoint, tr.overlapDuration, tr.swapOffset,
                         tr.style.stagedEQ ? "yes" : "no")
                + "\(journalRates)")
        // The "recovered" phase of the underwater hunt: the field reports the
        // muffle lifting right around here, so this capture is the bright half
        // of the per-song A/B against the t+25s one.
        captureOutputTapLocked(seconds: 8, label: "overlap")
        tr.phase = .overlapping
        tr.elapsed = 0
        tr.lastTickUptime = ProcessInfo.processInfo.systemUptime
        // The overlap automation writes the outgoing rate from here on (flat at
        // `outgoingRate` for a ramped plan, since the glide has already landed
        // it there), so the ramp has nothing left to hand back.
        tr.rampActive = false
        startTransitionTimerLocked(interval: tickInterval)
    }

    // MARK: - Pre-rendered segment splice (locked)

    /// Seconds the segment player has emitted, or nil before its scheduled
    /// start time arrives (`play(at:)` reports a negative sample time until
    /// then) or while the engine cannot say.
    ///
    /// This is the splice's only clock. Everything the tick does — the two
    /// crossfades, the midpoint, the hand-back — is a function of it, so the
    /// 50 Hz tick only decides *when* a parameter is written, never *what* it
    /// is: a late tick lands the same value it would have landed on time.
    private func segmentElapsedLocked() -> TimeInterval? {
        guard let nodeTime = Self.renderedNodeTime(segmentState.player),
              let playerTime = segmentState.player.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0, playerTime.sampleTime >= 0 else { return nil }
        // Same correction as `livePositionLocked`: a segment that was sounding
        // when the engine paused freezes with it, and its node clock does not.
        return PausedClockSkew.position(
            raw: Double(playerTime.sampleTime) / playerTime.sampleRate,
            startOffset: 0, skew: segmentState.pauseSkew)
    }

    /// Put the segment on the render clock so its first sample lands exactly
    /// where the outgoing deck's `spliceStart` frame does. Returns false when
    /// the clock cannot be read or the moment has already passed, which is the
    /// caller's cue to fall back to the live overlap.
    private func armSegmentLocked(_ tr: TransitionState,
                                  segment: TransitionSegment) -> Bool {
        let from = deckStates[tr.from]!
        let sampleRate = graphFormat.sampleRate
        let frame = AVAudioFramePosition(
            ((segment.spliceStart - from.startOffset) * sampleRate).rounded())
        let now = mach_absolute_time()
        guard frame >= 0, from.player.isPlaying,
              let start = from.player.nodeTime(
                forPlayerTime: AVAudioTime(sampleTime: frame, atRate: sampleRate)),
              start.isHostTimeValid,
              start.hostTime > now
        else { return false }

        // `nodeTime(forPlayerTime:)` extrapolates at the player node's own
        // sample rate, i.e. it assumes one source frame takes 1/sr of wall
        // time. A deck the tempo glide has bent is emitting those frames
        // `1/rate` times slower, so the splice would land up to ~6 % of the arm
        // lead early. Stretch the interval by the rate rather than trust it.
        // Exactly the same host time when the deck is at unity — every plan
        // without a ramp.
        //
        // And then hold the segment back by the live deck's measured output
        // latency. Everything above computes when the deck's *player clock*
        // reaches `spliceStart`; what has to coincide with the segment's first
        // sample is when that frame is **audible**, and the outgoing deck's
        // engaged time-pitch unit puts those two ~19 ms apart on this hardware.
        // Without this term the segment opens ahead of the deck it is supposed
        // to be identical to, and the half-second identity crossfade is a comb
        // filter — the doubled beat the field reported. See
        // `SeamLatencyCalibration` for where the number comes from and how it
        // re-measures itself.
        let deckRate = Double(from.timePitch.rate)
        let compensation = SeamLatencyStore.shared.headCompensationSeconds(
            pin: headLatencyPinMS)
        let ahead = AVAudioTime.seconds(forHostTime: start.hostTime &- now)
        let lead = SeamRelease.lead(rawLead: ahead, deckRate: deckRate,
                                    compensation: compensation)
        let startTime = AVAudioTime(
            hostTime: now &+ AVAudioTime.hostTime(forSeconds: lead))
        SeamLatencyStore.shared.noteArmed(milliseconds: compensation * 1000,
                                          pinned: headLatencyPinMS != nil)

        ensureEngineRunningLocked()
        segmentState.generation += 1
        clearPauseSkewLocked(segmentState)
        trace.record(.stop, .segment, .spliceArm, 0, 0)
        segmentState.player.stop()
        trace.record(.scheduleBuffer, .segment, .spliceArm,
                     Double(segment.buffer.frameLength), 0, 0)
        segmentState.player.scheduleBuffer(segment.buffer, at: nil, options: [],
                                           completionHandler: nil)
        // Silent until the head crossfade opens it: the segment's first half
        // second duplicates what the outgoing deck is already playing.
        segmentState.fader = 0
        segmentState.faderRequest = 0
        playOnHostClockLocked(segmentState, at: startTime, from: 0, .spliceArm)
        // The deck's own splice instant, without the compensation: the origin
        // every head window is placed against, and half of the pair whose
        // difference the seam-offset measurement reports.
        let deckSpliceHost = now &+ AVAudioTime.hostTime(
            forSeconds: SeamRelease.lead(rawLead: ahead, deckRate: deckRate,
                                         compensation: 0))
        seamOffsetContext = SeamOffsetContext(
            segment: segment,
            outgoingURL: Self.seamSourceURL(of: from.source),
            incomingURL: Self.seamSourceURL(of: deckStates[tr.to]!.source),
            deckSpliceHost: deckSpliceHost,
            segmentStartHost: startTime.hostTime,
            deckRate: deckRate,
            appliedMilliseconds: compensation * 1000)
        PlaybackJournal.note(String(
            format: "splice armed %@→%@ spliceStart=%.3f duration=%.3f head=%.3f tail=%.3f"
                + " comp=%+.1fms ",
            tr.from.rawValue, tr.to.rawValue, segment.spliceStart, segment.duration,
            segment.handoffIn, segment.handoffOut, compensation * 1000) + journalRates)
        // The head crossfade, on tape. Started at the arm rather than at the
        // splice instant because the arm is the last moment we are *sure* to
        // be on the queue before it: the release is up to a couple of seconds
        // out and nothing runs between here and the node's first sample.
        // Six seconds covers that lead, the half-second identity crossfade and
        // the run-out either side of it.
        captureOutputTapLocked(seconds: 6, label: "head")
        tr.phase = .segmentArmed
        startTransitionTimerLocked(interval: tickInterval)
        return true
    }

    /// Waiting for the scheduled start. If it never comes (a configuration
    /// change dropped the schedule, the render clock stalled), the splice point
    /// simply passes and the hand-over falls back to the live overlap.
    private func segmentArmedTickLocked(_ tr: TransitionState) {
        guard let segment = tr.segment else {
            disarmSegmentLocked()
            return
        }
        if segmentElapsedLocked() != nil {
            tr.phase = .segmentPlaying
            updateSegmentLocked(tr)
            return
        }
        let position = livePositionLocked(deckStates[tr.from]!)
        // `position` is on the outgoing song's clock, so the head window has to
        // be measured there too (they differ under a tempo ramp).
        if position > segment.spliceStart + segment.headSourceSpan + 0.5 {
            disarmSegmentLocked()
            tr.segment = nil
        }
    }

    /// Take the segment back off the render clock, leaving the outgoing deck
    /// exactly as it was found. Only valid while nothing has been handed over
    /// yet (`.segmentArmed`).
    private func disarmSegmentLocked() {
        guard let tr = transition, tr.phase == .segmentArmed else { return }
        parkSegmentLocked()
        // The head capture is still running and its "after" window was placed
        // where a segment that will now never sound was going to be. Dropping
        // the context is how that capture reports nothing instead of a
        // confident measurement of the wrong audio. Deliberately not in
        // `parkSegmentLocked`, which the *completing* path also calls — there
        // the tail's capture still has four seconds to run and needs this.
        seamOffsetContext = nil
        tr.phase = .waiting
    }

    /// Undo an incoming deck that has been scheduled for the segment's tail but
    /// has not started sounding yet — its `play(at:)` is on the host clock,
    /// which keeps running while the engine is paused.
    ///
    /// A converted deck's pre-roll goes with it: the node is stopped either way,
    /// so its queued chunks are gone, and `updateSegmentLocked` re-cues both
    /// from scratch once the segment's clock is running again.
    private func disarmSegmentTailLocked() {
        guard let tr = transition, tr.phase == .segmentPlaying,
              let segment = tr.segment,
              let elapsed = segmentElapsedLocked(), elapsed < segment.handoffOutStart
        else { return }
        let to = deckStates[tr.to]!
        guard to.isPlaying || tr.tailPrerolled else { return }
        cancelTailPrerollLocked(tr)
        guard to.isPlaying else { return }
        to.generation += 1
        hardSilenceFaderLocked(to)
        trace.record(.stop, to.traceDeck, .spliceTailCancel,
                     to.lastKnownPosition, Double(to.generation))
        to.player.stop()
        to.isPlaying = false
    }

    private func parkSegmentLocked() {
        segmentState.generation += 1
        segmentState.fader = 0
        segmentState.faderRequest = 0
        segmentState.player.stop()
    }

    /// One tick of a playing segment: the head crossfade off the outgoing
    /// deck, the midpoint latch, the tail crossfade back onto the incoming one.
    private func updateSegmentLocked(_ tr: TransitionState) {
        guard let segment = tr.segment, let elapsed = segmentElapsedLocked() else { return }
        let from = deckStates[tr.from]!
        let to = deckStates[tr.to]!

        // --- Head. The segment opens with the same audio the outgoing deck is
        // playing, at the same trim, so the two are crossfaded *linearly*: for
        // identical material `(1-u)·x + u·x` is `x`, and the swap is silent.
        if from.isPlaying {
            if elapsed < segment.handoffIn {
                let u = Float(max(0, elapsed / segment.handoffIn))
                setFaderLocked(from, 1 - u, .spliceHead)
                setSegmentFaderLocked(u)
            } else {
                setSegmentFaderLocked(1)
                PlaybackJournal.note(String(
                    format: "splice head done deck=%@ retired at=%.3f ",
                    tr.from.rawValue, elapsed) + journalRates)
                retireOutgoingForSegmentLocked(from)
            }
        }

        if !tr.midpointSent, elapsed >= segment.midpointOffset {
            tr.midpointSent = true
            eventContinuation.yield(.transitionMidpoint(
                from: tr.from, to: tr.to,
                via: TransitionOutcome(path: .splicedSegment, plan: tr.plan)))
        }

        // --- Tail, the head's mirror image: the incoming deck is started on
        // the segment's own clock, playing the same audio the segment's last
        // half second carries, and the two are crossfaded the same way.
        let tailStart = segment.handoffOutStart
        // The hand-back, on tape, from the pre-roll window rather than the
        // crossfade itself — the same six seconds as the head, spanning the
        // 1.5 s before the tail and the 4.5 s after, so a doubled δ shows up
        // against clean audio on both sides of it. One capture runs at a time
        // (`captureOutputTapLocked`), and by here the head's six seconds are
        // long finished: the shortest segment we render is far longer.
        if !tr.tailCaptured, elapsed >= tailStart - Self.segmentTailPreroll {
            tr.tailCaptured = captureOutputTapLocked(seconds: 6, label: "tail")
        }
        if !to.isPlaying, !tr.tailPrerolled, case .convertedFile(let feeder) = to.source,
           elapsed >= tailStart - Self.segmentTailPreroll {
            tr.tailPrerolled = true
            prerollIncomingFeederLocked(to, feeder: feeder, at: segment.incomingResume)
        }
        if !to.isPlaying, elapsed >= tailStart - Self.segmentArmLead {
            startIncomingFromSegmentLocked(tr, segment: segment)
        }
        if to.isPlaying, elapsed >= tailStart {
            let u = Float(min(1, max(0, (elapsed - tailStart) / max(segment.handoffOut, 1e-3))))
            setFaderLocked(to, u, .spliceTail)
            setSegmentFaderLocked(1 - u)
        }
        if elapsed >= segment.duration - tickInterval {
            finishSegmentLocked(tr)
        }
    }

    /// The segment's fader. Deliberately not `setFaderLocked`: the segment
    /// deck has no trim and no ride (both are already baked into the rendered
    /// audio), and it must never be caught by a deck's flush window.
    private func setSegmentFaderLocked(_ value: Float) {
        segmentState.faderRequest = value
        segmentState.fader = value
    }

    /// The outgoing deck has been crossfaded away. Stopped and silenced, but
    /// deliberately **not** `resetDeckLocked`: its file stays loaded so an
    /// aborted splice can resume normal playback from the mapped position.
    ///
    /// **Why it can leave the ride/pad bookkeeping alone.** This deck was bent
    /// and padded by the pre-seam glide, and nothing here hands either back —
    /// which is safe only because two other things always do, between them
    /// covering every way out of the splice. The completing path is
    /// `finishSegmentLocked`, which calls `resetDeckLocked` on this deck a few
    /// lines later. Every *other* path goes through the `transition` setter, and
    /// `endTempoRampLocked` still fires there because `rampActive` is untouched
    /// on the segment path: only `beginOverlapLocked` clears that flag, and a
    /// spliced hand-over never runs it. So an abort resumes this deck with its
    /// rate at unity and its pad already gliding home, and a completion resets
    /// it outright. Leaving the deck stopped-but-loaded here is what makes the
    /// abort possible; the invariant is what makes it clean.
    private func retireOutgoingForSegmentLocked(_ state: DeckState) {
        state.generation += 1   // orphan the completion the stop fires
        hardSilenceFaderLocked(state)
        trace.record(.stop, state.traceDeck, .spliceRetire,
                     state.lastKnownPosition, Double(state.generation))
        state.player.stop()
        neutralizeEffectsLocked(state)
        state.isPlaying = false
    }

    /// Cue a converted-file incoming deck for the segment's hand-back *without*
    /// starting it.
    ///
    /// A `.file` deck is cued and released in one breath, because
    /// `scheduleSegment` is synchronous and frame-exact. A feeder is neither: it
    /// opens the file, seeks and resamples on its own queue, so it is started
    /// here — up to `segmentTailPreroll` before the tail — and its chunks pile
    /// up on a node that is still stopped. `hostScheduledStart` is what keeps
    /// them piling instead of playing: the feeder's delivery callback ends in
    /// `startNodeIfNeededLocked`, which would otherwise open the hand-back the
    /// moment the first chunk landed.
    ///
    /// No `beginFaderFlushLocked`, unlike the seek path this otherwise mirrors:
    /// the deck is silent and stopped, there is nothing in its chain to push
    /// out, and a flush window would still be holding the fader down when the
    /// tail crossfade tries to raise it.
    private func prerollIncomingFeederLocked(_ state: DeckState, feeder: FileFeeder,
                                             at seconds: TimeInterval) {
        state.generation += 1
        state.player.stop()
        // The deck may have been idle for minutes since its last glide, which
        // is exactly the state the underwater timePitch was caught in. Its DSP
        // state has no business surviving into the track about to be fed.
        resetChainDSPLocked(state, .spliceTailPreroll)
        state.pendingStreamBuffers = 0
        state.streamEnded = false
        state.streamStalled = false
        state.feederStarved = false
        state.startOffset = seconds
        clearPauseSkewLocked(state)
        state.lastKnownPosition = seconds
        state.hostScheduledStart = true
        returnToServiceLocked(state)
        trace.record(.scheduleBuffer, state.traceDeck, .spliceTailPreroll,
                     seconds, Double(state.generation))
        feeder.start(from: seconds)
        PlaybackJournal.note(String(
            format: "splice tail preroll deck=%@ resume=%.3f ",
            journalDeckName(state), seconds) + journalRates)
    }

    /// Undo a pre-roll that will not be used: the feeder is halted (not
    /// cancelled — the deck still holds the track) and the chunks queued on the
    /// node are flushed. Safe to call when nothing was pre-rolled.
    private func cancelTailPrerollLocked(_ tr: TransitionState) {
        guard tr.tailPrerolled else { return }
        tr.tailPrerolled = false
        let to = deckStates[tr.to]!
        to.hostScheduledStart = false
        to.scheduledStartHostTime = nil
        guard case .convertedFile(let feeder) = to.source else { return }
        to.generation += 1
        trace.record(.stop, to.traceDeck, .spliceTailCancel,
                     to.lastKnownPosition, Double(to.generation))
        feeder.stop()
        to.player.stop()
        to.pendingStreamBuffers = 0
        to.streamEnded = false
        to.streamStalled = false
        to.feederStarved = false
    }

    /// Cue the incoming deck to where the segment's tail is and start it on the
    /// render clock, so the deck and the segment are playing the same samples
    /// at the same time.
    ///
    /// Both local sources get the same host-time release; they differ only in
    /// how they were cued. A `.file` deck is scheduled here, frame-exact. A
    /// converted one was pre-rolled above and is waiting with chunks in hand —
    /// frame-exact at the file's own rate, which after the resampler is within
    /// a fraction of a millisecond of the requested instant, and the segment's
    /// half-second identity crossfade is there to absorb exactly that.
    private func startIncomingFromSegmentLocked(_ tr: TransitionState,
                                                segment: TransitionSegment) {
        let to = deckStates[tr.to]!
        switch to.source {
        case .file:
            break
        case .convertedFile:
            // Nothing to release yet: the pre-roll has not produced its first
            // chunk. The next tick asks again, and `finishSegmentLocked` still
            // covers a pre-roll that never arrives at all.
            guard tr.tailPrerolled, to.pendingStreamBuffers > 0 else { return }
        case .stream, .none:
            return
        }
        let sampleRate = graphFormat.sampleRate
        let frame = AVAudioFramePosition((segment.handoffOutStart * sampleRate).rounded())
        guard let start = segmentState.player.nodeTime(
                forPlayerTime: AVAudioTime(sampleTime: frame, atRate: sampleRate)),
              start.isHostTimeValid, start.hostTime > mach_absolute_time()
        else { return }
        if case .file(let file) = to.source {
            scheduleSegmentLocked(to, file: file, from: segment.incomingResume, deck: tr.to,
                                  .spliceTail)
        }
        // The ride is still unwinding where the segment ends; the deck picks it
        // up at that value and finishes the release on its own glide timer.
        setRideLocked(to, db: segment.incomingRideDB)
        setFaderLocked(to, 0, .spliceTail)
        playOnHostClockLocked(to, at: start, from: segment.incomingResume, .spliceTail)
        // The tail capture is already running and will outlive this transition;
        // its "after" window is placed against exactly this instant.
        seamOffsetContext?.tailStartHost = start.hostTime
        // Only now: `play(at:)` has claimed the node, so an ordinary start can
        // no longer jump ahead of the host clock, and the deck has to look
        // playing to the rest of the engine (the fader flush, the pause path).
        to.hostScheduledStart = false
        to.isPlaying = true
        PlaybackJournal.note(String(
            format: "splice tail start deck=%@ resume=%.3f ride=%+.2fdB ",
            tr.to.rawValue, segment.incomingResume, segment.incomingRideDB) + journalRates)
    }

    private func finishSegmentLocked(_ tr: TransitionState) {
        let from = deckStates[tr.from]!
        let to = deckStates[tr.to]!
        if !tr.midpointSent {
            tr.midpointSent = true
            eventContinuation.yield(.transitionMidpoint(
                from: tr.from, to: tr.to,
                via: TransitionOutcome(path: .splicedSegment, plan: tr.plan)))
        }
        if !to.isPlaying, let segment = tr.segment {
            // The tail never started (the clock was unavailable at the arm
            // point). Start the incoming deck now: a few milliseconds of seam
            // is worth more than a silent deck.
            cancelTailPrerollLocked(tr)
            switch to.source {
            case .file(let file):
                scheduleSegmentLocked(to, file: file, from: segment.incomingResume,
                                      deck: tr.to, .spliceFinish)
                setRideLocked(to, db: segment.incomingRideDB)
                to.isPlaying = true
                startNodeIfNeededLocked(to)
            case .convertedFile(let feeder):
                // The pre-roll is re-run rather than released: it was cued for a
                // host time that never came, and `seekFeederLocked` is the one
                // path that puts a converted deck on the air from a standstill.
                seekFeederLocked(to, feeder: feeder, to: segment.incomingResume, .spliceFinish)
                setRideLocked(to, db: segment.incomingRideDB)
                to.isPlaying = true
                startNodeIfNeededLocked(to)
            case .stream, .none:
                break
            }
        }
        tr.tailPrerolled = false
        setFaderLocked(to, 1, .spliceFinish)
        releaseRideLocked(to)
        // The segment rendered its own rate release, so the deck picking the
        // track up at the tail is playing unbent audio and must be at unity to
        // match. It is the only completion path that never otherwise touches
        // the incoming chain, and "the deck was already neutral" is an
        // assumption about every caller rather than something stated here.
        neutralizeEffectsLocked(to)
        parkSegmentLocked()
        if from.isPlaying { retireOutgoingForSegmentLocked(from) }
        resetDeckLocked(from)
        PlaybackJournal.note("transition complete via=splice "
                             + "\(tr.from.rawValue)→\(tr.to.rawValue) "
                             + String(format: "ride=%+.2fdB ", to.rideDB) + journalRates)
        eventContinuation.yield(.transitionCompleted(from: tr.from, to: tr.to))
        dumpEngineTraceLocked(reason: "seam")
        transition = nil
        stopTransitionTimerLocked()
    }

    /// Abort a playing segment and put the decks back in charge, at whatever
    /// position the segment had reached on their own timelines.
    ///
    /// Before the midpoint the outgoing track is still "the song", so it comes
    /// back; after it, the incoming one is, so it takes over — the same rule
    /// `cancelTransitionLocked` applies to a live overlap.
    private func abortSegmentLocked(_ tr: TransitionState) {
        guard let segment = tr.segment else { return }
        let from = deckStates[tr.from]!
        let to = deckStates[tr.to]!
        let elapsed = segmentElapsedLocked() ?? 0
        parkSegmentLocked()

        if tr.midpointSent {
            if !to.isPlaying {
                cancelTailPrerollLocked(tr)
                var cued = true
                switch to.source {
                case .file(let file):
                    scheduleSegmentLocked(to, file: file,
                                          from: segment.incomingTime(at: elapsed),
                                          deck: tr.to, .spliceAbort)
                case .convertedFile(let feeder):
                    seekFeederLocked(to, feeder: feeder,
                                     to: segment.incomingTime(at: elapsed), .spliceAbort)
                case .stream, .none:
                    cued = false
                }
                if cued {
                    setRideLocked(to, db: segment.incomingRideDB)
                    to.isPlaying = true
                    startNodeIfNeededLocked(to)
                }
            }
            setFaderLocked(to, 1, .spliceAbort)
            // Same as a normal finish: this deck is the track now, so both of
            // its deck-level gains are let go of gently rather than snapped.
            releaseRideLocked(to)
            releaseRatePadLocked(to)
            neutralizeEffectsLocked(to)
            resetDeckLocked(from)
            eventContinuation.yield(.transitionCompleted(from: tr.from, to: tr.to))
            return
        }

        // The hand-over never became audible: the incoming deck goes back to
        // parked-and-loaded, and the outgoing one resumes where the segment
        // had got to in its own track. A pre-roll that had been cued for the
        // tail is part of "parked": left running it would keep converting into
        // a node this deck's next caller expects to find empty.
        cancelTailPrerollLocked(tr)
        if to.isPlaying {
            to.generation += 1
            hardSilenceFaderLocked(to)
            trace.record(.stop, to.traceDeck, .spliceAbort,
                         to.lastKnownPosition, Double(to.generation))
            to.player.stop()
            to.isPlaying = false
        }
        neutralizeEffectsLocked(to)
        setRideLocked(to, db: 0)
        setRatePadLocked(to, db: 0)
        neutralizeEffectsLocked(from)
        let resumeAt = segment.outgoingTime(at: elapsed)
        switch from.source {
        case .file(let file):
            scheduleSegmentLocked(from, file: file, from: resumeAt, deck: tr.from, .spliceResume)
        case .convertedFile(let feeder):
            seekFeederLocked(from, feeder: feeder, to: resumeAt, .spliceResume)
        case .stream, .none:
            return
        }
        setFaderLocked(from, 1, .spliceResume)
        from.isPlaying = true
        startNodeIfNeededLocked(from)
    }

    /// Void a pending/running transition that depends on `deck`, leaving both
    /// of its decks in a defined state (this is `cancelTransitionLocked`, just
    /// scoped to the decks that matter).
    private func invalidateTransitionLocked(touching deck: Deck) {
        guard let tr = transition, tr.from == deck || tr.to == deck else { return }
        cancelTransitionLocked()
    }

    /// Is a transition currently driving this deck's knobs? Only true once the
    /// hand-over is actually running — a `.waiting` plan has touched nothing
    /// yet, so a deck under one may still be normalized freely.
    private func deckIsInLiveTransitionLocked(_ deck: Deck) -> Bool {
        guard let tr = transition, tr.phase != .waiting else { return false }
        return tr.from == deck || tr.to == deck
    }

    /// Park a deck: silent at the mixer and every knob transparent. Used on
    /// the paths that end a deck's contribution outside `resetDeckLocked`
    /// (echo tail finished, transition cancelled while settling).
    private func silenceDeckLocked(_ state: DeckState) {
        hardSilenceFaderLocked(state)
        neutralizeEffectsLocked(state)
    }

    /// Post-overlap phase: ramp a beat-matched rate back to 1.0 on the
    /// incoming deck and/or decay an `.echoOut` tail on the outgoing one.
    /// Ends — clearing the transition — only when both are done and both
    /// decks are back to neutral.
    private func settleTickLocked(_ tr: TransitionState) {
        let from = deckStates[tr.from]!
        let to = deckStates[tr.to]!
        var done = true

        if tr.restoringRate {
            let settle = TransitionAutomation.settleFrame(
                plan: tr.plan, restoringRate: true, echoTailRinging: false,
                elapsed: tr.restoreElapsed)
            setRateLocked(to, settle.incomingRate, .settleTick)
            if settle.rateRestoreDone {
                tr.restoringRate = false
                PlaybackJournal.note(String(
                    format: "rate release DONE deck=%@ final=×%.4f after=%.3fs ",
                    tr.to.rawValue, to.timePitch.rate, tr.restoreElapsed) + journalRates)
                // Back at unity rate, so the pad has nothing left to cover.
                // Released here rather than alongside the rate glide because
                // it is a gain move and the rate is not: the rate hurries back
                // to get out of the phase vocoder, the pad only has to be
                // inaudible, and dropping it early would un-pad a deck that is
                // still bent.
                releaseRatePadLocked(to)
            } else {
                done = false
            }
        }

        if tr.echoTailRinging {
            let settle = TransitionAutomation.settleFrame(
                plan: tr.plan, restoringRate: false, echoTailRinging: true,
                elapsed: tr.restoreElapsed)
            // Wet level down alongside the delay's own feedback decay, so the
            // tail dies out instead of being chopped.
            from.delay.wetDryMix = settle.outgoingDelayWetDryMix
            from.delay.feedback = settle.outgoingDelayFeedback
            if settle.echoTailDone {
                tr.echoTailRinging = false
                silenceDeckLocked(from)
            } else {
                done = false
            }
        }

        if done {
            transition = nil
            stopTransitionTimerLocked()
        }
    }

    /// One overlap tick: the curves come from `TransitionAutomation` (shared
    /// with the offline renderer), this only applies them to the live graph
    /// and latches the events the rest of the engine keys off.
    private func updateOverlapLocked(_ tr: TransitionState) {
        let from = deckStates[tr.from]!
        let to = deckStates[tr.to]!
        let frame = TransitionAutomation.frame(
            plan: tr.plan, style: tr.style, elapsed: tr.elapsed, geometry: tr.geometry)

        applyAutomationLocked(frame.outgoing, to: from)
        applyAutomationLocked(frame.incoming, to: to)

        // `.echoOut`'s throw is a one-shot event for the settling phase; the
        // curve itself is a pure function of "progress has crossed the stop
        // point", so the latch only records that it happened.
        if frame.echoThrown, !tr.echoThrown {
            tr.echoThrown = true
            tr.echoTailRinging = true
        }

        if frame.midpointReached, !tr.midpointSent {
            tr.midpointSent = true
            eventContinuation.yield(.transitionMidpoint(
                from: tr.from, to: tr.to,
                via: TransitionOutcome(path: .liveOverlap, plan: tr.plan)))
        }
        if frame.isComplete {
            finishOverlapLocked(tr)
        }
    }

    /// Write one automation frame's deck parameters onto a live chain. The
    /// fader goes through `setFaderLocked` so an open seek-flush window still
    /// holds the mute; everything else is a direct parameter write.
    private func applyAutomationLocked(_ p: TransitionAutomation.DeckParameters,
                                       to state: DeckState) {
        setFaderLocked(state, p.fader, .overlapAutomation)
        traceRateLocked(state, p.rate, .overlapAutomation)
        if DeckChain.apply(p, timePitch: state.timePitch, eq: state.eq,
                           delay: state.delay) {
            traceBypassLocked(state, .overlapAutomation)
        }
    }

    private func finishOverlapLocked(_ tr: TransitionState) {
        let to = deckStates[tr.to]!
        if !tr.midpointSent {
            tr.midpointSent = true
            eventContinuation.yield(.transitionMidpoint(
                from: tr.from, to: tr.to,
                via: TransitionOutcome(path: .liveOverlap, plan: tr.plan)))
        }
        // A thrown echo tail outlives the overlap: stop the outgoing player
        // (so nothing new feeds the delay) but leave the delay wet, and let
        // the settling phase decay it to neutral.
        let tailRinging = tr.echoThrown && tr.echoTailRinging
        resetDeckLocked(deckStates[tr.from]!, keepingEchoTail: tailRinging)
        setFaderLocked(to, 1, .overlapFinish)
        // "Fader fully open" now means the deck's trim *and* its ride; start
        // letting go of the latter. The release runs on the deck's own glide
        // timer, so it does not hold the transition open — this block may well
        // clear `transition` two lines below while the ride is still unwinding.
        releaseRideLocked(to)
        to.band(.low).gain = 0
        to.band(.mid).gain = 0
        to.band(.high).gain = 0
        to.band(.highPass).bypass = true
        PlaybackJournal.note("transition complete via=overlap "
                             + "\(tr.from.rawValue)→\(tr.to.rawValue) "
                             + String(format: "ride=%+.2fdB ", to.rideDB)
                             + "echoTail=\(tailRinging ? "ringing" : "none") \(journalRates) "
                             + "eq \(tr.from.rawValue)=\(deckStates[tr.from].map(journalEQ) ?? "?") "
                             + "\(tr.to.rawValue)=\(deckStates[tr.to].map(journalEQ) ?? "?")")
        eventContinuation.yield(.transitionCompleted(from: tr.from, to: tr.to))
        dumpEngineTraceLocked(reason: "seam")

        // A plan with a post-swap glide has normally landed the deck on unity
        // *inside* the overlap, so there is no release left to run: the
        // settling phase is skipped and the pad goes home immediately. That is
        // the glide working, not a missing step — the `else` branch below is
        // exactly what the release would have finished with.
        let rateRelease = TransitionAutomation.rateReleaseDuration(tr.plan)
        if case .beatMatched(let plan) = tr.plan, abs(plan.incomingRate - 1) > 0.001,
           rateRelease > 0 {
            tr.restoringRate = true
            PlaybackJournal.note(String(
                format: "rate release start deck=%@ from=×%.4f over=%.2fs ",
                tr.to.rawValue, to.timePitch.rate, rateRelease) + journalRates)
        } else {
            setRateLocked(to, 1, .overlapFinish)
            releaseRatePadLocked(to)
        }
        if tr.restoringRate || tailRinging {
            tr.phase = .settling
            tr.restoreElapsed = 0
            tr.lastTickUptime = ProcessInfo.processInfo.systemUptime
            startTransitionTimerLocked(interval: tickInterval)
        } else {
            transition = nil
            stopTransitionTimerLocked()
        }
    }

    /// The outgoing deck of an active transition drained naturally.
    private func handleFromDeckDrainedLocked(_ tr: TransitionState) {
        let from = deckStates[tr.from]!
        switch tr.plan {
        case .gapless:
            let to = deckStates[tr.to]!
            if tr.phase == .waiting || !to.player.isPlaying {
                // Never armed (streamed/converted outgoing deck, or a
                // configuration change dropped the armed schedule) — start
                // the incoming deck now.
                switch to.source {
                case .file(let file):
                    scheduleSegmentLocked(to, file: file, from: 0, deck: tr.to, .drainRestart)
                case .convertedFile(let feeder):
                    seekFeederLocked(to, feeder: feeder, to: 0, .drainRestart)
                case .stream, .none:
                    break
                }
                setFaderLocked(to, 1, .drainRestart)
                to.isPlaying = true
                ensureEngineRunningLocked()
                startNodeIfNeededLocked(to)
            }
            eventContinuation.yield(.transitionMidpoint(
                from: tr.from, to: tr.to,
                via: TransitionOutcome(path: .gapless, plan: tr.plan)))
            resetDeckLocked(from)
            PlaybackJournal.note("transition complete via=gapless "
                                 + "\(tr.from.rawValue)→\(tr.to.rawValue) \(journalRates)")
            eventContinuation.yield(.transitionCompleted(from: tr.from, to: tr.to))
            transition = nil
            stopTransitionTimerLocked()
        case .crossfade, .beatMatched:
            if tr.phase == .overlapping {
                // The file ended a hair before the ramp did — close it out.
                finishOverlapLocked(tr)
            } else {
                // The out point was never reached (plan beyond the file end):
                // behave like a plain natural finish. The deck is spent but it
                // is reused, and dropping the plan un-bends it.
                transition = nil
                stopTransitionTimerLocked()
                from.isPlaying = false
                eventContinuation.yield(.deckFinished(tr.from))
            }
        }
    }

    private func cancelTransitionLocked() {
        guard let tr = transition else { return }
        // Named before the teardown runs: "which path did this seam die down"
        // is the question the journal exists to answer, and each `case` below
        // hands the decks back differently.
        PlaybackJournal.note(
            "transition cancel teardown=\(tr.phase) midpointSent=\(tr.midpointSent) "
                + "\(tr.from.rawValue)→\(tr.to.rawValue) \(journalRates)")
        transition = nil
        stopTransitionTimerLocked()
        let from = deckStates[tr.from]!
        let to = deckStates[tr.to]!
        switch tr.phase {
        case .waiting:
            // Nothing audible has changed decks. Any tempo glide went back to
            // unity with the `transition = nil` above.
            break
        case .segmentArmed:
            // Nothing has been handed over yet; take the segment back off the
            // clock and leave the outgoing deck exactly as it is.
            parkSegmentLocked()
        case .segmentPlaying:
            abortSegmentLocked(tr)
        case .armed, .overlapping:
            if tr.midpointSent {
                // Past the audible midpoint the incoming deck IS the current
                // track — finish the hand-over immediately instead of
                // silencing it and resurrecting the outgoing tail.
                resetDeckLocked(from)
                setFaderLocked(to, 1, .cancelComplete)
                // Same as a normal finish: this deck is the track now, so its
                // ride is let go of gently rather than snapped away.
                releaseRideLocked(to)
                neutralizeEffectsLocked(to)
                eventContinuation.yield(.transitionCompleted(from: tr.from, to: tr.to))
                return
            }
            // The incoming deck may already be sounding: silence it but keep
            // its source loaded so the caller can reuse it; un-ramp the
            // outgoing deck. The fader goes down before the stop and stays
            // down for the same reason resetDeckLocked parks a deck silent —
            // stop() leaves ~200 ms draining out of the chain.
            to.generation += 1
            hardSilenceFaderLocked(to)
            trace.record(.stop, to.traceDeck, .cancelUnramp,
                         to.lastKnownPosition, Double(to.generation))
            to.player.stop()
            neutralizeEffectsLocked(to)
            // The hand-over never happened, so neither did its ride. The deck
            // is silent, so dropping it is inaudible; leaving it would colour
            // whatever this deck is reused for next.
            setRideLocked(to, db: 0)
            setRatePadLocked(to, db: 0)
            to.isPlaying = false
            setFaderLocked(from, 1, .cancelUnramp)
            neutralizeEffectsLocked(from)
        case .settling:
            // The tail (if any) is cut short — a cancel means something else
            // needs these decks now. `to` is the deck now carrying the track,
            // so it keeps its fader; `from` is spent. A ride release on `to`
            // is left running: it belongs to the deck, not to this transition,
            // and whatever happens to that deck next settles or clears it.
            //
            // The interrupted rate release, and the bent-rate pad that was
            // covering it, are handed back by the `transition` setter's
            // invariant — which has already run, three lines above. This case
            // used to do both by hand, and being the *only* path that did is
            // precisely what made the strand fragile: every other way of losing
            // a settling transition would have left this deck bent. What is
            // left here is the ordinary chain tidy-up.
            neutralizeEffectsLocked(to)
            silenceDeckLocked(from)
        }
    }

    // MARK: - Output device (macOS)

    #if os(macOS)
    /// Point the engine's output at a specific CoreAudio device, or at the
    /// system default when `deviceID` is nil.
    ///
    /// This is macOS AirPlay support: a system-exposed AirPlay receiver is an
    /// ordinary CoreAudio device (transport 'airp'), and routing to it means
    /// setting the output unit's device — `AVRoutePickerView` routes AVPlayer,
    /// which this app no longer has. See `AudioOutputDevices`.
    ///
    /// The device can only be changed while the output unit is stopped, and
    /// changing it invalidates every player node's schedule exactly the way a
    /// hardware change does — so the resume path is the same one:
    /// `handleConfigurationChange` rebuilds the chains, puts the output tap
    /// back and restarts each deck from its cached position. Runs on `queue`
    /// like every other mutation, so it serialises against the
    /// AVAudioEngineConfigurationChange the switch itself provokes; neither
    /// path ever blocks on the other.
    ///
    /// Seam timing caveat: an AirPlay device adds a large output buffer
    /// (typically ~2 s). Position math reads the player node's clock, which is
    /// upstream of that buffer, so transitions still fire at the right place
    /// *in the stream*; what the listener hears is delayed as a whole, and the
    /// debug panel's countdown reaches zero before the seam is audible. Not
    /// compensated in v1 — see docs/automix-airplay.md.
    func setOutputDevice(_ deviceID: AudioDeviceID?) {
        queue.async { self.applyOutputDeviceLocked(deviceID) }
    }

    private func applyOutputDeviceLocked(_ deviceID: AudioDeviceID?) {
        guard let target = deviceID ?? AudioOutputDevices.defaultDeviceID() else {
            PlaybackJournal.note("output device change skipped: no target device")
            return
        }
        let unit = engine.outputNode.auAudioUnit
        guard unit.deviceID != target else { return }
        PlaybackJournal.note("output device change begin from=\(unit.deviceID) to=\(target)")
        engine.stop()
        do {
            try unit.setDeviceID(target)
        } catch {
            PlaybackJournal.note("output device change failed id=\(target) \(error)")
            // The old device is still wired; bring playback back on it rather
            // than leaving a stopped engine behind. Never a terminal path:
            // whatever CoreAudio thinks of the request, the rebuild below puts
            // the graph and both decks back on *something*.
        }
        // Setting the device provokes an AVAudioEngineConfigurationChange of its
        // own. This rebuild covers it, so the notification that follows is
        // told to stand down rather than tearing the graph down a second time
        // a few milliseconds later.
        ownConfigurationChangeUntil = Date().addingTimeInterval(1)
        handleConfigurationChange(reason: "device change")
        PlaybackJournal.note("output device change end id=\(unit.deviceID)")
    }

    // MARK: - Output overload sentinel (locked, macOS)

    /// **The dropout nothing else can see.**
    ///
    /// Every other instrument in this engine watches what *we* do: the trace
    /// ring records our writes, the taps record the samples we hand the mixer,
    /// the watchdog watches our playheads. A render callback that misses its
    /// deadline is none of those — the samples we produced were correct, the
    /// playhead moved, and the device simply had nothing to play for one cycle
    /// and clicked. CoreAudio posts `kAudioDeviceProcessorOverload` for exactly
    /// that, and it is the only witness there is.
    ///
    /// The listener lives on the device the output unit is currently on, so it
    /// has to move whenever the route does — `applyOutputDeviceLocked` and every
    /// graph rebuild call through here, and the old registration is removed
    /// before the new one goes down (a listener left on a departed device is
    /// both a leak and a lie about which hardware is complaining).
    private func refreshOverloadListenerLocked() {
        let device = engine.outputNode.auAudioUnit.deviceID
        guard device != overloadListenerDevice else { return }
        removeOverloadListenerLocked()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDeviceProcessorOverload,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Delivered on `queue`, so this is a locked context like any other.
            self?.handleOutputOverloadLocked(device: device)
        }
        let status = AudioObjectAddPropertyListenerBlock(device, &address, queue, block)
        guard status == noErr else {
            PlaybackJournal.note("output overload listener failed device=\(device) "
                                 + "status=\(status)")
            return
        }
        overloadListener = block
        overloadListenerDevice = device
    }

    private func removeOverloadListenerLocked() {
        guard let block = overloadListener, let device = overloadListenerDevice else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDeviceProcessorOverload,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(device, &address, queue, block)
        overloadListener = nil
        overloadListenerDevice = nil
    }

    /// One line and one count per overload; a dump at most every
    /// `EngineDumpThrottle.overloadInterval`, because a device that is missing
    /// its deadline misses a great many in a row and forty copies of the same
    /// second would roll every older specimen out of the directory.
    private func handleOutputOverloadLocked(device: AudioDeviceID) {
        overloadCount += 1
        trace.record(.alarm, .output, .overload, Double(device), Double(overloadCount))
        PlaybackJournal.note("output OVERLOAD device=\(device) count=\(overloadCount)")
        let now = EngineTraceRing.now()
        guard EngineDumpThrottle.shouldDump(now: now, lastDumpAt: lastOverloadDumpAt) else {
            return
        }
        lastOverloadDumpAt = now
        dumpEngineTraceLocked(reason: "overload")
    }
    #endif

    // MARK: - Configuration changes (locked)

    /// The engine stopped because the output hardware changed (new default
    /// device on macOS, route change on iOS). Player-node schedules are gone;
    /// rebuild the graph and resume every active deck from its cached
    /// position.
    /// Set by `applyOutputDeviceLocked` to the moment its own rebuild stops
    /// covering the notification the switch provokes. Read (and cleared) by the
    /// notification handler, which is why the window is short: a stale flag must
    /// never swallow a *genuine* hardware change, and a second of clock is more
    /// than CoreAudio takes to post the notification it already posted.
    private var ownConfigurationChangeUntil: Date?

    private func handleConfigurationChange(reason: String) {
        PlaybackJournal.note("graph rebuild begin reason=\(reason) "
                             + "paused=\(isPaused) \(journalRates)")
        rebuildGraphLocked()
        #if os(macOS)
        // The route may have moved; the sentinel follows it.
        refreshOverloadListenerLocked()
        #endif
        PlaybackJournal.note("graph rebuild end reason=\(reason) "
                             + "running=\(engine.isRunning) \(journalRates)")
    }

    /// Test hook: run the rebuild exactly as the hardware notification does.
    /// The notification itself cannot be provoked from a test (it is posted by
    /// CoreAudio for a device that really changed), and the path it runs is the
    /// one every deck has to survive.
    func simulateConfigurationChange() {
        queue.async { self.handleConfigurationChangeNotificationLocked() }
    }

    /// The notification's entry point: single-flight against the rebuild an
    /// explicit device switch has just done for it.
    private func handleConfigurationChangeNotificationLocked() {
        if let until = ownConfigurationChangeUntil {
            ownConfigurationChangeUntil = nil
            if Date() < until {
                PlaybackJournal.note("graph rebuild skipped reason=own device change")
                return
            }
        }
        handleConfigurationChange(reason: "hardware")
    }

    private func rebuildGraphLocked() {
        // An armed gapless hand-over died with the graph; disarm it so the
        // restart below doesn't blast the incoming deck from position zero.
        disarmGaplessLocked()
        // A pre-rendered segment died with it too, and unlike a deck it cannot
        // be resumed from a position: cancel the hand-over, which puts whichever
        // track is current back on its own deck at the mapped position for the
        // rescheduling loop below to pick up.
        if let tr = transition, tr.phase == .segmentArmed || tr.phase == .segmentPlaying {
            cancelTransitionLocked()
        }
        for state in deckStates.values {
            state.generation += 1 // orphan any in-flight completions
        }
        engine.stop()
        for state in deckStates.values {
            connectChainLocked(state, format: graphFormat)
        }
        // The master path too: a configuration change re-negotiates the output
        // node's format and can put `mainMixerNode` straight back onto it,
        // which would silently restore the pre-limiter topology — the one case
        // where the graph really is not immutable.
        connectMasterChainLocked()
        // The mixer's output format can have changed with the device; a tap
        // left over from the old one would be a format mismatch.
        installOutputSampleSinkLocked()
        let anyActive = deckStates.values.contains {
            if case .none = $0.source { return false }
            return true
        }
        guard anyActive else { return }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            // Never terminal. The decks are rescheduled below regardless, so a
            // later resume/seek — or the next configuration change, which a
            // device that comes back posts — starts them; a thrown start here
            // means the hardware is not ready, not that playback is over.
            PlaybackJournal.note("graph rebuild engine start failed \(error)")
        }

        for (deck, state) in deckStates {
            switch state.source {
            case .none:
                break
            case .file(let file):
                // Reschedule even when paused so resume() still works.
                scheduleSegmentLocked(state, file: file, from: state.lastKnownPosition,
                                      deck: deck, .graphRebuild)
                startNodeIfNeededLocked(state)
            case .convertedFile(let feeder):
                seekFeederLocked(state, feeder: feeder, to: state.lastKnownPosition, .graphRebuild)
                startNodeIfNeededLocked(state)
            case .stream(let loader):
                // Scheduled PCM was dropped with the graph; restart the
                // transfer from the cached position. This abandons the .part
                // cache write for this download (documented limitation).
                if loader.canSeek {
                    seekStreamLocked(state, deck: deck, to: state.lastKnownPosition, .graphRebuild)
                } else {
                    state.generation += 1
                    state.pendingStreamBuffers = 0
                }
                startNodeIfNeededLocked(state)
            }
        }
    }
}
#endif
