import Testing
@testable import KumoneCore
import AVFoundation
import Foundation

// The tempo ramp (P4): the DJ gesture of *gliding* into and out of a matched
// tempo instead of stepping onto it, and the wider beat-match gate the glide
// pays for.
//
// Two halves, and they are deliberately independent. The planner half asks
// which seams the widened caps admit and pins that the whole thing is inert
// with `tempoRampEnabled` off. The curve half asks whether the glide is the
// shape it claims to be — the position↔time map is the load-bearing piece,
// because the seam's beat phase is only exact if the deck really does arrive at
// the out point having consumed exactly the source it was supposed to.

@Suite struct TempoRampTests {

    // MARK: - Fixtures

    private func makeAnalysis(bpm: Double, duration: TimeInterval = 200) -> TrackAnalysis {
        let barLength = 4 * 60 / bpm
        return TrackAnalysis(
            version: TrackAnalysis.currentVersion,
            bpm: bpm, bpmConfidence: 0.9,
            beats: stride(from: 0.4, to: duration, by: 60 / bpm).map { $0 },
            downbeats: stride(from: 0.4, to: duration, by: barLength).map { $0 },
            phraseBoundaries: [150, 90, 30],
            rmsEnvelope: [Float](repeating: 0.5, count: Int(duration)),
            outroFadeStart: nil, introEnd: 2, duration: duration,
            melProfile: [], keyPitchClass: nil, keyIsMinor: false, keyConfidence: 0,
            vocalActivity: [], referenceLoudness: nil, peakDBFS: -6)
    }

    private var rampOff: TransitionPlanner.Config {
        var config = TransitionPlanner.Config.standard
        config.tempoRampEnabled = false
        return config
    }

    private func plan(_ outBPM: Double, _ inBPM: Double,
                      config: TransitionPlanner.Config = .standard) -> TransitionPlan {
        TransitionPlanner.plan(outgoing: makeAnalysis(bpm: outBPM),
                               incoming: makeAnalysis(bpm: inBPM),
                               config: config).plan
    }

    // MARK: - The gate

