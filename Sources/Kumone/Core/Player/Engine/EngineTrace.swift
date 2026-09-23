#if os(macOS)
import Accelerate
import Foundation

// The knob-level flight recorder for the playback engine.
//
// **Why this exists.** `PlaybackJournal` records *intent*: a plan was made, an
// overlap began, a deck was reset. That is the right altitude for "how did this
// seam get here", and it is useless for the three bugs the field keeps hitting —
// an outgoing deck that fades out and then comes back, a deck that stutters as
// if something re-scheduled it, and a deck whose player has quietly stopped
// while the bookkeeping still says it is playing. All three are stories about
// *writes*: which knob, in which order, from which call site. A journal line per
// write would be thousands of lines a minute in the unified log, so instead the
// writes go into a fixed ring in memory and are only ever spelled out as text
// when something interesting asks for them.
//
// **Threading.** Everything here is confined to the engine's serial queue. The
// ring is a plain array of PODs with no lock, and `record` is a struct
// assignment and two integer ops — no allocation, no string building, no
// `Date()`. The only work that formats anything is `dump`, which runs at a
// transition completion or a watchdog trip, i.e. a handful of times a song.
// Nothing in this file may ever be called from a render callback or an
// `AVAudioNode` tap.

/// Which chain a trace line is about. Not `Deck`, because the segment player is
/// a third chain the engine writes to and it has no `Deck` case.
enum TraceDeck: UInt8, Sendable {
    case a, b, segment
    /// Not a chain at all: the output device itself, for the sentinels that are
    /// about the hardware rather than about anything we wrote to a node.
    case output

    var name: String {
        switch self {
        case .a: return "a"
        case .b: return "b"
        case .segment: return "seg"
        case .output: return "out"
        }
    }

    init(_ deck: Deck) { self = deck == .a ? .a : .b }
}

/// What kind of write this was. The event decides how `dump` names the three
/// numbers a line carries.
enum TraceEvent: UInt8, Sendable {
    /// v0 = requested 0–1 fader, v1 = level actually written, v2 = trim·ride·pad.
    case fader
    /// v0 = old rate, v1 = new rate.
    case rate
    /// v0 = position the node was started at, v1 = seconds the scheduled host
    /// start was ahead of the call (0 for an ordinary, immediate start).
    case play
    case stop
    /// v0 = position, v1 = generation.
    case scheduleSegment
    /// v0 = frames, v1 = generation.
    case scheduleBuffer
    /// v0 = position/inFlight, v1 = delivered, v2 = generation.
    case feeder
    /// v0 = rate at reset, v1 = pad dB, v2 = ride dB.
    case reset
    /// v0 = rate before the snap.
    case neutralize
    /// v0 = phase ordinal — a transition changed shape.
    case phase
    /// A sentinel fired. v0/v1 carry whatever the sentinel measured.
    case alarm
    /// How late a host-clock `play(at:)` actually started rendering.
    /// v0 = error in ms (positive = late), v1 = scheduled lead, v2 = actual lead.
    case startError

    var name: String {
        switch self {
        case .fader: return "fader"
        case .rate: return "rate"
        case .play: return "play"
        case .stop: return "stop"
        case .scheduleSegment: return "schedSeg"
        case .scheduleBuffer: return "schedBuf"
        case .feeder: return "feeder"
        case .reset: return "reset"
        case .neutralize: return "neutral"
        case .phase: return "phase"
        case .alarm: return "ALARM"
        case .startError: return "startErr"
        }
    }
}

/// **The call site**, named. Every knob write in the engine passes one of these,
/// with no default value anywhere: the point of the recorder is to say *who*
/// wrote, and a defaulted parameter would let a new call site join the trace
/// anonymously. Raw values are used only by `dump`; a case carries no storage,
/// so recording one is free.
enum TraceReason: String, Sendable {

    // Transport
    case play, seek, stopDeck, stopAll, pauseAll, resumeAll, loadFile, startStream

    // Fader / gain plumbing
    case rideWrite          // setRideLocked re-applying the request at a new gain
    case padWrite           // setRatePadLocked, same
    case rideGlide          // the 20 Hz deck glide tick
    case flushRestore       // the seek flush window handing the level back
    case hardSilence        // a deck taken out of service

    // Live overlap
    case gaplessArm, overlapBegin, overlapAutomation, overlapFinish, settleTick
    case rampGlide, rampEnd, rateRestoreEnd

