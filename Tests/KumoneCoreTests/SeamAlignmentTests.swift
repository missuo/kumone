import Testing
@testable import KumoneCore
import AVFoundation
import Foundation

// The seam-alignment instrument and the two pieces of arithmetic it feeds: the
// correlator that says where a captured window really sat on its song, the
// splice-arm release that holds the segment back by what the correlator found,
// and the rule by which one measurement is allowed to move the estimate.
//
// All of it is pure — no engine, no audio clock, no files — which is the whole
// reason it was factored out of `PlaybackEngine`: a latency measurement whose
// only witness is the field is a latency measurement nobody can check.

// MARK: - Fixtures

private enum SeamFixtures {

    /// Deterministic broadband noise, shaped into short bursts so the
    /// correlation has transients to lock onto rather than a stationary hiss
    /// that matches itself equally well at every lag.
    ///
    /// A fixed LCG rather than `Float.random`: a correlation test that fails
    /// one run in fifty because the noise happened to be periodic is a test
    /// that gets deleted.
    static func music(seconds: Double, sampleRate: Double = 44_100,
                      seed: UInt64 = 0x5EED) -> [Float] {
        var state = seed
        func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int32(truncatingIfNeeded: state >> 33)) / Float(Int32.max)
        }
        let count = Int(seconds * sampleRate)
        var out = [Float](repeating: 0, count: count)
        let period = Int(sampleRate / 8)      // a transient every 125 ms
        for i in 0..<count {
            let phase = Float(i % period) / Float(period)
            out[i] = next() * expf(-8 * phase)
        }
        return out
    }

    /// `x` delayed by a whole number of samples, taken out of the middle so
    /// both signals are the same length and neither runs off an end.
    static func window(_ x: [Float], from: Int, count: Int) -> [Float] {
        Array(x[from..<(from + count)])
    }
}

// MARK: - Correlator

@Suite("Seam alignment")
struct SeamAlignmentTests {

    /// The straight case: a probe cut from a known place in the reference is
    /// found at that place, to a sample.
    @Test func recoversAKnownIntegerOffset() {
        let rate = 44_100.0
        let reference = SeamFixtures.music(seconds: 2)
        let probeStart = 30_000
        // The probe is nine samples *later* in the song than we will claim.
        let claimed = probeStart - 9
        let probe = SeamFixtures.window(reference, from: probeStart, count: 13_230)

        let match = SeamAlignment.match(
            probe: SeamAlignment.preEmphasised(probe),
            reference: SeamAlignment.preEmphasised(reference),
            expectedIndex: claimed, radiusSamples: 3_500, sampleRate: rate)
        let found = try! #require(match)
        #expect(abs(found.offsetSeconds - 9 / rate) < 0.0001)
        #expect(found.correlation > 0.99)
    }

