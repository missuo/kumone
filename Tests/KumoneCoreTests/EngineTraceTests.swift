import Testing
@testable import KumoneCore
import Foundation

// The flight recorder's own coverage: the ring's storage behaviour, the stall
// verdict as a pure function, the dump's text, and — through the journal tap —
// the one sentinel that can be reached without an audio graph.
//
// Deliberately network- and fixture-free. The engine is constructed (which
// attaches and connects nodes but never starts the AVAudioEngine) and driven
// through its public transport, so these run anywhere the smoke suite does not.

@Suite struct EngineTraceRingTests {

    @Test func aFullRingRollsOverAndKeepsTheNewest() {
        let ring = EngineTraceRing()
        ring.isEnabled = true
        let extra = 10
        for i in 0..<(EngineTraceRing.capacity + extra) {
            ring.record(.fader, .a, .play, Double(i))
        }
        let entries = ring.snapshot()
        #expect(entries.count == EngineTraceRing.capacity)
        #expect(ring.total == EngineTraceRing.capacity + extra)
        // Oldest first, and the first `extra` writes are the ones that fell off.
        #expect(entries.first?.v0 == Double(extra))
        #expect(entries.last?.v0 == Double(EngineTraceRing.capacity + extra - 1))
    }

    @Test func aPartlyFilledRingIsInOrderAndNothingMore() {
        let ring = EngineTraceRing()
        ring.isEnabled = true
        for i in 0..<5 { ring.record(.rate, .b, .rampGlide, Double(i), Double(i) + 1) }
        let entries = ring.snapshot()
        #expect(entries.count == 5)
        #expect(entries.map(\.v0) == [0, 1, 2, 3, 4])
        #expect(entries.allSatisfy { $0.deck == .b && $0.event == .rate })
    }

    @Test func aDisabledRingRecordsNothing() {
        let ring = EngineTraceRing()
        for i in 0..<100 { ring.record(.fader, .a, .play, Double(i)) }
        #expect(ring.snapshot().isEmpty)
        #expect(ring.total == 0)
    }

    @Test func clearingForgetsEverything() {
        let ring = EngineTraceRing()
        ring.isEnabled = true
        for _ in 0..<(EngineTraceRing.capacity + 3) { ring.record(.stop, .a, .deckReset) }
        ring.clear()
        #expect(ring.snapshot().isEmpty)
        #expect(ring.total == 0)
    }

    @Test func timestampsAreMonotonic() {
        let ring = EngineTraceRing()
        ring.isEnabled = true
        for _ in 0..<50 { ring.record(.fader, .a, .rideGlide) }
        let times = ring.snapshot().map(\.at)
        #expect(zip(times, times.dropFirst()).allSatisfy { $0 <= $1 })
    }
}

// What the ring refuses to spend a slot on. During an overlap the 50 Hz
// automation offers a hundred writes a second and most of them are the same
// number again; a ring that took them all would reach back two seconds.
@Suite struct EngineTraceCoalesceTests {

    @Test func theFirstWriteOfAllIsAlwaysNews() {
        #expect(EngineTraceCoalesce.shouldRecord(
            value: 1, reason: .overlapAutomation, lastValue: nil, lastReason: nil))
    }

    @Test func theSameValueFromTheSameCallSiteIsNot() {
        #expect(!EngineTraceCoalesce.shouldRecord(
            value: 1, reason: .overlapAutomation,
            lastValue: 1, lastReason: .overlapAutomation))
        // The unbent deck's rate write, which is most of an overlap's traffic.
        #expect(!EngineTraceCoalesce.shouldRecord(
            value: 1.0000_2, reason: .rampGlide,
            lastValue: 1, lastReason: .rampGlide))
    }

    @Test func aValueThatMovedIsRecorded() {
        #expect(EngineTraceCoalesce.shouldRecord(
            value: 0.98, reason: .overlapAutomation,
            lastValue: 1, lastReason: .overlapAutomation))
        // A tenth of a millesimal is under the quantiser; two of them are not.
        #expect(!EngineTraceCoalesce.shouldRecord(
            value: 1.00002, reason: .rideGlide, lastValue: 1, lastReason: .rideGlide))
        #expect(EngineTraceCoalesce.shouldRecord(
            value: 1.0002, reason: .rideGlide, lastValue: 1, lastReason: .rideGlide))
    }

    /// The hand-over between call sites is the thing the trace exists to show:
    /// the ramp letting go and the automation picking the same rate up is an
    /// event even though the number does not move.
    @Test func theFirstWriteAfterAReasonChangeIsAlwaysRecorded() {
        #expect(EngineTraceCoalesce.shouldRecord(
            value: 1, reason: .overlapAutomation, lastValue: 1, lastReason: .rampGlide))
        #expect(EngineTraceCoalesce.shouldRecord(
            value: 0, reason: .spliceTail, lastValue: 0, lastReason: .hardSilence))
    }

    @Test func theQuantiserIsSymmetricAboutZero() {
        #expect(EngineTraceCoalesce.quantised(0) == 0)
        #expect(EngineTraceCoalesce.quantised(1) == 10_000)
        #expect(EngineTraceCoalesce.quantised(-0.5) == -5_000)
    }
}