    // Pre-rendered segment splice
    case spliceArm, spliceHead, spliceTail, spliceTailPreroll, spliceTailCancel
    case spliceFinish, spliceAbort, spliceResume, spliceRetire, segmentPark

    // Teardown / recovery
    case deckReset, cancelComplete, cancelUnramp, drainRestart, graphRebuild
    /// `AVAudioNode.reset()` on a silent deck's effect chain — the DSP state
    /// itself, not its parameters (see `resetChainDSPLocked`).
    case auReset
    /// The time-pitch unit was engaged or bypassed (see `DeckChain.syncBypass`).
    /// `v0` is 1 when it went to bypassed, 0 when it was engaged — so the seam
    /// trace says exactly which spans of a glide the AU was in the signal path.
    case auBypass
    /// The stall watchdog re-cueing a `.file` deck whose node never started.
    case stallRestart

    // Source dispatch
    case feederChunk, feederStart, feederStop, feederCancel, feederEnded
    case streamChunk

    // Sentinels
    case resurrected, rescheduled, stalled, resumed
    /// A converted-file deck's node ran out of queued chunks while playing.
    case starved
    /// The output device reported that the render thread missed its deadline
    /// (`kAudioDeviceProcessorOverload`).
    case overload
}

/// **Which repeated writes are worth a slot**, as a pure function of the value
/// and the call site.
///
/// The ring is a fixed number of slots, so what it buys with each one decides
/// how far back a dump reaches. During an overlap the 50 Hz automation writes a
/// rate *and* a fader for *both* decks every tick — a hundred entries a second,
/// of which the overwhelming majority say nothing: `×1.0000 → ×1.0000` on a
/// deck that is not bent, the same fader level re-applied by a ride glide that
/// has already landed. At that rate even a large ring covers only the last few
/// seconds of the seam, which is precisely the window before the seam that
/// every one of these bugs is decided in.
///
/// So a write whose value is where the last one left it is not recorded. The
/// exception is the **first write after a reason change**: a knob arriving at
/// the same value from a different call site is a real event — it is how a
/// hand-over from the ramp to the overlap automation, or from the automation to
/// a settle tick, shows up at all — and coalescing that away would hide the
/// very transfer the trace exists to show.
///
/// The comparison is quantised to `epsilon` because these are floats that have
/// been through a dB conversion and back; two writes that differ in the sixth
/// decimal are the same write as far as anything audible is concerned.
enum EngineTraceCoalesce {

    /// Well under anything audible — a ten-thousandth of full scale is
    /// -80 dBFS on a fader, and a hundredth of a cent on a rate.
    static let epsilon = 1e-4

    static func quantised(_ value: Double) -> Int64 {
        Int64((value / epsilon).rounded())
    }

    static func shouldRecord(value: Double, reason: TraceReason,
                             lastValue: Double?, lastReason: TraceReason?) -> Bool {
        guard let lastValue, let lastReason else { return true }
        if reason != lastReason { return true }
        return quantised(value) != quantised(lastValue)
    }
}

/// One recorded write. Deliberately a POD of fixed size: recording is a single
/// struct assignment into a pre-allocated slot.
struct EngineTraceEntry: Sendable {
    var at: Double = 0
    var deck: TraceDeck = .a
    var event: TraceEvent = .fader
    var reason: TraceReason = .play
    var v0: Double = 0
    var v1: Double = 0
    var v2: Double = 0
}

/// A fixed-size ring of the engine's knob writes, plus the file dump.
///
/// Not thread-safe, and deliberately not: every writer is on the engine's
/// serial queue. A lock here would be paid on every fader write — 50 a second
/// during an overlap — to protect against a caller that does not exist.
final class EngineTraceRing {

    /// Sized to hold the whole of a seam *and its run-up*, which is the window
    /// every one of these bugs lives in. With the no-op automation writes
    /// coalesced away (`EngineTraceCoalesce`) that is now most of a minute of a
    /// running hand-over rather than a couple of seconds of it, and many
    /// minutes of ordinary playback. Two thousand PODs of seven words is under
    /// 120 kB — the reason to keep it small was never the memory, it was that
    /// a longer dump is a worse dump; a dump that stops before the run-up is
    /// worse still.
    static let capacity = 2048

    /// The whole instrument's off switch. False is the shipping default and
    /// makes `record` a single branch on a stored Bool.
    var isEnabled = false

    private var entries = [EngineTraceEntry](repeating: EngineTraceEntry(),
                                             count: EngineTraceRing.capacity)
    private var next = 0
    private var wrapped = false
    /// Everything ever recorded, including what has been rolled over — so a
    /// dump can say how much it is *not* showing.
    private(set) var total = 0

