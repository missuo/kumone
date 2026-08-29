import Testing
@testable import KumoneCore
import Foundation

@Suite struct TransitionPlannerTests {

    // MARK: - Fixtures

    /// Shared default timbre fingerprint, so fixtures compare as identical
    /// unless a test overrides one side. Shaped like what the analyzer now
    /// produces: a zero-sum, unit-norm 40-band spectral shape (here a plain
    /// bass-to-treble tilt).
    private static let defaultProfile: [Float] = unit((0..<40).map { Float($0) })

    /// A second shape, orthogonal to `defaultProfile`: a symmetric "smile"
    /// (mids scooped) with the tilt component projected out.
    private static let contrastProfile: [Float] = {
        let smile = (0..<40).map { b -> Float in
            let x = (Float(b) - 19.5) / 19.5
            return x * x
        }
        let base = defaultProfile
        let dot = zip(smile, base).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        return unit(zip(smile, base).map { $0 - dot * $1 })
    }()

    /// Zero-sum, unit-norm version of `v` — the invariants of a real profile.
    private static func unit(_ v: [Float]) -> [Float] {
        let mean = v.reduce(0, +) / Float(v.count)
        let centered = v.map { $0 - mean }
        let norm = centered.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        return centered.map { $0 / norm }
    }

    /// A profile sitting exactly `distance` (cosine distance) away from
    /// `defaultProfile`, by rotating it towards `contrastProfile`.
    private static func profile(distance: Float) -> [Float] {
        let cosine = 1 - distance
        let sine = (1 - cosine * cosine).squareRoot()
        return zip(defaultProfile, contrastProfile).map { cosine * $0 + sine * $1 }
    }

    private func makeAnalysis(
        bpm: Double = 120,
        confidence: Double = 0.9,
        duration: TimeInterval = 200,
        downbeats: [TimeInterval]? = nil,
        phraseBoundaries: [TimeInterval] = [150, 90, 30],
        rmsEnvelope: [Float]? = nil,
        outroFadeStart: TimeInterval? = nil,
        introEnd: TimeInterval = 2,
        melProfile: [Float]? = nil,
        keyPitchClass: Int? = nil,
        keyIsMinor: Bool = false,
        keyConfidence: Double = 0,
        vocalActivity: [Float] = [],
        referenceLoudness: Double? = nil,
        peakDBFS: Double? = -6
    ) -> TrackAnalysis {
        let barLength = 4 * 60 / bpm
        let db = downbeats ?? stride(from: 0.4, to: duration, by: barLength).map { $0 }
        let beats = stride(from: 0.4, to: duration, by: 60 / bpm).map { $0 }
        return TrackAnalysis(
            version: TrackAnalysis.currentVersion,
            bpm: bpm,
            bpmConfidence: confidence,
            beats: beats,
            downbeats: db,
            phraseBoundaries: phraseBoundaries,
            rmsEnvelope: rmsEnvelope ?? [Float](repeating: 0.5, count: Int(duration)),
            outroFadeStart: outroFadeStart,
            introEnd: introEnd,
            duration: duration,
            melProfile: melProfile ?? Self.defaultProfile,
            keyPitchClass: keyPitchClass, keyIsMinor: keyIsMinor,
            keyConfidence: keyConfidence,
            vocalActivity: vocalActivity,
            referenceLoudness: referenceLoudness,
            peakDBFS: peakDBFS)
    }

    /// Mechanics-only view of the planner result; style assertions use
    /// `TransitionPlanner.plan` directly.
    private func planOnly(
        outgoing: TrackAnalysis?, incoming: TrackAnalysis?
    ) -> TransitionPlan {
        TransitionPlanner.plan(outgoing: outgoing, incoming: incoming).plan
    }

    /// Choppy envelope: high coefficient of variation, never "steady".
    private func choppyEnvelope(duration: Int) -> [Float] {
        (0..<duration).map { $0 % 2 == 0 ? 0.1 : 0.9 }
    }

    // MARK: - Rule 1: beat-matched