@Suite struct EngineTraceRenderTests {

    @Test func everyEventNamesItsOwnNumbers() {
        let entries: [EngineTraceEntry] = [
            EngineTraceEntry(at: 100, deck: .a, event: .fader, reason: .overlapAutomation,
                             v0: 0.75, v1: 0.612, v2: 0.816),
            EngineTraceEntry(at: 100.5, deck: .b, event: .rate, reason: .rampGlide,
                             v0: 1, v1: 1.063),
            EngineTraceEntry(at: 101, deck: .segment, event: .scheduleBuffer,
                             reason: .spliceArm, v0: 480_000, v1: 0, v2: 0),
            EngineTraceEntry(at: 102, deck: .a, event: .alarm, reason: .resurrected, v0: 1),
        ]
        let text = EngineTrace.render(entries, reason: "seam", total: 900)
        #expect(text.contains("reason=seam"))
        #expect(text.contains("4 entries shown of 900 recorded (896 rolled over)"))
        #expect(text.contains("req=0.7500 level=0.6120 gain=0.8160"))
        #expect(text.contains("×1.0000 → ×1.0630"))
        #expect(text.contains("frames=480000"))
        #expect(text.contains("ALARM"))
        #expect(text.contains("resurrected        level=1.0000"))
        // Times are relative to the first entry, not raw uptime.
        #expect(text.contains("+0.0000"))
        #expect(text.contains("+2.0000"))
        #expect(!text.contains("100.0000"))
    }

    /// A host-clock release is only readable next to how far ahead it was; an
    /// ordinary `play()` has no lead and must not pretend to one.
    @Test func aHostClockStartShowsHowFarAheadItWasScheduled() {
        let text = EngineTrace.render([
            EngineTraceEntry(at: 0, deck: .b, event: .play, reason: .spliceTail,
                             v0: 42.5, v1: 0.184),
            EngineTraceEntry(at: 1, deck: .a, event: .play, reason: .play, v0: 12),
        ], reason: "stall", total: 2)
        #expect(text.contains("at=42.500 lead=+0.184s"))
        #expect(text.contains("at=12.000\n"))
    }

    /// A starved converted deck carries the feeder's counters, because the
    /// question the line has to answer is whether delivery stopped or was never
    /// fast enough.
    @Test func aStarvedFeederShowsWhatItHadDelivered() {
        let text = EngineTrace.render([
            EngineTraceEntry(at: 0, deck: .b, event: .alarm, reason: .starved,
                             v0: 0, v1: 412, v2: 0),
        ], reason: "starved", total: 1)
        #expect(text.contains("ALARM"))
        #expect(text.contains("starved"))
        #expect(text.contains("pending=0 delivered=412 inFlight=0"))
    }

    /// The measured half of a host-clock start, next to the `.play` entry that
    /// asked for it — the two share an origin, so `lead=` and `scheduled=`
    /// must read the same.
    @Test func aStartErrorNamesTheDelayInMilliseconds() {
        let text = EngineTrace.render([
            EngineTraceEntry(at: 0, deck: .segment, event: .startError, reason: .spliceArm,
                             v0: 23.4, v1: 0.278, v2: 0.3014),
        ], reason: "seam", total: 1)
        #expect(text.contains("startErr"))
        #expect(text.contains("spliceArm"))
        #expect(text.contains("error=+23.4ms scheduled=+0.278s actual=+0.301s"))
    }

    @Test func aFullRingSaysSoWithoutClaimingLosses() {
        let text = EngineTrace.render([EngineTraceEntry()], reason: "stall", total: 1)
        #expect(text.contains("1 entries shown of 1 recorded\n"))
        #expect(!text.contains("rolled over"))
    }
}