    /// Monotonic seconds since boot; the same clock host time is derived from,
    /// read without a conversion table.
    static func now() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
    }

    func record(_ event: TraceEvent, _ deck: TraceDeck, _ reason: TraceReason,
                _ v0: Double = 0, _ v1: Double = 0, _ v2: Double = 0) {
        guard isEnabled else { return }
        entries[next] = EngineTraceEntry(at: Self.now(), deck: deck, event: event,
                                         reason: reason, v0: v0, v1: v1, v2: v2)
        next += 1
        if next == Self.capacity {
            next = 0
            wrapped = true
        }
        total += 1
    }

    /// Oldest first. Allocates, so only ever called from a dump.
    func snapshot() -> [EngineTraceEntry] {
        guard wrapped else { return Array(entries[0..<next]) }
        return Array(entries[next...]) + Array(entries[0..<next])
    }

    func clear() {
        next = 0
        wrapped = false
        total = 0
    }
}

/// Formatting and file handling for a ring dump. Separate from the ring so the
/// text side can be exercised without an engine.
enum EngineTrace {

    /// Keep the newest this many dumps; a field session wants recent specimens,
    /// not an archive.
    static let keepFiles = 40

    static var directory: URL {
        KumoneDirectories.applicationSupport("seamtraces")
    }

    /// `+12.3456 a  fader    overlapAutomation  req=0.7500 level=0.6120 gain=0.8160`
    ///
    /// Times are relative to the first entry in the dump, because an absolute
    /// uptime is unreadable and the only thing anyone measures off these lines
    /// is the gap between two of them.
    static func line(_ e: EngineTraceEntry, origin: Double) -> String {
        let values: String
        switch e.event {
        case .fader:
            values = String(format: "req=%.4f level=%.4f gain=%.4f", e.v0, e.v1, e.v2)
        case .rate where e.reason == .auBypass:
            values = String(format: "timePitch=%@ at ×%.4f",
                            e.v0 > 0.5 ? "byp" : "on", e.v1)
        case .rate:
            values = String(format: "×%.4f → ×%.4f", e.v0, e.v1)
        case .play:
            // An immediate `play()` carries no lead and says nothing about one;
            // a host-clock `play(at:)` is only ever interesting *with* it.
            values = e.v1 == 0
                ? String(format: "at=%.3f", e.v0)
                : String(format: "at=%.3f lead=%+.3fs", e.v0, e.v1)
        case .stop:
            values = String(format: "at=%.3f gen=%.0f", e.v0, e.v1)
        case .scheduleSegment:
            values = String(format: "from=%.3f gen=%.0f frames=%.0f", e.v0, e.v1, e.v2)
        case .scheduleBuffer:
            values = String(format: "frames=%.0f gen=%.0f pending=%.0f", e.v0, e.v1, e.v2)
        case .feeder:
            values = String(format: "inFlight=%.0f delivered=%.0f gen=%.0f", e.v0, e.v1, e.v2)
        case .reset:
            values = String(format: "rate=×%.4f pad=%+.2fdB ride=%+.2fdB", e.v0, e.v1, e.v2)
        case .neutralize:
            values = String(format: "rate=×%.4f", e.v0)
        case .phase:
            values = String(format: "%.0f", e.v0)
        case .alarm:
            switch e.reason {
            case .resurrected:
                values = String(format: "level=%.4f", e.v0)
            case .rescheduled:
                values = String(format: "at=%.3f", e.v0)
            case .stalled, .resumed:
                values = String(format: "pos=%.3f advanced=%.3fs/%.3fs", e.v0, e.v1, e.v2)
            case .starved:
                values = String(format: "pending=%.0f delivered=%.0f inFlight=%.0f",
                                e.v0, e.v1, e.v2)
            case .overload:
                values = String(format: "device=%.0f count=%.0f", e.v0, e.v1)
            default:
                values = String(format: "%.4f %.4f %.4f", e.v0, e.v1, e.v2)
            }
        case .startError:
            values = String(format: "error=%+.1fms scheduled=%+.3fs actual=%+.3fs",
                            e.v0, e.v1, e.v2)
        }
        // Padded by hand: `String(format:)`'s width flags are not honoured for
        // `%@`, and a trace whose columns do not line up is a trace nobody scans.
        return String(format: "%+10.4f ", e.at - origin)
            + pad(e.deck.name, 4) + pad(e.event.name, 10)
            + pad(e.reason.rawValue, 19) + values
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }

