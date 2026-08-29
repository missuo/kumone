import Testing
@testable import KumoneCore
import Foundation

// The loudness pair: the BS.1770 meter that measures a master, and the
// compensation that turns that measurement into a playback trim.

@Suite struct LoudnessMeterTests {

    private func sine(_ hz: Double, dBFS: Double, seconds: Double,
                      sampleRate sr: Double) -> [Float] {
        // "dBFS" for a sine means its RMS relative to a full-scale sine's, so
        // the amplitude is 10^(dB/20) — the convention EBU Tech 3341 uses.
        let amplitude = pow(10.0, dBFS / 20.0)
        return (0..<Int(seconds * sr)).map {
            Float(amplitude * sin(2 * .pi * hz * Double($0) / sr))
        }
    }

    /// EBU Tech 3341 compliance case 1: a 1 kHz sine at −23 dBFS must read
    /// −23 LUFS. This pins the whole chain at once — the shelf and high-pass
    /// coefficients (re-derived at 22.05 kHz rather than the spec's 48 kHz),
    /// the −0.691 dB channel-sum offset, and the mono-as-centred-pair
    /// convention. Anything wrong in the filter design shows up here.
    @Test func oneKilohertzSineCalibratesToItsNominalLevel() {
        let sr = TrackAnalyzer.analysisSampleRate
        for level in [-23.0, -30.0, -12.0] {
            let x = sine(1000, dBFS: level, seconds: 10, sampleRate: sr)
            let measured = LoudnessMeter.integratedLUFS(x, sampleRate: sr)
            #expect(measured != nil)
            #expect(abs(measured! - level) < 0.25,
                    "1 kHz at \(level) dBFS measured \(measured ?? .nan) LUFS")
        }
    }

    /// Scaling the signal must move the reading by exactly the same dB: the
    /// gating is level-relative, so it cannot introduce a bias.
    @Test func measurementIsExactlyGainInvariant() {
        let sr = TrackAnalyzer.analysisSampleRate
        let base = sine(440, dBFS: -14, seconds: 12, sampleRate: sr)
        let quiet = base.map { $0 * Float(pow(10.0, -10.0 / 20.0)) }
        let loud = LoudnessMeter.integratedLUFS(base, sampleRate: sr)!
        let soft = LoudnessMeter.integratedLUFS(quiet, sampleRate: sr)!
        #expect(abs((loud - soft) - 10) < 0.05)
    }

    /// K-weighting is the point of using LUFS over RMS: equal-RMS tones at
    /// different frequencies must not read equally loud. A 50 Hz tone sits
    /// under the RLB high-pass and has to measure clearly quieter than 1 kHz.
    @Test func lowFrequencyEnergyIsDiscountedRelativeToMidrange() {
        let sr = TrackAnalyzer.analysisSampleRate
        let mid = LoudnessMeter.integratedLUFS(
            sine(1000, dBFS: -20, seconds: 8, sampleRate: sr), sampleRate: sr)!
        let low = LoudnessMeter.integratedLUFS(
            sine(50, dBFS: -20, seconds: 8, sampleRate: sr), sampleRate: sr)!
        // Measured: 1 kHz −19.96 LUFS, 50 Hz −24.59 LUFS — a 4.6 dB discount.
        #expect(mid - low > 4, "50 Hz read \(low), 1 kHz read \(mid)")
    }

    /// The relative gate is what lets the number ignore intro/outro: padding a
    /// track with silence must not drag its loudness down.
    @Test func silentPaddingDoesNotChangeTheReading() {
        let sr = TrackAnalyzer.analysisSampleRate
        let body = sine(440, dBFS: -16, seconds: 10, sampleRate: sr)
        let padded = [Float](repeating: 0, count: Int(8 * sr)) + body
            + [Float](repeating: 0, count: Int(8 * sr))
        let bare = LoudnessMeter.integratedLUFS(body, sampleRate: sr)!
        let withPadding = LoudnessMeter.integratedLUFS(padded, sampleRate: sr)!
        #expect(abs(bare - withPadding) < 0.5)
    }

    @Test func silenceAndTooShortInputHaveNoOpinion() {
        let sr = TrackAnalyzer.analysisSampleRate
        #expect(LoudnessMeter.integratedLUFS([Float](repeating: 0, count: Int(sr)),
                                             sampleRate: sr) == nil)
        #expect(LoudnessMeter.integratedLUFS([0.1, 0.2, 0.3], sampleRate: sr) == nil)
        #expect(LoudnessMeter.peakDBFS([]) == nil)
        #expect(abs(LoudnessMeter.peakDBFS([0.5, -0.25])! + 6.0206) < 0.01)
    }

    /// The property the whole feature rests on: `referenceLoudness` measures
    /// the master's level, so the same music 10 dB down must read 10 dB down.
    @Test func analysisReferenceLoudnessTracksGainExactly() {
        let sr = TrackAnalyzer.analysisSampleRate
        let x = sine(220, dBFS: -12, seconds: 30, sampleRate: sr)
        let quiet = x.map { $0 * Float(pow(10.0, -10.0 / 20.0)) }
        let a = TrackAnalyzer.analyze(samples: x, sampleRate: sr)
        let b = TrackAnalyzer.analyze(samples: quiet, sampleRate: sr)
        let loud = try! #require(a.referenceLoudness)
        let soft = try! #require(b.referenceLoudness)
        #expect(abs((loud - soft) - 10) < 0.05)
        // The peak follows too, and stays a sane dBFS figure.
        #expect(abs((a.peakDBFS! - b.peakDBFS!) - 10) < 0.05)
        #expect(a.peakDBFS! < 0)
    }

    @Test func analysisVersionCoversTheNewFields() {
        // 6 added the loudness fields; 7 added `sections` (predev §2.1).
        #expect(TrackAnalysis.currentVersion == 7)
    }
}