@Suite struct PlaybackStallCheckTests {

    @Test func aDeckAdvancingWithTheClockIsFine() {
        #expect(!PlaybackStallCheck.isStalled(advanced: 2, over: 2))
        #expect(!PlaybackStallCheck.isStalled(advanced: 1.98, over: 2))
    }

    @Test func aBentDeckIsStillFine() {
        // The rate cap is ±8 %; nothing legitimate comes near halving.
        #expect(!PlaybackStallCheck.isStalled(advanced: 2 * 0.92, over: 2))
        #expect(!PlaybackStallCheck.isStalled(advanced: 2 * 1.08, over: 2))
    }

    @Test func aStoppedDeckIsStalled() {
        #expect(PlaybackStallCheck.isStalled(advanced: 0, over: 2))
        #expect(PlaybackStallCheck.isStalled(advanced: 0.3, over: 2))
    }

    @Test func exactlyHalfIsNotStalled() {
        #expect(!PlaybackStallCheck.isStalled(advanced: 1, over: 2))
        #expect(PlaybackStallCheck.isStalled(advanced: 0.999, over: 2))
    }

    @Test func aWindowTooShortToJudgeAbstains() {
        #expect(!PlaybackStallCheck.isStalled(advanced: 0, over: 0))
        #expect(!PlaybackStallCheck.isStalled(advanced: 0, over: 0.5))
        #expect(PlaybackStallCheck.isStalled(advanced: 0, over: PlaybackStallCheck.minimumWindow))
    }

    @Test func aStalledFileDeckWhoseHostStartIsLongGoneIsRestarted() {
        // The field incident: released on the segment's host clock, twenty-two
        // seconds ago, and the playhead never moved.
        #expect(PlaybackStallCheck.shouldRestartStalledDeck(
            sourceIsFile: true, isPaused: false, alreadyRestarted: false,
            hostStartLead: -22))
    }

    @Test func aDeckStillWaitingForItsReleaseIsLeftAlone() {
        // Ahead of its start, or only just past it — the watchdog may simply
        // have looked between the release and the first rendered buffer.
        #expect(!PlaybackStallCheck.shouldRestartStalledDeck(
            sourceIsFile: true, isPaused: false, alreadyRestarted: false,
            hostStartLead: 1.2))
        #expect(!PlaybackStallCheck.shouldRestartStalledDeck(
            sourceIsFile: true, isPaused: false, alreadyRestarted: false,
            hostStartLead: -PlaybackStallCheck.interval))
        #expect(PlaybackStallCheck.shouldRestartStalledDeck(
            sourceIsFile: true, isPaused: false, alreadyRestarted: false,
            hostStartLead: -PlaybackStallCheck.interval - 0.001))
    }

    @Test func aDeckStartedImmediatelyHasNoExcuse() {
        // No scheduled release to be waiting for: it was told to play at once.
        #expect(PlaybackStallCheck.shouldRestartStalledDeck(
            sourceIsFile: true, isPaused: false, alreadyRestarted: false,
            hostStartLead: nil))
    }

    @Test func onlyFileDecksAreRestarted() {
        // A feeder or a stream stalls for reasons that live elsewhere.
        #expect(!PlaybackStallCheck.shouldRestartStalledDeck(
            sourceIsFile: false, isPaused: false, alreadyRestarted: false,
            hostStartLead: -22))
        #expect(!PlaybackStallCheck.shouldRestartStalledDeck(
            sourceIsFile: false, isPaused: false, alreadyRestarted: false,
            hostStartLead: nil))
    }

    @Test func aPausedOrAlreadyRestartedDeckIsNotTouched() {
        #expect(!PlaybackStallCheck.shouldRestartStalledDeck(
            sourceIsFile: true, isPaused: true, alreadyRestarted: false,
            hostStartLead: -22))
        #expect(!PlaybackStallCheck.shouldRestartStalledDeck(
            sourceIsFile: true, isPaused: false, alreadyRestarted: true,
            hostStartLead: -22))
    }

    /// A rendering, connected, running deck is the only one it is safe to call
    /// `play()` on — anything else raises an NSException out of a timer.
    @Test func aRenderingGraphIsSafeToRestart() {
        #expect(PlaybackStallCheck.restartRefusal(
            engineIsRunning: true, isConnected: true, hasRenderTime: true) == nil)
    }

    @Test func aStoppedOrRebuildingGraphIsRefusedWithItsReason() {
        #expect(PlaybackStallCheck.restartRefusal(
            engineIsRunning: false, isConnected: true, hasRenderTime: true)
            == .engineNotRunning)
        #expect(PlaybackStallCheck.restartRefusal(
            engineIsRunning: true, isConnected: false, hasRenderTime: true)
            == .notConnected)
        #expect(PlaybackStallCheck.restartRefusal(
            engineIsRunning: true, isConnected: true, hasRenderTime: false)
            == .noRenderTime)
    }

    /// The three overlap constantly — a device switch stops the engine *and*
    /// drops the connections — so the reason has to be the most fundamental
    /// one, or the journal would blame the symptom.
    @Test func theWorstProblemIsTheOneReported() {
        #expect(PlaybackStallCheck.restartRefusal(
            engineIsRunning: false, isConnected: false, hasRenderTime: false)
            == .engineNotRunning)
        #expect(PlaybackStallCheck.restartRefusal(
            engineIsRunning: true, isConnected: false, hasRenderTime: false)
            == .notConnected)
    }

    /// The refusal spells itself the way the journal line reads.
    @Test func theRefusalNamesItselfInPlainWords() {
        #expect(PlaybackStallCheck.RestartRefusal.engineNotRunning.rawValue
            == "engine not running")
        #expect(PlaybackStallCheck.RestartRefusal.notConnected.rawValue == "not connected")
        #expect(PlaybackStallCheck.RestartRefusal.noRenderTime.rawValue == "no render time")
    }

    @Test func aPlayheadThatWentBackwardsIsStalled() {
        // A re-schedule to an earlier point looks like this; it is exactly the
        // kind of thing the watchdog should not shrug off.
        #expect(PlaybackStallCheck.isStalled(advanced: -3, over: 2))
    }
}