    /// The whole dump as text, header included. Pure, so a test can read it.
    static func render(_ entries: [EngineTraceEntry], reason: String, total: Int) -> String {
        let origin = entries.first?.at ?? 0
        var out = "# kumone engine trace — reason=\(reason)\n"
        out += "# written \(ISO8601DateFormatter().string(from: Date()))\n"
        out += "# \(entries.count) entries shown of \(total) recorded"
        out += total > entries.count ? " (\(total - entries.count) rolled over)\n" : "\n"
        out += "#     t(s)   deck event     by                 values\n"
        for entry in entries {
            out += line(entry, origin: origin) + "\n"
        }
        return out
    }

    /// Write a dump and prune the directory. Returns the file name for the
    /// journal line, or nil if the write failed (a full disk must not take
    /// playback down with it).
    static func write(_ entries: [EngineTraceEntry], reason: String, total: Int) -> String? {
        let dir = directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        let safeReason = reason.replacingOccurrences(of: "/", with: "-")
        let url = dir.appendingPathComponent("\(stamp)-\(safeReason).log")
        let text = render(entries, reason: reason, total: total)
        guard (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil else {
            return nil
        }
        prune(dir)
        return url.lastPathComponent
    }

    /// Keep the newest `keeping` files in `dir` by modification date and drop
    /// the rest. Shared with the engine's tap captures, which keep a different
    /// number of a different kind of specimen.
    static func prune(_ dir: URL, keeping: Int = keepFiles) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            return a > b
        }
        for stale in sorted.dropFirst(keeping) {
            try? FileManager.default.removeItem(at: stale)
        }
    }
}

/// **When a deck counts as stalled**, as a pure function of two numbers.
///
/// The engine's own reading is "this deck says it is playing, but its playhead
/// is not moving like a playhead". Half of wall-clock is a deliberately blunt
/// threshold: a bent deck runs at ±8 % of real time, a slow tick or a busy queue
/// can cost a few tens of milliseconds, and none of that comes anywhere near
/// halving the rate. Anything under half is not a slow deck, it is a stopped one.
enum PlaybackStallCheck {

    /// How often the watchdog looks.
    static let interval: TimeInterval = 2

    /// Below this the sample is too short to say anything — a timer that fired
    /// early, or a deck that started mid-window.
    static let minimumWindow: TimeInterval = 1

    /// The fraction of wall clock a live deck must at least advance by.
    static let minimumRate: Double = 0.5

    static func isStalled(advanced: TimeInterval, over wall: TimeInterval) -> Bool {
        guard wall >= minimumWindow else { return false }
        return advanced < wall * minimumRate
    }

    /// **Whether a stalled deck may be re-cued in place**, as a pure function
    /// of everything the watchdog knows about it.
    ///
    /// The field incident this exists for: a `.file` deck released by
    /// `play(at:)` on the segment's host clock, whose node timeline did not
    /// start until twenty-two seconds after the intended instant. The fader had
    /// ramped, the bookkeeping said playing, and the only thing that would have
    /// fixed it is the one thing nobody was doing — cueing the deck again and
    /// starting it with an ordinary `play()`.
    ///
    /// Every clause is a refusal, and each names a stall we must *not* touch:
    ///
    /// - **Only `.file`.** A feeder or a stream that stops advancing has its
    ///   own story — an underrun, a download that stopped, a converter that
    ///   threw — and re-cueing it would paper over the evidence and restart the
    ///   very work that is failing. The file deck is the one source whose
    ///   audio is already on the node, where "start it again" is the whole fix.
    /// - **Not while paused.** A paused deck is supposed to stand still.
    /// - **Once per episode.** If a restart did not take, a restart every two
    ///   seconds will not either; it would only shred the journal and re-flush
    ///   the fader forever. The caller clears the flag when the deck resumes.
    /// - **A scheduled host start must be in the past by more than one look.**
    ///   `hostStartLead` is seconds *until* that start (negative once it has
    ///   passed), or nil for a deck started immediately. A deck whose release
    ///   is still ahead of it is not stalled, it is waiting; and one released
    ///   within the last interval may simply not have been sampled yet. A deck
    ///   with no scheduled start (nil) has no such excuse to offer — it was
    ///   told to play at once and did not.
    static func shouldRestartStalledDeck(sourceIsFile: Bool,
                                         isPaused: Bool,
                                         alreadyRestarted: Bool,
                                         hostStartLead: TimeInterval?) -> Bool {
        guard sourceIsFile, !isPaused, !alreadyRestarted else { return false }
        guard let lead = hostStartLead else { return true }
        return lead < -interval
    }

