import Testing
@testable import KumoneCore
import Foundation

// The four approved loosenings, and the one principle behind all of them: a
// gate is only as tight as the risk it is holding back, so when a technique
// absorbs that risk the gate has to be re-priced or it is just superstition.
//
//   - the ride's cut side, because a cut is free of everything a boost costs;
//   - the neutral overlap cap, because it was priced for cue points the
//     structure layer replaced;
//   - the steadiness bar inside a single section, because the CV was a proxy
//     for a thing structure now measures directly;
//   - the ramped bend cap, because the pair of tempo caps has to be internally
//     consistent to mean anything.
//
// Each knob is also tested *off*, because "the old behaviour is one field
// away" is the property that makes any of this safe to ship.

@Suite struct AdmissionGateTests {

    // MARK: - Fixtures

    private func makeAnalysis(
        bpm: Double = 120,
        duration: TimeInterval = 200,
        rmsEnvelope: [Float]? = nil,
        referenceLoudness: Double? = nil,
        peakDBFS: Double? = -6,
        sections: [TrackAnalysis.Section] = [],
        structureConfidence: Double = 0.8
    ) -> TrackAnalysis {
        let barLength = 4 * 60 / bpm
        var a = TrackAnalysis(
            version: TrackAnalysis.currentVersion,
            bpm: bpm, bpmConfidence: 0.9,
            beats: stride(from: 0.4, to: duration, by: 60 / bpm).map { $0 },
            downbeats: stride(from: 0.4, to: duration, by: barLength).map { $0 },
            phraseBoundaries: [150, 90, 30],
            rmsEnvelope: rmsEnvelope ?? [Float](repeating: 0.5, count: Int(duration)),
            outroFadeStart: nil, introEnd: 2, duration: duration,
            melProfile: [], keyPitchClass: nil, keyIsMinor: false, keyConfidence: 0,
            vocalActivity: [], referenceLoudness: referenceLoudness, peakDBFS: peakDBFS)
        a.sections = sections
        a.structureConfidence = structureConfidence
        return a
    }

    private func section(_ kind: TrackAnalysis.Section.Kind,
                         _ start: TimeInterval, _ end: TimeInterval)
    -> TrackAnalysis.Section {
        TrackAnalysis.Section(start: start, end: end, kind: kind, repetition: 2,
                              energy: 0.7, vocalDensity: 1)
    }

    /// An envelope that wobbles hard enough to fail 0.40 and clear 0.50.
    /// ±22 % square wave: CV is exactly the amplitude ratio, so this is 0.44.
    private func wobbly(_ count: Int, ratio: Float = 0.44) -> [Float] {
        (0..<count).map { $0 % 2 == 0 ? 0.5 * (1 - ratio) : 0.5 * (1 + ratio) }
    }

    // MARK: - 1. The ride's two directions

