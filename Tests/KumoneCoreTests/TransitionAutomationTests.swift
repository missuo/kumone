import Testing
@testable import KumoneCore
import AVFoundation
import Foundation

// The transition's parameter curves, pinned as pure functions.
//
// These exist because `TransitionAutomation` is now shared by two consumers:
// the real-time `PlaybackEngine` tick and the offline `audition` renderer. The
// engine smoke tests prove the curves are *wired up* (they sample a running
// graph for each style's fingerprint); these prove the curves are *right*, at
// far finer resolution than a 20 Hz sampler on a live engine can manage.
@Suite struct TransitionAutomationTests {

    // MARK: - Fixtures

    private let crossfade = TransitionPlan.crossfade(duration: 4, outPoint: 100, inPoint: 0)
    private let beatMatched = TransitionPlan.beatMatched(BeatMatchedPlan(
        outPoint: 100, inPoint: 0, overlapBars: 8,
        outgoingRate: 0.99, incomingRate: 1.02,
        bassSwapOffset: 4, overlapDuration: 8))

    private func frame(_ plan: TransitionPlan, _ style: TransitionStyle,
                       _ t: TimeInterval) -> TransitionAutomation.Frame {
        TransitionAutomation.frame(plan: plan, style: style, elapsed: t)
    }

    // MARK: - Fader law