    /// **Why the graph is in no state to be restarted**, if it is not.
    ///
    /// `AVAudioPlayerNode.play()` on a node whose engine is not rendering
    /// raises an NSException — "player started when engine not running" — and
    /// an exception out of the watchdog's timer handler takes the app with it.
    /// That is the worst possible trade here, because *every* condition this
    /// function refuses on is also a way to produce a stall that is not real:
    /// a device switch or a graph rebuild stops the engine and disconnects the
    /// chains, and a node with no `lastRenderTime` at all has not been asked to
    /// render anything yet. The deck's playhead genuinely is not advancing in
    /// all three, and in none of them is a restart the answer — the rebuild
    /// path puts the deck back itself.
    ///
    /// So it is a separate question from `shouldRestartStalledDeck`, which
    /// decides whether this *deck* is the kind we heal; this one asks whether
    /// the *graph* can be touched at all, and its answer is a reason, so the
    /// journal can say which of the three it was rather than going quiet.
    static func restartRefusal(engineIsRunning: Bool,
                               isConnected: Bool,
                               hasRenderTime: Bool) -> RestartRefusal? {
        if !engineIsRunning { return .engineNotRunning }
        if !isConnected { return .notConnected }
        if !hasRenderTime { return .noRenderTime }
        return nil
    }

    /// Spelled the way the journal line reads, so the two cannot drift.
    enum RestartRefusal: String, Sendable {
        case engineNotRunning = "engine not running"
        case notConnected = "not connected"
        case noRenderTime = "no render time"
    }
}

/// **How late a node actually started**, as arithmetic over the two clocks the
/// engine already has — and the one measurement nothing in the flight recorder
/// was making.
///
/// **The field problem.** Both ends of a spliced hand-over are half-second
/// *identity* crossfades: for the head, the segment's first samples are the
/// same audio the outgoing deck is already playing, and for the tail the
/// incoming deck resumes exactly where the segment's last samples are. Mixed
/// against each other at matching trims, `(1-u)·x + u·x` is `x` and the swap is
/// inaudible — but only while the two streams are *aligned*. Offset them by δ
/// and the listener hears δ of the song twice, which is precisely the small
/// stutter the remote 48 kHz machine reports at both ends.
///
/// Everything that alignment rests on is a `play(at:)` on a host time we
/// computed from the other player's render clock. The ring records that we
/// *asked* for an instant; nothing recorded whether the node honoured it. This
/// closes that gap, and it is the same measurement that would have caught the
/// twenty-two-second start (`restartStalledDeckLocked`) as it happened rather
/// than two seconds of stall later.
///
/// **The arithmetic.** `playerTime(forNodeTime:)` maps a host instant to the
/// player's own sample timeline, whose sample 0 *is* the start. So the host
/// time the node really started at is
///
///     actual = renderHostTime − playerSampleTime / sampleRate
///
/// and it works in both directions: before the scheduled release the node
/// reports a *negative* sample time, so `actual` comes out in the future and
/// the error says "this deck will not start for another twenty-one seconds"
/// rather than waiting for the playhead to fail to move.
///
/// Every number arrives as a plain scalar, host ticks per second included, so
/// the whole of it is testable without a clock, a graph, or a device.
enum PlaybackStartErrorCheck {

    /// How long after the scheduled instant to look. Long enough that a node
    /// which started on time has certainly rendered a buffer (a 512-frame
    /// buffer at 44.1 kHz is 12 ms; the largest anyone ships is a few times
    /// that), short enough that the answer is still next to the event in the
    /// journal.
    static let settleDelay: TimeInterval = 0.2

    /// Signed seconds from `a` to `b`. Host times are unsigned and the whole
    /// point here is a difference that goes both ways, so the subtraction is
    /// done in the right order and the sign put back by hand — `&-` on a past
    /// instant wraps to roughly three hundred years.
    static func signedSeconds(from a: UInt64, to b: UInt64,
                              ticksPerSecond: Double) -> TimeInterval {
        guard ticksPerSecond > 0 else { return 0 }
        return b >= a
            ? Double(b - a) / ticksPerSecond
            : -Double(a - b) / ticksPerSecond
    }

    /// Has the scheduled instant been past for long enough to judge it?
    static func isDue(now: UInt64, scheduled: UInt64, ticksPerSecond: Double) -> Bool {
        signedSeconds(from: scheduled, to: now, ticksPerSecond: ticksPerSecond) >= settleDelay
    }