    /// With the knob off the pre-ramp planner is back, whole: the old ±8 % /
    /// ±4 % caps, and a plan that carries no ramp at all — which is what every
    /// path downstream reads as "step onto the rate, as you always did".
    @Test func rampOffRestoresTheOldCapsAndCarriesNoRampFields() throws {
        // 8 % apart was the old ceiling and is still inside it.
        guard case .beatMatched(let stepped) = plan(120, 129, config: rampOff) else {
            Issue.record("expected beatMatched at 7.5 % apart")
            return
        }
        #expect(stepped.rampLeadSeconds == 0)
        #expect(stepped.rampReleaseSeconds == 0)
        #expect(!stepped.rampGlideBackFromSwap)
        #expect(abs(Double(stepped.outgoingRate) - 1) <= 0.04)
        // A stepped plan still meets exactly in the middle: 120 and 129 fold to
        // 124.5, which is the midpoint and *not* what a 70/30 share would give.
        #expect(abs(Double(stepped.outgoingRate) - 124.5 / 120.0) < 1e-6)
        #expect(abs(Double(stepped.incomingRate) - 124.5 / 129.0) < 1e-6)
        // And a pair the *ramped* caps would take is refused, so the widening
        // and the gesture really are one switch.
        if case .beatMatched = plan(120, 132, config: rampOff) {
            Issue.record("10 % apart must not beat-match with the ramp off")
        }
        // No ramp fields means no ramp anywhere downstream — neither the
        // outgoing deck's pre-seam glide nor the incoming deck's walk home.
        #expect(TransitionAutomation.tempoRamp(for: .beatMatched(stepped)) == nil)
        #expect(TransitionAutomation.incomingGlide(
            for: .beatMatched(stepped),
            geometry: TransitionAutomation.Geometry(plan: .beatMatched(stepped))) == nil)
    }

    /// The payoff: 10 % apart is beat-matchable with the glide, 12 % is not —
    /// the cap moved, it did not disappear.
    @Test func theWidenedCapsAdmitTenPercentAndRefuseTwelve() throws {
        guard case .beatMatched(let matched) = plan(120, 132) else {
            Issue.record("expected beatMatched at 10 % apart")
            return
        }
        // A 10 % gap is more than the outgoing deck's 70 % share can take at a
        // 6.5 % cap, so it sits *on* the cap and the rest spills to the
        // incoming deck: 127.8 BPM, +6.5 % / −3.2 %. Both are past the old
        // ±4 % step limit, which is what makes this a ramped-only pair.
        #expect(abs(Double(matched.outgoingRate) - 127.8 / 120.0) < 1e-4)
        #expect(abs(Double(matched.outgoingRate) - 1) > 0.04)
        #expect(abs(Double(matched.outgoingRate) - 1) <= 0.065 + 1e-6)
        // The exposed deck gets the smaller half, which is the point of the
        // asymmetric share.
        #expect(abs(Double(matched.incomingRate) - 1)
                < abs(Double(matched.outgoingRate) - 1))
        #expect(matched.rampGlideBackFromSwap)
        #expect(matched.rampLeadSeconds == TransitionPlanner.Config.standard.rampLeadSeconds)
        #expect(matched.rampReleaseSeconds
                == TransitionPlanner.Config.standard.rampReleaseSeconds)

        if case .beatMatched = plan(120, 134.4) {
            Issue.record("12 % apart must still fall back to a crossfade")
        }
    }

    /// The two gates say which regime judged them, because "why was this pair
    /// not beat-matched" is otherwise a question about an invisible field.
    @Test func theTraceNamesTheCapThatApplied() throws {
        var trace: PlanTrace? = PlanTrace()
        _ = TransitionPlanner.plan(outgoing: makeAnalysis(bpm: 120),
                                   incoming: makeAnalysis(bpm: 132),
                                   config: .standard, trace: &trace)
        let gate = try #require(trace?.gates.last { $0.id == "rateDeviation" })
        #expect(gate.threshold == TransitionPlanner.Config.standard.rampMaxRateDeviation)
        #expect(gate.detail.contains("ramped"))

        var stepped: PlanTrace? = PlanTrace()
        _ = TransitionPlanner.plan(outgoing: makeAnalysis(bpm: 120),
                                   incoming: makeAnalysis(bpm: 132),
                                   config: rampOff, trace: &stepped)
        let steppedGate = try #require(stepped?.gates.last { $0.id == "bpmDelta" })
        #expect(steppedGate.threshold == TransitionPlanner.Config.standard.maxBPMDeltaRatio)
        #expect(steppedGate.detail.contains("stepped"))
    }

    // MARK: - The curve

    /// The glide must be finished one segment handoff before the out point, or
    /// a pre-rendered segment's head — rendered at the constant bent rate —
    /// would be crossfaded against a deck still moving. Not a stylistic
    /// preference: it is what makes the identity crossfade an identity.
    @Test func theGlideFinishesBeforeTheSegmentHandoff() throws {
        guard case .beatMatched(let matched) = plan(120, 132) else {
            Issue.record("expected beatMatched")
            return
        }
        let ramp = try #require(TransitionAutomation.tempoRamp(for: .beatMatched(matched)))
        #expect(abs(ramp.end - (matched.outPoint - TransitionAutomation.segmentHandoff)) < 1e-9)
        #expect(ramp.end <= matched.outPoint - 0.5 + 1e-9)
        #expect(abs(ramp.leadSeconds - matched.rampLeadSeconds) < 1e-9)
        // Rate is unity at the start, the plan's bent rate at the end, and flat
        // outside — the deck is at the matched tempo for the whole handoff.
        #expect(abs(ramp.rate(at: ramp.start - 5) - 1) < 1e-6)
        #expect(abs(ramp.rate(at: ramp.start) - 1) < 1e-6)
        #expect(abs(ramp.rate(at: ramp.end) - matched.outgoingRate) < 1e-6)
        #expect(abs(ramp.rate(at: matched.outPoint) - matched.outgoingRate) < 1e-6)
        // Halfway across, halfway bent: the glide is linear in the rate.
        #expect(abs(ramp.rate(at: (ramp.start + ramp.end) / 2)
                    - (1 + matched.outgoingRate) / 2) < 1e-6)
    }

    /// The audibility bound the 12 s default was chosen against: at the widest
    /// bend the caps allow, the rate must move slower than ~0.5 % per second.
    @Test func theGlideStaysUnderTheAudibleSlope() {
        let config = TransitionPlanner.Config.standard
        let ramp = TransitionAutomation.TempoRamp(
            start: 0, end: config.rampLeadSeconds,
            target: Float(1 + config.rampMaxRateDeviation))
        // The lead is derived from this bound (0.065 / 0.005 = 13 s), so the
        // slack is only for `target` making the round trip through Float.
        #expect(ramp.slopePerSecond <= 0.005 + 1e-6)
        // The release is deliberately *not* held to that bound. Time spent off
        // unity is time spent in the phase vocoder, so the release optimises
        // for getting out fast; it only has to stay slow enough to be a settle
        // rather than a step, and short enough not to outstay the seam.
        #expect(config.rampReleaseSeconds <= 4)
        #expect(config.rampReleaseSeconds >= 1)
    }

    /// The load-bearing piece of the beat-phase argument: how long the deck
    /// takes, in wall time, to walk a stretch of its own song under the glide.
    /// The closed form is `lead · ln(target)/(target − 1)` over the ramp; check
    /// it against a plain Riemann sum of `ds / r(s)`, which is the definition.
    @Test func thePositionToTimeMapIsClosedFormAndMatchesIntegration() {
        for target in [Float(0.94), 0.97, 1.0001, 1.03, 1.06] {
            let ramp = TransitionAutomation.TempoRamp(start: 30, end: 42, target: target)
            for (a, b) in [(30.0, 42.0), (25.0, 45.0), (34.0, 38.0), (42.0, 50.0),
                           (20.0, 29.0)] {
                let closed = ramp.wallSeconds(from: a, to: b)
                // Numeric ∫ ds/r(s), midpoint rule at 1 ms of source.
                let steps = Int((b - a) / 0.001)
                var numeric = 0.0
                for i in 0..<steps {
                    let s = a + (Double(i) + 0.5) * 0.001
                    numeric += 0.001 / Double(ramp.rate(at: s))
                }
                #expect(abs(closed - numeric) < 1e-6,
                        "target \(target) over [\(a), \(b)]: \(closed) vs \(numeric)")
            }
            // Degenerate ranges are zero, not NaN.
            #expect(ramp.wallSeconds(from: 40, to: 40) == 0)
            #expect(ramp.wallSeconds(from: 40, to: 30) == 0)
        }
    }

    /// Slowing the deck down makes the pre-roll take *longer* in the room than
    /// it does in the song, and speeding it up shortens it. Stated as a test
    /// because it is the one thing the offline renderer has to get right for
    /// its pre-roll to land on the out point.
    @Test func theGlideStretchesWallTimeInTheDirectionOfTheBend() {
        let slower = TransitionAutomation.TempoRamp(start: 0, end: 12, target: 0.94)
        #expect(slower.wallSeconds(from: 0, to: 12) > 12)
        let faster = TransitionAutomation.TempoRamp(start: 0, end: 12, target: 1.06)
        #expect(faster.wallSeconds(from: 0, to: 12) < 12)
        // A ramp that bends nowhere is the identity map.
        let flat = TransitionAutomation.TempoRamp(start: 0, end: 12, target: 1)
        #expect(abs(flat.wallSeconds(from: 0, to: 12) - 12) < 1e-9)
    }

    // MARK: - The automation

    /// A ramped plan runs the overlap flat: the deck arrived already bent, so
    /// the in-overlap ease is not just redundant, it would be a beat-phase
    /// error at the exact moment the two grids are supposed to lock.
    @Test func theOverlapIsFlatUnderARampAndEasedWithoutOne() throws {
        guard case .beatMatched(let ramped) = plan(120, 132),
              case .beatMatched(let stepped) = plan(120, 129, config: rampOff)
        else {
            Issue.record("expected two beat-matched plans")
            return
        }
        let atSeam = TransitionAutomation.frame(
            plan: .beatMatched(ramped), style: .plain, elapsed: 0)
        #expect(atSeam.outgoing.rate == ramped.outgoingRate)

        // Without a ramp, the legacy ease is untouched: unity at the seam,
        // fully bent a second later.
        let steppedSeam = TransitionAutomation.frame(
            plan: .beatMatched(stepped), style: .plain, elapsed: 0)
        #expect(steppedSeam.outgoing.rate == 1)
        let steppedLater = TransitionAutomation.frame(
            plan: .beatMatched(stepped), style: .plain, elapsed: 1.5)
        #expect(steppedLater.outgoing.rate == stepped.outgoingRate)
    }

    /// A plan with the post-swap glide has **nothing left to release**: the
    /// deck walked home inside the overlap, so the settling phase is a no-op
    /// and `transition complete` finds it already at unity. That is the fix
    /// working, not a missing step.
    ///
    /// A plan without the glide keeps the old back half — the plan's own
    /// `rampReleaseSeconds`, or the legacy 1.5 s with the ramp off entirely.
    @Test func theRateReleaseFollowsThePlan() throws {
        guard case .beatMatched(let ramped) = plan(120, 132),
              case .beatMatched(let stepped) = plan(120, 129, config: rampOff)
        else {
            Issue.record("expected two beat-matched plans")
            return
        }
        #expect(TransitionAutomation.rateReleaseDuration(.beatMatched(ramped)) == 0)
        let atComplete = TransitionAutomation.settleFrame(
            plan: .beatMatched(ramped), restoringRate: true, echoTailRinging: false,
            elapsed: 0)
        #expect(abs(atComplete.incomingRate - 1) < 1e-6)
        #expect(atComplete.rateRestoreDone)

        // The same plan with the glide switched off is the old gesture, whole.
        var held = ramped
        held.rampGlideBackFromSwap = false
        #expect(TransitionAutomation.rateReleaseDuration(.beatMatched(held))
                == held.rampReleaseSeconds)
        let half = TransitionAutomation.settleFrame(
            plan: .beatMatched(held), restoringRate: true, echoTailRinging: false,
            elapsed: held.rampReleaseSeconds / 2)
        #expect(abs(half.incomingRate - (held.incomingRate + 1) / 2) < 1e-5)
        #expect(!half.rateRestoreDone)
        let end = TransitionAutomation.settleFrame(
            plan: .beatMatched(held), restoringRate: true, echoTailRinging: false,
            elapsed: held.rampReleaseSeconds)
        #expect(end.incomingRate == 1)
        #expect(end.rateRestoreDone)

        // And a plan made with the ramp off still finishes at 1.5 s, to the
        // sample.
        #expect(TransitionAutomation.rateReleaseDuration(.beatMatched(stepped))
                == TransitionAutomation.rateRestoreDuration)
        let legacy = TransitionAutomation.settleFrame(
            plan: .beatMatched(stepped), restoringRate: true, echoTailRinging: false,
            elapsed: TransitionAutomation.rateRestoreDuration)
        #expect(legacy.incomingRate == 1)
    }

    // MARK: - Offline parity

    /// The audition console's renders are the A/B evidence for this gesture, so
    /// the offline path has to walk the same curve the deck does. The cheap
    /// observable: the render's pre-roll is the outgoing song's own
    /// `preRoll` seconds, so under a glide it occupies *more* rendered seconds
    /// than that — by exactly the closed-form map.
    @Test func theOfflineRenderWalksTheSameGlide() throws {
        let outgoing = TempoRampAudio.outgoing
        let incoming = TempoRampAudio.incoming

        // A slowed-down outgoing deck (target < 1), so the stretch is a
        // lengthening and cannot be confused with a rounding error.
        let matched = BeatMatchedPlan(
            outPoint: 12, inPoint: 0, overlapBars: 4,
            outgoingRate: 0.95, incomingRate: 1.05,
            bassSwapOffset: 1, overlapDuration: 2,
            rampLeadSeconds: 6, rampReleaseSeconds: 3)
        var options = OfflineTransitionRenderer.Options()
        options.preRoll = 8
        options.postRoll = 1
        let mix = try OfflineTransitionRenderer.renderMix(
            .plain(.beatMatched(matched)),
            outgoing: outgoing, incoming: incoming, options: options)

        let ramp = try #require(
            TransitionAutomation.tempoRamp(for: .beatMatched(matched)))
        // The pre-roll covers the whole glide, stretching back past its start
        // (here the requested 8 s already reaches further than the 6 s lead).
        let outStart = try #require(mix.outgoing.first?.source)
        #expect(outStart <= ramp.start,
                "the render must open before the glide does (\(outStart) vs \(ramp.start))")
        let expected = ramp.wallSeconds(from: outStart, to: matched.outPoint)
        #expect(abs(mix.overlapStart - expected) < 0.02,
                "pre-roll rendered \(mix.overlapStart) s, closed form \(expected) s")
        // Slowed down, so it really is longer than the source span it covers.
        #expect(mix.overlapStart > matched.outPoint - outStart)
        // And the deck lands *on* the out point, which is the whole point: the
        // incoming downbeat has to meet the outgoing one.
        #expect(abs(OfflineTransitionRenderer.Mix.source(of: mix.outgoing,
                                                        at: mix.overlapStart)
                    - matched.outPoint) < 0.02)

        // A pre-roll shorter than the glide is stretched to hold it: a render
        // that opened halfway up the ramp would sound like a bent deck, which
        // is precisely the thing under test.
        options.preRoll = 2
        let stretched = try OfflineTransitionRenderer.renderMix(
            .plain(.beatMatched(matched)),
            outgoing: outgoing, incoming: incoming, options: options)
        #expect(abs((stretched.outgoing.first?.source ?? -1) - (ramp.start - 1)) < 0.01)
        #expect(abs(stretched.overlapStart
                    - ramp.wallSeconds(from: ramp.start - 1, to: matched.outPoint)) < 0.02)
    }

    /// …and with the ramp off, the pre-roll is the flat block it always was.
    @Test func theOfflineRenderIsUnchangedWithoutARamp() throws {
        let outgoing = TempoRampAudio.outgoing
        let incoming = TempoRampAudio.incoming
        let stepped = BeatMatchedPlan(
            outPoint: 12, inPoint: 0, overlapBars: 4,
            outgoingRate: 0.95, incomingRate: 1.05,
            bassSwapOffset: 1, overlapDuration: 2)
        var options = OfflineTransitionRenderer.Options()
        options.preRoll = 8
        options.postRoll = 1
        let mix = try OfflineTransitionRenderer.renderMix(
            .plain(.beatMatched(stepped)),
            outgoing: outgoing, incoming: incoming, options: options)
        #expect(abs(mix.overlapStart - 8) < 0.01)
        #expect(abs((mix.outgoing.first?.source ?? -1) - 4) < 0.01)
    }

    // MARK: - The asymmetric bend split

    /// The gap is split 70/30 onto the deck that can hide the artifact, and
    /// the arithmetic is exact rather than approximately right.
    @Test func theBendSplitFavoursTheOutgoingDeck() throws {
        // 120 → 124: a 4 BPM gap, well inside the cap, so the share applies in
        // full. 120 + 0.7 × 4 = 122.8.
        guard case .beatMatched(let shared) = plan(120, 124) else {
            Issue.record("expected beatMatched")
            return
        }
        #expect(abs(Double(shared.outgoingRate) - 122.8 / 120) < 1e-6)
        #expect(abs(Double(shared.incomingRate) - 122.8 / 124) < 1e-6)
        // The share is of the *gap*, so the outgoing deck carries 70 % of the
        // BPM move; expressed as rate deviations the two are 2.33 % and 0.97 %.
        #expect(abs(abs(Double(shared.outgoingRate) - 1) - 0.7 * 4 / 120) < 1e-6)

        // Moving the knob moves the split, and 0.5 is the old midpoint exactly.
        var even = TransitionPlanner.Config.standard
        even.rampBendShareOutgoing = 0.5
        guard case .beatMatched(let middle) = plan(120, 124, config: even) else {
            Issue.record("expected beatMatched at an even split")
            return
        }
        #expect(abs(Double(middle.outgoingRate) - 122.0 / 120) < 1e-6)
        #expect(abs(Double(middle.incomingRate) - 122.0 / 124) < 1e-6)
        // Bit-identical to the pre-share planner: the even case is still
        // written as the midpoint, not as `o + 0.5·(f − o)`.
        #expect(middle.outgoingRate == Float(((120.0 + 124.0) / 2) / 120))
    }

    /// Past the cap the 70 % side clamps and the remainder spills to the other
    /// deck, so the effective split degrades toward 50/50 rather than the plan
    /// being refused.
    @Test func theBendSplitClampsAtTheCapAndSpillsTheRemainder() throws {
        let cap = TransitionPlanner.Config.standard.rampMaxRateDeviation
        // 120 → 132 is a 10 % gap; 70 % of it would bend the outgoing deck
        // 7 %, past the 6.5 % cap.
        guard case .beatMatched(let clamped) = plan(120, 132) else {
            Issue.record("expected beatMatched")
            return
        }
        let out = abs(Double(clamped.outgoingRate) - 1)
        let incoming = abs(Double(clamped.incomingRate) - 1)
        #expect(abs(out - cap) < 1e-5, "the outgoing deck sits on the cap (\(out))")
        #expect(incoming < cap, "and the spill lands under it (\(incoming))")
        // Degraded toward even, but still not even: the exposed deck keeps the
        // smaller share of a gap this wide.
        #expect(incoming < out)
        #expect(incoming > 0.3 * out, "the spill really is a spill, not a rounding error")

        // A gap small enough for the full share does *not* clamp, so the clamp
        // is a ceiling rather than a rule.
        guard case .beatMatched(let unclamped) = plan(120, 124) else {
            Issue.record("expected beatMatched")
            return
        }
        #expect(abs(Double(unclamped.outgoingRate) - 1) < cap - 0.01)
    }

    // MARK: - The incoming deck's post-swap glide

    /// The curve itself: held at the bent rate to the swap, monotone to unity
    /// by the end of the overlap, and C¹ at both joins (a smoothstep has zero
    /// slope at its ends, so the rate curve has no corner anywhere).
    @Test func theIncomingDeckGlidesHomeFromTheSwap() throws {
        let matched = BeatMatchedPlan(
            outPoint: 100, inPoint: 0, overlapBars: 8,
            outgoingRate: 1.045, incomingRate: 0.965,
            bassSwapOffset: 8, overlapDuration: 16,
            rampLeadSeconds: 13, rampReleaseSeconds: 3,
            rampGlideBackFromSwap: true)
        let plan = TransitionPlan.beatMatched(matched)
        let geometry = TransitionAutomation.Geometry(plan: plan)
        let glide = try #require(TransitionAutomation.incomingGlide(for: plan,
                                                                   geometry: geometry))
        #expect(glide.start == geometry.swapOffset)
        #expect(abs(glide.end - geometry.overlapDuration) < 1e-9,
                "with room to spare the glide lands exactly on the overlap's end")

        func rate(_ t: TimeInterval) -> Float {
            TransitionAutomation.frame(plan: plan, style: .plain,
                                       elapsed: t, geometry: geometry).incoming.rate
        }
        // Flat at the bend before the swap…
        #expect(rate(0) == matched.incomingRate)
        #expect(rate(geometry.swapOffset - 0.5) == matched.incomingRate)
        #expect(rate(geometry.swapOffset) == matched.incomingRate)
        // …home by the end…
        #expect(abs(rate(geometry.overlapDuration) - 1) < 1e-6)
        // …and monotone all the way, sampled at the engine's own 50 Hz.
        var previous = rate(0)
        var maxSlope: Float = 0
        for tick in 1...Int(geometry.overlapDuration * 50) {
            let t = Double(tick) / 50
            let now = rate(t)
            #expect(now >= previous - 1e-7, "the glide must not wander (\(t): \(now))")
            maxSlope = max(maxSlope, abs(now - previous) * 50)
            previous = now
        }
        #expect(abs(previous - 1) < 1e-6)

        // C¹ at the swap: a smoothstep's slope is zero where it starts, so the
        // join with the flat stretch before it has no corner. Measured as "the
        // first tick after the swap moves far less than the steepest tick".
        let atSwap = geometry.swapOffset
        let firstStep = abs(rate(atSwap + 0.02) - rate(atSwap)) * 50
        #expect(firstStep < maxSlope * 0.05,
                "the glide must leave the plateau flat (\(firstStep) vs \(maxSlope))")
        // …and the same at the far end, where it joins unity.
        let lastStep = abs(rate(geometry.overlapDuration)
                           - rate(geometry.overlapDuration - 0.02)) * 50
        #expect(lastStep < maxSlope * 0.05)

        // With the glide off, the whole overlap is the flat bend it always was
        // — byte-identical, not merely close.
        var held = matched
        held.rampGlideBackFromSwap = false
        let heldPlan = TransitionPlan.beatMatched(held)
        let heldGeometry = TransitionAutomation.Geometry(plan: heldPlan)
        for tick in 0...Int(heldGeometry.overlapDuration * 50) {
            let f = TransitionAutomation.frame(plan: heldPlan, style: .plain,
                                               elapsed: Double(tick) / 50,
                                               geometry: heldGeometry)
            #expect(f.incoming.rate == held.incomingRate)
        }
    }

    /// A degenerate geometry — a swap so late that the post-swap stretch is
    /// shorter than the plan's own release — does not get a step. The glide is
    /// floored at `rampReleaseSeconds` and its tail spills into the settling
    /// phase, which picks up the *same curve* rather than restarting it.
    @Test func aShortPostSwapStretchSpillsIntoTheSettlingPhase() throws {
        let matched = BeatMatchedPlan(
            outPoint: 100, inPoint: 0, overlapBars: 1,
            outgoingRate: 1.03, incomingRate: 0.97,
            bassSwapOffset: 1.8, overlapDuration: 2,
            rampLeadSeconds: 13, rampReleaseSeconds: 3,
            rampGlideBackFromSwap: true)
        let plan = TransitionPlan.beatMatched(matched)
        let geometry = TransitionAutomation.Geometry(plan: plan)
        let glide = try #require(TransitionAutomation.incomingGlide(for: plan,
                                                                   geometry: geometry))
        #expect(glide.glideSeconds == matched.rampReleaseSeconds)
        let spill = TransitionAutomation.rateReleaseDuration(plan, geometry: geometry)
        #expect(abs(spill - (glide.end - geometry.overlapDuration)) < 1e-9)
        #expect(spill > 0)

        // Continuous across `transition complete`: the last frame of the
        // overlap and the first frame of the settle are the same rate.
        let lastOverlap = TransitionAutomation.frame(
            plan: plan, style: .plain, elapsed: geometry.overlapDuration,
            geometry: geometry).incoming.rate
        let firstSettle = TransitionAutomation.settleFrame(
            plan: plan, restoringRate: true, echoTailRinging: false,
            elapsed: 0, geometry: geometry).incomingRate
        #expect(abs(lastOverlap - firstSettle) < 1e-6)
        #expect(lastOverlap != 1, "the glide really has not finished yet")

        let done = TransitionAutomation.settleFrame(
            plan: plan, restoringRate: true, echoTailRinging: false,
            elapsed: spill, geometry: geometry)
        #expect(abs(done.incomingRate - 1) < 1e-6)
        #expect(done.rateRestoreDone)
    }

    /// The glide's integral is the map from overlap time onto the incoming
    /// song's own clock, and everything that places an instant on that clock —
    /// the stem layer above all — reads it. Checked against direct numerical
    /// integration of the rate curve, and inverted back again.
    @Test func theGlideIntegralMatchesNumericalIntegration() throws {
        let glide = TransitionAutomation.IncomingGlide(bent: 0.9607, start: 6, end: 20)
        // Trapezoid over a fine grid; the closed form is a quartic, so this is
        // an independent computation rather than the same one twice.
        func integrate(to t: TimeInterval) -> Double {
            let steps = 200_000
            let h = t / Double(steps)
            var total = 0.0
            for i in 0..<steps {
                let a = Double(glide.rate(at: Double(i) * h))
                let b = Double(glide.rate(at: Double(i + 1) * h))
                total += (a + b) / 2 * h
            }
            return total
        }
        for t in [3.0, 6.0, 13.0, 20.0, 25.0] {
            #expect(abs(glide.sourceAdvance(to: t) - integrate(to: t)) < 1e-4,
                    "integral mismatch at \(t)")
        }
        // Before the glide it is just the bent rate, after it the flat run-out.
        #expect(abs(glide.sourceAdvance(to: 6) - 6 * Double(glide.bent)) < 1e-12)
        #expect(abs(glide.sourceAdvance(to: 25)
                    - (glide.sourceAdvance(to: 20) + 5)) < 1e-9)

        // And the inverse round-trips.
        for t in [1.0, 7.5, 12.0, 19.0, 22.0] {
            let back = glide.overlapElapsed(atSource: glide.sourceAdvance(to: t), within: 30)
            #expect(abs(back - t) < 1e-6, "inverse mismatch at \(t) (\(back))")
        }

        // The size of the correction is the thing that made this necessary: a
        // constant-rate map is wrong by half the bend times the glide's length.
        let naive = 20 * 0.9607
        let actual = glide.sourceAdvance(to: 20)
        #expect(abs((actual - naive) - 0.5 * (1 - 0.9607) * 14) < 0.01)
        #expect(actual - naive > 0.15, "…which is well past a stem layer's budget")
    }

    /// Live and offline agree on the new curve: the renderer walks the incoming
    /// deck through the glide, so where it ends up in its own song is the
    /// glide's integral and not `overlap × incomingRate`.
    @Test func theOfflineRenderWalksTheIncomingGlide() throws {
        let matched = BeatMatchedPlan(
            outPoint: 12, inPoint: 0, overlapBars: 4,
            outgoingRate: 1.03, incomingRate: 0.94,
            bassSwapOffset: 4, overlapDuration: 8,
            rampLeadSeconds: 6, rampReleaseSeconds: 3,
            rampGlideBackFromSwap: true)
        let plan = TransitionPlan.beatMatched(matched)
        let geometry = TransitionAutomation.Geometry(plan: plan)
        let glide = try #require(TransitionAutomation.incomingGlide(for: plan,
                                                                   geometry: geometry))
        var options = OfflineTransitionRenderer.Options()
        options.preRoll = 8
        options.postRoll = 1
        let mix = try OfflineTransitionRenderer.renderMix(
            .plain(plan), outgoing: TempoRampAudio.outgoing,
            incoming: TempoRampAudio.incoming, options: options)

        // Where the incoming deck is in its own song at the end of the overlap.
        let atEnd = OfflineTransitionRenderer.Mix.source(
            of: mix.incoming, at: mix.overlapStart + geometry.overlapDuration)
        #expect(abs(atEnd - (matched.inPoint + glide.sourceAdvance(to: geometry.overlapDuration)))
                < 0.05,
                "the render must consume the glide's integral (\(atEnd))")
        // …and that is measurably *not* the constant-rate answer.
        let naive = matched.inPoint + geometry.overlapDuration * Double(matched.incomingRate)
        #expect(abs(atEnd - naive) > 0.05)
    }
}