    /// The pair of faders is equal-power for every style whose outro is a plain
    /// fade: sin² + cos² = 1 at every instant, so the blend holds a constant
    /// perceived level instead of dipping in the middle (which a linear
    /// crossfade of uncorrelated material audibly does).
    @Test func plainFadeIsEqualPowerThroughout() {
        for step in 0...100 {
            let t = 4 * Double(step) / 100
            let f = frame(crossfade, .plain, t)
            let power = f.outgoing.fader * f.outgoing.fader
                + f.incoming.fader * f.incoming.fader
            #expect(abs(power - 1) < 0.001,
                    "equal-power law broken at t=\(t): \(f.outgoing.fader)² + \(f.incoming.fader)² = \(power)")
        }
    }

    // MARK: - Dominant-deck law

    /// A long staged beat-matched blend, with the law on and off. 30 s and a
    /// swap at 15 s is the shape a listener reported the trough in.
    private var longStaged: TransitionPlan {
        .beatMatched(BeatMatchedPlan(
            outPoint: 200, inPoint: 0, overlapBars: 16,
            outgoingRate: 0.99, incomingRate: 1.02,
            bassSwapOffset: 15, overlapDuration: 30))
    }

    private var dominantStyle: TransitionStyle {
        var s = TransitionStyle(outroEffect: .fade, stagedEQ: true)
        s.dominantDeck = true
        return s
    }

    /// The shape, stated as the rule it exists to enforce: **one deck owns the
    /// floor at every instant**. Before the swap that is the outgoing deck,
    /// after it the incoming one, and at no point are both backed off at once.
    @Test func theDominantDeckOwnsTheFloorThroughout() {
        let geometry = TransitionAutomation.Geometry(plan: longStaged)
        let swapAt = geometry.swapOffset
        for step in 0...300 {
            let t = 30 * Double(step) / 300
            let f = frame(longStaged, dominantStyle, t)
            if t < swapAt - 0.05 {
                // The outgoing deck is still the dominant one: full level bar
                // the courtesy dip, which is under a dB.
                #expect(f.outgoing.fader >= TransitionAutomation.dominantCourtesyLevel - 0.001,
                        "outgoing dipped to \(f.outgoing.fader) at t=\(t), before the swap")
                #expect(f.incoming.fader <= 1.0001)
            }
            // Somebody is always near full: the trough this law removes was
            // both decks at 0.707 for seconds at a time.
            #expect(max(f.outgoing.fader, f.incoming.fader) > 0.82,
                    "no dominant deck at t=\(t): out \(f.outgoing.fader), in \(f.incoming.fader)")
        }
    }

    /// The incoming deck climbs, waits under the outgoing one at the plateau,
    /// and arrives at unity exactly where the low end changes hands.
    @Test func theIncomingDeckWaitsAtThePlateauAndArrivesAtTheSwap() {
        let geometry = TransitionAutomation.Geometry(plan: longStaged)
        let swapAt = geometry.swapOffset
        let riseEnd = swapAt * TimeInterval(TransitionAutomation.dominantRiseShare)
        let plateau = dominantStyle.preSwapPlateau

        #expect(frame(longStaged, dominantStyle, 0).incoming.fader == 0)
        // At the top of the climb: at the plateau, not past it.
        let atRise = frame(longStaged, dominantStyle, riseEnd).incoming.fader
        #expect(abs(atRise - plateau) < 0.01, "plateau not reached at \(riseEnd): \(atRise)")
        // Waiting: still near the plateau a moment later, not still climbing.
        let waiting = frame(longStaged, dominantStyle, riseEnd + 0.5).incoming.fader
        #expect(waiting >= plateau - 0.01 && waiting < plateau + 0.06,
                "not a plateau at \(riseEnd + 0.5): \(waiting)")
        // Unity at the swap, where the EQ hands it the low end.
        #expect(abs(frame(longStaged, dominantStyle, swapAt).incoming.fader - 1) < 0.005)
        #expect(abs(frame(longStaged, dominantStyle, 30).incoming.fader - 1) < 0.005)
    }

    /// The outgoing deck leaves *after* the swap, over what is left of the
    /// overlap, and reaches silence at the end — so every downstream invariant
    /// that keys off the endpoints still holds.
    @Test func theOutgoingDeckLeavesOnlyAfterTheSwap() {
        let geometry = TransitionAutomation.Geometry(plan: longStaged)
        let swapAt = geometry.swapOffset
        #expect(abs(frame(longStaged, dominantStyle, 0).outgoing.fader - 1) < 0.001)
        #expect(abs(frame(longStaged, dominantStyle, swapAt).outgoing.fader
                    - TransitionAutomation.dominantCourtesyLevel) < 0.005)
        // Monotonically down after the swap, to zero.
        var previous = Float.greatestFiniteMagnitude
        for step in 0...100 {
            let t = swapAt + (30 - swapAt) * Double(step) / 100
            let level = frame(longStaged, dominantStyle, t).outgoing.fader
            #expect(level <= previous + 0.001, "outgoing rose again at t=\(t)")
            previous = level
        }
        #expect(frame(longStaged, dominantStyle, 30).outgoing.fader < 0.001)
    }

    /// Both curves are continuous — the engine writes them at 50 Hz and a step
    /// is a click. Checked as a bound on the per-tick move at the two joints
    /// the law is built from (the top of the climb, and the swap).
    @Test func theDominantCurvesNeverStep() {
        let tick = 1.0 / 50
        var lastOut = frame(longStaged, dominantStyle, 0).outgoing.fader
        var lastIn = frame(longStaged, dominantStyle, 0).incoming.fader
        var t = tick
        while t <= 30 {
            let f = frame(longStaged, dominantStyle, t)
            #expect(abs(f.outgoing.fader - lastOut) < 0.02,
                    "outgoing stepped \(lastOut) → \(f.outgoing.fader) at t=\(t)")
            #expect(abs(f.incoming.fader - lastIn) < 0.02,
                    "incoming stepped \(lastIn) → \(f.incoming.fader) at t=\(t)")
            lastOut = f.outgoing.fader
            lastIn = f.incoming.fader
            t += tick
        }
    }

    /// The trough, measured: the old law puts the *sum* of the two faders at
    /// its lowest in the middle of the blend, which is where the listener
    /// heard the mix collapse. The new law never lets it fall that far.
    @Test func theNewLawRemovesTheMidBlendTrough() {
        var symmetric = TransitionStyle(outroEffect: .fade, stagedEQ: true)
        symmetric.dominantDeck = false
        let geometry = TransitionAutomation.Geometry(plan: longStaged)
        let swapAt = geometry.swapOffset

        // Around the swap, where the staged EQ has both decks spectrally
        // halved, the old law backs both of them off to 0.707.
        let old = frame(longStaged, symmetric, swapAt)
        #expect(abs(old.outgoing.fader - 0.7071) < 0.01)
        #expect(abs(old.incoming.fader - 0.7071) < 0.01)
        #expect(max(old.outgoing.fader, old.incoming.fader) < 0.72,
                "the old law really does leave nobody in charge at the swap")

        let new = frame(longStaged, dominantStyle, swapAt)
        #expect(new.incoming.fader > 0.99, "the new law hands the floor over whole")
    }

    /// Knob off — and every hand-over that is not a staged beat-match — keeps
    /// the symmetric curves exactly, to the last bit.
    @Test func theLawIsOffForEverythingItWasNotAskedFor() {
        var symmetric = TransitionStyle(outroEffect: .fade, stagedEQ: true)
        symmetric.dominantDeck = false
        var stagedCrossfade = TransitionStyle(outroEffect: .fade, stagedEQ: true)
        stagedCrossfade.dominantDeck = true          // asked for, but not a beat-match
        var unstaged = TransitionStyle(outroEffect: .fade, stagedEQ: false)
        unstaged.dominantDeck = true                 // asked for, but not staged

        for step in 0...200 {
            let t = 30 * Double(step) / 200
            let progress = Float(min(1, t / 30))
            let expectedOut = cos(progress * .pi / 2)
            let expectedIn = sin(progress * .pi / 2)

            // The knob off.
            let off = frame(longStaged, symmetric, t)
            #expect(off.outgoing.fader == expectedOut)
            #expect(off.incoming.fader == expectedIn)
            // Staged, dominant asked for — but a crossfade, which has no beat
            // grid and therefore no meaningful swap point to hold up to.
            let cf = TransitionPlan.crossfade(duration: 30, outPoint: 200, inPoint: 0)
            let crossfaded = frame(cf, stagedCrossfade, t)
            #expect(crossfaded.outgoing.fader == expectedOut)
            #expect(crossfaded.incoming.fader == expectedIn)
            // Beat-matched, dominant asked for — but not staged, so it is the
            // legacy single-low-shelf hand-over and keeps its own curves.
            let legacy = frame(longStaged, unstaged, t)
            #expect(legacy.outgoing.fader == expectedOut)
            #expect(legacy.incoming.fader == expectedIn)
        }
    }

    /// `.plain` is the regression floor: it never opts in, so its faders are
    /// bit-identical to what they were before the law existed.
    @Test func plainStyleFadersAreUntouched() {
        #expect(TransitionStyle.plain.dominantDeck == false)
        for step in 0...100 {
            let t = 8 * Double(step) / 100
            let f = frame(beatMatched, .plain, t)
            let progress = Float(min(1, t / 8))
            #expect(f.outgoing.fader == cos(progress * .pi / 2))
            #expect(f.incoming.fader == sin(progress * .pi / 2))
        }
    }

    @Test func equalPowerMidpointIsMinusThreeDB() {
        let f = frame(crossfade, .plain, 2)  // exactly half of a 4s overlap
        #expect(abs(f.outgoing.fader - 0.7071) < 0.001, "outgoing: \(f.outgoing.fader)")
        #expect(abs(f.incoming.fader - 0.7071) < 0.001, "incoming: \(f.incoming.fader)")
    }

    @Test func fadersStartAndEndAtTheirEndpoints() {
        let start = frame(crossfade, .plain, 0)
        #expect(abs(start.outgoing.fader - 1) < 0.001)
        #expect(abs(start.incoming.fader) < 0.001)
        let end = frame(crossfade, .plain, 4)
        #expect(abs(end.outgoing.fader) < 0.001)
        #expect(abs(end.incoming.fader - 1) < 0.001)
        #expect(end.isComplete)
    }

    /// `.filterSweep` deliberately breaks the equal-power law: the sweep, not
    /// the level, carries the exit, so the outgoing deck is held up early.
    @Test func filterSweepHoldsLevelEarlyThenCollapses() {
        let style = TransitionStyle(outroEffect: .filterSweep, stagedEQ: false)
        let quarter = frame(crossfade, style, 1)
        let plainQuarter = frame(crossfade, .plain, 1)
        #expect(quarter.outgoing.fader > plainQuarter.outgoing.fader + 0.05,
                "the sweep should hold the outgoing level above a plain fade early on")
        #expect(abs(frame(crossfade, style, 4).outgoing.fader) < 0.001,
                "…and still land on silence")
    }

    /// 20 Hz → 1.2 kHz, logarithmically: equal ratios in equal time, so the
    /// sweep sounds like it moves at a constant speed.
    @Test func filterSweepIsLogarithmic() {
        let style = TransitionStyle(outroEffect: .filterSweep, stagedEQ: false)
        #expect(frame(crossfade, style, 0).outgoing.highPassBypassed == false,
                "the high-pass band must un-bypass for the whole sweep")
        let f0 = frame(crossfade, style, 0).outgoing.highPassFrequency
        let f1 = frame(crossfade, style, 1).outgoing.highPassFrequency
        let f2 = frame(crossfade, style, 2).outgoing.highPassFrequency
        let f4 = frame(crossfade, style, 4).outgoing.highPassFrequency
        #expect(abs(f0 - 20) < 0.01, "sweep starts at 20 Hz, got \(f0)")
        #expect(abs(f4 - 1200) < 1, "sweep ends at 1.2 kHz, got \(f4)")
        #expect(abs((f1 / f0) - (f2 / f1)) < 0.01,
                "equal time should mean equal frequency ratio (\(f1 / f0) vs \(f2 / f1))")
        // …and no other style touches the band.
        #expect(frame(crossfade, .plain, 2).outgoing.highPassBypassed)
    }

    // MARK: - Staged EQ milestones

    /// The staged hand-over's whole point is an *order*: the outgoing track
    /// loses its highs first, then its mids, and keeps the low end until the
    /// swap — with the incoming track the exact mirror image.
    @Test func stagedEQHandsOverHighsThenMidsThenLows() {
        let style = TransitionStyle(outroEffect: .fade, stagedEQ: true)
        // 8s overlap, swap at 4s → high stage ends 1.8s, mid stage 1.4→3.4s.
        let early = frame(beatMatched, style, 1.8).outgoing
        #expect(abs(early.highGain - TransitionAutomation.highCutDB) < 0.01,
                "highs should be fully out by the end of the high stage (\(early.highGain))")
        #expect(early.midGain > TransitionAutomation.midCutDB + 1,
                "mids should still be on their way out (\(early.midGain))")
        #expect(abs(early.lowGain) < 0.01,
                "the low end must be untouched before the swap (\(early.lowGain))")

        let mid = frame(beatMatched, style, 3.4).outgoing
        #expect(abs(mid.midGain - TransitionAutomation.midCutDB) < 0.01,
                "mids fully out by the end of the mid stage (\(mid.midGain))")
        #expect(mid.lowGain > TransitionAutomation.bassCutDB + 1,
                "the low end still holds just before the swap (\(mid.lowGain))")

        let afterSwap = frame(beatMatched, style, 4.4).outgoing
        #expect(abs(afterSwap.lowGain - TransitionAutomation.bassCutDB) < 0.01,
                "the low end is gone once the swap ramp completes (\(afterSwap.lowGain))")
    }

    /// Highs and mids hand over on a shared ramp — what one deck gives up, the
    /// other takes at the same instant, so the spectrum never has a hole.
    @Test func stagedEQHighsAndMidsHandOverWithoutAGap() {
        let style = TransitionStyle(outroEffect: .fade, stagedEQ: true)
        for step in 0...80 {
            let t = 8 * Double(step) / 80
            let f = frame(beatMatched, style, t)
            #expect(abs((f.outgoing.highGain + f.incoming.highGain)
                        - TransitionAutomation.highCutDB) < 0.01, "highs at t=\(t)")
            #expect(abs((f.outgoing.midGain + f.incoming.midGain)
                        - TransitionAutomation.midCutDB) < 0.01, "mids at t=\(t)")
        }
    }

    /// The low end is the exception, and deliberately so: the outgoing bass
    /// ducks out *before* the swap and the incoming bass only comes up
    /// *after* it, so the two kick drums are never in the mix together — the
    /// brief bass-light moment at the swap is the classic DJ bass swap, not a
    /// bug. (Two low ends at once is what makes an amateur blend sound muddy.)
    @Test func stagedEQBassSwapIsStaggeredNotMirrored() {
        let style = TransitionStyle(outroEffect: .fade, stagedEQ: true)
        let geometry = TransitionAutomation.Geometry(plan: beatMatched)
        let swap = geometry.swapOffset
        let ramp = min(0.4, max(0.1, swap * 0.2))

        // Well before the swap: the outgoing deck owns the low end alone.
        let before = frame(beatMatched, style, swap - ramp - 0.1)
        #expect(abs(before.outgoing.lowGain) < 0.01, "outgoing keeps its bass (\(before.outgoing.lowGain))")
        #expect(abs(before.incoming.lowGain - TransitionAutomation.bassCutDB) < 0.01,
                "incoming is held back (\(before.incoming.lowGain))")

        // At the swap: the hand-over point — the outgoing deck is out and the
        // incoming one has not come up yet.
        let at = frame(beatMatched, style, swap)
        #expect(abs(at.outgoing.lowGain - TransitionAutomation.bassCutDB) < 0.01,
                "outgoing bass is gone at the swap (\(at.outgoing.lowGain))")
        #expect(abs(at.incoming.lowGain - TransitionAutomation.bassCutDB) < 0.01,
                "incoming bass has not arrived yet (\(at.incoming.lowGain))")

        // After the swap ramp: the incoming deck owns it alone.
        let after = frame(beatMatched, style, swap + ramp + 0.1)
        #expect(abs(after.outgoing.lowGain - TransitionAutomation.bassCutDB) < 0.01)
        #expect(abs(after.incoming.lowGain) < 0.01,
                "incoming bass is fully in (\(after.incoming.lowGain))")

        // …and at no point are both decks' low shelves open at once.
        for step in 0...200 {
            let t = 8 * Double(step) / 200
            let f = frame(beatMatched, style, t)
            let bothOpen = f.outgoing.lowGain > -6 && f.incoming.lowGain > -6
            #expect(!bothOpen,
                    "two low ends in the mix at t=\(t): \(f.outgoing.lowGain) / \(f.incoming.lowGain)")
        }
    }

    /// The incoming deck must start fully held back and end fully released —
    /// a stage left engaged colours the whole next song.
    @Test func stagedEQReleasesTheIncomingDeckCompletely() {
        let style = TransitionStyle(outroEffect: .fade, stagedEQ: true)
        let start = frame(beatMatched, style, 0).incoming
        #expect(abs(start.highGain - TransitionAutomation.highCutDB) < 0.01)
        #expect(abs(start.midGain - TransitionAutomation.midCutDB) < 0.01)
        #expect(abs(start.lowGain - TransitionAutomation.bassCutDB) < 0.01)
        let end = frame(beatMatched, style, 8).incoming
        #expect(abs(end.highGain) < 0.01 && abs(end.midGain) < 0.01 && abs(end.lowGain) < 0.01,
                "incoming deck must be transparent by the end of the overlap (\(end))")
    }

    /// `.plain` on a beat-matched plan still runs the legacy single low-shelf
    /// bass swap and touches nothing else — the pre-styles regression floor.
    @Test func plainBeatMatchedTouchesOnlyTheLowShelf() {
        var sawBassDuck = false
        for step in 0...80 {
            let t = 8 * Double(step) / 80
            let f = frame(beatMatched, .plain, t)
            if f.outgoing.lowGain < -1 { sawBassDuck = true }
            #expect(abs(f.outgoing.midGain) < 0.001 && abs(f.outgoing.highGain) < 0.001,
                    "plain must not touch mid/high at t=\(t)")
            #expect(f.outgoing.highPassBypassed && f.incoming.highPassBypassed,
                    "plain must not touch the high-pass at t=\(t)")
            #expect(abs(f.outgoing.delayWetDryMix) < 0.001
                    && abs(f.outgoing.delayFeedback) < 0.001,
                    "plain must leave the delay dry at t=\(t)")
        }
        #expect(sawBassDuck, "the low-shelf bass swap should still duck the outgoing deck")
    }

    // MARK: - echoOut

    /// The throw is an event in the real engine and a threshold here; the two
    /// must agree on *when*, and on the fact that nothing rings before it.
    @Test func echoOutThrowsExactlyAtTheStopPoint() {
        let style = TransitionStyle(outroEffect: .echoOut, stagedEQ: false)
        let geometry = TransitionAutomation.Geometry(plan: crossfade)
        let stopAt = geometry.echoStopOffset
        #expect(abs(stopAt - 4 * 0.65) < 0.001, "crossfade stop point is 65% in (\(stopAt))")

        let before = frame(crossfade, style, stopAt - 0.001)
        #expect(!before.echoThrown, "no throw before the stop point")
        #expect(abs(before.outgoing.delayWetDryMix) < 0.001, "the delay must be dry before the throw")
        #expect(abs(before.outgoing.eqGlobalGain) < 0.001, "the source is not cut before the throw")
        #expect(before.outgoing.fader > 0.7,
                "before the stop point the outgoing track only ducks slightly (\(before.outgoing.fader))")

        let at = frame(crossfade, style, stopAt)
        #expect(at.echoThrown)
        #expect(abs(at.outgoing.delayWetDryMix - TransitionAutomation.echoWetMix) < 0.001)
        #expect(abs(at.outgoing.delayFeedback - TransitionAutomation.echoFeedback) < 0.001)
        #expect(abs(at.outgoing.eqGlobalGain) < 0.001,
                "the cut starts *at* the stop point, it is not instant (\(at.outgoing.eqGlobalGain))")

        // The cut completes over echoCutDuration, using the EQ's global gain —
        // never the fader, which sits downstream of the delay and would mute
        // the tail this style exists for.
        let cut = frame(crossfade, style, stopAt + TransitionAutomation.echoCutDuration)
        #expect(abs(cut.outgoing.eqGlobalGain - TransitionAutomation.echoCutGainDB) < 0.01,
                "the source should be fully cut after echoCutDuration (\(cut.outgoing.eqGlobalGain))")
        #expect(cut.outgoing.fader > 0.5,
                "the fader must stay up so the delay tail still reaches the mixer (\(cut.outgoing.fader))")
        #expect(abs(cut.outgoing.delayWetDryMix - TransitionAutomation.echoWetMix) < 0.001,
                "the tail keeps ringing while the source is cut")
    }

    /// The delay time follows the planner's hint, then the plan's beat grid,
    /// then a fixed 250 ms — in that order.
    @Test func echoDelayTimePrefersThePlannerHintThenTheBeatGrid() {
        let hinted = TransitionStyle(outroEffect: .echoOut, stagedEQ: false, echoDelayTime: 0.42)
        let bare = TransitionStyle(outroEffect: .echoOut, stagedEQ: false)
        let beatGeometry = TransitionAutomation.Geometry(plan: beatMatched)   // 8 bars / 8 s
        let flatGeometry = TransitionAutomation.Geometry(plan: crossfade)

        #expect(abs(TransitionAutomation.echoDelayTime(style: hinted, geometry: beatGeometry)
                    - 0.42) < 0.001, "the planner's hint wins")
        // 8 s over 32 beats = 0.25 s/beat; a dotted eighth is 0.75 of that.
        #expect(abs(TransitionAutomation.echoDelayTime(style: bare, geometry: beatGeometry)
                    - 0.1875) < 0.001, "beat-synced dotted eighth")
        #expect(abs(TransitionAutomation.echoDelayTime(style: bare, geometry: flatGeometry)
                    - TransitionAutomation.echoDefaultDelayTime) < 0.001,
                "a plain crossfade has no grid, so 250 ms")
    }

    // MARK: - Rates and midpoint

    @Test func beatMatchedRatesEaseInAndTheIncomingDeckIsPinned() {
        let style = TransitionStyle(outroEffect: .fade, stagedEQ: true)
        // Ramp-in is min(1s, duration/4) = 1s for an 8s overlap.
        #expect(abs(frame(beatMatched, style, 0).outgoing.rate - 1) < 0.001,
                "the outgoing deck starts at its own tempo")
        #expect(abs(frame(beatMatched, style, 0.5).outgoing.rate - 0.995) < 0.001,
                "…and eases half way there at t=0.5s")
        #expect(abs(frame(beatMatched, style, 1).outgoing.rate - 0.99) < 0.001)
        #expect(abs(frame(beatMatched, style, 6).outgoing.rate - 0.99) < 0.001,
                "…then holds")
        for t in [0.0, 1.0, 4.0, 8.0] {
            #expect(abs(frame(beatMatched, style, t).incoming.rate - 1.02) < 0.001,
                    "the incoming deck sits at its matched rate for the whole overlap (t=\(t))")
        }
        // A plain crossfade never bends either deck.
        #expect(abs(frame(crossfade, .plain, 2).outgoing.rate - 1) < 0.001)
        #expect(abs(frame(crossfade, .plain, 2).incoming.rate - 1) < 0.001)
    }

    @Test func midpointLandsOnTheSwapNotTheHalfwayMark() {
        // A crossfade's audible midpoint is simply half way.
        #expect(!frame(crossfade, .plain, 1.99).midpointReached)
        #expect(frame(crossfade, .plain, 2.0).midpointReached)
        // A staged beat-matched hand-over's midpoint is the bass swap.
        let staged = TransitionStyle(outroEffect: .fade, stagedEQ: true)
        let swap = TransitionAutomation.Geometry(plan: beatMatched).swapOffset
        #expect(!frame(beatMatched, staged, swap - 0.01).midpointReached)
        #expect(frame(beatMatched, staged, swap).midpointReached)
    }

    // MARK: - Settling

    @Test func settlingRestoresRateAndDecaysTheTail() {
        let atStart = TransitionAutomation.settleFrame(
            plan: beatMatched, restoringRate: true, echoTailRinging: true, elapsed: 0)
        #expect(abs(atStart.incomingRate - 1.02) < 0.001)
        #expect(abs(atStart.outgoingDelayWetDryMix - TransitionAutomation.echoWetMix) < 0.001)
        #expect(!atStart.isDone)

        let done = TransitionAutomation.settleFrame(
            plan: beatMatched, restoringRate: true, echoTailRinging: true,
            elapsed: max(TransitionAutomation.rateRestoreDuration,
                         TransitionAutomation.echoTailDuration))
        #expect(abs(done.incomingRate - 1) < 0.001, "the rate must land exactly on 1.0")
        #expect(abs(done.outgoingDelayWetDryMix) < 0.001, "the tail must decay to fully dry")
        #expect(abs(done.outgoingDelayFeedback) < 0.001)
        #expect(done.isDone)

        // Nothing to settle → done immediately.
        #expect(TransitionAutomation.settleFrame(
            plan: crossfade, restoringRate: false, echoTailRinging: false, elapsed: 0).isDone)
    }

    // MARK: - Continuity

    /// Parameters are written to a live audio graph 50 times a second; a step
    /// between adjacent ticks is an audible click. Every automated value must
    /// move smoothly (the one legitimate discontinuity is `.echoOut`'s throw,
    /// which is a deliberate slam).
    @Test func everyCurveIsContinuousAcrossTicks() {
        let cases: [(String, TransitionPlan, TransitionStyle)] = [
            ("plain crossfade", crossfade, .plain),
            ("staged crossfade", crossfade,
             TransitionStyle(outroEffect: .fade, stagedEQ: true)),
            ("sweep", crossfade, TransitionStyle(outroEffect: .filterSweep, stagedEQ: false)),
            ("plain beatMatched", beatMatched, .plain),
            ("staged beatMatched", beatMatched,
             TransitionStyle(outroEffect: .fade, stagedEQ: true)),
        ]
        let tick = 1.0 / 50
        for (name, plan, style) in cases {
            let duration = TransitionAutomation.Geometry(plan: plan).overlapDuration
            var previous = TransitionAutomation.frame(plan: plan, style: style, elapsed: 0)
            var t = tick
            while t <= duration {
                let f = TransitionAutomation.frame(plan: plan, style: style, elapsed: t)
                for (label, a, b) in [
                    ("outgoing fader", previous.outgoing.fader, f.outgoing.fader),
                    ("incoming fader", previous.incoming.fader, f.incoming.fader),
                    ("outgoing low", previous.outgoing.lowGain, f.outgoing.lowGain),
                    ("outgoing mid", previous.outgoing.midGain, f.outgoing.midGain),
                    ("outgoing high", previous.outgoing.highGain, f.outgoing.highGain),
                    ("incoming low", previous.incoming.lowGain, f.incoming.lowGain),
                ] {
                    // 24 dB of cut spread over ≥0.1 s of ramp is ~5 dB/tick at
                    // the very worst; anything beyond that is a step.
                    #expect(abs(a - b) < 6,
                            "\(name): \(label) jumped \(a) → \(b) at t=\(t)")
                }
                previous = f
                t += tick
            }
        }
    }

    // MARK: - Offline renderer

    /// End-to-end proof that the offline path actually mixes: render a 440 Hz
    /// tone into an 880 Hz one and check that both are present, at the right
    /// levels, in the right places.
    @Test func offlineRenderOverlapsBothTracks() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("audition-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let a = directory.appendingPathComponent("a.caf")
        let b = directory.appendingPathComponent("b.caf")
        try writeTone(440, seconds: 30, to: a)
        try writeTone(880, seconds: 30, to: b)

        let planned = PlannedTransition(
            plan: .crossfade(duration: 4, outPoint: 20, inPoint: 0),
            style: .plain)
        let output = directory.appendingPathComponent("out.wav")
        var options = OfflineTransitionRenderer.Options()
        options.preRoll = 3
        options.postRoll = 3
        let result = try OfflineTransitionRenderer.render(
            planned, outgoing: a, incoming: b, to: output, options: options)

        #expect(abs(result.duration - 10) < 0.2,
                "3s pre-roll + 4s overlap + 3s post-roll (\(result.duration))")
        #expect(abs(result.overlapStart - 3) < 0.05)

        let file = try AVAudioFile(forReading: output)
        #expect(file.fileFormat.sampleRate == 44100)
        #expect(file.fileFormat.channelCount == 2)

        let tones = try toneEnergy(in: output)
        // Pre-roll: only the outgoing 440 Hz.
        let pre = tones(1.0, 2.0)
        #expect(pre.at440 > 0.05, "the outgoing track should be sounding in the pre-roll (\(pre))")
        #expect(pre.at880 < pre.at440 * 0.1, "…and the incoming one should not be (\(pre))")
        // Mid-overlap: BOTH, and at roughly the equal-power −3 dB level each.
        let middle = tones(4.9, 5.1)
        #expect(middle.at440 > pre.at440 * 0.4 && middle.at440 < pre.at440 * 0.95,
                "the outgoing track should be half way down mid-overlap (\(middle) vs \(pre))")
        #expect(middle.at880 > pre.at440 * 0.4,
                "the incoming track should be half way up mid-overlap (\(middle))")
        // Post-roll: only the incoming 880 Hz.
        let post = tones(8.0, 9.0)
        #expect(post.at880 > 0.05, "the incoming track should carry the post-roll (\(post))")
        #expect(post.at440 < post.at880 * 0.1,
                "…and the outgoing one must be gone (\(post))")
    }

    /// The two levels the renderer touches, and the fact that they are
    /// independent: the per-deck **trim** is the product's own compensation and
    /// must change the balance between the two songs, while the output
    /// **normalization** is a blind-test fairness device applied to the finished
    /// mix and must not change that balance at all.
    @Test func renderAppliesDeckTrimsAndNormalizesTheFinishedFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("audition-loudness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let a = directory.appendingPathComponent("a.caf")
        let b = directory.appendingPathComponent("b.caf")
        try writeTone(440, seconds: 30, to: a)
        try writeTone(880, seconds: 30, to: b)
        let planned = PlannedTransition(
            plan: .crossfade(duration: 4, outPoint: 20, inPoint: 0), style: .plain)

        func render(outTrim: Double, inTrim: Double, normalize: Double?,
                    name: String) throws -> (OfflineTransitionRenderer.Result, URL) {
            var options = OfflineTransitionRenderer.Options()
            options.preRoll = 3
            options.postRoll = 3
            options.outgoingTrimDB = outTrim
            options.incomingTrimDB = inTrim
            options.normalizeToLUFS = normalize
            let url = directory.appendingPathComponent("\(name).wav")
            return (try OfflineTransitionRenderer.render(
                planned, outgoing: a, incoming: b, to: url, options: options), url)
        }

        // 1. Un-normalized, no trims: the reference balance.
        let (plainResult, plainURL) = try render(
            outTrim: 0, inTrim: 0, normalize: nil, name: "plain")
        #expect(plainResult.normalizationGainDB == 0)
        #expect(plainResult.normalizationTargetLUFS == nil)
        let plainTones = try toneEnergy(in: plainURL)

        // 2. The incoming deck 6 dB down, still un-normalized: only the
        //    incoming tone moves, and by half.
        let (trimmed, trimmedURL) = try render(
            outTrim: 0, inTrim: -6.0206, normalize: nil, name: "trimmed")
        #expect(trimmed.incomingTrimDB == -6.0206)
        let trimmedTones = try toneEnergy(in: trimmedURL)
        let plainPre = plainTones(1.0, 2.0), trimmedPre = trimmedTones(1.0, 2.0)
        let plainPost = plainTones(8.0, 9.0), trimmedPost = trimmedTones(8.0, 9.0)
        #expect(abs(trimmedPre.at440 - plainPre.at440) < plainPre.at440 * 0.05,
                "the untrimmed deck must be untouched (\(trimmedPre) vs \(plainPre))")
        #expect(abs(trimmedPost.at880 - plainPost.at880 * 0.5) < plainPost.at880 * 0.06,
                "the trimmed deck must land at half amplitude (\(trimmedPost) vs \(plainPost))")

        // 3. Normalized: the file lands on the target, and — the point of the
        //    device — the *balance* between the two songs is untouched.
        let (normalized, normalizedURL) = try render(
            outTrim: 0, inTrim: -6.0206, normalize: -16, name: "normalized")
        #expect(normalized.normalizationTargetLUFS == -16)
        #expect(normalized.measuredLUFS != nil)
        let measured = try measureLUFS(of: normalizedURL)
        #expect(abs(measured - -16) < 0.5, "normalized file measured \(measured) LUFS")
        let normalizedTones = try toneEnergy(in: normalizedURL)
        let normPre = normalizedTones(1.0, 2.0), normPost = normalizedTones(8.0, 9.0)
        let trimmedRatio = trimmedPost.at880 / trimmedPre.at440
        let normalizedRatio = normPost.at880 / normPre.at440
        #expect(abs(normalizedRatio - trimmedRatio) < trimmedRatio * 0.02,
                "normalization must scale the whole file, not the mix (\(normalizedRatio) vs \(trimmedRatio))")
        // And it is a real, non-trivial gain on this material.
        #expect(abs(normalized.normalizationGainDB) > 0.5)
    }

    /// BS.1770 loudness of a rendered file, via the same meter the analyzer
    /// uses (mono downmix, counted as a centred pair).
    private func measureLUFS(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                      frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: frames)
        for channel in 0..<channels {
            let data = buffer.floatChannelData![channel]
            for i in 0..<frames { mono[i] += data[i] / Float(channels) }
        }
        return LoudnessMeter.integratedLUFS(mono, sampleRate: format.sampleRate)!
    }

    /// `.gapless` is tail-to-head with no overlap: the outgoing track plays out
    /// and the incoming one starts on the very next sample. The render must
    /// show a clean splice — never both tones at once, and never a hole.
    @Test func offlineRenderGaplessSplicesWithoutOverlapOrGap() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("audition-gapless-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let a = directory.appendingPathComponent("a.caf")
        let b = directory.appendingPathComponent("b.caf")
        try writeTone(440, seconds: 10, to: a)
        try writeTone(880, seconds: 10, to: b)

        let output = directory.appendingPathComponent("out.wav")
        var options = OfflineTransitionRenderer.Options()
        options.preRoll = 3
        options.postRoll = 3
        let result = try OfflineTransitionRenderer.render(
            .plain(.gapless), outgoing: a, incoming: b, to: output, options: options)

        #expect(abs(result.duration - 6) < 0.2, "3s of tail + 3s of head (\(result.duration))")
        #expect(abs(result.overlapStart - 3) < 0.05, "the splice sits at 3s")
        #expect(result.overlapDuration == 0, "gapless has no overlap")

        let tones = try toneEnergy(in: output)
        let before = tones(1.0, 2.5)
        #expect(before.at440 > 0.05 && before.at880 < before.at440 * 0.1,
                "only the outgoing track before the splice (\(before))")
        let after = tones(3.5, 5.0)
        #expect(after.at880 > 0.05 && after.at440 < after.at880 * 0.1,
                "only the incoming track after it (\(after))")
        // No hole: level is continuous straight across the splice point.
        let across = tones(2.9, 3.1)
        #expect(across.at440 + across.at880 > 0.05 * 0.5,
                "the splice must not leave a silent gap (\(across))")
    }

    // MARK: - Transition gain ride

    /// The release envelope, as a pure function: full value at the seam, a
    /// constant dB-per-second slope, and a hard floor at unity in both
    /// directions (a ride never overshoots past 0 into the other sign).
    ///
    /// **The slope is chosen by sign**, which is the whole point: releasing a
    /// cut walks the new track *up* to its own level and must not take a verse
    /// to do it, while releasing a boost walks it *down* and is the move that
    /// has to stay hidden.
    @Test func theRideReleasesAtAConstantSlopeAndStopsAtUnity() {
        #expect(TransitionAutomation.rideReleaseBoostDBPerSecond == 0.3)
        #expect(TransitionAutomation.rideReleaseCutDBPerSecond == 1.2)
        #expect(TransitionAutomation.rideReleaseDBPerSecond(for: -4) == 1.2)
        #expect(TransitionAutomation.rideReleaseDBPerSecond(for: 2) == 0.3)
        // A zero ride has no release to have a slope for; the boost side is the
        // harmless answer, and `rideDB` short-circuits before ever using it.
        #expect(TransitionAutomation.rideReleaseDBPerSecond(for: 0) == 0.3)

        // A cut: −4 dB unwinds upward at 1.2 dB/s and lands exactly on 0.
        #expect(TransitionAutomation.rideDB(-4, secondsAfterOverlap: 0) == -4)
        #expect(abs(TransitionAutomation.rideDB(-4, secondsAfterOverlap: 1) - -2.8) < 1e-9)
        #expect(abs(TransitionAutomation.rideDB(-4, secondsAfterOverlap: 2) - -1.6) < 1e-9)
        #expect(TransitionAutomation.rideDB(-4, secondsAfterOverlap: 3.334) == 0)
        #expect(TransitionAutomation.rideDB(-4, secondsAfterOverlap: 60) == 0)
        // A boost unwinds downward at 0.3 dB/s, and also stops at 0.
        #expect(abs(TransitionAutomation.rideDB(2, secondsAfterOverlap: 1) - 1.7) < 1e-9)
        #expect(TransitionAutomation.rideDB(2, secondsAfterOverlap: 7) == 0)
        // Before the seam is the seam.
        #expect(TransitionAutomation.rideDB(-4, secondsAfterOverlap: -5) == -4)
        // No ride, no envelope.
        #expect(TransitionAutomation.rideDB(0, secondsAfterOverlap: 3) == 0)

        // The deepest cut the planner may ask for is home inside one phrase;
        // the deepest boost still takes the unhurried 13 s.
        #expect(abs(TransitionAutomation.rideReleaseDuration(-4) - 4 / 1.2) < 1e-9)
        #expect(abs(TransitionAutomation.rideReleaseDuration(4) - 4 / 0.3) < 1e-9)
        #expect(TransitionAutomation.rideReleaseDuration(0) == 0)
    }

    /// End to end through the offline graph: the ride really does shrink the
    /// level difference across the hand-over, and really does hand it back
    /// afterwards. Two equal-amplitude tones, so any difference between them
    /// in the finished WAV is the ride and nothing else.
    @Test func renderAppliesTheRideAcrossTheOverlapAndReleasesItAfter() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("audition-ride-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let a = directory.appendingPathComponent("a.caf")
        let b = directory.appendingPathComponent("b.caf")
        // The case the ride exists for: a quiet outro (4 dB down) meeting a hot
        // opening. Two tones, so any level difference in the finished WAV is
        // the material and the ride and nothing else.
        try writeTone(440, seconds: 40, amplitude: 0.5 * 0.63096, to: a)
        try writeTone(880, seconds: 40, to: b)
        let planned = PlannedTransition(
            plan: .crossfade(duration: 4, outPoint: 20, inPoint: 0), style: .plain)

        func render(ride: Double, name: String) throws
            -> (OfflineTransitionRenderer.Result, (Double, Double) -> ToneEnergy) {
            var options = OfflineTransitionRenderer.Options()
            options.preRoll = 3
            options.postRoll = 3
            options.rideDB = ride
            // The blind-test normalization is a whole-file gain; it would
            // rescale both renders differently and hide exactly what we are
            // measuring here.
            options.normalizeToLUFS = nil
            let url = directory.appendingPathComponent("\(name).wav")
            let result = try OfflineTransitionRenderer.render(
                planned, outgoing: a, incoming: b, to: url, options: options)
            return (result, try toneEnergy(in: url))
        }

        // Ride 0 is the untouched render: post-roll not stretched, and the
        // whole gain path is the one that existed before the ride.
        let (flat, flatTones) = try render(ride: 0, name: "flat")
        #expect(flat.rideDB == 0)
        #expect(flat.rideReleaseSeconds == 0)
        #expect(abs(flat.duration - 10) < 0.2, "3 + 4 + 3 (\(flat.duration))")

        // −4 dB: the incoming deck is held down for the whole overlap, then
        // let go of over 4 / 1.2 ≈ 3.3 s (a cut climbs back fast, so the new
        // track is not left in a level pit), which the post-roll holds easily.
        let (ridden, tones) = try render(ride: -4, name: "ridden")
        #expect(abs(ridden.rideDB - -4) < 1e-9)
        #expect(abs(ridden.rideReleaseSeconds - 4 / 1.2) < 1e-9)
        #expect(ridden.duration > 4 + ridden.rideReleaseSeconds,
                "the release must fit inside the file (\(ridden.duration))")

        // The overlap runs 3…7 s into the file. Sample just past its end, where
        // the incoming fader is fully open and the release has barely begun.
        // (A cut releases at 1.2 dB/s, so "barely" is a shorter window than it
        // used to be — 200 ms is 0.24 dB.)
        let heldFlat = flatTones(7.02, 7.22).at880
        let held = tones(7.02, 7.22).at880
        let ratio = Double(held / heldFlat)
        #expect(abs(20 * log10(ratio) - -4) < 0.6,
                "the incoming deck should sit ~4 dB down at the seam (\(ratio))")

        // …and back at its own level once the release has run out (7 + 3.33 s).
        let released = tones(10.6, 11.2).at880
        // The un-ridden render is only 10 s long, so its reference window is a
        // different second of the same steady tone.
        let releasedFlat = flatTones(9.0, 9.6).at880
        #expect(abs(20 * log10(Double(released / releasedFlat))) < 0.5,
                "the ride must be fully released by then (\(released) vs \(releasedFlat))")

        // Monotone in between: a ride that wandered would be audible.
        let mid1 = tones(8.0, 8.4).at880
        let mid2 = tones(9.3, 9.7).at880
        #expect(held < mid1 && mid1 < mid2 && mid2 <= released * 1.02,
                "the release should climb steadily (\(held) \(mid1) \(mid2) \(released))")

        // The whole point: the level *difference* across the seam. The outgoing
        // tail measures 4 dB below the incoming opening, so without a ride the
        // new track arrives 4 dB hot; with one it arrives level. The outgoing
        // deck is untouched either way — the ride is one-sided by construction —
        // so this is the same comparison a listener makes.
        let outAtSeam = tones(2.5, 2.9).at440
        #expect(abs(tones(2.5, 2.9).at440 - flatTones(2.5, 2.9).at440) < 0.005,
                "the outgoing deck must be identical with and without a ride")
        let flatGap = 20 * log10(Double(heldFlat / outAtSeam))
        let riddenGap = 20 * log10(Double(held / outAtSeam))
        #expect(abs(flatGap - 4) < 0.6, "the un-ridden seam is a 4 dB step (\(flatGap))")
        #expect(abs(riddenGap) < 0.6, "the ride levels it (\(riddenGap))")
    }

    /// A `.gapless` seam has no overlap to ride over, so the renderer ignores
    /// the ride entirely rather than drifting the new track's opening.
    @Test func aGaplessRenderIgnoresTheRide() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("audition-ride-gapless-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = directory.appendingPathComponent("a.caf")
        let b = directory.appendingPathComponent("b.caf")
        try writeTone(440, seconds: 10, to: a)
        try writeTone(880, seconds: 10, to: b)

        var options = OfflineTransitionRenderer.Options()
        options.preRoll = 3
        options.postRoll = 3
        options.rideDB = -4
        let result = try OfflineTransitionRenderer.render(
            .plain(.gapless), outgoing: a, incoming: b,
            to: directory.appendingPathComponent("out.wav"), options: options)
        #expect(result.rideDB == 0)
        #expect(abs(result.duration - 6) < 0.2, "post-roll untouched (\(result.duration))")
    }

    // MARK: - Helpers

    private func writeTone(_ hz: Double, seconds: Double, amplitude: Double = 0.5,
                           to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData!
        for frame in 0..<Int(frames) {
            let sample = Float(amplitude * sin(2 * .pi * hz * Double(frame) / format.sampleRate))
            data[0][frame] = sample
            data[1][frame] = sample
        }
        try file.write(from: buffer)
    }

    private struct ToneEnergy: CustomStringConvertible {
        let at440: Float
        let at880: Float
        var description: String {
            String(format: "440Hz=%.3f 880Hz=%.3f", at440, at880)
        }
    }

    /// Goertzel magnitude of each tone over an arbitrary window of the render —
    /// enough to tell "both tracks are sounding" from "one of them is".
    private func toneEnergy(in url: URL) throws -> (Double, Double) -> ToneEnergy {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                      frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0],
                                                count: Int(buffer.frameLength)))
        let rate = format.sampleRate
        func goertzel(_ hz: Double, _ slice: ArraySlice<Float>) -> Float {
            let coefficient = 2 * cos(2 * .pi * hz / rate)
            var s1: Double = 0, s2: Double = 0
            for sample in slice {
                let s0 = Double(sample) + coefficient * s1 - s2
                s2 = s1
                s1 = s0
            }
            let power = s1 * s1 + s2 * s2 - coefficient * s1 * s2
            return Float(sqrt(max(0, power)) / Double(slice.count) * 2)
        }
        return { from, to in
            let start = max(0, min(samples.count - 1, Int(from * rate)))
            let end = max(start + 1, min(samples.count, Int(to * rate)))
            let slice = samples[start..<end]
            return ToneEnergy(at440: goertzel(440, slice), at880: goertzel(880, slice))
        }
    }
}