    /// All three numbers the journal line carries. The two leads are relative
    /// to the instant `play(at:)` was called, which is the same origin the
    /// ring's `.play` entry already prints its `lead=` against — so a line and
    /// its trace entry can be read together.
    struct Measurement: Equatable, Sendable {
        var scheduledLead: TimeInterval
        var actualLead: TimeInterval
        var errorMilliseconds: Double
    }

    static func measure(requestedAt origin: UInt64,
                        scheduled: UInt64,
                        renderHostTime: UInt64,
                        playerSampleTime: Int64,
                        sampleRate: Double,
                        ticksPerSecond: Double) -> Measurement? {
        guard sampleRate > 0, ticksPerSecond > 0 else { return nil }
        let rendered = signedSeconds(from: origin, to: renderHostTime,
                                     ticksPerSecond: ticksPerSecond)
        let actualLead = rendered - Double(playerSampleTime) / sampleRate
        let scheduledLead = signedSeconds(from: origin, to: scheduled,
                                          ticksPerSecond: ticksPerSecond)
        return Measurement(scheduledLead: scheduledLead, actualLead: actualLead,
                           errorMilliseconds: (actualLead - scheduledLead) * 1000)
    }

    /// `deck START ERROR deck=b by=spliceTail scheduled=+0.278s actual=+0.301s error=+23.4ms`
    ///
    /// Printed for **every** host-clock start, not only the late ones: what the
    /// next field session needs is the distribution — whether the head and the
    /// tail are both a millisecond out (and the stutter is something else
    /// entirely) or one of them is reliably tens of milliseconds late.
    static func line(deck: String, reason: String, _ m: Measurement) -> String {
        String(format: "deck START ERROR deck=%@ by=%@ scheduled=%+.3fs actual=%+.3fs "
               + "error=%+.1fms",
               deck, reason, m.scheduledLead, m.actualLead, m.errorMilliseconds)
    }

    /// The same line for a node whose clock would not answer. Reported only
    /// after a retry: a single nil is ordinary — the node may not have rendered
    /// its first buffer yet — and a nil that survives the next tick is itself
    /// the finding.
    static func unmeasuredLine(deck: String, reason: String,
                               scheduledLead: TimeInterval) -> String {
        String(format: "deck START ERROR deck=%@ by=%@ scheduled=%+.3fs "
               + "error=unmeasured(playerTime nil)", deck, reason, scheduledLead)
    }
}

/// **Which mid-hand-over re-cue is by design**, as a pure function of the call
/// site and what the deck was doing when it arrived.
///
/// Split out of the engine so the allow-list can be read (and tested) without
/// an audio graph: the sentinel's whole value is that the list is short and
/// deliberate, and a list nobody can see is a list that grows by accident.
enum PlaybackRescheduleCheck {

    /// The call sites that are *supposed* to (re)cue a deck while a hand-over
    /// runs, whatever that deck is doing: the splice's own head and tail
    /// windows, the gapless arm, the drain fallback, the ordinary chunk
    /// dispatch of a buffer-fed source, and the stall watchdog's self-heal —
    /// which exists precisely to re-cue a deck that has stopped advancing, and
    /// would otherwise report itself.
    static let alwaysLegitimate: Set<TraceReason> = [
        .gaplessArm, .spliceArm, .spliceTail, .spliceTailPreroll, .spliceTailCancel,
        .spliceFinish, .spliceAbort, .spliceResume, .drainRestart,
        .feederChunk, .streamChunk, .stallRestart,
    ]

    /// `.overlapBegin` is the conditional one, and the condition is the whole
    /// point. The incoming deck of a live overlap is loaded at arm time with
    /// `loadFile`, which cues it from 0; when the overlap begins it is cued
    /// again, to its in-point, and *that* re-schedule is the design — thirteen
    /// of them on one field session, every single one a false alarm.
    ///
    /// The same call site landing on a deck that is **already playing** is the
    /// stutter this sentinel was written for, so that stays reported: the
    /// difference between cueing silence and cutting live audio is exactly the
    /// difference between the feature and the bug.
    static func isLegitimate(reason: TraceReason,
                             isIncomingDeck: Bool,
                             deckIsPlaying: Bool) -> Bool {
        if alwaysLegitimate.contains(reason) { return true }
        return reason == .overlapBegin && isIncomingDeck && !deckIsPlaying
    }
}