// The instrument the spliced stutter hunt turns on: both ends of a splice are
// identity crossfades, so a node that starts δ late plays δ of the song twice.
// Every number is injected — host ticks per second included — so the whole of
// it runs without a clock, a graph or a device.
@Suite struct PlaybackStartErrorCheckTests {

    /// A round, unmistakable timebase: one tick is one microsecond.
    private let ticks: Double = 1_000_000
    private let origin: UInt64 = 1_000_000_000

    @Test func aNodeThatStartedExactlyOnTimeMeasuresZero() {
        // Scheduled 300 ms out; at the check the node has rendered 100 ms past
        // its start, and the render clock agrees to the tick.
        let m = PlaybackStartErrorCheck.measure(
            requestedAt: origin, scheduled: origin + 300_000,
            renderHostTime: origin + 400_000,
            playerSampleTime: 4_800, sampleRate: 48_000, ticksPerSecond: ticks)
        #expect(m?.scheduledLead == 0.3)
        #expect(abs((m?.actualLead ?? 0) - 0.3) < 1e-9)
        #expect(abs(m?.errorMilliseconds ?? 1) < 1e-6)
    }

    /// The field case: the node started later than we asked, so during the
    /// crossfade the two identical streams are offset by exactly this much.
    @Test func aLateStartIsPositiveMilliseconds() {
        // Same render instant, but only 76.6 ms of audio has come out —
        // the timeline began 23.4 ms after the requested instant.
        let m = PlaybackStartErrorCheck.measure(
            requestedAt: origin, scheduled: origin + 300_000,
            renderHostTime: origin + 400_000,
            playerSampleTime: AVAudioFramePositionForTest(0.0766 * 48_000),
            sampleRate: 48_000, ticksPerSecond: ticks)
        #expect(abs((m?.errorMilliseconds ?? 0) - 23.4) < 0.05)
        #expect(abs((m?.actualLead ?? 0) - 0.3234) < 1e-4)
    }

    /// And the other direction, which is just as much a splice offset: a node
    /// that jumped the gun renders more audio than the schedule accounts for.
    @Test func anEarlyStartIsNegativeMilliseconds() {
        let m = PlaybackStartErrorCheck.measure(
            requestedAt: origin, scheduled: origin + 300_000,
            renderHostTime: origin + 400_000,
            playerSampleTime: AVAudioFramePositionForTest(0.11 * 48_000),
            sampleRate: 48_000, ticksPerSecond: ticks)
        #expect(abs((m?.errorMilliseconds ?? 0) + 10) < 0.05)
    }