    /// 0.1 ms is the tolerance the field report is written to; the correlator
    /// resolves better than a twentieth of that.
    @Test func recoversAnOffsetToWellUnderATenthOfAMillisecond() {
        let rate = 44_100.0
        let reference = SeamFixtures.music(seconds: 2)
        for lag in [-40, -1, 0, 1, 17, 220] {
            let probeStart = 40_000 + lag
            let probe = SeamFixtures.window(reference, from: probeStart, count: 13_230)
            let match = SeamAlignment.match(
                probe: SeamAlignment.preEmphasised(probe),
                reference: SeamAlignment.preEmphasised(reference),
                expectedIndex: 40_000, radiusSamples: 3_500, sampleRate: rate)
            let found = try! #require(match)
            #expect(abs(found.offsetSeconds - Double(lag) / rate) < 0.0001,
                    "lag \(lag) recovered as \(found.offsetSeconds * 1000) ms")
        }
    }

    /// A *fractional* offset — the case the parabolic refinement exists for.
    /// Built by resampling, so the probe genuinely sits half a sample off the
    /// grid rather than being relabelled.
    @Test func recoversAFractionalOffset() {
        let rate = 44_100.0
        let reference = SeamFixtures.music(seconds: 2)
        // Shift by half a sample: linear-interpolate midway between neighbours.
        var shifted = [Float](repeating: 0, count: reference.count - 1)
        for i in 0..<shifted.count { shifted[i] = 0.5 * (reference[i] + reference[i + 1]) }
        let probe = SeamFixtures.window(shifted, from: 50_000, count: 13_230)
        let match = SeamAlignment.match(
            probe: SeamAlignment.preEmphasised(probe),
            reference: SeamAlignment.preEmphasised(reference),
            expectedIndex: 50_000, radiusSamples: 400, sampleRate: rate)
        let found = try! #require(match)
        #expect(abs(found.offsetSeconds - 0.5 / rate) < 0.0001)
    }

    /// The normalisation earns its keep: a probe 12 dB quieter than the
    /// reference (which is what a tap taken after a trim, a ride and a limiter
    /// is) still scores ~1 and still lands on the same sample.
    @Test func gainDoesNotMoveTheMatch() {
        let rate = 44_100.0
        let reference = SeamFixtures.music(seconds: 2)
        let quiet = SeamFixtures.window(reference, from: 60_000, count: 13_230)
            .map { $0 * 0.25 }
        let match = SeamAlignment.match(
            probe: SeamAlignment.preEmphasised(quiet),
            reference: SeamAlignment.preEmphasised(reference),
            expectedIndex: 60_000 - 55, radiusSamples: 3_500, sampleRate: rate)
        let found = try! #require(match)
        #expect(abs(found.offsetSeconds - 55 / rate) < 0.0001)
        #expect(found.correlation > 0.99)
    }

    /// Unrelated material scores far under the gate, which is the only thing
    /// stopping a bad seam from moving the calibration.
    @Test func unrelatedAudioDoesNotClearTheGate() {
        let reference = SeamFixtures.music(seconds: 2, seed: 1)
        let other = SeamFixtures.music(seconds: 2, seed: 2)
        let match = SeamAlignment.match(
            probe: SeamAlignment.preEmphasised(SeamFixtures.window(other, from: 20_000,
                                                                   count: 13_230)),
            reference: SeamAlignment.preEmphasised(reference),
            expectedIndex: 20_000, radiusSamples: 3_500, sampleRate: 44_100)
        let found = try! #require(match)
        #expect(found.correlation < SeamLatencyCalibration.minCorrelation)
    }

    @Test func refusesWhatItCannotMeasure() {
        let reference = SeamFixtures.music(seconds: 1)
        // Silence has no energy to normalise by.
        #expect(SeamAlignment.match(probe: [Float](repeating: 0, count: 1_000),
                                    reference: reference, expectedIndex: 100,
                                    radiusSamples: 50, sampleRate: 44_100) == nil)
        // A probe longer than the reference has nowhere to sit.
        #expect(SeamAlignment.match(probe: reference, reference: Array(reference[0..<10]),
                                    expectedIndex: 0, radiusSamples: 5,
                                    sampleRate: 44_100) == nil)
    }

    /// Differencing is applied to both sides, so it must not move anything.
    @Test func preEmphasisIntroducesNoShift() {
        let x: [Float] = [0, 1, 3, 6, 10]
        #expect(SeamAlignment.preEmphasised(x) == [1, 2, 3, 4])
        #expect(SeamAlignment.preEmphasised([1]).isEmpty)
    }

    /// Sample `i` of the output is exactly `i·source/target` samples into the
    /// input — the one property the measurement asks of the resampler.
    @Test func linearResamplingKeepsItsPhase() {
        let ramp = (0..<100).map { Float($0) }
        let doubled = SeamAlignment.resampled(ramp, from: 44_100, to: 88_200)
        #expect(doubled.count == 199)
        #expect(abs(doubled[0] - 0) < 1e-5)
        #expect(abs(doubled[1] - 0.5) < 1e-5)
        #expect(abs(doubled[100] - 50) < 1e-5)
        // Same rate in and out is the identity, not a round trip through
        // interpolation.
        #expect(SeamAlignment.resampled(ramp, from: 44_100, to: 44_100) == ramp)
    }
}