/// **What a global pause does to a player node's clock**, as arithmetic that
/// can be checked without an engine.
///
/// **The field bug.** `AVAudioEngine.pause()` freezes rendering, and while it
/// is paused `AVAudioPlayerNode.lastRenderTime` is nil — so far so good. But
/// the node's *timeline* is not frozen with it: after `engine.start()`,
/// `playerTime(forNodeTime: lastRenderTime!)` reports a sample time that
/// includes the whole of the paused wall clock. Measured on this hardware,
/// with both an ordinary `play()` and a host-clock `play(at:)`: one second
/// played, two seconds paused, half a second after resume reports **3.508 s**
/// — while the audio itself correctly resumes from 1 s. The clock lies; the
/// audio does not.
///
/// The consequence is not cosmetic. A user paused at 12:57:09 and resumed at
/// 13:00:31; deck a had really played ~91 s, the engine read ~293 s, and that
/// is past the transition's out point (230.6 s) — so the crossfade fired the
/// instant playback came back.
///
/// **The fix.** Every pause that a node's schedule survives adds its wall
/// duration to that deck's `pauseSkew`, and every position read subtracts it.
/// A deck that is re-cued or started fresh gets a new anchor (`startOffset`)
/// and its skew goes back to zero with it — the skew only ever describes the
/// gap between *this* anchor and the node clock that is still counting from it.
enum PausedClockSkew {

    /// Accumulate: two pauses in one schedule are two lots of wall clock the
    /// node counted and the song did not. Negatives cannot happen from a
    /// monotonic host clock, and are refused rather than allowed to walk the
    /// playhead forward.
    static func skew(after paused: TimeInterval, existing: TimeInterval) -> TimeInterval {
        max(0, existing) + max(0, paused)
    }

    /// The corrected position, floored at the anchor it was cued from.
    ///
    /// The floor is the same one the raw read has always had — `sampleTime` is
    /// briefly negative after a `play(at:)` — and it doubles as the guarantee
    /// that a skew can only ever hold the playhead back to where the deck
    /// started, never behind it.
    static func position(raw: TimeInterval, startOffset: TimeInterval,
                         skew: TimeInterval) -> TimeInterval {
        max(startOffset, raw - max(0, skew))
    }

    /// `resume skew paused=202.3s deck=a total=202.3s`
    static func line(deck: String, paused: TimeInterval, total: TimeInterval) -> String {
        String(format: "resume skew paused=%.1fs deck=%@ total=%.1fs", paused, deck, total)
    }
}

/// **How often a sentinel may spend a trace dump**, as a pure function of two
/// timestamps.
///
/// `kAudioDeviceProcessorOverload` is not a once-a-session event: a device that
/// is missing its deadline usually misses a great many of them in a row, and
/// one dump per overload would fill the trace directory with forty copies of
/// the same second and roll every older specimen away. One dump per window is
/// as much as anyone can read; the count on the journal line carries the rest.
enum EngineDumpThrottle {

    /// The overload sentinel's window.
    static let overloadInterval: TimeInterval = 30

    /// `lastDumpAt` is nil before the first dump, which is therefore always
    /// allowed. Times are `EngineTraceRing.now()` — monotonic uptime seconds.
    static func shouldDump(now: Double, lastDumpAt: Double?,
                           interval: TimeInterval = overloadInterval) -> Bool {
        guard let lastDumpAt else { return true }
        return now - lastDumpAt >= interval
    }
}

/// **What a tap capture's writer owes**, as arithmetic over frame counts.
///
/// **The field bug.** A capture used to do its bookkeeping by asking the
/// `AVAudioFile` how long it was — inside the tap block, under the capture's
/// lock, right next to the write itself. That put the whole capture (open,
/// write, "am I done?", and then the *analysis* of the finished file) on the
/// audio-delivery thread, and while a tap block runs, `AVAudioPlayerNode.stop()`
/// on any node of the same engine blocks: a 2.4 s analysis on the tap thread
/// cost a spliced hand-over 1.9 s inside `stop()` and left a 1.19 s hole of
/// silence in the output.
///
/// So the writing moved to a serial writer queue, and the file stopped being
/// the bookkeeping. This is what replaced it: the two counters and the one
/// timestamp a writer needs, with no file, no lock and no audio types, so the
/// rules that matter — *done fires exactly once*, *the start host time comes
/// from the first buffer that carried frames* — are testable on their own.
struct TapWriteLedger: Sendable, Equatable {