    /// The twenty-two second incident, caught 200 ms in rather than two seconds
    /// of stall later: before its release a node reports a *negative* sample
    /// time, which puts the real start in the future and says so.
    @Test func aNodeStillWaitingReportsAStartThatHasNotHappenedYet() {
        let m = PlaybackStartErrorCheck.measure(
            requestedAt: origin, scheduled: origin + 300_000,
            renderHostTime: origin + 500_000,
            playerSampleTime: -22 * 48_000, sampleRate: 48_000, ticksPerSecond: ticks)
        // Render clock is 0.5 s past the call and the timeline starts 22 s
        // after that: 22.5 s out, against a 0.3 s request.
        #expect(abs((m?.actualLead ?? 0) - 22.5) < 1e-6)
        #expect(abs((m?.errorMilliseconds ?? 0) - 22_200) < 0.5)
    }

    @Test func aNonsenseClockRefusesToGuess() {
        #expect(PlaybackStartErrorCheck.measure(
            requestedAt: origin, scheduled: origin, renderHostTime: origin,
            playerSampleTime: 0, sampleRate: 0, ticksPerSecond: ticks) == nil)
        #expect(PlaybackStartErrorCheck.measure(
            requestedAt: origin, scheduled: origin, renderHostTime: origin,
            playerSampleTime: 0, sampleRate: 48_000, ticksPerSecond: 0) == nil)
    }

    /// Host times are unsigned; a render clock behind the call must not wrap
    /// into three hundred years.
    @Test func aClockReadingBackwardsStaysNegative() {
        #expect(PlaybackStartErrorCheck.signedSeconds(
            from: origin, to: origin - 250_000, ticksPerSecond: ticks) == -0.25)
        #expect(PlaybackStartErrorCheck.signedSeconds(
            from: origin, to: origin + 250_000, ticksPerSecond: ticks) == 0.25)
    }

    @Test func theCheckWaitsForTheScheduledInstantToBeWellPast() {
        let scheduled = origin + 300_000
        #expect(!PlaybackStartErrorCheck.isDue(
            now: scheduled, scheduled: scheduled, ticksPerSecond: ticks))
        #expect(!PlaybackStartErrorCheck.isDue(
            now: origin, scheduled: scheduled, ticksPerSecond: ticks))
        #expect(PlaybackStartErrorCheck.isDue(
            now: scheduled + UInt64(PlaybackStartErrorCheck.settleDelay * ticks),
            scheduled: scheduled, ticksPerSecond: ticks))
    }

    /// The line the next field session greps for, character for character.
    @Test func theJournalLineSpellsBothEndsOut() {
        let line = PlaybackStartErrorCheck.line(
            deck: "seg", reason: "spliceArm",
            .init(scheduledLead: 0.278, actualLead: 0.3014, errorMilliseconds: 23.4))
        #expect(line == "deck START ERROR deck=seg by=spliceArm scheduled=+0.278s "
            + "actual=+0.301s error=+23.4ms")
    }

    @Test func aClockThatWouldNotAnswerSaysSoRatherThanGoingQuiet() {
        let line = PlaybackStartErrorCheck.unmeasuredLine(
            deck: "b", reason: "spliceTail", scheduledLead: 0.25)
        #expect(line == "deck START ERROR deck=b by=spliceTail scheduled=+0.250s "
            + "error=unmeasured(playerTime nil)")
    }
}

/// `AVAudioFramePosition` without importing AVFoundation for one cast.
private func AVAudioFramePositionForTest(_ value: Double) -> Int64 { Int64(value.rounded()) }

@Suite struct PlaybackRescheduleCheckTests {