/// Test tones, shared across the offline cases.
///
/// Reached through `static let`, not through a call: the suite's tests run in
/// parallel, and two of them racing on "does this file exist yet" was a real
/// flake (one opened the half-written file). Lazy statics are initialized
/// exactly once, whoever asks first.
private enum TempoRampAudio {
    static let outgoing: URL = try! sine(hz: 440, seconds: 30, name: "ramp-out")
    static let incoming: URL = try! sine(hz: 660, seconds: 30, name: "ramp-in")

    static let dir: URL = {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("TempoRamp-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func sine(hz: Double, seconds: Double, name: String) throws -> URL {
        let url = dir.appendingPathComponent("\(name).caf")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let sampleRate = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk: AVAudioFrameCount = 4096
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)!
        var frame = 0
        let total = Int(seconds * sampleRate)
        while frame < total {
            let n = min(Int(chunk), total - frame)
            for channel in 0..<2 {
                let data = buffer.floatChannelData![channel]
                for i in 0..<n {
                    data[i] = 0.25 * sinf(2 * .pi * Float(hz)
                                          * Float(frame + i) / Float(sampleRate))
                }
            }
            buffer.frameLength = AVAudioFrameCount(n)
            try file.write(from: buffer)
            frame += n
        }
        return url
    }
}
