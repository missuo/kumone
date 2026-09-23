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

    // MARK: - The output-tap instrument

    /// Plain RMS has exactly one right answer for a sine, and this pins it: a
    /// full-scale sine is −3.01 dBFS (its RMS is 1/√2), and everything else
    /// follows the amplitude one for one. No gate, no weighting, so unlike the
    /// LUFS meter it must read a 50 Hz tone and a 1 kHz tone at the same
    /// amplitude identically — which is the property that makes it the right
    /// instrument for "did the engine's gain change", as opposed to "how loud
    /// does this sound".
    @Test func plainRMSReadsASineAtItsKnownLevel() {
        let sr = TrackAnalyzer.analysisSampleRate
        func tone(_ hz: Double, amplitude: Double) -> [Float] {
            (0..<Int(4 * sr)).map {
                Float(amplitude * sin(2 * .pi * hz * Double($0) / sr))
            }
        }
        // A full-scale sine: 20·log10(1/√2) = −3.0103 dBFS.
        #expect(abs(LoudnessMeter.rmsDBFS(tone(1000, amplitude: 1))! + 3.0103) < 0.01)
        // …and a tenth of the amplitude is exactly 20 dB down from it.
        #expect(abs(LoudnessMeter.rmsDBFS(tone(1000, amplitude: 0.1))! + 23.0103) < 0.01)
        // Frequency-flat, which is the whole difference from the LUFS meter:
        // 50 Hz reads 4.6 LU quieter there and identically here.
        let low = LoudnessMeter.rmsDBFS(tone(50, amplitude: 0.1))!
        let mid = LoudnessMeter.rmsDBFS(tone(1000, amplitude: 0.1))!
        #expect(abs(low - mid) < 0.02)
        // A constant offset in, the same offset out — the property a
        // seam-versus-body delta is read off.
        let half = tone(1000, amplitude: 0.1).map { $0 * 0.5 }
        #expect(abs((mid - LoudnessMeter.rmsDBFS(half)!) - 6.0206) < 0.01)
        // No opinion about nothing.
        #expect(LoudnessMeter.rmsDBFS([]) == nil)
        #expect(LoudnessMeter.rmsDBFS([Float](repeating: 0, count: 1000)) == nil)
    }

    /// The downmix a captured tap is measured through: the mean of the
    /// channels, which is what `AVAudioConverter` hands `TrackAnalyzer` for the
    /// source files — so a tap and the analysis of the track that produced it
    /// are measured the same way and their difference means something.
    @Test func theTapDownmixIsTheMeanOfItsChannels() {
        let left: [Float] = [1, 0.5, 0, -0.5]
        let right: [Float] = [0, 0.5, 1, -0.5]
        #expect(LoudnessMeter.monoDownmix([left, right]) == [0.5, 0.5, 0.5, -0.5])
        // Mono in, the same samples out — no stray halving.
        #expect(LoudnessMeter.monoDownmix([left]) == left)
        #expect(LoudnessMeter.monoDownmix([]).isEmpty)
        // A ragged pair (a capture torn mid-buffer) is truncated, not crashed.
        #expect(LoudnessMeter.monoDownmix([left, [0, 0]]) == [0.5, 0.25])
        // Two channels of the same signal read at that signal's own level,
        // which is what makes a stereo tap comparable to a mono analysis.
        let sine = (0..<4410).map { Float(0.25 * sin(2 * .pi * 440 * Double($0) / 22050)) }
        let doubled = LoudnessMeter.monoDownmix([sine, sine])
        #expect(abs(LoudnessMeter.rmsDBFS(doubled)! - LoudnessMeter.rmsDBFS(sine)!) < 1e-6)
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

    // MARK: - The house level (`enableBodyLevel`)

    /// The shipped target is the one the struct still defaults to; the raised
    /// one is reached only through the planner config the override writes.
    @Test func theRaisedTargetIsOptInAndOnlyMovesTheTarget() {
        #expect(LoudnessCompensation.Config.standard.targetLUFS == -14)
        #expect(TransitionPlanner.Config.standard.loudnessTargetLUFS == -14)
        var overrides = AutoMixOverrides()
        overrides.enableBodyLevel = true
        let config = AutoMixDebugOverrides.plannerConfig(.standard, overrides: overrides)
        #expect(config.loudnessTargetLUFS == AutoMixDebugOverrides.bodyLevelTargetLUFS)
        #expect(config.loudnessConfig.targetLUFS == -11)
        // Everything else about the compensation is untouched: only the house
        // level moves, so the clip guard and the caps still read as they did.
        #expect(config.loudnessConfig.maxBoostDB
                == LoudnessCompensation.Config.standard.maxBoostDB)
        #expect(config.loudnessConfig.peakCeilingDBFS
                == LoudnessCompensation.Config.standard.peakCeilingDBFS)
        #expect(config.loudnessConfig.downmixPeakAllowanceDB
                == LoudnessCompensation.Config.standard.downmixPeakAllowanceDB)
    }

    /// The corpus quantiles from the doc comment on
    /// `TransitionPlanner.Config.loudnessTargetLUFS`, played back through the
    /// formula: the 157 cached analyses at their measured p10 / median / p90
    /// loudness, all with hot peaks (median +0.5 dBFS, so no boost is ever
    /// granted). The raised target is worth exactly 3 dB on every one of them,
    /// and lands the typical track inside [−3, 0] dB where −14 put it near −5.
    @Test func theRaisedTargetLiftsTypicalMaterialByThreeDecibels() {
        let raised = LoudnessCompensation.Config.targeting(
            AutoMixDebugOverrides.bodyLevelTargetLUFS)
        // (loudness LUFS, trim at −14, trim at −11) — min / p10 / median / p90.
        let corpus: [(Double, Double, Double)] = [
            (-13.3, -0.70, 0.00),   // the quietest master in the cache
            (-11.0, -3.00, 0.00),   // p10
            (-9.0, -5.00, -2.00),   // median
            (-7.1, -6.90, -3.90),   // p90
            (-5.8, -8.20, -5.20),   // the loudest master in the cache
        ]
        for (loudness, atFourteen, atEleven) in corpus {
            let track = analysis(loudness: loudness, peakDBFS: 0.5)
            #expect(abs(LoudnessCompensation.trimDB(for: track) - atFourteen) < 1e-6)
            #expect(abs(LoudnessCompensation.trimDB(for: track, config: raised)
                        - atEleven) < 1e-6)
        }
    }

    /// The property that makes raising the target safe: it can only ever make a
    /// cut *shallower*, never turn one into a boost the peak cannot pay for.
    @Test func theRaisedTargetNeverBoostsPastThePeakGuard() {
        let raised = LoudnessCompensation.Config.targeting(-11)
        // A quiet master with a hot peak — the corpus's whole quiet decile.
        // It "wants" +2.3 dB at −11 and gets none, so it plays at its own level.
        #expect(LoudnessCompensation.trimDB(for: analysis(loudness: -13.3, peakDBFS: 0.5),
                                            config: raised) == 0)
        // The same master mastered with real headroom may have its boost, and
        // only as much as the guard allows (−8 dBFS peak + 3 dB allowance
        // leaves 4 dB under the −1 ceiling, so the full 2.3 dB is granted).
        let quiet = LoudnessCompensation.trimDB(for: analysis(loudness: -13.3, peakDBFS: -8),
                                                config: raised)
        #expect(abs(quiet - 2.3) < 1e-6)
    }

    @Test func decibelsConvertToTheFaderMultiplier() {
        #expect(abs(LoudnessCompensation.gain(fromDB: 0) - 1) < 1e-6)
        #expect(abs(LoudnessCompensation.gain(fromDB: -6.0206) - 0.5) < 1e-4)
    }
}