    /// The false positive this rule was written for: the incoming deck of a
    /// live overlap, loaded from 0 at arm time and cued to its in-point when
    /// the overlap begins. It is not sounding, so nothing can stutter.
    @Test func cueingTheSilentIncomingDeckAtOverlapBeginIsByDesign() {
        #expect(PlaybackRescheduleCheck.isLegitimate(
            reason: .overlapBegin, isIncomingDeck: true, deckIsPlaying: false))
    }

    /// And the bug it must keep catching: the same call site cutting audio
    /// that is already on the air.
    @Test func cueingAPlayingDeckAtOverlapBeginIsStillReported() {
        #expect(!PlaybackRescheduleCheck.isLegitimate(
            reason: .overlapBegin, isIncomingDeck: true, deckIsPlaying: true))
        // Nor is the outgoing deck ever a legitimate target for it.
        #expect(!PlaybackRescheduleCheck.isLegitimate(
            reason: .overlapBegin, isIncomingDeck: false, deckIsPlaying: false))
    }

    @Test func aUserSeekMidHandOverIsAlwaysWorthALine() {
        for playing in [true, false] {
            #expect(!PlaybackRescheduleCheck.isLegitimate(
                reason: .seek, isIncomingDeck: true, deckIsPlaying: playing))
            #expect(!PlaybackRescheduleCheck.isLegitimate(
                reason: .seek, isIncomingDeck: false, deckIsPlaying: playing))
        }
    }

    /// The unconditional list does not care what the deck was doing — a splice
    /// tail cues a deck that is about to play, a chunk dispatch one that is.
    @Test func theDesignedCueSitesPassWhateverTheDeckIsDoing() {
        for reason in PlaybackRescheduleCheck.alwaysLegitimate {
            for playing in [true, false] {
                #expect(PlaybackRescheduleCheck.isLegitimate(
                    reason: reason, isIncomingDeck: true, deckIsPlaying: playing))
                #expect(PlaybackRescheduleCheck.isLegitimate(
                    reason: reason, isIncomingDeck: false, deckIsPlaying: playing))
            }
        }
    }

    /// The watchdog's self-heal re-cues by definition; it must not report
    /// itself for doing so.
    @Test func theStallRestartIsOnTheList() {
        #expect(PlaybackRescheduleCheck.alwaysLegitimate.contains(.stallRestart))
    }
}

// The coalescing rule where it actually spends slots: through the engine's own
// fader writer, on a deck no graph is attached to.
@Suite struct EngineTraceRingHygieneTests {

    @Test func aRepeatedFaderWriteOnlyCostsOneSlot() {
        let engine = PlaybackEngine()
        engine.setVerboseTrace(true)
        for _ in 0..<50 { engine.writeFaderForTesting(.a, 0.5, .overlapAutomation) }
        #expect(engine.traceEntryCountForTesting == 1)
        // A different call site landing the same level is still an event.
        engine.writeFaderForTesting(.a, 0.5, .rideGlide)
        #expect(engine.traceEntryCountForTesting == 2)
        // And so, of course, is a level that moved.
        engine.writeFaderForTesting(.a, 0.25, .rideGlide)
        #expect(engine.traceEntryCountForTesting == 3)
    }

    /// The two decks keep their own memory; b's writes must not be silenced by
    /// a's having landed the same number.
    @Test func eachDeckIsJudgedOnItsOwn() {
        let engine = PlaybackEngine()
        engine.setVerboseTrace(true)
        engine.writeFaderForTesting(.a, 1, .overlapAutomation)
        engine.writeFaderForTesting(.b, 1, .overlapAutomation)
        #expect(engine.traceEntryCountForTesting == 2)
    }
}

// Serialized: `PlaybackJournal.Tap` is a single global and deliberately not
// re-entrant, so two captures running at once would each see the other's lines.
@Suite(.serialized) struct EngineResurrectionSentinelTests {

    /// A deck taken out of service and then handed a level above zero is the
    /// bug the sentinel is named after; the line has to carry the deck, the
    /// level and the call site that did it.
    @Test func aFaderWriteAfterAResetIsReported() {
        let engine = PlaybackEngine()
        engine.setVerboseTrace(true)
        let (_, lines) = PlaybackJournal.tap.capture {
            engine.stop(deck: .a)
            engine.writeFaderForTesting(.a, 1, .drainRestart)
        }
        let alarm = lines.first { $0.contains("deck RESURRECTED") }
        #expect(alarm != nil)
        #expect(alarm?.contains("deck=a") == true)
        #expect(alarm?.contains("level=1.0000") == true)
        #expect(alarm?.contains("by=drainRestart") == true)
        #expect(engine.traceEntryCountForTesting > 0)
    }

    /// Silence is not resurrection: the ride and pad glides re-apply the deck's
    /// remembered request, which a hard silence has already set to zero, and
    /// those must never trip the alarm.
    @Test func writingZeroToAParkedDeckIsSilent() {
        let engine = PlaybackEngine()
        engine.setVerboseTrace(true)
        let (_, lines) = PlaybackJournal.tap.capture {
            engine.stop(deck: .b)
            engine.writeFaderForTesting(.b, 0, .rideGlide)
        }
        #expect(!lines.contains { $0.contains("RESURRECTED") })
    }