// MARK: - The arm's arithmetic

@Suite("Splice release arithmetic")
struct SeamReleaseTests {

    /// At unity with nothing to compensate, the new arithmetic is the old
    /// arithmetic — the invariant that lets it replace the branch it grew out
    /// of without moving a single unramped seam.
    @Test func unityAndNoCompensationIsTheIdentity() {
        #expect(SeamRelease.lead(rawLead: 0.25, deckRate: 1, compensation: 0) == 0.25)
    }

    /// A bent deck emits its frames more slowly, so the interval to its splice
    /// frame is longer than the player clock's extrapolation says.
    @Test func aBentDeckStretchesTheLead() {
        let lead = SeamRelease.lead(rawLead: 0.25, deckRate: 1.02, compensation: 0)
        #expect(abs(lead - 0.25 / 1.02) < 1e-9)
    }

    /// The compensation is wall-clock and lands *after* the rate correction:
    /// it is a property of the graph, not of the song's tempo.
    @Test func compensationIsAddedAfterTheRateCorrection() {
        let lead = SeamRelease.lead(rawLead: 0.25, deckRate: 1.02, compensation: 0.019)
        #expect(abs(lead - (0.25 / 1.02 + 0.019)) < 1e-9)
        // And the field's own numbers: a quarter-second arm lead on an unbent
        // deck becomes 269 ms.
        let unbent = SeamRelease.lead(rawLead: 0.25, deckRate: 1, compensation: 0.019)
        #expect(abs(unbent - 0.269) < 1e-9)
    }

    @Test func neverReleasesInThePast() {
        #expect(SeamRelease.lead(rawLead: -1, deckRate: 1, compensation: 0.019) == 0)
    }

    /// A rate of zero or a NaN one is a deck whose clock we could not read;
    /// unity keeps the seam where it was rather than dividing by nothing.
    @Test func anImpossibleRateFallsBackToUnity() {
        #expect(SeamRelease.lead(rawLead: 0.25, deckRate: 0, compensation: 0) == 0.25)
        #expect(SeamRelease.lead(rawLead: 0.25, deckRate: .nan, compensation: 0) == 0.25)
    }
}

// MARK: - Calibration

@Suite("Seam latency calibration")
struct SeamLatencyCalibrationTests {

    /// Fresh, it is the field measurement and nothing has been folded in.
    @Test func startsAtTheFieldValue() {
        let fresh = SeamLatencyCalibration()
        #expect(fresh.headMilliseconds == SeamLatencyCalibration.fieldDefaultMilliseconds)
        #expect(fresh.headCount == 0)
    }

    /// The first measurement on a machine replaces the shipped default; the
    /// ones after it are smoothed.
    @Test func theFirstMeasurementReplacesAndTheRestSmooth() {
        var calibration = SeamLatencyCalibration()
        calibration.foldHead(impliedMilliseconds: 11)
        #expect(abs(calibration.headMilliseconds - 11) < 1e-9)
        #expect(calibration.headCount == 1)

        calibration.foldHead(impliedMilliseconds: 21)
        // 11 + 0.3·(21 − 11)
        #expect(abs(calibration.headMilliseconds - 14) < 1e-9)
        #expect(calibration.headCount == 2)
    }

    /// One wild measurement moves the applied compensation by under a
    /// millisecond, which is the whole point of smoothing a number that is
    /// written straight into the audio clock.
    @Test func oneOutlierCannotTearTheSeamOpen() {
        var calibration = SeamLatencyCalibration()
        calibration.foldHead(impliedMilliseconds: 19)
        let before = calibration.headMilliseconds
        calibration.foldHead(impliedMilliseconds: 60)
        #expect(calibration.headMilliseconds - before < 13)
    }