@Suite struct LoudnessCompensationTests {

    /// A track with `loudness` LUFS and plenty of headroom.
    private func analysis(loudness: Double?, peakDBFS: Double = -6) -> TrackAnalysis {
        TrackAnalysis(
            version: TrackAnalysis.currentVersion, bpm: 120, bpmConfidence: 0.9,
            beats: [], downbeats: [], phraseBoundaries: [],
            rmsEnvelope: [Float](repeating: 0.2, count: 200),
            outroFadeStart: nil, introEnd: 0, duration: 200, melProfile: [],
            keyPitchClass: nil, keyIsMinor: false, keyConfidence: 0,
            vocalActivity: [], referenceLoudness: loudness, peakDBFS: peakDBFS)
    }

    @Test func aLoudMasterIsPulledDownToTheTarget() {
        // −8 LUFS against a −14 target is a 6 dB cut, and cuts are never capped
        // by anything but `maxCutDB`.
        let trim = LoudnessCompensation.trimDB(for: analysis(loudness: -8))
        #expect(abs(trim - -6) < 1e-9)
    }

    @Test func anAbsurdlyLoudMasterIsHeldAtTheCutCeiling() {
        let trim = LoudnessCompensation.trimDB(for: analysis(loudness: 4))
        #expect(abs(trim - -LoudnessCompensation.Config.standard.maxCutDB) < 1e-9)
    }

    @Test func aQuietMasterIsLiftedOnlyToTheBoostCeiling() {
        // −24 LUFS "wants" +10 dB; it may have +3.
        let trim = LoudnessCompensation.trimDB(for: analysis(loudness: -24, peakDBFS: -20))
        #expect(abs(trim - 3) < 1e-9)
    }

    @Test func theClipGuardOverridesTheBoostCeiling() {
        // A quiet-but-peaky master: −24 LUFS wants a boost, but the peak sits
        // at −2 dBFS, and with the downmix allowance there is no room at all.
        #expect(LoudnessCompensation.trimDB(for: analysis(loudness: -24, peakDBFS: -2)) == 0)
        // −5.5 dBFS peak + 3 dB allowance leaves 1.5 dB under the −1 ceiling.
        let partial = LoudnessCompensation.trimDB(for: analysis(loudness: -24, peakDBFS: -5.5))
        #expect(abs(partial - 1.5) < 1e-6)
    }

    @Test func aCutIsNeverBlockedByThePeakGuard() {
        // Even a master already over the ceiling: pulling it *down* is safe.
        let trim = LoudnessCompensation.trimDB(for: analysis(loudness: -6, peakDBFS: -0.1))
        #expect(abs(trim - -8) < 1e-9)
    }

    @Test func noAnalysisAndNoMeasurementMeanUnityGain() {
        #expect(LoudnessCompensation.trimDB(for: nil) == 0)
        #expect(LoudnessCompensation.trimDB(for: analysis(loudness: nil)) == 0)
        #expect(LoudnessCompensation.trimDB(for: analysis(loudness: -8), enabled: false) == 0)
    }

    @Test func decibelsConvertToTheFaderMultiplier() {
        #expect(abs(LoudnessCompensation.gain(fromDB: 0) - 1) < 1e-6)
        #expect(abs(LoudnessCompensation.gain(fromDB: -6.0206) - 0.5) < 1e-4)
    }
}
