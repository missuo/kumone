import AVFoundation
import Foundation

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
/// Every effect node is attached and wired at init with neutral parameters
/// (all EQ gains 0, the high-pass band bypassed, the delay 100% dry), because
/// reconnecting the graph while the other deck renders throws an NSException.
/// `TransitionStyle` is executed purely by moving those parameters.
///
/// The user-facing volume lives on `mainMixerNode.outputVolume`; transition
/// fades use each deck's `playerNode.volume`.
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

    var outputVolume: Float {
        get { queue.sync { engine.mainMixerNode.outputVolume } }
        set { queue.async { self.engine.mainMixerNode.outputVolume = newValue } }
    }

    // MARK: - Private state (all confined to `queue`)

    private let queue = DispatchQueue(label: "app.kumone.playback-engine")
    private let engine = AVAudioEngine()
    private let eventContinuation: AsyncStream<PlaybackEngineEvent>.Continuation

    /// The one format every deck chain is wired with, fixed at init.
    /// Reconnecting a running engine's graph (to adopt a per-file format)
    /// throws NSException while the other deck renders — so the graph never
    /// changes; sources that don't match are converted into it instead
    /// (ProgressiveLoader for streams, FileFeeder for local files).
    private let graphFormat = DeckChain.format

    /// Everything one deck needs: nodes, source, clock offsets, stream flags.
    private final class DeckState {
        let player = AVAudioPlayerNode()
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
        /// and it lives below the user's volume (`mainMixerNode.outputVolume`),
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

        func band(_ band: EQBand) -> AVAudioUnitEQFilterParameters {
            eq.bands[band.rawValue]
        }
    }

    /// Fixed band assignment of every deck's 4-band EQ; see `DeckChain`, which
    /// the offline `audition` renderer builds its decks from too.
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
    private let segmentState = DeckState()

    private var isPaused = false
    private var sessionConfigured = false

    // Stream backpressure: pause the download when this many ~0.5s buffers
    // are scheduled but unplayed, resume below the low mark.
    private let streamHighWater = 40  // ≈ 20s of decoded PCM
    private let streamLowWater = 10

    // The transition's parameter curves — and the constants that shape them —
    // live in `TransitionAutomation`, so the offline `audition` renderer drives
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
        var midpointSent = false
        /// A pre-rendered stem hand-over for exactly this plan, if one was
        /// finished in time. Nil is the ordinary case and means the live
        /// two-deck overlap below runs, unchanged.
        var segment: TransitionSegment?
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
            let state = DeckState()
            DeckChain.configureBands(state.eq)
            DeckChain.configureDelay(state.delay)

            engine.attach(state.player)
            engine.attach(state.timePitch)
            engine.attach(state.eq)
            engine.attach(state.delay)
            states[deck] = state
        }
        deckStates = states

        DeckChain.configureBands(segmentState.eq)
        DeckChain.configureDelay(segmentState.delay)
        engine.attach(segmentState.player)
        engine.attach(segmentState.timePitch)
        engine.attach(segmentState.eq)
        engine.attach(segmentState.delay)

        // Touch the mixer so it is wired to the output before first start.
        engine.mainMixerNode.outputVolume = 1

        // Wire all three chains once, before the engine ever starts — the graph
        // is immutable from here on (see graphFormat).
        for state in deckStates.values {
            connectChainLocked(state, format: graphFormat)
        }
        connectChainLocked(segmentState, format: graphFormat)
        segmentState.player.volume = 0

        // Output device / route changes stop the engine and wipe every player
        // node's schedule — on macOS this fires when switching audio devices,
        // on iOS on route changes. Rebuild and resume from the cached
        // positions, or playback dies the moment headphones are plugged in.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.handleConfigurationChange() }
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
                forPeakDBFS: peakDBFS, afterTrimDB: trimDB)
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
            }
            state.format = graphFormat
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
            let generation = state.generation
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
            loader.onCompleted = { [weak self, weak loader] cacheCommitted in
                guard let self, let loader,
                      let state = self.deckStates[deck],
                      case .stream(let current) = state.source, current === loader else { return }
                state.streamEnded = true
                if cacheCommitted {
                    self.eventContinuation.yield(.streamDownloadCompleted(deck))
                }
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
            self.setFaderLocked(state, 1)
            self.ensureEngineRunningLocked()
            switch state.source {
            case .none:
                break
            case .file(let file):
                state.isPlaying = true
                self.scheduleSegmentLocked(state, file: file, from: seconds, deck: deck)
                self.startNodeIfNeededLocked(state)
            case .convertedFile(let feeder):
                state.isPlaying = true
                self.seekFeederLocked(state, feeder: feeder, to: seconds)
                self.startNodeIfNeededLocked(state)
            case .stream(let loader):
                state.isPlaying = true
                if seconds > 0.25, abs(seconds - self.livePositionLocked(state)) > 0.5, loader.canSeek {
                    self.seekStreamLocked(state, deck: deck, to: seconds)
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
        }
    }

    func resume() {
        queue.async {
            guard self.isPaused else { return }
            self.isPaused = false
            self.ensureEngineRunningLocked()
            for state in self.deckStates.values where state.isPlaying {
                self.startNodeIfNeededLocked(state)
            }
        }
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
                self.scheduleSegmentLocked(state, file: file, from: seconds, deck: deck)
                self.startNodeIfNeededLocked(state)
            case .convertedFile(let feeder):
                self.seekFeederLocked(state, feeder: feeder, to: seconds)
                self.startNodeIfNeededLocked(state)
            case .stream(let loader):
                guard loader.canSeek else { return }
                self.seekStreamLocked(state, deck: deck, to: seconds)
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
                    + "\(self.journalRates)")
            self.startTransitionTimerLocked(interval: self.slowTickInterval)
        }
    }

    /// Hand the engine a pre-rendered hand-over to play in place of the live
    /// overlap of the transition it currently has waiting.
    ///
    /// Rejected — silently, leaving the live path armed — unless the segment
    /// belongs to *this* plan and the outgoing deck has not yet reached the
    /// splice point. Both are the same rule: a segment is audio cut for one
    /// exact seam, so anything that has moved the seam (a seek that degraded
    /// the plan, a late re-plan, a pre-render that finished too late) makes it
    /// the wrong audio, and the live path is always still there.
    func armTransitionSegment(_ segment: TransitionSegment) {
        queue.async {
            guard let tr = self.transition, tr.phase == .waiting, tr.segment == nil,
                  let signature = TransitionSegment.Signature(plan: tr.plan),
                  signature == segment.signature,
                  case .file = self.deckStates[tr.to]!.source
            else { return }
            let position = self.livePositionLocked(self.deckStates[tr.from]!)
            guard position < segment.spliceStart - Self.segmentArmLead else { return }
            tr.segment = segment
        }
    }

    /// Test hook: is a pre-rendered segment armed for the pending transition?
    var hasArmedSegment: Bool { queue.sync { transition?.segment != nil } }

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
    /// The tap sits on `mainMixerNode`'s output, so it hears both decks, the
    /// pre-rendered segment and the user's volume — whatever a listener hears,
    /// with no dependence on which deck is live or how a hand-over is running.
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

    private func installOutputSampleSinkLocked() {
        let mixer = engine.mainMixerNode
        mixer.removeTap(onBus: 0)
        guard let sink = outputSampleSink else { return }
        mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            sink(buffer)
        }
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
        let player = state.player
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
            block(peak * player.volume)
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
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try? AVAudioSession.sharedInstance().setActive(true)
        }
        #endif
        engine.prepare()
        do {
            try engine.start()
            startClockTimerLocked()
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

    private func startNodeIfNeededLocked(_ state: DeckState) {
        guard state.isPlaying, !isPaused, state.isConnected, engine.isRunning else { return }
        if !state.player.isPlaying { state.player.play() }
    }

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
        DeckChain.neutralize(timePitch: state.timePitch, eq: state.eq, delay: state.delay)
    }

    /// Which deck a state belongs to, for a journal line. Linear over two
    /// entries, and only ever on a lifecycle event.
    private func journalDeckName(_ state: DeckState) -> String {
        if state === segmentState { return "segment" }
        return deckStates.first { $0.value === state }?.key.rawValue ?? "?"
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
    private func setFaderLocked(_ state: DeckState, _ value: Float) {
        state.faderRequest = value
        let level = value * state.trim * state.ride * state.ratePad
        if state.pendingFaderRestore != nil {
            state.pendingFaderRestore = level
        } else {
            state.player.volume = level
        }
    }

    /// Close any open flush window and drop the fader to 0 immediately.
    /// The *request* goes to 0 too: a deck taken out of service must not be
    /// resurrected by the ride glide re-applying a stale level.
    private func hardSilenceFaderLocked(_ state: DeckState) {
        state.pendingFaderRestore = nil
        state.faderRequest = 0
        state.player.volume = 0
    }

    // MARK: - Transition gain ride (locked)

    /// Tick of the ride glide. Deliberately slow: at 0.3 dB/s a 20 Hz glide
    /// moves 0.015 dB a step, which is three orders of magnitude under
    /// audibility, and the release can run for 13 s — this is not something to
    /// burn the 50 Hz ramp tick on.
    private static let rideTick: TimeInterval = 0.05

    /// Put the deck's ride at `db` **now**, with no glide, and re-write the
    /// fader through it.
    private func setRideLocked(_ state: DeckState, db: Double) {
        state.rideDB = db
        state.rideTargetDB = db
        state.rideReleaseFromDB = db
        state.rideReleaseElapsed = 0
        state.ride = LoudnessCompensation.gain(fromDB: db)
        setFaderLocked(state, state.faderRequest)
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
        setFaderLocked(state, state.faderRequest)
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
    /// spare, which is most of the library.
    private func padTargetLocked(_ state: DeckState) -> Double { state.padCeilingDB }

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
    }

    /// One tick of the deck-level gain glides — the ride's release, and the
    /// bent-rate pad's. Two independent multipliers on the same fader, both
    /// owned by the deck rather than by any transition, both let go of at
    /// 0.3 dB/s because that is the slope at which a level change stops being
    /// an event. A deck can be unwinding both at once (a hand-over that both
    /// rode the incoming level and padded it for the bend), which is exactly
    /// why they are separate numbers and one fader write.
    private func rideTickLocked() {
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
                state.rideReleaseElapsed += Self.rideTick
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
                let step = TransitionAutomation.ratePadGlideDBPerSecond * Self.rideTick
                let remaining = state.ratePadTargetDB - state.ratePadDB
                state.ratePadDB += remaining > 0
                    ? Swift.min(step, remaining) : Swift.max(-step, remaining)
                state.ratePad = LoudnessCompensation.gain(fromDB: state.ratePadDB)
            }
            setFaderLocked(state, state.faderRequest)
        }
        if !anyGliding {
            rideTimer?.cancel()
            rideTimer = nil
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
        state.player.volume = 0
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
            state.player.volume = target
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
        state.player.stop()
        if keepingEchoTail {
            // The fader stays where `.echoOut` left it — pulling it down would
            // mute the tail, which reaches the mixer through this same deck.
            // The dry residue is already silenced by the EQ's global gain.
            state.timePitch.rate = 1
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
        state.startOffset = 0
        state.lastKnownPosition = 0
        state.pendingStreamBuffers = 0
        state.streamStalled = false
        state.streamEnded = false
    }

    // MARK: - Clock (locked)

    /// Sample-accurate position: schedule-start offset + frames the node has
    /// actually rendered. Falls back to the cached value when the node clock
    /// is unavailable (engine paused/stopped).
    private func livePositionLocked(_ state: DeckState) -> TimeInterval {
        guard let nodeTime = state.player.lastRenderTime,
              let playerTime = state.player.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0 else {
            return state.lastKnownPosition
        }
        let position = state.startOffset + Double(playerTime.sampleTime) / playerTime.sampleRate
        guard position >= state.startOffset else {
            // sampleTime can be briefly negative right after play(at:).
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
            guard let self, !self.isPaused else { return }
            for state in self.deckStates.values where state.isPlaying {
                _ = self.livePositionLocked(state)
            }
        }
        timer.resume()
        clockTimer = timer
    }

    // MARK: - File scheduling (locked)

    private func scheduleSegmentLocked(_ state: DeckState, file: AVAudioFile,
                                       from seconds: TimeInterval, deck: Deck) {
        state.generation += 1
        let generation = state.generation
        beginFaderFlushLocked(state)
        state.player.stop()
        let sampleRate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition((max(0, seconds) * sampleRate).rounded())
        state.startOffset = Double(startFrame) / sampleRate
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
    private func seekFeederLocked(_ state: DeckState, feeder: FileFeeder, to seconds: TimeInterval) {
        state.generation += 1
        beginFaderFlushLocked(state)
        state.player.stop()
        state.pendingStreamBuffers = 0
        state.streamEnded = false
        state.streamStalled = false
        state.startOffset = seconds
        state.lastKnownPosition = seconds
        feeder.start(from: seconds)
    }

    private func seekStreamLocked(_ state: DeckState, deck: Deck, to seconds: TimeInterval) {
        guard case .stream(let loader) = state.source else { return }
        state.generation += 1
        beginFaderFlushLocked(state)
        state.player.stop()
        state.pendingStreamBuffers = 0
        state.streamEnded = false
        state.startOffset = seconds
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
        guard let tr = transition else {
            stopTransitionTimerLocked()
            return
        }
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
            tr.elapsed += transitionTimerInterval
            updateOverlapLocked(tr)
        case .settling:
            tr.restoreElapsed += transitionTimerInterval
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
        from.timePitch.rate = bent.rate(at: position)
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
        from.timePitch.rate = 1
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
        to.timePitch.rate = 1
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
        to.startOffset = 0
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
        scheduleSegmentLocked(to, file: file, from: 0, deck: tr.to)
        setFaderLocked(to, 1)
        to.isPlaying = true
        let startHost = mach_absolute_time() &+ AVAudioTime.hostTime(forSeconds: seconds)
        to.player.play(at: AVAudioTime(hostTime: startHost))
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
            scheduleSegmentLocked(to, file: file, from: inPoint, deck: tr.to)
        case .convertedFile(let feeder):
            seekFeederLocked(to, feeder: feeder, to: inPoint)
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
            to.timePitch.rate = plan.incomingRate
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
        setFaderLocked(to, 0)
        to.isPlaying = true
        startNodeIfNeededLocked(to)
        PlaybackJournal.note(
            "overlap begin \(tr.from.rawValue)→\(tr.to.rawValue) "
                + String(format: "in=%.3f overlap=%.3f swap=%.3f stagedEQ=%@ ",
                         inPoint, tr.overlapDuration, tr.swapOffset,
                         tr.style.stagedEQ ? "yes" : "no")
                + "\(journalRates)")
        tr.phase = .overlapping
        tr.elapsed = 0
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
        guard let nodeTime = segmentState.player.lastRenderTime,
              let playerTime = segmentState.player.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0, playerTime.sampleTime >= 0 else { return nil }
        return Double(playerTime.sampleTime) / playerTime.sampleRate
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
        var startTime = start
        let deckRate = Double(from.timePitch.rate)
        if abs(deckRate - 1) > 0.001 {
            let ahead = AVAudioTime.seconds(forHostTime: start.hostTime &- now)
            startTime = AVAudioTime(
                hostTime: now &+ AVAudioTime.hostTime(forSeconds: ahead / deckRate))
        }

        ensureEngineRunningLocked()
        segmentState.generation += 1
        segmentState.player.stop()
        segmentState.player.scheduleBuffer(segment.buffer, at: nil, options: [],
                                           completionHandler: nil)
        // Silent until the head crossfade opens it: the segment's first half
        // second duplicates what the outgoing deck is already playing.
        segmentState.player.volume = 0
        segmentState.faderRequest = 0
        segmentState.player.play(at: startTime)
        PlaybackJournal.note(String(
            format: "splice armed %@→%@ spliceStart=%.3f duration=%.3f head=%.3f tail=%.3f ",
            tr.from.rawValue, tr.to.rawValue, segment.spliceStart, segment.duration,
            segment.handoffIn, segment.handoffOut) + journalRates)
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
        tr.phase = .waiting
    }

    /// Undo an incoming deck that has been scheduled for the segment's tail but
    /// has not started sounding yet — its `play(at:)` is on the host clock,
    /// which keeps running while the engine is paused.
    private func disarmSegmentTailLocked() {
        guard let tr = transition, tr.phase == .segmentPlaying,
              let segment = tr.segment,
              let elapsed = segmentElapsedLocked(), elapsed < segment.handoffOutStart
        else { return }
        let to = deckStates[tr.to]!
        guard to.isPlaying else { return }
        to.generation += 1
        hardSilenceFaderLocked(to)
        to.player.stop()
        to.isPlaying = false
    }

    private func parkSegmentLocked() {
        segmentState.generation += 1
        segmentState.player.volume = 0
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
                setFaderLocked(from, 1 - u)
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
        if !to.isPlaying, elapsed >= tailStart - Self.segmentArmLead {
            startIncomingFromSegmentLocked(tr, segment: segment)
        }
        if to.isPlaying, elapsed >= tailStart {
            let u = Float(min(1, max(0, (elapsed - tailStart) / max(segment.handoffOut, 1e-3))))
            setFaderLocked(to, u)
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
        segmentState.player.volume = value
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
        state.player.stop()
        neutralizeEffectsLocked(state)
        state.isPlaying = false
    }

    /// Cue the incoming deck to where the segment's tail is and start it on the
    /// render clock, so the deck and the segment are playing the same samples
    /// at the same time.
    private func startIncomingFromSegmentLocked(_ tr: TransitionState,
                                                segment: TransitionSegment) {
        let to = deckStates[tr.to]!
        guard case .file(let file) = to.source else { return }
        let sampleRate = graphFormat.sampleRate
        let frame = AVAudioFramePosition((segment.handoffOutStart * sampleRate).rounded())
        guard let start = segmentState.player.nodeTime(
                forPlayerTime: AVAudioTime(sampleTime: frame, atRate: sampleRate)),
              start.isHostTimeValid, start.hostTime > mach_absolute_time()
        else { return }
        scheduleSegmentLocked(to, file: file, from: segment.incomingResume, deck: tr.to)
        // The ride is still unwinding where the segment ends; the deck picks it
        // up at that value and finishes the release on its own glide timer.
        setRideLocked(to, db: segment.incomingRideDB)
        setFaderLocked(to, 0)
        to.isPlaying = true
        to.player.play(at: start)
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
            if case .file(let file) = to.source {
                scheduleSegmentLocked(to, file: file, from: segment.incomingResume, deck: tr.to)
                setRideLocked(to, db: segment.incomingRideDB)
                to.isPlaying = true
                startNodeIfNeededLocked(to)
            }
        }
        setFaderLocked(to, 1)
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
            if !to.isPlaying, case .file(let file) = to.source {
                scheduleSegmentLocked(to, file: file,
                                      from: segment.incomingTime(at: elapsed), deck: tr.to)
                setRideLocked(to, db: segment.incomingRideDB)
                to.isPlaying = true
                startNodeIfNeededLocked(to)
            }
            setFaderLocked(to, 1)
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
        // had got to in its own track.
        if to.isPlaying {
            to.generation += 1
            hardSilenceFaderLocked(to)
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
            scheduleSegmentLocked(from, file: file, from: resumeAt, deck: tr.from)
        case .convertedFile(let feeder):
            seekFeederLocked(from, feeder: feeder, to: resumeAt)
        case .stream, .none:
            return
        }
        setFaderLocked(from, 1)
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
            to.timePitch.rate = settle.incomingRate
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
        setFaderLocked(state, p.fader)
        DeckChain.apply(p, timePitch: state.timePitch, eq: state.eq, delay: state.delay)
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
        setFaderLocked(to, 1)
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
            to.timePitch.rate = 1
            releaseRatePadLocked(to)
        }
        if tr.restoringRate || tailRinging {
            tr.phase = .settling
            tr.restoreElapsed = 0
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
                    scheduleSegmentLocked(to, file: file, from: 0, deck: tr.to)
                case .convertedFile(let feeder):
                    seekFeederLocked(to, feeder: feeder, to: 0)
                case .stream, .none:
                    break
                }
                setFaderLocked(to, 1)
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
                setFaderLocked(to, 1)
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
            to.player.stop()
            neutralizeEffectsLocked(to)
            // The hand-over never happened, so neither did its ride. The deck
            // is silent, so dropping it is inaudible; leaving it would colour
            // whatever this deck is reused for next.
            setRideLocked(to, db: 0)
            setRatePadLocked(to, db: 0)
            to.isPlaying = false
            setFaderLocked(from, 1)
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

    // MARK: - Configuration changes (locked)

    /// The engine stopped because the output hardware changed (new default
    /// device on macOS, route change on iOS). Player-node schedules are gone;
    /// rebuild the graph and resume every active deck from its cached
    /// position.
    private func handleConfigurationChange() {
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
        // The mixer's output format can have changed with the device; a tap
        // left over from the old one would be a format mismatch.
        installOutputSampleSinkLocked()
        let anyActive = deckStates.values.contains {
            if case .none = $0.source { return false }
            return true
        }
        guard anyActive else { return }
        engine.prepare()
        try? engine.start()

        for (deck, state) in deckStates {
            switch state.source {
            case .none:
                break
            case .file(let file):
                // Reschedule even when paused so resume() still works.
                scheduleSegmentLocked(state, file: file, from: state.lastKnownPosition, deck: deck)
                startNodeIfNeededLocked(state)
            case .convertedFile(let feeder):
                seekFeederLocked(state, feeder: feeder, to: state.lastKnownPosition)
                startNodeIfNeededLocked(state)
            case .stream(let loader):
                // Scheduled PCM was dropped with the graph; restart the
                // transfer from the cached position. This abandons the .part
                // cache write for this download (documented limitation).
                if loader.canSeek {
                    seekStreamLocked(state, deck: deck, to: state.lastKnownPosition)
                } else {
                    state.generation += 1
                    state.pendingStreamBuffers = 0
                }
                startNodeIfNeededLocked(state)
            }
        }
    }
}