    /// The two directions share a depth cap and differ in how they are *let go
    /// of*, which is where the asymmetry actually lives.
    ///
    /// The cut cap used to be the deeper of the two, on the reasoning that a
    /// cut is free — no headroom spent, no artefact, applied under a closed
    /// fader. All true, and all beside the point: a cut is released by walking
    /// the new track back *up*, so its depth is also how long that track spends
    /// under the level it was mastered at. 4 dB in both directions, and a cut
    /// let go of four times faster than a boost, is what keeps that climb
    /// inside the new song's first phrase instead of its first verse.
    @Test func theRideCapsBothDirectionsAndReleasesThemDifferently() {
        let c = TransitionPlanner.Config.standard
        #expect(c.rideMaxCutDB == 4)
        #expect(c.rideMaxDB == 4)
        let roomy = makeAnalysis(peakDBFS: -30)

        // Cut side: bounded by its own cap, never by the incoming peak.
        #expect(TransitionPlanner.rideDB(forTrimmedGapDB: -6, incoming: roomy,
                                         incomingTrimDB: 0, config: c) == -4)
        // Past it: still clipped at the cap.
        #expect(TransitionPlanner.rideDB(forTrimmedGapDB: -9, incoming: roomy,
                                         incomingTrimDB: 0, config: c) == -4)
        // A gap the cap does not reach is taken in full.
        #expect(TransitionPlanner.rideDB(forTrimmedGapDB: -2.5, incoming: roomy,
                                         incomingTrimDB: 0, config: c) == -2.5)
        // The boost side: same cap, peak-guarded on top.
        #expect(TransitionPlanner.rideDB(forTrimmedGapDB: 6, incoming: roomy,
                                         incomingTrimDB: 0, config: c) == 4)
        let hot = makeAnalysis(peakDBFS: -1)
        let boosted = TransitionPlanner.rideDB(forTrimmedGapDB: 6, incoming: hot,
                                               incomingTrimDB: 0, config: c)
        #expect(boosted < 4, "a hot master's headroom must still bite before the cap")
        #expect(boosted >= 0)

        // And the release, which is the half that is actually asymmetric: the
        // deepest cut is home in about three seconds, the deepest boost takes
        // the unhurried thirteen.
        #expect(TransitionAutomation.rideReleaseDuration(-c.rideMaxCutDB) < 3.5)
        #expect(TransitionAutomation.rideReleaseDuration(c.rideMaxDB) > 13)
    }

    /// `rideMaxDB` is the feature's off switch for *both* directions — a config
    /// that said "no ride" but still cut 6 dB would be a trap.
    @Test func zeroRideMaxTurnsBothDirectionsOff() {
        var off = TransitionPlanner.Config.standard
        off.rideMaxDB = 0
        let roomy = makeAnalysis(peakDBFS: -30)
        #expect(TransitionPlanner.rideDB(forTrimmedGapDB: -9, incoming: roomy,
                                         incomingTrimDB: 0, config: off) == 0)
        #expect(TransitionPlanner.rideDB(forTrimmedGapDB: 9, incoming: roomy,
                                         incomingTrimDB: 0, config: off) == 0)
        // …and so does turning compensation off, which is the user-facing one.
        var uncompensated = TransitionPlanner.Config.standard
        uncompensated.loudnessCompensation = false
        #expect(TransitionPlanner.rideDB(forTrimmedGapDB: -9, incoming: roomy,
                                         incomingTrimDB: 0, config: uncompensated) == 0)
    }

    /// The payoff, at the gate rather than at the knob: a 6 dB seam in the
    /// direction the ride can absorb is a compatible pair, where the raw gap
    /// alone would have been demoted. The ride does not have to close the gap
    /// *entirely* to do that — it has to leave a residual the gate can live
    /// with, and 4 dB of ride leaves 2, comfortably inside `neutral`. The
    /// remaining 2 dB is deliberately left on the table: the depth the ride
    /// does not take is depth the new track does not have to climb out of.
    @Test func aSixDBCutSeamIsNoLongerDemoted() {
        let quietTail = [Float](repeating: 0.5 * 0.501, count: 200)   // −6 dB
        let loudOpening = [Float](repeating: 0.5, count: 200)
        let outgoing = makeAnalysis(rmsEnvelope: quietTail, referenceLoudness: -14)
        let incoming = makeAnalysis(rmsEnvelope: loudOpening, referenceLoudness: -14)

        let now = TransitionPlanner.signals(outgoing: outgoing, incoming: incoming)
        #expect(abs(now.rideDB - -4) < 1e-6)
        #expect(abs(now.loudnessGapDB - 2) < 0.3)
        #expect(TransitionPlanner.tier(of: now) == .compatible)

        // Without the ride at all, the gate sees the whole 6 dB and demotes.
        var noRide = TransitionPlanner.Config.standard
        noRide.rideMaxDB = 0
        let before = TransitionPlanner.signals(outgoing: outgoing, incoming: incoming,
                                               config: noRide)
        #expect(before.rideDB == 0)
        #expect(before.loudnessGapDB > 5.5)
        #expect(TransitionPlanner.tier(of: before, config: noRide) != .compatible)
    }

    // MARK: - Bent-rate headroom pad

    /// The pad is sized from the track's own peak, so most of the library pays
    /// nothing: only a master hot enough that the time-pitch overshoot would
    /// push it past the ceiling comes down at all.
    @Test func onlyHotMastersPayTheBentRatePad() {
        let c = LoudnessCompensation.Config.standard
        // "LOVE.": +0.60 dBFS peak on a −4.06 dB trim. 0.60 − 4.06 + 5.5 =
        // +2.04 against a −1 ceiling, so it owes ~3 dB.
        let hot = LoudnessCompensation.timePitchPadDB(forPeakDBFS: 0.596, afterTrimDB: -4.06)
        #expect(abs(hot - -3.04) < 0.01, "\(hot)")
        // A quiet master with the same trim has headroom to spare and is left
        // completely alone — no pad, so no path changes for it at all.
        #expect(LoudnessCompensation.timePitchPadDB(
            forPeakDBFS: -12, afterTrimDB: -4.06) == 0)
        // Exactly at the ceiling: still nothing owed.
        #expect(LoudnessCompensation.timePitchPadDB(
            forPeakDBFS: -(c.timePitchOvershootDB + 1), afterTrimDB: 0) == 0)
        // It is only ever a cut, never a lift.
        for peak in stride(from: -30.0, through: 3.0, by: 1.0) {
            #expect(LoudnessCompensation.timePitchPadDB(
                forPeakDBFS: peak, afterTrimDB: -3) <= 0)
        }
        // Unknown peak → no pad. The opposite of the boost guard's
        // conservatism, and deliberately: see the doc comment.
        #expect(LoudnessCompensation.timePitchPadDB(forPeakDBFS: nil, afterTrimDB: -4) == 0)
        #expect(LoudnessCompensation.boostHeadroomDB(for: nil, afterTrimDB: -4) == 0)
    }

    /// The pad's lead-in is what makes it useful: the overshoot is full from
    /// the first fraction of a percent of bend, so the pad has to be all the
    /// way on before the rate moves at all.
    @Test func thePadIsFullyOnBeforeTheBendBegins() {
        let lead = TransitionAutomation.ratePadLeadSeconds(-3.04)
        #expect(abs(lead - 3.04 / 0.3) < 0.01, "\(lead)")
        // …at the ride's inaudible slope, not faster.
        #expect(3.04 / lead <= TransitionAutomation.ratePadGlideDBPerSecond + 1e-9)
        // No pad, no lead — a deck with headroom keeps the plain ramp window.
        #expect(TransitionAutomation.ratePadLeadSeconds(0) == 0)
    }

    // MARK: - 2. Neutral overlap cap

    @Test func theNeutralCapIsTenSecondsAndTheClashCapIsUnchanged() {
        let c = TransitionPlanner.Config.standard
        #expect(c.neutralOverlapCap == 10)
        #expect(c.clashOverlapCap == 2.5)
        #expect(c.neutralOverlapCap > c.clashOverlapCap)
    }

    /// A neutral pair whose audio supports a long blend now gets up to 10 s of
    /// it. The cap has to be what actually binds for this to mean anything, so
    /// the fixture is built with plenty of tail and intake capacity.
    @Test func aNeutralPairMayNowBlendForTenSeconds() {
        // Far enough apart in timbre to be neutral, not far enough to clash.
        let outgoing = makeAnalysis(referenceLoudness: -14)
        // An 8 s build into a steady body: intake capacity is the climb plus
        // `intakeBodySeconds`, so it clears 10 s and the tier cap is what
        // actually binds. (A flat opening caps the fade at 8 s on intake alone
        // and would hide the knob entirely.)
        let incoming = makeAnalysis(
            rmsEnvelope: (0..<200).map { min(0.5, 0.05 + Float($0) * 0.056) },
            referenceLoudness: -14)

        func overlap(cap: TimeInterval) -> TimeInterval? {
            var config = TransitionPlanner.Config.standard
            config.neutralOverlapCap = cap
            // Force the neutral tier and nothing worse: any timbre distance is
            // "not very alike", none of them is a clash.
            config.neutralTimbreDistance = -1
            config.clashTimbreDistance = 2
            config.clashLoudnessDB = 60
            guard case .crossfade(let d, _, _) = TransitionPlanner
                .plan(outgoing: outgoing, incoming: incoming, config: config).plan
            else { return nil }
            return d
        }
        guard let wide = overlap(cap: 10), let old = overlap(cap: 6) else {
            Issue.record("expected crossfades on both configs")
            return
        }
        #expect(old <= 6.0001)
        #expect(wide > old, "the raised cap must actually buy length")
        #expect(wide <= 10.0001)
    }

    // MARK: - 3. Section-aware steadiness

    /// A window that wobbles past the 0.40 bar but sits wholly inside one
    /// labelled section clears the looser 0.50 one — and the ledger says which
    /// bar it was judged against, so two seams with different numbers are
    /// tellable apart.
    @Test func aSingleSectionWindowGetsTheLooserSteadinessBar() throws {
        // One long chorus covering the whole overlap window at 150 s.
        let sections = [section(.intro, 0, 30), section(.verse, 30, 120),
                        section(.chorus, 120, 190), section(.outro, 190, 200)]
        let outgoing = makeAnalysis(rmsEnvelope: wobbly(200), sections: sections)
        let incoming = makeAnalysis(rmsEnvelope: wobbly(200), sections: sections)

        var trace: PlanTrace? = PlanTrace()
        let planned = TransitionPlanner.plan(outgoing: outgoing, incoming: incoming,
                                             trace: &trace)
        guard case .beatMatched(let plan) = planned.plan else {
            Issue.record("expected beatMatched")
            return
        }
        // 0.44 fails 0.40 and clears 0.50, so the upgrade only happens under
        // the section rule.
        #expect(plan.overlapBars > 4)
        let gate = try #require(
            trace?.gates.last { $0.id.hasSuffix(".stableOut") && $0.passed })
        #expect(gate.threshold == TransitionPlanner.Config.standard.sectionSteadyCV)
        #expect(gate.detail.contains("single-section window"))
        #expect(gate.detail.contains("0.50"))
    }

    /// The same audio with no sections is judged exactly as it was: the rule is
    /// unreachable without structure, which is most of the library.
    @Test func withoutSectionsTheOldBarApplies() throws {
        let outgoing = makeAnalysis(rmsEnvelope: wobbly(200))
        let incoming = makeAnalysis(rmsEnvelope: wobbly(200))
        var trace: PlanTrace? = PlanTrace()
        _ = TransitionPlanner.plan(outgoing: outgoing, incoming: incoming, trace: &trace)
        let gate = try #require(trace?.gates.last { $0.id.hasSuffix(".stableOut") })
        #expect(gate.threshold == TransitionPlanner.Config.standard.stableCV)
        #expect(!gate.detail.contains("single-section"))
        #expect(gate.detail.contains("0.40"))
    }

    /// A window that *straddles* a section boundary gets no relief — crossing
    /// an arrangement change is exactly what the CV was there to catch, and the
    /// structure evidence says this window does cross one.
    @Test func aWindowStraddlingABoundaryKeepsTheStrictBar() throws {
        // Boundaries chopped so that any 8- or 16-bar window at the tail
        // candidates crosses one.
        let chopped = stride(from: 0.0, to: 200.0, by: 6.0).map {
            section(.verse, $0, $0 + 6)
        }
        let outgoing = makeAnalysis(rmsEnvelope: wobbly(200), sections: chopped)
        let incoming = makeAnalysis(rmsEnvelope: wobbly(200), sections: chopped)
        var trace: PlanTrace? = PlanTrace()
        _ = TransitionPlanner.plan(outgoing: outgoing, incoming: incoming, trace: &trace)
        let gate = try #require(trace?.gates.last { $0.id.hasSuffix(".stableOut") })
        #expect(gate.threshold == TransitionPlanner.Config.standard.stableCV)
        #expect(!gate.detail.contains("single-section"))
    }

    /// The rule relaxes, it never vetoes: a genuinely lurching window inside
    /// one section is still refused.
    @Test func theSectionRuleStillRefusesALurchingWindow() {
        let sections = [section(.chorus, 0, 200)]
        // CV 0.8 — past even the looser bar.
        let outgoing = makeAnalysis(rmsEnvelope: wobbly(200, ratio: 0.8), sections: sections)
        let incoming = makeAnalysis(rmsEnvelope: wobbly(200, ratio: 0.8), sections: sections)
        guard case .beatMatched(let plan) = TransitionPlanner
            .plan(outgoing: outgoing, incoming: incoming).plan else {
            Issue.record("expected beatMatched")
            return
        }
        #expect(plan.overlapBars == 4, "no upgrade for a window that really does lurch")
    }

    /// Turning the knob down to `stableCV` reproduces the pre-rule planner
    /// field for field, sections or no sections.
    @Test func matchingTheKnobsDisablesTheSectionRule() {
        let sections = [section(.chorus, 0, 200)]
        let outgoing = makeAnalysis(rmsEnvelope: wobbly(200), sections: sections)
        let incoming = makeAnalysis(rmsEnvelope: wobbly(200), sections: sections)
        var off = TransitionPlanner.Config.standard
        off.sectionSteadyCV = off.stableCV
        guard case .beatMatched(let withRule) = TransitionPlanner
                .plan(outgoing: outgoing, incoming: incoming).plan,
              case .beatMatched(let without) = TransitionPlanner
                .plan(outgoing: outgoing, incoming: incoming, config: off).plan
        else {
            Issue.record("expected two beat-matched plans")
            return
        }
        #expect(withRule.overlapBars > without.overlapBars)
        #expect(without.overlapBars == 4)
    }

    // MARK: - 4. Ramped bend cap

    /// 6.5 % admits the corpus's near-miss (a 133.3 → 118.0 seam needing
    /// 6.48 %), and the gap window is unchanged around it.
    @Test func theBendCapAdmitsTheNearMiss() {
        let c = TransitionPlanner.Config.standard
        #expect(c.rampMaxRateDeviation == 0.065)
        #expect(c.rampMaxBPMDeltaRatio == 0.115)

        guard case .beatMatched(let plan) = TransitionPlanner
            .plan(outgoing: makeAnalysis(bpm: 133.3),
                  incoming: makeAnalysis(bpm: 118.0)).plan else {
            Issue.record("expected the near-miss seam to beat-match now")
            return
        }
        // The near-miss now lands on the *outgoing* deck: `rampBendShareOutgoing`
        // offers it 70 % of an 11.5 % gap, which is past the cap, so it is held
        // exactly at 6.5 % and the remainder spills to the incoming side. That
        // spill is what the extra half percent buys — at 6.0 % the outgoing
        // deck clamps sooner, leaves the incoming one over the line, and the
        // seam is refused (below).
        let outBend = abs(Double(plan.outgoingRate) - 1)
        let inBend = abs(Double(plan.incomingRate) - 1)
        #expect(abs(outBend - 0.065) < 1e-4,
                "the outgoing deck should sit exactly on the cap (\(outBend))")
        #expect(inBend > 0.05 && inBend < outBend,
                "and the spill should land under it on the exposed side (\(inBend))")

        // The same seam under the old cap is refused, so this is the knob.
        var old = TransitionPlanner.Config.standard
        old.rampMaxRateDeviation = 0.06
        if case .beatMatched = TransitionPlanner
            .plan(outgoing: makeAnalysis(bpm: 133.3),
                  incoming: makeAnalysis(bpm: 118.0), config: old).plan {
            Issue.record("the old cap must still refuse it")
        }
    }

    /// The gap window itself did not move: 10 % in, 12 % out, as before.
    @Test func theGapWindowIsUnchangedByTheBendCap() {
        if case .beatMatched = TransitionPlanner
            .plan(outgoing: makeAnalysis(bpm: 120), incoming: makeAnalysis(bpm: 132)).plan {
        } else {
            Issue.record("10 % apart must still beat-match")
        }
        if case .beatMatched = TransitionPlanner
            .plan(outgoing: makeAnalysis(bpm: 120), incoming: makeAnalysis(bpm: 134.4)).plan {
            Issue.record("12 % apart must still be refused")
        }
    }

    /// The two tempo caps are consistent by construction: nothing inside the
    /// gap window can fail the bend window. Checked by sweeping the window
    /// rather than asserted, because it is the kind of claim that quietly stops
    /// being true when someone moves one of the two numbers.
    @Test func insideTheGapWindowTheBendCapNeverBites() {
        let c = TransitionPlanner.Config.standard
        for step in 0...230 {
            let d = Double(step) / 2000.0        // 0 … 0.115
            guard d <= c.rampMaxBPMDeltaRatio else { continue }
            for folded in [100.0 * (1 - d), 100.0 * (1 + d)] {
                let target = (100.0 + folded) / 2
                let bend = max(abs(target / 100.0 - 1), abs(target / folded - 1))
                #expect(bend <= c.rampMaxRateDeviation + 1e-9,
                        "gap \(d) needs a \(bend) bend, past the cap")
            }
        }
    }
}