    /// A deck that has legitimately been put back on the air is in service
    /// again, and an ordinary fader write is ordinary.
    @Test func playingTheDeckAgainStandsTheSentinelDown() {
        let engine = PlaybackEngine()
        engine.setVerboseTrace(true)
        let (_, lines) = PlaybackJournal.tap.capture {
            engine.stop(deck: .a)
            // No source loaded, so nothing sounds — but `play` is still the
            // "make this deck sound" entry point and clears the flag.
            engine.play(deck: .a, from: 0)
            engine.writeFaderForTesting(.a, 1, .overlapFinish)
        }
        #expect(!lines.contains { $0.contains("RESURRECTED") })
    }

    /// With the switch off the instrument costs nothing and says nothing —
    /// including about a write that would otherwise be an alarm.
    @Test func theSwitchOffRecordsAndJudgesNothing() {
        let engine = PlaybackEngine()
        let (_, lines) = PlaybackJournal.tap.capture {
            engine.stop(deck: .a)
            engine.writeFaderForTesting(.a, 1, .drainRestart)
            engine.play(deck: .b, from: 0)
            engine.writeFaderForTesting(.b, 0.5, .overlapAutomation)
        }
        #expect(!lines.contains { $0.contains("RESURRECTED") })
        #expect(engine.traceEntryCountForTesting == 0)
    }

    /// And turning it off again empties the ring rather than leaving a stale
    /// one to be dumped by the next manual press.
    @Test func turningTheSwitchOffClearsWhatWasRecorded() {
        let engine = PlaybackEngine()
        engine.setVerboseTrace(true)
        engine.writeFaderForTesting(.a, 0.5, .overlapAutomation)
        #expect(engine.traceEntryCountForTesting > 0)
        engine.setVerboseTrace(false)
        #expect(engine.traceEntryCountForTesting == 0)
    }
}

// The paused-clock correction, as arithmetic. The behaviour it models cannot
// be reached without an audio device — `AVAudioPlayerNode`'s clock only lies
// about a real pause of a real engine — so what is tested here is the rule the
// engine applies once someone tells it how long the pause was.
@Suite struct PausedClockSkewTests {

    /// The measured case: 1 s played, 2 s paused, 0.5 s after resume. The node
    /// clock reports 3.5 s; the song is at 1.5 s.
    @Test func theMeasuredPauseIsSubtracted() {
        let skew = PausedClockSkew.skew(after: 2, existing: 0)
        #expect(skew == 2)
        #expect(PausedClockSkew.position(raw: 3.5, startOffset: 0, skew: skew) == 1.5)
    }

    /// The field incident: paused at 12:57:09, resumed at 13:00:31, deck a
    /// really 91 s into the song and reported at ~293 s — past the 230.6 s out
    /// point, so the crossfade fired on resume.
    @Test func theFieldIncidentLandsBeforeTheOutPoint() {
        let paused: TimeInterval = 202
        let skew = PausedClockSkew.skew(after: paused, existing: 0)
        let corrected = PausedClockSkew.position(raw: 293, startOffset: 0, skew: skew)
        #expect(abs(corrected - 91) < 0.5)
        #expect(corrected < 230.6)
    }

    /// Two pauses in one schedule are two lots of wall clock the node counted.
    @Test func skewAccumulatesAcrossPauses() {
        var skew = PausedClockSkew.skew(after: 5, existing: 0)
        skew = PausedClockSkew.skew(after: 7, existing: skew)
        #expect(skew == 12)
        #expect(PausedClockSkew.position(raw: 100, startOffset: 0, skew: skew) == 88)
    }

    /// The floor. A deck cued at 120 s can never be reported behind 120 s,
    /// whatever the skew says — an over-correction would walk the playhead
    /// backwards into audio that has already played.
    @Test func positionNeverGoesBelowTheStartOffset() {
        #expect(PausedClockSkew.position(raw: 122, startOffset: 120, skew: 30) == 120)
        #expect(PausedClockSkew.position(raw: 120, startOffset: 120, skew: 0) == 120)
        // And the case the raw read has always had: sampleTime briefly negative
        // right after a host-clock release.
        #expect(PausedClockSkew.position(raw: 119.9, startOffset: 120, skew: 0) == 120)
    }