    @Test func theEstimateStaysInsideItsBounds() {
        var calibration = SeamLatencyCalibration()
        for _ in 0..<50 { calibration.foldHead(impliedMilliseconds: 900) }
        #expect(calibration.headMilliseconds == SeamLatencyCalibration.bounds.upperBound)
        for _ in 0..<50 { calibration.foldHead(impliedMilliseconds: -900) }
        #expect(calibration.headMilliseconds == SeamLatencyCalibration.bounds.lowerBound)
    }

    /// The tail is observation only, so it is *not* clamped to the head's
    /// non-negative range — a tail that runs early has to be able to say so.
    @Test func theTailIsRecordedSignedAndUnclamped() {
        var calibration = SeamLatencyCalibration()
        calibration.foldTail(impliedMilliseconds: -4.7)
        #expect(abs(calibration.tailMilliseconds + 4.7) < 1e-9)
        #expect(calibration.tailCount == 1)
        // And the head, which is what gets applied, is untouched by it.
        #expect(calibration.headMilliseconds
                == SeamLatencyCalibration.fieldDefaultMilliseconds)
    }

    /// Only a measurement that found the same music on both sides is allowed
    /// near the estimate.
    @Test func onlyTrustedMeasurementsQualify() {
        #expect(SeamOffsetMeasurement(offsetMilliseconds: 19,
                                      beforeCorrelation: 0.98,
                                      afterCorrelation: 0.97).isTrusted)
        #expect(!SeamOffsetMeasurement(offsetMilliseconds: 19,
                                       beforeCorrelation: 0.98,
                                       afterCorrelation: 0.42).isTrusted)
    }

    /// The spelling the journal and the panel share.
    @Test func measurementsPrintTheFieldFormat() {
        #expect(SeamOffsetMeasurement(offsetMilliseconds: 19.24,
                                      beforeCorrelation: 0.981,
                                      afterCorrelation: 0.9749).summary
                == "+19.2ms (corr 0.98/0.97)")
        #expect(SeamOffsetMeasurement(offsetMilliseconds: -0.5,
                                      beforeCorrelation: 1, afterCorrelation: 1).summary
                == "-0.5ms (corr 1.00/1.00)")
    }

    /// The pin wins over the calibration, and neither may invert the seam.
    @Test func thePinShadowsTheCalibrationAndIsStillBounded() {
        let store = SeamLatencyStore.shared
        let learned = store.headCompensationSeconds(pin: nil)
        #expect(learned >= 0)
        #expect(abs(store.headCompensationSeconds(pin: 25) - 0.025) < 1e-9)
        #expect(store.headCompensationSeconds(pin: -5) == 0)
        #expect(store.headCompensationSeconds(pin: 5_000)
                == SeamLatencyCalibration.bounds.upperBound / 1000)
    }
}

// MARK: - The override that pins it

@Suite("Head latency override")
struct HeadLatencyOverrideTests {

    /// Nil is the shipped player, exactly — the invariant every other override
    /// is held to.
    @Test func theNeutralStructIsUnpinned() {
        #expect(AutoMixOverrides().headLatencyCompensationMS == nil)
        #expect(!AutoMixOverrides().isActive)
        #expect(AutoMixOverrides().badges.isEmpty)
    }

    @Test func aPinShowsUpAsABadge() {
        var pinned = AutoMixOverrides()
        pinned.headLatencyCompensationMS = 19
        #expect(pinned.isActive)
        #expect(pinned.badges == ["headLatency=19ms"])
    }

    /// It moves nothing about the plan or the rendered audio — only when the
    /// segment's first sample is released — so it must not tear down a seam
    /// that is already armed.
    @Test func pinningDoesNotForceAReArm() {
        var pinned = AutoMixOverrides()
        pinned.headLatencyCompensationMS = 19
        #expect(!pinned.needsReArm(comparedTo: AutoMixOverrides()))
        #expect(!AutoMixOverrides().needsReArm(comparedTo: pinned))
    }
}