    /// Frames the capture was asked for. A capture that wants nothing is
    /// complete on its first buffer.
    let want: Int64
    /// Frames handed to the file so far.
    private(set) var written: Int64 = 0
    /// Render host time of the capture's first sample, from the timestamp the
    /// tap handed over with the first buffer. Nil when that timestamp was not
    /// valid, which the caller treats as "not measurable" rather than guessing.
    private(set) var startHostTime: UInt64?
    /// Set by the buffer that reached `want`. No buffer is accepted after it.
    private(set) var isComplete = false

    init(want: Int64) { self.want = want }

    /// Take one buffer's frames.
    ///
    /// Returns true **exactly once**: on the buffer that completes the capture.
    /// That is the whole contract the writer queue relies on to call `done`
    /// once and to tear its state down once.
    mutating func accept(frames: Int64, hostTime: UInt64?) -> Bool {
        guard !isComplete else { return false }
        // The first buffer that actually carries audio is the one whose
        // timestamp describes sample zero of the file; an empty buffer ahead
        // of it wrote nothing, so it cannot be sample zero.
        if written == 0, frames > 0 { startHostTime = hostTime }
        written += max(0, frames)
        guard written >= want else { return false }
        isComplete = true
        return true
    }

    /// Frames still owed, never negative.
    var remaining: Int64 { max(0, want - written) }
}


/// **Do the player's samples still explain the timePitch's samples?**
///
/// The field bug this exists to name in one number: after a deck was glided,
/// stopped and left idle for minutes, its `AVAudioUnitTimePitch` came back
/// with a corrupt phase-vocoder state and produced output that was *shaped*
/// like the input — same spectral envelope, same level, so every per-stage
/// number in a chain capture looked normal — but decorrelated from it. The
/// only measurement that separates "the unit is passing music through" from
/// "the unit is inventing music with the right envelope" is a correlation
/// against its own input, and the chain capture already writes both.
///
/// So: peak normalized cross-correlation between two mono-summed captures,
/// over lags of ±`maxLag` samples (2048 ≈ 46 ms at 44.1 kHz, wide enough for
/// the unit's own latency and for any bend-induced drift over a short
/// capture). A healthy stage reads ≈1.0 at some lag; the field's underwater
/// deck read below 0.2 at every lag.
///
/// Pure array math so it is testable without an engine, and `vDSP` per lag so
/// the sweep stays a fraction of a second on the tap-analysis queue.
enum ChainCoherence {

    /// Samples of each capture compared at one lag. One second of music is
    /// far more than a correlation needs to decide, and it keeps the sweep
    /// (4097 lags, two vDSP passes each) well under a second on the
    /// tap-analysis queue.
    static let windowSamples = 44_100

    /// Peak |normalized cross-correlation| over lags in `-maxLag...maxLag`,
    /// or nil when there is not enough signal to decide (too short a capture,
    /// or silence — a stage that wrote nothing is not evidence of anything).
    static func peakCorrelation(_ a: [Float], _ b: [Float],
                                maxLag: Int = 2048) -> Float? {
        let n = min(a.count, b.count)
        guard maxLag > 0, n > 2 * maxLag + 64 else { return nil }
        let window = min(n - 2 * maxLag, windowSamples)
        let reference = Array(a[maxLag..<(maxLag + window)])
        var axx: Float = 0
        vDSP_svesq(reference, 1, &axx, vDSP_Length(window))
        guard axx > 1e-12 else { return nil }
        var best: Float = 0
        var measured = false
        b.withUnsafeBufferPointer { p in
            guard let base = p.baseAddress else { return }
            for lag in -maxLag...maxLag {
                let q = base + (maxLag + lag)
                var dot: Float = 0, byy: Float = 0
                vDSP_dotpr(reference, 1, q, 1, &dot, vDSP_Length(window))
                vDSP_svesq(q, 1, &byy, vDSP_Length(window))
                guard byy > 1e-12 else { continue }
                measured = true
                let c = abs(dot) / (axx * byy).squareRoot()
                if c > best { best = c }
            }
        }
        return measured ? min(1, best) : nil
    }

    /// Channels as they come off a capture, summed to mono — correlation is a
    /// question about the programme, not about the stereo field.
    static func monoSum(_ channels: [[Float]]) -> [Float] {
        guard let first = channels.first else { return [] }
        guard channels.count > 1 else { return first }
        var out = first
        for channel in channels.dropFirst() {
            let n = min(out.count, channel.count)
            for i in 0..<n { out[i] += channel[i] }
        }
        return out
    }
}
#endif