    /// A fresh anchor carries its own offset through the correction.
    @Test func theOffsetIsPartOfThePositionNotOfTheSkew() {
        // Cued at 60 s, played 10 s, paused 3 s: raw = 73, song is at 70.
        #expect(PausedClockSkew.position(raw: 73, startOffset: 60, skew: 3) == 70)
    }

    /// A monotonic host clock cannot produce these, and neither may they move
    /// the playhead forward.
    @Test func negativesAreRefusedRatherThanApplied() {
        #expect(PausedClockSkew.skew(after: -5, existing: 2) == 2)
        #expect(PausedClockSkew.skew(after: 3, existing: -2) == 3)
        #expect(PausedClockSkew.position(raw: 50, startOffset: 0, skew: -10) == 50)
    }

    @Test func theJournalLineNamesTheDeckAndBothNumbers() {
        #expect(PausedClockSkew.line(deck: "a", paused: 202.3, total: 202.3)
            == "resume skew paused=202.3s deck=a total=202.3s")
        #expect(PausedClockSkew.line(deck: "segment", paused: 1.25, total: 9.75)
            == "resume skew paused=1.2s deck=segment total=9.8s")
    }

    /// The stall watchdog's sanity check. Its window is restarted at resume
    /// (the tick zeroes `watchAt` while paused), so the first comparable window
    /// after a resume is an ordinary one — and with the skew applied the
    /// playhead advances with the wall clock rather than jumping. Neither the
    /// corrected nor the uncorrected reading can be *stalled*: the failure the
    /// bug produced was a position too far ahead, and a forward jump is never a
    /// stall.
    @Test func aResumedDeckIsNotReportedAsStalled() {
        let skew = PausedClockSkew.skew(after: 202, existing: 0)
        // Two watchdog windows after the resume, corrected.
        let first = PausedClockSkew.position(raw: 293, startOffset: 0, skew: skew)
        let second = PausedClockSkew.position(raw: 295, startOffset: 0, skew: skew)
        #expect(!PlaybackStallCheck.isStalled(advanced: second - first, over: 2))
        // And the uncorrected reading, which is what a pause used to leave
        // behind: a forward jump, never a stall.
        #expect(!PlaybackStallCheck.isStalled(advanced: 293 - 91, over: 2))
    }
}

// One dump per window, however many overloads arrive inside it.
@Suite struct EngineDumpThrottleTests {

    @Test func theFirstDumpIsAlwaysAllowed() {
        #expect(EngineDumpThrottle.shouldDump(now: 0, lastDumpAt: nil))
        #expect(EngineDumpThrottle.shouldDump(now: 12345, lastDumpAt: nil))
    }

    @Test func aBurstInsideTheWindowSpendsOneDump() {
        let start = 1000.0
        #expect(EngineDumpThrottle.shouldDump(now: start, lastDumpAt: nil))
        for offset in stride(from: 0.1, through: 29.9, by: 5) {
            #expect(!EngineDumpThrottle.shouldDump(now: start + offset, lastDumpAt: start))
        }
    }

    @Test func theWindowReopensExactlyOnTheInterval() {
        let start = 1000.0
        let interval = EngineDumpThrottle.overloadInterval
        #expect(!EngineDumpThrottle.shouldDump(now: start + interval - 0.001,
                                               lastDumpAt: start))
        #expect(EngineDumpThrottle.shouldDump(now: start + interval, lastDumpAt: start))
        #expect(EngineDumpThrottle.shouldDump(now: start + interval * 3, lastDumpAt: start))
    }

    @Test func theWindowIsCallerSettable() {
        #expect(EngineDumpThrottle.shouldDump(now: 5, lastDumpAt: 0, interval: 5))
        #expect(!EngineDumpThrottle.shouldDump(now: 4, lastDumpAt: 0, interval: 5))
    }
}

// The overload sentinel's own trace line — the only part of it reachable
// without a CoreAudio device posting the property change.
@Suite struct OverloadTraceLineTests {

    @Test func theOverloadLineNamesTheDeviceAndTheCount() {
        let entry = EngineTraceEntry(at: 3, deck: .output, event: .alarm,
                                     reason: .overload, v0: 91, v1: 4, v2: 0)
        let line = EngineTrace.line(entry, origin: 1)
        #expect(line.contains("out"))
        #expect(line.contains("ALARM"))
        #expect(line.contains("overload"))
        #expect(line.contains("device=91 count=4"))
    }
}