    @Test func beatMatchedCloseBPMSteadyEnergyUses8Bars() throws {
        let outgoing = makeAnalysis(bpm: 120)
        let incoming = makeAnalysis(bpm: 124, introEnd: 2)
        guard case .beatMatched(let plan) = planOnly(
            outgoing: outgoing, incoming: incoming) else {
            Issue.record("expected beatMatched")
            return
        }
        // The outgoing deck absorbs 70 % of the 4 BPM gap (rampBendShareOutgoing),
        // so the two meet at 120 + 0.7 × 4 = 122.8 rather than at the midpoint.
        #expect(abs(Double(plan.outgoingRate) - 122.8 / 120.0) < 1e-4)
        #expect(abs(Double(plan.incomingRate) - 122.8 / 124.0) < 1e-4)
        // …and the exposed deck's bend really is the smaller of the two.
        #expect(abs(Double(plan.incomingRate) - 1) < abs(Double(plan.outgoingRate) - 1))
        #expect(abs(Double(plan.outgoingRate) - 1) <= 0.04)
        #expect(abs(Double(plan.incomingRate) - 1) <= 0.04)
        // Steady envelopes on both sides → 8 bars.
        #expect(plan.overlapBars == 8)
        // Best-scored phrase boundary that fits the overlap.
        #expect(plan.outPoint == 150)
        // First downbeat at/after introEnd.
        let expectedInPoint = try #require(
            incoming.downbeats.first { $0 >= incoming.introEnd - 0.05 })
        #expect(abs(plan.inPoint - expectedInPoint) < 1e-9)
        #expect(abs(plan.overlapDuration - 8 * 4 * 60 / 122.8) < 1e-9)
        #expect(abs(plan.bassSwapOffset - plan.overlapDuration / 2) < 1e-9)
    }

    @Test func beatMatchedUnstableEnergyUses4Bars() {
        let outgoing = makeAnalysis(bpm: 120)
        let incoming = makeAnalysis(
            bpm: 120, rmsEnvelope: choppyEnvelope(duration: 200))
        guard case .beatMatched(let plan) = planOnly(
            outgoing: outgoing, incoming: incoming) else {
            Issue.record("expected beatMatched")
            return
        }
        #expect(plan.overlapBars == 4)
        #expect(abs(plan.overlapDuration - 4 * 4 * 60 / 120) < 1e-9)
    }

    @Test func beatMatchedDoubleTimeFolding() {
        // 240 folds to 120: exact match, both rates 1.0.
        let outgoing = makeAnalysis(bpm: 120)
        let incoming = makeAnalysis(bpm: 240)
        guard case .beatMatched(let plan) = planOnly(
            outgoing: outgoing, incoming: incoming) else {
            Issue.record("expected beatMatched")
            return
        }
        #expect(abs(Double(plan.outgoingRate) - 1) < 1e-6)
        #expect(abs(Double(plan.incomingRate) - 1) < 1e-6)
    }

    @Test func beatMatchedHalfTimeFolding() {
        let outgoing = makeAnalysis(bpm: 124)
        let incoming = makeAnalysis(bpm: 62)
        guard case .beatMatched = planOnly(
            outgoing: outgoing, incoming: incoming) else {
            Issue.record("expected beatMatched after half-time folding")
            return
        }
    }

    @Test func beatMatchedSkipsPhraseBoundaryAfterOutroFade() {
        // Boundary 150 sits inside the outro fade; 120 is the best remaining
        // candidate inside the tail window [max(100, 80), 140].
        let outgoing = makeAnalysis(bpm: 120, phraseBoundaries: [150, 120, 30],
                                    outroFadeStart: 140)
        let incoming = makeAnalysis(bpm: 120)
        guard case .beatMatched(let plan) = planOnly(
            outgoing: outgoing, incoming: incoming) else {
            Issue.record("expected beatMatched")
            return
        }
        #expect(plan.outPoint == 120)
    }

    @Test func beatMatchedIgnoresMidSongPhraseBoundary() {
        // The only boundaries sit mid-song (before 50% of the duration);
        // cutting there would skip half the track, so the plan degrades.
        let outgoing = makeAnalysis(bpm: 120, phraseBoundaries: [90, 30])
        let incoming = makeAnalysis(bpm: 120)
        guard case .crossfade = planOnly(
            outgoing: outgoing, incoming: incoming) else {
            Issue.record("expected crossfade when no tail-window boundary exists")
            return
        }
    }

    @Test func beatMatchedWithoutPhraseBoundariesFallsBackToCrossfade() {
        let outgoing = makeAnalysis(bpm: 120, phraseBoundaries: [])
        let incoming = makeAnalysis(bpm: 120)
        guard case .crossfade = planOnly(
            outgoing: outgoing, incoming: incoming) else {
            Issue.record("expected crossfade fallback without phrase boundaries")
            return
        }
    }

    // MARK: - Rule 2: crossfade

    @Test func farBPMFallsBackToCrossfade() {
        let outgoing = makeAnalysis(bpm: 120)
        let incoming = makeAnalysis(bpm: 100, introEnd: 3)
        guard case .crossfade(let duration, let outPoint, let inPoint) =
            planOnly(outgoing: outgoing, incoming: incoming) else {
            Issue.record("expected crossfade")
            return
        }
        // Flat 0.5 envelope: tail carries plenty, but the incoming opening is
        // already at full energy → intake caps the fade at 8 s.
        #expect(duration == 8)
        #expect(outPoint == 150)  // best phrase boundary in the tail window
        #expect(inPoint == 3)
    }

    @Test func lowConfidenceFallsBackToCrossfade() {
        let outgoing = makeAnalysis(bpm: 120, confidence: 0.5)
        let incoming = makeAnalysis(bpm: 120)
        guard case .crossfade = planOnly(
            outgoing: outgoing, incoming: incoming) else {
            Issue.record("expected crossfade with low confidence")
            return
        }
    }

    @Test func outroFadeUsesShortTailCrossfade() {
        let outgoing = makeAnalysis(bpm: 120, duration: 200, outroFadeStart: 180)
        let incoming = makeAnalysis(bpm: 100, introEnd: 1.5)
        guard case .crossfade(let duration, let outPoint, let inPoint) =
            planOnly(outgoing: outgoing, incoming: incoming) else {
            Issue.record("expected crossfade")
            return
        }
        // The limp outro is trimmed: the hand-over starts where the fade
        // begins, not two seconds before silence. Length still bounded by
        // the hot-opening incoming side (8 s).
        #expect(duration == 8)
        #expect(outPoint == 180)
        #expect(inPoint == 1.5)
    }

    @Test func crossfadeWithoutPhraseBoundariesUsesTail() {
        let outgoing = makeAnalysis(bpm: 120, confidence: 0.2, phraseBoundaries: [])
        let incoming = makeAnalysis(bpm: 120)
        guard case .crossfade(let duration, let outPoint, _) =
            planOnly(outgoing: outgoing, incoming: incoming) else {
            Issue.record("expected crossfade")
            return
        }
        #expect(duration == 8)
        #expect(outPoint == 192)
    }

    @Test func quietOpeningEarnsLongCrossfade() {
        // Incoming spends its first 12 s well below peak: the climb hides
        // under the outgoing tail, so the fade stretches (climb ≈ 10 + 8).
        var env = [Float](repeating: 0.1, count: 12)
        env += [Float](repeating: 0.9, count: 188)
        let outgoing = makeAnalysis(bpm: 120)
        let incoming = makeAnalysis(bpm: 100, rmsEnvelope: env, introEnd: 2)
        guard case .crossfade(let duration, _, _) = planOnly(
            outgoing: outgoing, incoming: incoming) else {
            Issue.record("expected crossfade")
            return
        }
        #expect(duration == 18)
    }

    @Test func hotJaggedTailKeepsCrossfadeShort() {
        // Outgoing ends loud and choppy (no steady tail window): fade
        // collapses to the 4 s floor of tailCapacity.
        let outgoing = makeAnalysis(bpm: 120, rmsEnvelope: choppyEnvelope(duration: 200))
        let incoming = makeAnalysis(bpm: 100)
        guard case .crossfade(let duration, _, _) = planOnly(
            outgoing: outgoing, incoming: incoming) else {
            Issue.record("expected crossfade")
            return
        }
        #expect(duration == 4)
    }

    @Test func fastTempoSteadyEnergyUses16Bars() {
        // At ~198 BPM sixteen bars fit inside the 20 s ceiling; flat
        // envelopes on both sides let the upgrade through.
        let outgoing = makeAnalysis(bpm: 200)
        let incoming = makeAnalysis(bpm: 196, introEnd: 2)
        guard case .beatMatched(let plan) = planOnly(
            outgoing: outgoing, incoming: incoming) else {
            Issue.record("expected beatMatched")
            return
        }
        #expect(plan.overlapBars == 16)
    }

    // MARK: - Compatibility gate

    @Test func loudnessClashForcesShortFade() {
        // Same BPM would normally beat-match, but a ~24 dB loudness gap
        // (banger → whisper-quiet track) gates the pair down to a
        // boundary-respecting short fade.
        let outgoing = makeAnalysis(bpm: 120,
                                    rmsEnvelope: [Float](repeating: 0.8, count: 200))
        let incoming = makeAnalysis(bpm: 120,
                                    rmsEnvelope: [Float](repeating: 0.05, count: 200))
        guard case .crossfade(let duration, _, _) = planOnly(
            outgoing: outgoing, incoming: incoming) else {
            Issue.record("expected short crossfade, not beatMatched")
            return
        }
        #expect(duration <= TransitionPlanner.clashOverlapCap)
    }

    @Test func outroFadeIsNotALoudnessClash() {
        // The outgoing track fades itself out over its last 20 s. Its level
        // *before* the fade matches the incoming opening — the fade is not a
        // mismatch, so the pair must not be gated down to the clash tier.
        var env = [Float](repeating: 0.5, count: 180)
        env += (0..<20).map { 0.5 * Float(20 - $0) / 20 }
        let outgoing = makeAnalysis(bpm: 120, rmsEnvelope: env, outroFadeStart: 180)
        let incoming = makeAnalysis(bpm: 100)
        guard case .crossfade(let duration, _, _) = planOnly(
            outgoing: outgoing, incoming: incoming) else {
            Issue.record("expected crossfade")
            return
        }
        #expect(duration > TransitionPlanner.clashOverlapCap)
    }

    // MARK: - Loudness compensation and the tier gate

    /// The gate must judge what will be *played*, not what is on disk. Two
    /// masters 8 dB apart are a clash on the raw numbers; once each deck runs
    /// at its own trim the gap is gone, so the pair must not be punished.
    @Test func compensationRemovesAMasteringLoudnessClash() {
        // −6 LUFS vs −14 LUFS, and the RMS windows carry the same 8 dB gap.
        let loudEnv = [Float](repeating: 0.5, count: 200)
        let quietEnv = [Float](repeating: 0.5 * 0.398, count: 200)  // −8 dB
        let outgoing = makeAnalysis(bpm: 120, rmsEnvelope: loudEnv, referenceLoudness: -6)
        let incoming = makeAnalysis(bpm: 120, rmsEnvelope: quietEnv, referenceLoudness: -14)

        var off = TransitionPlanner.Config.standard
        off.loudnessCompensation = false
        let raw = TransitionPlanner.signals(outgoing: outgoing, incoming: incoming, config: off)
        #expect(abs(raw.loudnessGapDB - 8) < 0.2)
        #expect(raw.loudnessGapDB > TransitionPlanner.clashLoudnessDB)
        #expect(TransitionPlanner.tier(of: raw, config: off) == .clash)

        let compensated = TransitionPlanner.signals(outgoing: outgoing, incoming: incoming)
        // −6 LUFS gets −8 dB, −14 LUFS gets 0: exactly the 8 dB gap.
        #expect(abs(compensated.outgoingTrimDB - -8) < 1e-6)
        #expect(abs(compensated.incomingTrimDB) < 1e-6)
        #expect(abs(compensated.rawLoudnessGapDB - 8) < 0.2)
        #expect(compensated.loudnessGapDB < 0.2)
        #expect(TransitionPlanner.tier(of: compensated) == .compatible)
    }

    /// What the trim cannot reach, the gate still sees. A master so quiet that
    /// the +3 dB boost ceiling bites leaves a residual, and that residual —
    /// not the full raw gap — is what the thresholds are measured against.
    @Test func theGateStillSeesWhatTheTrimCannotAbsorb() {
        let loudEnv = [Float](repeating: 0.5, count: 200)
        let quietEnv = [Float](repeating: 0.5 * 0.0794, count: 200)  // −22 dB
        let outgoing = makeAnalysis(bpm: 120, rmsEnvelope: loudEnv, referenceLoudness: -8)
        // −33 LUFS wants +19 dB and may have +3 (the peak leaves room).
        let incoming = makeAnalysis(bpm: 120, rmsEnvelope: quietEnv,
                                    referenceLoudness: -33, peakDBFS: -30)

        let s = TransitionPlanner.signals(outgoing: outgoing, incoming: incoming)
        #expect(abs(s.outgoingTrimDB - -6) < 1e-6)
        #expect(abs(s.incomingTrimDB - 3) < 1e-6)
        #expect(abs(s.rawLoudnessGapDB - 22) < 0.3)
        // 22 raw − 6 (cut) − 3 (boost) = 13 dB the trims could not close…
        #expect(abs(s.trimmedLoudnessGapDB - 13) < 0.3)
        // …of which the ride takes its own 4 dB cap's worth (the incoming
        // track is the quiet side, and its −30 dBFS peak leaves ample room for
        // a lift), leaving 9 dB for the gate — still a clash.
        #expect(abs(s.rideDB - 4) < 1e-6)
        #expect(abs(s.loudnessGapDB - 9) < 0.3)
        #expect(TransitionPlanner.tier(of: s) == .clash)
    }

    /// The three stages are exactly that: each one is measured after the one
    /// before it, and the tier gate reads only the last.
    @Test func theGateReadsWhatBothGainStagesLeftBehind() {
        // A 6 dB local gap with matched masters: the trims have nothing to do,
        // so the ride is the only thing that closes it — and being a *cut*, it
        // can close the whole 6 dB rather than clipping at the boost cap.
        let quietTail = [Float](repeating: 0.5 * 0.501, count: 200)  // −6 dB
        let loudOpening = [Float](repeating: 0.5, count: 200)
        let outgoing = makeAnalysis(bpm: 120, rmsEnvelope: quietTail, referenceLoudness: -14)
        let incoming = makeAnalysis(bpm: 120, rmsEnvelope: loudOpening, referenceLoudness: -14)

        let s = TransitionPlanner.signals(outgoing: outgoing, incoming: incoming)
        #expect(abs(s.outgoingTrimDB) < 1e-6)
        #expect(abs(s.incomingTrimDB) < 1e-6)
        // Stage 1 and 2 agree: nothing for the whole-track trims to absorb.
        #expect(abs(s.rawLoudnessGapDB - 6) < 0.2)
        #expect(abs(s.trimmedLoudnessGapDB - 6) < 0.2)
        // Stage 3: a quiet outro meeting a hot opening — the incoming deck is
        // held *down*, so the ride is negative, and it takes as much of the gap
        // as `rideMaxCutDB` allows. That cap is 4 dB, not the gap's 6: a deeper
        // cut buys a smaller residual but costs the new track a longer climb
        // out of it, and the climb is what a listener hears as "muffled, then
        // it got better".
        #expect(s.rideDB < 0)
        #expect(abs(s.rideDB - -TransitionPlanner.Config.standard.rideMaxCutDB) < 1e-6)
        // 2 dB is left for the gate to judge — and 2 dB is not a clash, which
        // is the point of judging the residual rather than the raw gap.
        #expect(abs(s.loudnessGapDB - 2) < 0.3)
        #expect(TransitionPlanner.tier(of: s) == .compatible)
    }

    /// The cap is a cap in both directions, and a boost is additionally held
    /// to the incoming track's own peak headroom — the same clip guard the
    /// load-time trim runs.
    @Test func theRideIsCappedAndPeakGuarded() {
        let c = TransitionPlanner.Config.standard
        let roomy = makeAnalysis(peakDBFS: -30)
        // Cut side: unbounded by peaks, bounded by its own — deeper — cap.
        #expect(TransitionPlanner.rideDB(forTrimmedGapDB: -20, incoming: roomy,
                                         incomingTrimDB: 0, config: c) == -c.rideMaxCutDB)
        // The two caps match: a cut costs no headroom, but it costs *time* —
        // the release has to walk back up — and that is what bounds it.
        #expect(c.rideMaxCutDB == c.rideMaxDB)
        // Boost side: the cap bites first when there is plenty of headroom.
        #expect(TransitionPlanner.rideDB(forTrimmedGapDB: 20, incoming: roomy,
                                         incomingTrimDB: 0, config: c) == c.rideMaxDB)
        // A hot master leaves 2 dB (−6 peak + 3 downmix allowance vs a −1
        // ceiling), and that, not the cap, is the limit.
        let hot = makeAnalysis(peakDBFS: -6)
        #expect(abs(TransitionPlanner.rideDB(forTrimmedGapDB: 20, incoming: hot,
                                             incomingTrimDB: 0, config: c) - 2) < 1e-9)
        // A track whose peak is unknown never gets a boost at all.
        #expect(TransitionPlanner.rideDB(forTrimmedGapDB: 20, incoming: makeAnalysis(peakDBFS: nil),
                                         incomingTrimDB: 0, config: c) == 0)
        // A gap smaller than the cap is closed exactly, not over-ridden.
        #expect(abs(TransitionPlanner.rideDB(forTrimmedGapDB: -1.5, incoming: roomy,
                                             incomingTrimDB: 0, config: c) - -1.5) < 1e-9)
    }

    /// `rideMaxDB = 0` is the off switch: the gate goes back to reading the
    /// trim-only residual, exactly as it did before the ride existed.
    @Test func aZeroCapTurnsTheRideOff() {
        let quietTail = [Float](repeating: 0.5 * 0.501, count: 200)
        let loudOpening = [Float](repeating: 0.5, count: 200)
        let outgoing = makeAnalysis(bpm: 120, rmsEnvelope: quietTail, referenceLoudness: -14)
        let incoming = makeAnalysis(bpm: 120, rmsEnvelope: loudOpening, referenceLoudness: -14)

        var off = TransitionPlanner.Config.standard
        off.rideMaxDB = 0
        let s = TransitionPlanner.signals(outgoing: outgoing, incoming: incoming, config: off)
        #expect(s.rideDB == 0)
        #expect(abs(s.loudnessGapDB - s.trimmedLoudnessGapDB) < 1e-9)
        #expect(TransitionPlanner.plan(outgoing: outgoing, incoming: incoming,
                                       config: off).rideDB == 0)
    }

    /// Both gain stages are the same feature and the same user switch: with
    /// compensation off, neither the trim nor the ride is applied.
    @Test func compensationOffAlsoTurnsTheRideOff() {
        let quietTail = [Float](repeating: 0.5 * 0.501, count: 200)
        let loudOpening = [Float](repeating: 0.5, count: 200)
        var off = TransitionPlanner.Config.standard
        off.loudnessCompensation = false
        let s = TransitionPlanner.signals(
            outgoing: makeAnalysis(bpm: 120, rmsEnvelope: quietTail, referenceLoudness: -14),
            incoming: makeAnalysis(bpm: 120, rmsEnvelope: loudOpening, referenceLoudness: -14),
            config: off)
        #expect(s.outgoingTrimDB == 0)
        #expect(s.incomingTrimDB == 0)
        #expect(s.rideDB == 0)
        #expect(abs(s.loudnessGapDB - s.rawLoudnessGapDB) < 1e-9)
    }

    /// The plan carries the ride to the engine — but only when there is an
    /// overlap to ride over. `.gapless` (short tracks, no analysis, AutoMix
    /// off) stays at ride 0, which is what keeps the whole gain path
    /// bit-identical on those paths.
    @Test func thePlanCarriesTheRideOnlyWhenThereIsAnOverlap() {
        let quietTail = [Float](repeating: 0.5 * 0.501, count: 200)
        let loudOpening = [Float](repeating: 0.5, count: 200)
        let outgoing = makeAnalysis(bpm: 120, rmsEnvelope: quietTail, referenceLoudness: -14)
        let incoming = makeAnalysis(bpm: 120, rmsEnvelope: loudOpening, referenceLoudness: -14)
        let planned = TransitionPlanner.plan(outgoing: outgoing, incoming: incoming)
        #expect(planned.rideDB
                == -TransitionPlanner.Config.standard.rideMaxCutDB)

        // No analysis at all → gapless → no ride.
        #expect(TransitionPlanner.plan(outgoing: nil, incoming: incoming).rideDB == 0)
        // Too short to transition → gapless → no ride.
        let tiny = makeAnalysis(duration: 20, rmsEnvelope: loudOpening)
        #expect(TransitionPlanner.plan(outgoing: tiny, incoming: incoming).rideDB == 0)
        #expect(PlannedTransition.plain(.gapless).rideDB == 0)
    }

    /// Tracks with no loudness reading (never analyzed at v6) behave exactly
    /// as they did before compensation existed.
    @Test func withoutAMeasurementTheGateIsUnchanged() {
        let loudEnv = [Float](repeating: 0.5, count: 200)
        let quietEnv = [Float](repeating: 0.5 * 0.398, count: 200)
        let s = TransitionPlanner.signals(
            outgoing: makeAnalysis(bpm: 120, rmsEnvelope: loudEnv),
            incoming: makeAnalysis(bpm: 120, rmsEnvelope: quietEnv))
        #expect(s.outgoingTrimDB == 0)
        #expect(s.incomingTrimDB == 0)
        // Nothing to trim against, so stages 1 and 2 are the same number.
        #expect(abs(s.trimmedLoudnessGapDB - s.rawLoudnessGapDB) < 1e-9)
        #expect(abs(s.trimmedLoudnessGapDB - 8) < 0.2)
        // The ride, though, is derived from the *RMS envelopes* and needs no
        // loudness reading at all — an unmeasured pair still gets its seam
        // levelled, up to whatever the incoming track's peak allows (a −6 dBFS
        // peak leaves 2 dB, which is what bites here rather than the 4 dB cap).
        #expect(abs(s.rideDB - 2) < 1e-9)
        #expect(abs(s.loudnessGapDB - 6) < 0.2)
    }

    @Test func timbreClashForcesShortFade() {
        // Spectral shapes 0.6 apart — past the 0.45 clash line, and well past
        // anything a single track reaches against its own other half (≤ 0.09
        // across the audition corpus).
        let outgoing = makeAnalysis(bpm: 120, melProfile: Self.defaultProfile)
        let incoming = makeAnalysis(bpm: 120, melProfile: Self.profile(distance: 0.6))
        guard case .crossfade(let duration, _, _) = planOnly(
            outgoing: outgoing, incoming: incoming) else {
            Issue.record("expected short crossfade, not beatMatched")
            return
        }
        #expect(duration <= TransitionPlanner.clashOverlapCap)
    }

    @Test func mildTimbreDifferenceCapsAtNeutral() {
        // Cosine distance 0.35 — between the neutral (0.25) and clash (0.45)
        // thresholds. A slow-building incoming would otherwise earn an 18 s
        // fade; the neutral tier caps it at 6 s.
        var env = [Float](repeating: 0.1, count: 12)
        env += [Float](repeating: 0.9, count: 188)
        let outgoing = makeAnalysis(bpm: 120, melProfile: Self.defaultProfile)
        let incoming = makeAnalysis(bpm: 100, rmsEnvelope: env, introEnd: 2,
                                    melProfile: Self.profile(distance: 0.35))
        guard case .crossfade(let duration, _, _) = planOnly(
            outgoing: outgoing, incoming: incoming) else {
            Issue.record("expected crossfade")
            return
        }
        #expect(duration == TransitionPlanner.neutralOverlapCap)
    }

    @Test func withinStyleTimbreDifferenceStaysCompatible() {
        // 0.10 apart: the scale a single track reaches between its own two
        // halves on the audition corpus (median 0.03, worst 0.09). Two
        // arrangements of one style must keep the full AutoMix treatment.
        let planned = TransitionPlanner.plan(
            outgoing: makeAnalysis(bpm: 120, melProfile: Self.defaultProfile),
            incoming: makeAnalysis(bpm: 124, introEnd: 2,
                                   melProfile: Self.profile(distance: 0.10)))
        guard case .beatMatched = planned.plan else {
            Issue.record("expected beatMatched for a within-style timbre gap")
            return
        }
    }

    @Test func confidentTempoClashForcesShortFade() {
        // 120 vs 88 BPM: folded distance 26.7% — two confident but
        // incompatible grooves must not blend for long.
        let outgoing = makeAnalysis(bpm: 120)
        let incoming = makeAnalysis(bpm: 88)
        guard case .crossfade(let duration, _, _) = planOnly(
            outgoing: outgoing, incoming: incoming) else {
            Issue.record("expected crossfade")
            return
        }
        #expect(duration <= TransitionPlanner.clashOverlapCap)
    }

    // MARK: - Style strategy

    @Test func beatMatchedGetsStagedEQ() {
        let planned = TransitionPlanner.plan(
            outgoing: makeAnalysis(bpm: 120),
            incoming: makeAnalysis(bpm: 124, introEnd: 2))
        guard case .beatMatched = planned.plan else {
            Issue.record("expected beatMatched")
            return
        }
        #expect(planned.style.stagedEQ)
        #expect(planned.style.outroEffect == .fade)
    }

    @Test func clashTierExitsOnBeatSyncedEcho() throws {
        // Far-apart timbres → clash tier; a confident outgoing tempo turns
        // the short fade into an echo-out with a dotted-eighth delay.
        let planned = TransitionPlanner.plan(
            outgoing: makeAnalysis(bpm: 120, melProfile: Self.defaultProfile),
            incoming: makeAnalysis(bpm: 120, melProfile: Self.profile(distance: 0.6)))
        #expect(planned.style.outroEffect == .echoOut)
        #expect(!planned.style.stagedEQ)
        let delay = try #require(planned.style.echoDelayTime)
        #expect(abs(delay - 0.75 * 60 / 120) < 1e-9)
    }

    @Test func neutralTierHotTailGetsFilterSweep() {
        // Mild timbre difference → neutral tier; no natural outro means the
        // outgoing track leaves via the high-pass sweep.
        let planned = TransitionPlanner.plan(
            outgoing: makeAnalysis(bpm: 120, melProfile: Self.defaultProfile),
            incoming: makeAnalysis(bpm: 100, melProfile: Self.profile(distance: 0.35)))
        #expect(planned.style.outroEffect == .filterSweep)
    }

    @Test func compatibleLongCrossfadeGetsStagedEQ() {
        // Quiet-opening incoming earns a 15 s fade (see
        // quietOpeningEarnsLongCrossfade); long compatible fades upgrade to
        // the staged EQ hand-over.
        var env = [Float](repeating: 0.1, count: 12)
        env += [Float](repeating: 0.9, count: 188)
        let planned = TransitionPlanner.plan(
            outgoing: makeAnalysis(bpm: 120),
            incoming: makeAnalysis(bpm: 100, rmsEnvelope: env, introEnd: 2))
        guard case .crossfade(let duration, _, _) = planned.plan else {
            Issue.record("expected crossfade")
            return
        }
        #expect(duration == 18)
        #expect(planned.style.stagedEQ)
        #expect(planned.style.outroEffect == .fade)
    }

    // MARK: - Key gate

    @Test func distantKeysDemoteCompatibleToNeutral() {
        // Identical timbre/loudness, but C major against A major — three
        // fifths apart: the long blend is denied (neutral cap), though not
        // forced down to the clash tier.
        var env = [Float](repeating: 0.1, count: 12)
        env += [Float](repeating: 0.9, count: 188)
        let planned = TransitionPlanner.plan(
            outgoing: makeAnalysis(bpm: 120, keyPitchClass: 0, keyConfidence: 0.8),
            incoming: makeAnalysis(bpm: 100, rmsEnvelope: env, introEnd: 2,
                                   keyPitchClass: 9, keyConfidence: 0.8))
        guard case .crossfade(let duration, _, _) = planned.plan else {
            Issue.record("expected crossfade")
            return
        }
        #expect(duration == TransitionPlanner.neutralOverlapCap)
    }

    @Test func relativeMinorKeysStayCompatible() {
        // A minor folds to C major: distance 0, no demotion — the pair still
        // beat-matches.
        let planned = TransitionPlanner.plan(
            outgoing: makeAnalysis(bpm: 120, keyPitchClass: 0, keyConfidence: 0.8),
            incoming: makeAnalysis(bpm: 124, introEnd: 2,
                                   keyPitchClass: 9, keyIsMinor: true, keyConfidence: 0.8))
        guard case .beatMatched = planned.plan else {
            Issue.record("expected beatMatched")
            return
        }
    }

    @Test func lowConfidenceKeysNeverDemote() {
        let planned = TransitionPlanner.plan(
            outgoing: makeAnalysis(bpm: 120, keyPitchClass: 0, keyConfidence: 0.3),
            incoming: makeAnalysis(bpm: 124, introEnd: 2,
                                   keyPitchClass: 6, keyConfidence: 0.3))
        guard case .beatMatched = planned.plan else {
            Issue.record("expected beatMatched")
            return
        }
    }

    // MARK: - Vocal gate

    /// Vocal contour with a modest baseline and a hot region.
    private func vocalEnvelope(
        duration: Int, hot: Range<Int>
    ) -> [Float] {
        (0..<duration).map { hot.contains($0) ? 0.9 : 0.2 }
    }

    @Test func vocalsOnBothSidesCapTheFade() {
        // Both overlap windows are vocal-heavy relative to their tracks:
        // the fade collapses to the vocal-clash cap instead of the 18 s the
        // energy shapes would earn. (Confidence below the BPM threshold so
        // the pair crossfades rather than beat-matching.)
        var env = [Float](repeating: 0.1, count: 12)
        env += [Float](repeating: 0.9, count: 188)
        let planned = TransitionPlanner.plan(
            outgoing: makeAnalysis(bpm: 120, confidence: 0.3,
                                   vocalActivity: vocalEnvelope(duration: 200, hot: 130..<200)),
            incoming: makeAnalysis(bpm: 120, confidence: 0.3, rmsEnvelope: env, introEnd: 2,
                                   vocalActivity: vocalEnvelope(duration: 200, hot: 0..<40)))
        guard case .crossfade(let duration, _, _) = planned.plan else {
            Issue.record("expected crossfade")
            return
        }
        #expect(duration <= TransitionPlanner.vocalClashFadeCap)
    }

    @Test func vocalClashBlocksLongBeatMatchedOverlap() {
        // Beat-matchable pair, but vocals ride both overlap windows: the
        // 8-bar upgrade is denied and the plan falls to the 4-bar floor.
        let planned = TransitionPlanner.plan(
            outgoing: makeAnalysis(bpm: 120,
                                   vocalActivity: vocalEnvelope(duration: 200, hot: 140..<200)),
            incoming: makeAnalysis(bpm: 124, introEnd: 2,
                                   vocalActivity: vocalEnvelope(duration: 200, hot: 0..<40)))
        guard case .beatMatched(let plan) = planned.plan else {
            Issue.record("expected beatMatched")
            return
        }
        #expect(plan.overlapBars == 4)
    }

    // MARK: - Stem layer

    /// Slow-building incoming: earns the 18 s fade the stem tests reason about.
    private func slowBuildEnvelope() -> [Float] {
        [Float](repeating: 0.1, count: 12) + [Float](repeating: 0.9, count: 188)
    }

    /// Outgoing whose last third is sung, incoming whose opening is sung —
    /// the two-lead-vocals case. Without stems this is punished; with them it
    /// is ducked.
    private func clashingVocalPair(
        confidence: Double = 0.3, incomingBPM: Double = 120,
        outgoingOutroFadeStart: TimeInterval? = nil
    ) -> (TrackAnalysis, TrackAnalysis) {
        (makeAnalysis(bpm: 120, confidence: confidence,
                      outroFadeStart: outgoingOutroFadeStart,
                      vocalActivity: vocalEnvelope(duration: 200, hot: 130..<200)),
         makeAnalysis(bpm: incomingBPM, confidence: confidence,
                      rmsEnvelope: slowBuildEnvelope(), introEnd: 2,
                      vocalActivity: vocalEnvelope(duration: 200, hot: 0..<40)))
    }

    /// The hard contract: at `.none` the planner is the pre-stem planner,
    /// field for field, across every shape the rules can reach.
    @Test func stemsNoneIsIndistinguishableFromTheOldPlanner() {
        var cases: [(TrackAnalysis, TrackAnalysis)] = [
            (makeAnalysis(bpm: 120), makeAnalysis(bpm: 124, introEnd: 2)),
            (makeAnalysis(bpm: 120), makeAnalysis(bpm: 100, introEnd: 3)),
            (makeAnalysis(bpm: 120, melProfile: Self.defaultProfile),
             makeAnalysis(bpm: 120, melProfile: Self.profile(distance: 0.6))),
            (makeAnalysis(bpm: 120, duration: 200, outroFadeStart: 180),
             makeAnalysis(bpm: 100, introEnd: 1.5)),
            (makeAnalysis(bpm: 120, rmsEnvelope: choppyEnvelope(duration: 200)),
             makeAnalysis(bpm: 100)),
        ]
        cases.append(clashingVocalPair())
        cases.append(clashingVocalPair(confidence: 0.9, incomingBPM: 124))

        for (outgoing, incoming) in cases {
            let implicit = TransitionPlanner.plan(outgoing: outgoing, incoming: incoming)
            let explicit = TransitionPlanner.plan(outgoing: outgoing, incoming: incoming,
                                                  stems: .none)
            #expect(implicit.style == explicit.style)
            #expect(implicit.style.stemTechnique == nil)
            switch (implicit.plan, explicit.plan) {
            case (.crossfade(let d1, let o1, let i1), .crossfade(let d2, let o2, let i2)):
                #expect(d1 == d2 && o1 == o2 && i1 == i2)
            case (.beatMatched(let a), .beatMatched(let b)):
                #expect(a.outPoint == b.outPoint && a.inPoint == b.inPoint)
                #expect(a.overlapBars == b.overlapBars)
                #expect(a.overlapDuration == b.overlapDuration)
                #expect(a.outgoingRate == b.outgoingRate && a.incomingRate == b.incomingRate)
                #expect(a.bassSwapOffset == b.bassSwapOffset)
            case (.gapless, .gapless):
                break
            default:
                Issue.record("plan kind changed between omitted and explicit .none")
            }
        }
    }

    /// The headline rule: the vocal clash that used to cut a crossfade to
    /// `vocalClashFadeCap` becomes a technique instead, and the overlap the
    /// energy shapes earned is kept.
    @Test func vocalClashUpgradesToAnExchangeAndKeepsTheLongOverlap() {
        let (outgoing, incoming) = clashingVocalPair()
        guard case .crossfade(let capped, _, _) = TransitionPlanner
                .plan(outgoing: outgoing, incoming: incoming).plan else {
            Issue.record("expected a crossfade")
            return
        }
        #expect(capped <= TransitionPlanner.vocalClashFadeCap)

        let ducked = TransitionPlanner.plan(outgoing: outgoing, incoming: incoming,
                                            stems: .ready)
        guard case .crossfade(let full, let outPoint, _) = ducked.plan else {
            Issue.record("expected a crossfade")
            return
        }
        #expect(full == 18)                       // the uncapped, energy-derived length
        #expect(outPoint == 150)                  // a phrase boundary that is being sung
        #expect(ducked.style.stemTechnique == .vocalExchange)
        // Composition: the technique layers under the style, it does not replace it.
        #expect(ducked.style.outroEffect == .fade)
        #expect(ducked.style.stagedEQ)
    }

    /// Same rule on the beat-matched path: the 8-bar upgrade the vocal gate
    /// refused is granted, because the clash is now handled rather than avoided.
    /// The planner names the *template*; compiling it into curves is
    /// `Audition.decide`'s job, and needs lyrics the planner cannot see.
    @Test func exchangeRestoresTheLongBeatMatchedOverlap() {
        let outgoing = makeAnalysis(
            bpm: 120, vocalActivity: vocalEnvelope(duration: 200, hot: 140..<200))
        let incoming = makeAnalysis(
            bpm: 124, introEnd: 2, vocalActivity: vocalEnvelope(duration: 200, hot: 0..<40))
        guard case .beatMatched(let short) = TransitionPlanner
                .plan(outgoing: outgoing, incoming: incoming).plan else {
            Issue.record("expected beatMatched")
            return
        }
        #expect(short.overlapBars == 4)

        let ducked = TransitionPlanner.plan(outgoing: outgoing, incoming: incoming,
                                            stems: .ready)
        guard case .beatMatched(let long) = ducked.plan else {
            Issue.record("expected beatMatched")
            return
        }
        #expect(long.overlapBars == 8)
        #expect(long.outPoint == 150)
        #expect(ducked.style.stemTechnique == .vocalExchange)
        #expect(ducked.style.stagedEQ)            // still the staged hand-over underneath
    }

    /// A sung outgoing tail over an instrumental-leaning opening, at the one
    /// tier that licenses a full blend, is what `acapellaOver` is for.
    @Test func vocalTailOverAnInstrumentalOpeningEarnsAcapella() {
        let outgoing = makeAnalysis(
            bpm: 120, confidence: 0.3,
            vocalActivity: vocalEnvelope(duration: 200, hot: 130..<200))
        // Incoming sings from 40 s on, so its opening reads well below its own
        // mean — 0.26 against the 0.90 ceiling.
        let incoming = makeAnalysis(
            bpm: 120, confidence: 0.3, rmsEnvelope: slowBuildEnvelope(), introEnd: 2,
            vocalActivity: vocalEnvelope(duration: 200, hot: 40..<200))
        let planned = TransitionPlanner.plan(outgoing: outgoing, incoming: incoming,
                                             stems: .ready)
        guard case .crossfade(let fade, let outPoint, _) = planned.plan else {
            Issue.record("expected a crossfade")
            return
        }
        #expect(planned.style.stemTechnique == .acapellaOver)
        #expect(outPoint == 150)
        #expect(fade == 18)
    }

    /// The corpus's real problem: the plain out-point search pins the hand-over
    /// to the outro fade, where there is no vocal left to work on. The stem
    /// search must land before it.
    @Test func stemSearchLandsBeforeTheOutroFadePin() {
        let outgoing = makeAnalysis(
            bpm: 120, confidence: 0.3, outroFadeStart: 160,
            vocalActivity: vocalEnvelope(duration: 200, hot: 130..<200))
        let incoming = makeAnalysis(
            bpm: 120, confidence: 0.3, rmsEnvelope: slowBuildEnvelope(), introEnd: 2,
            vocalActivity: vocalEnvelope(duration: 200, hot: 40..<200))
        guard case .crossfade(_, let pinned, _) = TransitionPlanner
                .plan(outgoing: outgoing, incoming: incoming).plan,
              case .crossfade(_, let reaimed, _) = TransitionPlanner
                .plan(outgoing: outgoing, incoming: incoming, stems: .ready).plan
        else {
            Issue.record("expected crossfades")
            return
        }
        #expect(pinned == 160)                    // the outro fade
        #expect(reaimed == 150)                   // the last sung phrase boundary before it
    }

    /// A vocal-heavy incoming opening is a ducking case, never an acapella one:
    /// floating one lead over another is the thing the whole gate exists to stop.
    @Test func aSingingIncomingNeverGetsAcapella() {
        let (outgoing, incoming) = clashingVocalPair()
        let planned = TransitionPlanner.plan(outgoing: outgoing, incoming: incoming,
                                             stems: .ready)
        #expect(planned.style.stemTechnique != .acapellaOver)
    }

    /// Acapella is a compatible-tier technique — its separation residue is the
    /// one that is genuinely exposed (S1 §4).
    @Test func acapellaIsRefusedBelowTheCompatibleTier() {
        let outgoing = makeAnalysis(
            bpm: 120, confidence: 0.3, melProfile: Self.defaultProfile,
            vocalActivity: vocalEnvelope(duration: 200, hot: 130..<200))
        let incoming = makeAnalysis(
            bpm: 120, confidence: 0.3, rmsEnvelope: slowBuildEnvelope(), introEnd: 2,
            melProfile: Self.profile(distance: 0.35),        // → neutral tier
            vocalActivity: vocalEnvelope(duration: 200, hot: 40..<200))
        let planned = TransitionPlanner.plan(outgoing: outgoing, incoming: incoming,
                                             stems: .ready)
        #expect(planned.style.stemTechnique == nil)
    }

    /// Nothing to sing over the hand-over, nothing for a stem technique to do.
    @Test func anInstrumentalTailDeclinesEveryStemTechnique() {
        // Vocals finish long before any tail-window boundary.
        let outgoing = makeAnalysis(
            bpm: 120, confidence: 0.3,
            vocalActivity: vocalEnvelope(duration: 200, hot: 10..<80))
        let incoming = makeAnalysis(
            bpm: 120, confidence: 0.3, rmsEnvelope: slowBuildEnvelope(), introEnd: 2,
            vocalActivity: vocalEnvelope(duration: 200, hot: 0..<40))
        let planned = TransitionPlanner.plan(outgoing: outgoing, incoming: incoming,
                                             stems: .ready)
        #expect(planned.style.stemTechnique == nil)
    }

    /// `stemMinOverlap` is the "is this worth a separation pass" gate: raise it
    /// past the overlap and the pair falls all the way back to the whole-mix
    /// decision, vocal cap included.
    @Test func aShortOverlapIsNotWorthASeparationPass() {
        let (outgoing, incoming) = clashingVocalPair()
        var strict = TransitionPlanner.Config.standard
        strict.stemMinOverlap = 25
        let planned = TransitionPlanner.plan(outgoing: outgoing, incoming: incoming,
                                             stems: .ready, config: strict)
        guard case .crossfade(let fade, let outPoint, _) = planned.plan else {
            Issue.record("expected a crossfade")
            return
        }
        #expect(planned.style.stemTechnique == nil)
        #expect(fade <= strict.vocalClashFadeCap)
        #expect(outPoint == 150)
    }

    /// `instrumentalOut` never won a pair in S1's blind test, so the planner
    /// never asks for it — it stays a hand-picked technique.
    @Test func instrumentalOutIsNeverChosenAutomatically() {
        let fixtures: [(TrackAnalysis, TrackAnalysis)] = [
            clashingVocalPair(),
            clashingVocalPair(confidence: 0.9, incomingBPM: 124),
            (makeAnalysis(bpm: 120, confidence: 0.3,
                          vocalActivity: vocalEnvelope(duration: 200, hot: 130..<200)),
             makeAnalysis(bpm: 120, confidence: 0.3, rmsEnvelope: slowBuildEnvelope(),
                          introEnd: 2,
                          vocalActivity: vocalEnvelope(duration: 200, hot: 40..<200))),
            (makeAnalysis(bpm: 120), makeAnalysis(bpm: 124, introEnd: 2)),
        ]
        for (outgoing, incoming) in fixtures {
            let planned = TransitionPlanner.plan(outgoing: outgoing, incoming: incoming,
                                                 stems: .ready)
            #expect(planned.style.stemTechnique != .instrumentalOut)
        }
    }

    /// A track with no vocal contour at all must not crash or invent a
    /// technique — absence of evidence is not a vocal.
    @Test func missingVocalContoursNeverEarnAStemTechnique() {
        let planned = TransitionPlanner.plan(
            outgoing: makeAnalysis(bpm: 120, confidence: 0.3),
            incoming: makeAnalysis(bpm: 120, confidence: 0.3, introEnd: 2),
            stems: .ready)
        #expect(planned.style.stemTechnique == nil)
    }

    // MARK: - Rule 3: gapless

    @Test func nilOutgoingIsGapless() {
        guard case .gapless = planOnly(
            outgoing: nil, incoming: makeAnalysis()) else {
            Issue.record("expected gapless")
            return
        }
    }

    @Test func nilIncomingIsGapless() {
        guard case .gapless = planOnly(
            outgoing: makeAnalysis(), incoming: nil) else {
            Issue.record("expected gapless")
            return
        }
    }

    @Test func shortTrackIsGapless() {
        let short = makeAnalysis(duration: 40, phraseBoundaries: [20])
        guard case .gapless = planOnly(
            outgoing: short, incoming: makeAnalysis()) else {
            Issue.record("expected gapless for a <45 s track")
            return
        }
        guard case .gapless = planOnly(
            outgoing: makeAnalysis(), incoming: short) else {
            Issue.record("expected gapless for a <45 s track")
            return
        }
    }

    // MARK: - Decision ledger (PlanTrace)

    /// Plan once with a ledger, once without, and hand back both the plan and
    /// the ledger — so every test here can assert the two agree.
    private func traced(
        outgoing: TrackAnalysis?, incoming: TrackAnalysis?,
        stems: StemAvailability = .none,
        config: TransitionPlanner.Config = .standard
    ) -> (planned: PlannedTransition, trace: PlanTrace) {
        var trace: PlanTrace? = PlanTrace()
        let planned = TransitionPlanner.plan(outgoing: outgoing, incoming: incoming,
                                             stems: stems, config: config, trace: &trace)
        return (planned, trace!)
    }

    /// Every field of a decision, flattened — so "tracing changed nothing" is
    /// a string comparison rather than a hand-written list of `#expect`s.
    private func fingerprint(_ p: PlannedTransition) -> String {
        var out: String
        switch p.plan {
        case .gapless:
            out = "gapless"
        case .crossfade(let d, let o, let i):
            out = String(format: "crossfade %.6f %.6f %.6f", d, o, i)
        case .beatMatched(let b):
            out = String(format: "beatMatched %.6f %.6f %d %.6f %.6f %.6f %.6f",
                         b.outPoint, b.inPoint, b.overlapBars, Double(b.outgoingRate),
                         Double(b.incomingRate), b.bassSwapOffset, b.overlapDuration)
        }
        out += " | \(p.style.outroEffect) \(p.style.stagedEQ)"
        out += " \(p.style.echoDelayTime.map { String(format: "%.6f", $0) } ?? "—")"
        out += " \(p.style.stemTechnique?.label ?? "—")"
        return out
    }

    /// The whole point of the design: asking for the ledger must not move a
    /// single number. Run the corpus of shapes these tests already cover
    /// through both entry points and compare field for field.
    @Test func askingForATraceChangesNothing() {
        let shapes: [(String, TrackAnalysis?, TrackAnalysis?)] = [
            ("beat-matched", makeAnalysis(bpm: 120), makeAnalysis(bpm: 124)),
            ("choppy", makeAnalysis(bpm: 120, rmsEnvelope: choppyEnvelope(duration: 200)),
             makeAnalysis(bpm: 124, rmsEnvelope: choppyEnvelope(duration: 200))),
            ("far bpm", makeAnalysis(bpm: 120), makeAnalysis(bpm: 160)),
            ("shy tempo", makeAnalysis(bpm: 120, confidence: 0.3),
             makeAnalysis(bpm: 120, confidence: 0.3)),
            ("timbre clash", makeAnalysis(bpm: 120),
             makeAnalysis(bpm: 124, melProfile: Self.profile(distance: 0.6))),
            ("no boundaries", makeAnalysis(bpm: 120, phraseBoundaries: []),
             makeAnalysis(bpm: 124)),
            ("outro fade", makeAnalysis(bpm: 120, outroFadeStart: 170),
             makeAnalysis(bpm: 124)),
            ("gapless", makeAnalysis(duration: 40, phraseBoundaries: [20]), makeAnalysis()),
            ("no incoming", makeAnalysis(), nil),
        ]
        for (name, a, b) in shapes {
            let plain = TransitionPlanner.plan(outgoing: a, incoming: b)
            let withLedger = traced(outgoing: a, incoming: b).planned
            #expect(fingerprint(plain) == fingerprint(withLedger),
                    "tracing moved the decision for \(name)")
            // Same again with stems offered, where the planner has a second
            // search to run.
            let plainStems = TransitionPlanner.plan(outgoing: a, incoming: b, stems: .ready)
            let ledgerStems = traced(outgoing: a, incoming: b, stems: .ready).planned
            #expect(fingerprint(plainStems) == fingerprint(ledgerStems),
                    "tracing moved the stem decision for \(name)")
        }
    }

    /// The ledger and the plan are never allowed to disagree: a blocker means
    /// no beat-matched plan, and a beat-matched plan means no blocker — and its
    /// recorded bar count is the one in the plan.
    @Test func theLedgerAgreesWithThePlanItRecorded() {
        let shapes: [(TrackAnalysis?, TrackAnalysis?)] = [
            (makeAnalysis(bpm: 120), makeAnalysis(bpm: 124)),
            (makeAnalysis(bpm: 120, rmsEnvelope: choppyEnvelope(duration: 200)),
             makeAnalysis(bpm: 124, rmsEnvelope: choppyEnvelope(duration: 200))),
            (makeAnalysis(bpm: 120), makeAnalysis(bpm: 160)),
            (makeAnalysis(bpm: 120, confidence: 0.3), makeAnalysis(bpm: 120, confidence: 0.3)),
            (makeAnalysis(bpm: 120), makeAnalysis(bpm: 124,
                                                 melProfile: Self.profile(distance: 0.6))),
            (makeAnalysis(bpm: 120, phraseBoundaries: []), makeAnalysis(bpm: 124)),
            (makeAnalysis(duration: 40, phraseBoundaries: [20]), makeAnalysis()),
            (nil, makeAnalysis()),
        ]
        for (a, b) in shapes {
            let (planned, trace) = traced(outgoing: a, incoming: b)
            if case .beatMatched(let plan) = planned.plan {
                #expect(trace.blocker == nil,
                        "a beat-matched pair must have no blocker, got \(trace.blocker?.id ?? "—")")
                #expect(trace.chosenBars == plan.overlapBars)
            } else {
                #expect(trace.blocker != nil,
                        "a non-beat-matched pair must name the gate that stopped it")
                #expect(trace.chosenBars == nil)
            }
        }
    }

    /// Each gate, made to be the one that fails, is the one the ledger blames.
    @Test func theLedgerBlamesTheGateThatActuallyFailed() {
        func blocker(_ a: TrackAnalysis?, _ b: TrackAnalysis?) -> String? {
            traced(outgoing: a, incoming: b).trace.blocker?.id
        }
        // Too short to be worth a transition.
        #expect(blocker(makeAnalysis(duration: 40, phraseBoundaries: [20]),
                        makeAnalysis()) == "minDuration")
        // Timbre far enough apart to demote the tier.
        #expect(blocker(makeAnalysis(bpm: 120),
                        makeAnalysis(bpm: 124,
                                     melProfile: Self.profile(distance: 0.6)))
                == "timbreDistance")
        // Confident keys three fifths apart.
        #expect(blocker(makeAnalysis(bpm: 120, keyPitchClass: 0, keyConfidence: 0.9),
                        makeAnalysis(bpm: 124, keyPitchClass: 3, keyConfidence: 0.9))
                == "keyDistance")
        // Neither tempo is trusted.
        #expect(blocker(makeAnalysis(bpm: 120, confidence: 0.3),
                        makeAnalysis(bpm: 120, confidence: 0.3)) == "bpmConfidence")
        // 120 → 135 is inside the 20 % clash line, so the tier stays
        // compatible, but 12.5 % is past the beat-match window even with the
        // tempo ramp's widened 11.5 %.
        #expect(blocker(makeAnalysis(bpm: 120), makeAnalysis(bpm: 135)) == "bpmDelta")
        // Further out still and the tempo signal demotes the tier first, so
        // the blame moves up the chain rather than down it.
        #expect(blocker(makeAnalysis(bpm: 120), makeAnalysis(bpm: 160)) == "tempoClash")
        // rateDeviation needs the *stepped* regime to be reachable at all: at
        // the ramped defaults the two caps are consistent, so anything inside
        // the 11.5 % gap window is inside the 6.5 % bend window too (the worst
        // case, a maximally slower incoming deck, needs 6.497 %). It is a
        // safety net there, not a gate — see `rampMaxRateDeviation`. Stepped,
        // the old lip is still open: 100 → 92 is inside 8 % but bends the
        // faster deck 4.35 %, past ±4 %.
        var stepped = TransitionPlanner.Config.standard
        stepped.tempoRampEnabled = false
        #expect(traced(outgoing: makeAnalysis(bpm: 100), incoming: makeAnalysis(bpm: 92),
                       config: stepped).trace.blocker?.id == "rateDeviation")
        // No downbeat to align the incoming track to.
        #expect(blocker(makeAnalysis(bpm: 120),
                        makeAnalysis(bpm: 124, downbeats: [])) == "inPoint")
        // No phrase boundary in the outgoing tail to start the overlap on.
        #expect(blocker(makeAnalysis(bpm: 120, phraseBoundaries: []),
                        makeAnalysis(bpm: 124)) == "outPoint")
    }

    /// First gate wins: once a pair is out, the chain stops, so the ledger
    /// never blames it for a gate it was never asked to clear.
    @Test func theChainStopsAtTheFirstFailure() {
        // Tempos too shy to trust *and* far apart. Only the first is recorded.
        let trace = traced(outgoing: makeAnalysis(bpm: 120, confidence: 0.3),
                           incoming: makeAnalysis(bpm: 160, confidence: 0.3)).trace
        #expect(trace.blocker?.id == "bpmConfidence")
        #expect(!trace.gates.contains { $0.id == "bpmDelta" })
        #expect(trace.gates.filter { !$0.passed }.count == 1)
    }

    /// The bar search shortens an overlap; it never eliminates a pair. A
    /// choppy pair beat-matches at the 4-bar floor with failed upgrade gates
    /// on the ledger and no blocker at all.
    @Test func theBarSearchIsNeverBlamedForAnElimination() {
        let choppy = choppyEnvelope(duration: 200)
        let (planned, trace) = traced(
            outgoing: makeAnalysis(bpm: 120, rmsEnvelope: choppy),
            incoming: makeAnalysis(bpm: 124, rmsEnvelope: choppy))
        guard case .beatMatched(let plan) = planned.plan else {
            Issue.record("expected a beat-matched plan at the 4-bar floor")
            return
        }
        #expect(plan.overlapBars == 4)
        #expect(trace.blocker == nil)
        #expect(trace.gates.contains { $0.stage == .barUpgrade && !$0.passed })
    }

    /// The shadow ledger answers the counterfactual a demoted pair otherwise
    /// cannot: had the tier let it through, would anything else have stopped
    /// it? Same two tempos, one pair only demoted by timbre — so nothing else
    /// would have.
    @Test func theShadowLedgerWalksTheChainTheTierCutShort() {
        let clash = traced(
            outgoing: makeAnalysis(bpm: 120),
            incoming: makeAnalysis(bpm: 124, melProfile: Self.profile(distance: 0.6))).trace
        #expect(clash.blocker?.id == "timbreDistance")
        #expect(clash.shadowBlocker == nil, "this pair fails nothing but the tier")
        #expect(clash.shadowGates.contains { $0.id == "bpmDelta" && $0.passed })

        // Now a pair that is *both* timbre-demoted and tempo-mismatched: the
        // blame stays on the tier, and the shadow says what came next.
        let both = traced(
            outgoing: makeAnalysis(bpm: 120),
            incoming: makeAnalysis(bpm: 160, melProfile: Self.profile(distance: 0.6))).trace
        #expect(both.blocker?.stage == .tier)
        #expect(both.shadowBlocker?.id == "bpmDelta")
    }

    /// A gate's margin is what "by how much" means in the report, and it has
    /// to point the right way on both sides of a line.
    @Test func aGateReportsHowFarItMissedItsLine() {
        let trace = traced(outgoing: makeAnalysis(bpm: 120),
                           incoming: makeAnalysis(bpm: 135)).trace
        guard let blocker = trace.blocker, let margin = blocker.margin else {
            Issue.record("expected a numeric blocker")
            return
        }
        // 120 → 135 is a 12.5 % gap against the window actually in force —
        // the tempo ramp's 11.5 % at the shipped defaults.
        #expect(margin > 0)
        #expect(abs((blocker.value ?? 0) - 0.125) < 0.001)
        #expect(blocker.threshold == TransitionPlanner.Config.standard.beatMatchBPMDeltaCap)

        // A confidence gate misses from below, so its margin is negative.
        let shy = traced(outgoing: makeAnalysis(bpm: 120, confidence: 0.3),
                         incoming: makeAnalysis(bpm: 120, confidence: 0.3)).trace
        #expect((shy.blocker?.margin ?? 0) < 0)
    }

    // MARK: - Config

    /// The flat constants the rest of the codebase reads must stay exactly
    /// `Config.standard`'s fields — the promotion to a struct is not allowed
    /// to have moved a shipped number.
    @Test func standardConfigMatchesTheShippedConstants() {
        let c = TransitionPlanner.Config.standard
        #expect(c.minTrackDuration == TransitionPlanner.minTrackDuration)
        #expect(c.bpmConfidenceThreshold == TransitionPlanner.bpmConfidenceThreshold)
        #expect(c.maxBPMDeltaRatio == TransitionPlanner.maxBPMDeltaRatio)
        #expect(c.maxRateDeviation == TransitionPlanner.maxRateDeviation)
        #expect(c.stableCV == TransitionPlanner.stableCV)
        #expect(c.maxOverlap == TransitionPlanner.maxOverlap)
        #expect(c.minOverlap == TransitionPlanner.minOverlap)
        #expect(c.maxOverlapShare == TransitionPlanner.maxOverlapShare)
        #expect(c.tailStableCV == TransitionPlanner.tailStableCV)
        #expect(c.neutralLoudnessDB == 4.5)
        #expect(c.clashLoudnessDB == 6.5)
        #expect(c.neutralTimbreDistance == 0.35)
        #expect(c.clashTimbreDistance == 0.45)
        #expect(c.clashTempoRatio == 0.2)
        #expect(c.neutralOverlapCap == 10)
        #expect(c.clashOverlapCap == 2.5)
        #expect(c.keyConfidenceThreshold == 0.5)
        #expect(c.clashKeyDistance == 3)
        #expect(c.vocalClashRatio == 1.1)
        #expect(c.vocalClashFadeCap == 4)
        #expect(c.stemVocalActiveRatio == 1.15)
        #expect(c.stemAcapellaIncomingVocalMax == 0.90)
        #expect(c.stemMinOverlap == 5)
        #expect(c.stemDuckDepthDB == 9)
        // The two rules must stay disjoint: an incoming opening cannot be both
        // quiet enough to float over and hot enough to duck against.
        #expect(c.stemAcapellaIncomingVocalMax < c.vocalClashRatio)
        // And "vocal-active enough for a stem technique" must be a stricter bar
        // than "loud enough to clash".
        #expect(c.stemVocalActiveRatio > c.vocalClashRatio)
    }

    /// Omitting `config:` must be indistinguishable from passing `.standard`.
    @Test func omittingConfigIsTheStandardConfig() {
        let outgoing = makeAnalysis(melProfile: Self.profile(distance: 0.4))
        let incoming = makeAnalysis()
        let implicit = TransitionPlanner.plan(outgoing: outgoing, incoming: incoming)
        let explicit = TransitionPlanner.plan(outgoing: outgoing, incoming: incoming,
                                              config: .standard)
        guard case .crossfade(let d1, let o1, let i1) = implicit.plan,
              case .crossfade(let d2, let o2, let i2) = explicit.plan else {
            Issue.record("expected crossfades")
            return
        }
        #expect(d1 == d2 && o1 == o2 && i1 == i2)
        #expect(implicit.style == explicit.style)
    }

    /// Moving the timbre clash line down must actually re-tier a pair that
    /// sits between the old and new line — this is the console's whole point.
    @Test func loweringTheTimbreClashLineDemotesAPair() {
        let outgoing = makeAnalysis(melProfile: Self.profile(distance: 0.35))
        let incoming = makeAnalysis()

        #expect(TransitionPlanner.compatibility(outgoing: outgoing, incoming: incoming)
                == .neutral)

        var strict = TransitionPlanner.Config.standard
        strict.clashTimbreDistance = 0.30
        #expect(TransitionPlanner.compatibility(outgoing: outgoing, incoming: incoming,
                                                config: strict) == .clash)

        // …and the plan follows the tier: the clash cap shortens the overlap.
        guard case .crossfade(let wide, _, _) = TransitionPlanner
                .plan(outgoing: outgoing, incoming: incoming).plan,
              case .crossfade(let tight, _, _) = TransitionPlanner
                .plan(outgoing: outgoing, incoming: incoming, config: strict).plan
        else {
            Issue.record("expected crossfades")
            return
        }
        // The neutral tier's length is whatever the audio supports up to its
        // cap (here the incoming intake, 8 s); the clash tier's is the cap.
        #expect(wide <= TransitionPlanner.neutralOverlapCap)
        #expect(tight < wide)
        #expect(tight <= strict.clashOverlapCap)
    }

    /// A widened beat-match window lets a pair that just missed the tempo
    /// gate through — the knob reaches the beat-matching path too.
    @Test func wideningTheBeatMatchWindowAdmitsAPair() {
        let outgoing = makeAnalysis(bpm: 120)
        // 12 % apart: over the shipped line even with the tempo ramp's
        // widened 11.5 %.
        let incoming = makeAnalysis(bpm: 134.4)
        guard case .crossfade = planOnly(outgoing: outgoing, incoming: incoming) else {
            Issue.record("expected a crossfade at the shipped window")
            return
        }
        var loose = TransitionPlanner.Config.standard
        loose.rampMaxBPMDeltaRatio = 0.14
        loose.rampMaxRateDeviation = 0.08
        guard case .beatMatched = TransitionPlanner
                .plan(outgoing: outgoing, incoming: incoming, config: loose).plan else {
            Issue.record("expected a beat-match once the window opens to 14 %")
            return
        }
        // …and the same widening applied to the *stepped* caps does nothing
        // while the ramp is on, which is the coupling stated out loud.
        var looseStep = TransitionPlanner.Config.standard
        looseStep.maxBPMDeltaRatio = 0.14
        looseStep.maxRateDeviation = 0.08
        guard case .crossfade = TransitionPlanner
                .plan(outgoing: outgoing, incoming: incoming, config: looseStep).plan else {
            Issue.record("the stepped caps must be inert while the ramp is on")
            return
        }
    }

    /// `standard(overriding:)` is the console's entry point: unknown names
    /// are ignored and out-of-range values clamp, so a stale saved preset can
    /// never produce a config the planner would choke on.
    @Test func configOverridesAreNamedClampedAndForgiving() {
        let c = TransitionPlanner.Config.standard(overriding: [
            "clashTimbreDistance": 0.31,
            "neutralLoudnessDB": -50,          // below the field's min
            "notAKnob": 7,                     // stale preset entry
        ])
        #expect(c.clashTimbreDistance == 0.31)
        #expect(c.neutralLoudnessDB == 0)      // clamped to the field min
        #expect(c.clashLoudnessDB == TransitionPlanner.clashLoudnessDB)

        let diff = c.diffFromStandard.map(\.name).sorted()
        #expect(diff == ["clashTimbreDistance", "neutralLoudnessDB"])
        #expect(TransitionPlanner.Config.standard(overriding: [:]) == .standard)
        #expect(TransitionPlanner.Config.standard.diffFromStandard.isEmpty)
    }

    /// Every field the console shows must round-trip through the dictionary
    /// the browser posts back, or a slider would silently do nothing.
    @Test func everyFieldRoundTripsThroughTheOverrideDictionary() {
        let fields = TransitionPlanner.Config.fields
        #expect(!fields.isEmpty)
        for field in fields {
            let probe = (field.read(.standard) + field.step * 3)
                .clamped(to: field.min...field.max)
            guard abs(probe - field.read(.standard)) > 1e-9 else { continue }
            let c = TransitionPlanner.Config.standard(overriding: [field.name: probe])
            #expect(abs(field.read(c) - probe) <= max(1e-9, field.step),
                    "\(field.name) did not take \(probe)")
            #expect(c.asDictionary[field.name] != nil, "\(field.name) missing from asDictionary")
            #expect(field.min < field.max, "\(field.name) has an empty range")
            #expect(field.read(.standard) >= field.min && field.read(.standard) <= field.max,
                    "\(field.name)'s shipped value sits outside its own slider range")
        }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
