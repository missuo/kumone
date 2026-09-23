import Testing
@testable import KumoneCore
import Foundation

// swift-testing is used instead of XCTest because the build environment
// (Command Line Tools) ships Testing.framework but not XCTest.framework.

@Suite struct TrackAnalyzerTests {

    // MARK: - Synthetic signal generator

    /// Kick-drum train at a known BPM: short exponentially decaying 55 Hz
    /// bursts with a noise click, downbeats accented, plus a low noise floor.
    private func kickTrain(bpm: Double, seconds: Double, sampleRate sr: Double) -> [Float] {
        let n = Int(seconds * sr)
        var x = [Float](repeating: 0, count: n)

        // Deterministic noise (LCG).
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        func nextNoise() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let v = Float(Int32(truncatingIfNeeded: Int64(bitPattern: seed >> 33)))
            return v / Float(Int32.max)
        }
        for i in 0..<n { x[i] = 0.004 * nextNoise() }

        let period = 60.0 / bpm
        let kickLength = Int(0.09 * sr)
        let clickLength = Int(0.006 * sr)
        var beat = 0
        while true {
            let start = Int(Double(beat) * period * sr)
            if start >= n { break }
            let amp: Float = beat % 4 == 0 ? 1.0 : 0.6
            for s in 0..<kickLength where start + s < n {
                let t = Double(s) / sr
                let envelope = Float(exp(-t / 0.02))
                x[start + s] += amp * envelope * Float(sin(2 * .pi * 55 * t))
            }
            for s in 0..<clickLength where start + s < n {
                let envelope = Float(exp(-Double(s) / (0.002 * sr)))
                x[start + s] += 0.4 * amp * envelope * nextNoise()
            }
            beat += 1
        }
        return x
    }

    /// Fold `measured` by double/half-time to the closest match of `truth`.
    private func foldedBPMError(measured: Double, truth: Double) -> Double {
        [0.5, 1.0, 2.0].map { abs(measured * $0 - truth) }.min()!
    }

    private func assertKickTrainAnalysis(bpm: Double, sampleRate: Double) {
        let seconds = 60.0
        let samples = kickTrain(bpm: bpm, seconds: seconds, sampleRate: sampleRate)
        let analysis = TrackAnalyzer.analyze(samples: samples, sampleRate: sampleRate)

        // BPM within ±2 after double/half folding.
        let bpmError = foldedBPMError(measured: analysis.bpm, truth: bpm)
        #expect(bpmError <= 2.0,
                "BPM \(analysis.bpm) vs truth \(bpm), folded error \(bpmError)")

        #expect(analysis.bpmConfidence > 0.3,
                "confidence \(analysis.bpmConfidence) low for a clean kick train")

        // Median beat phase error < 70 ms against the true grid.
        let period = 60.0 / bpm
        let innerBeats = analysis.beats.filter { $0 > 2 && $0 < seconds - 2 }
        #expect(innerBeats.count > 20, "only \(innerBeats.count) beats tracked")
        guard !innerBeats.isEmpty else { return }
        let phaseErrors = innerBeats.map { t -> Double in
            let e = t.truncatingRemainder(dividingBy: period)
            return min(e, period - e)
        }.sorted()
        let medianPhaseError = phaseErrors[phaseErrors.count / 2]
        #expect(medianPhaseError < 0.070,
                "median beat phase error \(medianPhaseError * 1000) ms")

        // Downbeats spaced 4 beats apart.
        #expect(analysis.downbeats.count > 4)
        guard analysis.downbeats.count >= 2 else { return }
        let downbeatIntervals = zip(analysis.downbeats.dropFirst(), analysis.downbeats)
            .map { $0 - $1 }
            .sorted()
        let medianDownbeatInterval = downbeatIntervals[downbeatIntervals.count / 2]
        #expect(abs(medianDownbeatInterval - 4 * period) < 0.15,
                "median downbeat interval \(medianDownbeatInterval), expected \(4 * period)")

        // Downbeats are exactly every 4th entry of the beat grid.
        if let first = analysis.downbeats.first,
           let firstIdx = analysis.beats.firstIndex(of: first) {
            for (k, db) in analysis.downbeats.enumerated() {
                let idx = firstIdx + 4 * k
                #expect(idx < analysis.beats.count)
                guard idx < analysis.beats.count else { break }
                #expect(analysis.beats[idx] == db)
            }
        }
        print("[analyzer] truth \(bpm) BPM @\(Int(sampleRate))Hz -> measured "
              + String(format: "%.2f", analysis.bpm)
              + String(format: " (err %.2f), conf %.2f, ", bpmError, analysis.bpmConfidence)
              + String(format: "median phase err %.1f ms, ", medianPhaseError * 1000)
              + String(format: "median downbeat interval %.3f s", medianDownbeatInterval))
    }

    // MARK: - BPM regression

    @Test func kickTrain100BPM() {
        assertKickTrainAnalysis(bpm: 100, sampleRate: 22_050)
    }

    @Test func kickTrain120BPMAt44100() {
        // 44.1 kHz input exercises the resampling path.
        assertKickTrainAnalysis(bpm: 120, sampleRate: 44_100)
    }

    @Test func kickTrain128BPM() {
        assertKickTrainAnalysis(bpm: 128, sampleRate: 22_050)
    }

    // MARK: - Structure features

    @Test func introEndAndEnvelopeOnKickTrain() {
        let samples = kickTrain(bpm: 120, seconds: 60, sampleRate: 22_050)
        let analysis = TrackAnalyzer.analyze(samples: samples, sampleRate: 22_050)
        #expect(analysis.rmsEnvelope.count == 60)
        #expect(abs(analysis.duration - 60) < 0.1)
        #expect(analysis.introEnd >= 0)
        #expect(analysis.introEnd < 10)
        #expect(analysis.version == TrackAnalysis.currentVersion)
    }

    @Test func outroFadeDetected() throws {
        // Steady tone that fades linearly to silence over the last 20 s.
        let sr = 22_050.0
        let seconds = 60.0
        let n = Int(seconds * sr)
        var x = [Float](repeating: 0, count: n)
        let fadeStart = 40.0
        for i in 0..<n {
            let t = Double(i) / sr
            var gain = 1.0
            if t > fadeStart { gain = max(0, 1 - (t - fadeStart) / 20) }
            x[i] = Float(0.5 * gain * sin(2 * .pi * 220 * t))
        }
        let analysis = TrackAnalyzer.analyze(samples: x, sampleRate: sr)
        let outro = try #require(analysis.outroFadeStart)
        #expect(abs(outro - fadeStart) <= 5, "outro detected at \(outro)")
    }

    // MARK: - Edge cases

    @Test func silenceDoesNotCrashAndHasLowConfidence() {
        let silence = [Float](repeating: 0, count: Int(30 * 22_050))
        let analysis = TrackAnalyzer.analyze(samples: silence, sampleRate: 22_050)
        #expect(analysis.bpmConfidence < 0.3)
        #expect(analysis.beats.isEmpty)
        #expect(analysis.downbeats.isEmpty)
        #expect(analysis.outroFadeStart == nil)
    }

    @Test func veryShortInputDoesNotCrash() {
        for seconds in [0.01, 1.0, 3.0] {
            let samples = kickTrain(bpm: 120, seconds: seconds, sampleRate: 22_050)
            let analysis = TrackAnalyzer.analyze(samples: samples, sampleRate: 22_050)
            #expect(analysis.version == TrackAnalysis.currentVersion)
            #expect(abs(analysis.duration - seconds) < 0.2)
        }
    }

    @Test func emptyInput() {
        let analysis = TrackAnalyzer.analyze(samples: [], sampleRate: 22_050)
        #expect(analysis.bpmConfidence == 0)
        #expect(analysis.beats.isEmpty)
    }

    // MARK: - Key detection

    /// Deterministic LCG noise source.
    private func makeNoise(seed: UInt64) -> () -> Float {
        var state = seed
        return {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let v = Float(Int32(truncatingIfNeeded: Int64(bitPattern: state >> 33)))
            return v / Float(Int32.max)
        }
    }

    /// Plucked arpeggio over the given MIDI notes, five harmonics per note.
    private func arpeggio(
        midiNotes: [Int], seconds: Double, sampleRate sr: Double
    ) -> [Float] {
        let n = Int(seconds * sr)
        var x = [Float](repeating: 0, count: n)
        let noise = makeNoise(seed: 0x1234_5678_9ABC_DEF0)
        for i in 0..<n { x[i] = 0.001 * noise() }

        let noteSamples = Int(0.5 * sr)
        var idx = 0
        var step = 0
        while idx < n {
            let midi = midiNotes[step % midiNotes.count]
            let f0 = 440.0 * pow(2.0, (Double(midi) - 69) / 12)
            for s in 0..<noteSamples where idx + s < n {
                let t = Double(s) / sr
                let env = exp(-t / 0.35) * (1 - exp(-t / 0.005))
                var v = 0.0
                for h in 1...5 {
                    let f = f0 * Double(h)
                    if f > 8000 { break }
                    v += (1.0 / Double(h)) * sin(2 * .pi * f * t)
                }
                x[idx + s] += Float(0.25 * env * v)
            }
            idx += noteSamples
            step += 1
        }
        return x
    }

    private func whiteNoise(seconds: Double, sampleRate sr: Double) -> [Float] {
        let n = Int(seconds * sr)
        let noise = makeNoise(seed: 0xDEAD_BEEF_CAFE_1234)
        return (0..<n).map { _ in 0.3 * noise() }
    }

    @Test func detectsCMajorFromArpeggio() {
        // C4-E4-G4-C5 arpeggio: pitch classes C, E, G.
        let x = arpeggio(
            midiNotes: [60, 64, 67, 72, 67, 64, 60, 55],
            seconds: 40, sampleRate: 22_050)
        let a = TrackAnalyzer.analyze(samples: x, sampleRate: 22_050)
        #expect(a.keyPitchClass == 0, "expected C, got \(String(describing: a.keyPitchClass))")
        #expect(!a.keyIsMinor)
        #expect(a.keyConfidence > 0.4, "confidence \(a.keyConfidence)")
        #expect(a.keyConfidence <= 1)
    }

    @Test func detectsAMinorFromArpeggio() {
        // A3-C4-E4-A4: pitch classes A, C, E.
        let x = arpeggio(
            midiNotes: [57, 60, 64, 69, 64, 60, 57, 52],
            seconds: 40, sampleRate: 22_050)
        let a = TrackAnalyzer.analyze(samples: x, sampleRate: 22_050)
        #expect(a.keyPitchClass == 9, "expected A, got \(String(describing: a.keyPitchClass))")
        #expect(a.keyIsMinor)
        #expect(a.keyConfidence > 0.4, "confidence \(a.keyConfidence)")
    }

    @Test func whiteNoiseHasNoKey() {
        let a = TrackAnalyzer.analyze(
            samples: whiteNoise(seconds: 40, sampleRate: 22_050), sampleRate: 22_050)
        #expect(a.keyPitchClass == nil)
        #expect(a.keyConfidence == 0)
    }

    @Test func keyIsTranspositionEquivariant() {
        // The same arpeggio a whole tone up must come out as D major.
        let x = arpeggio(
            midiNotes: [62, 66, 69, 74, 69, 66, 62, 57],
            seconds: 40, sampleRate: 22_050)
        let a = TrackAnalyzer.analyze(samples: x, sampleRate: 22_050)
        #expect(a.keyPitchClass == 2, "expected D, got \(String(describing: a.keyPitchClass))")
        #expect(!a.keyIsMinor)
    }

    @Test func silenceHasNoKeyAndNoVocals() {
        let silence = [Float](repeating: 0, count: Int(30 * 22_050))
        let a = TrackAnalyzer.analyze(samples: silence, sampleRate: 22_050)
        #expect(a.keyPitchClass == nil)
        #expect(a.keyConfidence == 0)
        #expect(a.vocalActivity.count == a.rmsEnvelope.count)
        #expect(a.vocalActivity.allSatisfy { $0 == 0 })
    }

    // MARK: - Timbre fingerprint

    /// Cosine distance, the same number `TransitionPlanner` gates on.
    private func timbreDistance(_ a: [Float], _ b: [Float]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        return Double(max(0, 1 - zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }))
    }

    @Test func timbreProfileIsUnitNormAndLevelFree() throws {
        let a = TrackAnalyzer.analyze(
            samples: kickTrain(bpm: 120, seconds: 40, sampleRate: 22_050),
            sampleRate: 22_050)
        #expect(a.melProfile.count == 40)
        // Each frame's own across-band mean is removed, so the profile is a
        // pure shape: it sums to zero and carries unit length.
        let sum = a.melProfile.reduce(Float(0), +)
        #expect(abs(sum) < 1e-3, "profile sum \(sum)")
        let norm = a.melProfile.reduce(Float(0)) { $0 + $1 * $1 }
        #expect(abs(norm - 1) < 1e-4, "profile squared norm \(norm)")
    }

    @Test func timbreDistanceSeparatesDifferentSpectra() {
        let sr = 22_050.0
        let noise = TrackAnalyzer.analyze(
            samples: whiteNoise(seconds: 40, sampleRate: sr), sampleRate: sr)
        let tones = TrackAnalyzer.analyze(
            samples: arpeggio(midiNotes: [60, 64, 67, 72], seconds: 40, sampleRate: sr),
            sampleRate: sr)
        let kicks = TrackAnalyzer.analyze(
            samples: kickTrain(bpm: 120, seconds: 40, sampleRate: sr), sampleRate: sr)

        // A mid-range harmonic stack against flat noise or a bass-heavy kick
        // train: opposite spectral shapes, comfortably past the clash line.
        let noiseTones = timbreDistance(noise.melProfile, tones.melProfile)
        let tonesKicks = timbreDistance(tones.melProfile, kicks.melProfile)
        #expect(noiseTones > TransitionPlanner.clashTimbreDistance, "noise/tones \(noiseTones)")
        #expect(tonesKicks > TransitionPlanner.clashTimbreDistance, "tones/kicks \(tonesKicks)")
        // Noise against kicks is the near pair — the kick train carries a
        // noise floor and broadband clicks. Assert a fixed sanity floor
        // rather than the tunable neutral line (which was recalibrated to
        // real-corpus percentiles): the point is that the fingerprint
        // separates them at all, where the old one put every pair below 0.04.
        let noiseKicks = timbreDistance(noise.melProfile, kicks.melProfile)
        #expect(noiseKicks > 0.2, "noise/kicks \(noiseKicks)")
        print(String(format: "[timbre] noise/tones %.3f, tones/kicks %.3f, noise/kicks %.3f",
                     noiseTones, tonesKicks, noiseKicks))
    }

    @Test func timbreDistanceIgnoresLevelAndTempo() {
        let sr = 22_050.0
        let loud = TrackAnalyzer.analyze(
            samples: kickTrain(bpm: 120, seconds: 40, sampleRate: sr), sampleRate: sr)
        let quiet = TrackAnalyzer.analyze(
            samples: kickTrain(bpm: 120, seconds: 40, sampleRate: sr).map { $0 * 0.05 },
            sampleRate: sr)
        let faster = TrackAnalyzer.analyze(
            samples: kickTrain(bpm: 150, seconds: 40, sampleRate: sr), sampleRate: sr)

        // 26 dB quieter, same instrument: the fingerprint must not move.
        let levelDistance = timbreDistance(loud.melProfile, quiet.melProfile)
        #expect(levelDistance < 0.01, "level distance \(levelDistance)")
        // Same instrument at another tempo stays comfortably compatible —
        // tempo has its own signal and must not leak into this one.
        let tempoDistance = timbreDistance(loud.melProfile, faster.melProfile)
        #expect(tempoDistance < TransitionPlanner.neutralTimbreDistance,
                "tempo distance \(tempoDistance)")
        print(String(format: "[timbre] level %.4f, tempo %.4f",
                     levelDistance, tempoDistance))
    }

    @Test func timbreProfileEmptyForUnusableInput() {
        #expect(TrackAnalyzer.analyze(samples: [], sampleRate: 22_050).melProfile.isEmpty)
        let silence = [Float](repeating: 0, count: Int(30 * 22_050))
        let a = TrackAnalyzer.analyze(samples: silence, sampleRate: 22_050)
        // Digital silence has no shape at all; either an empty profile or a
        // zero-sum one is fine, but it must never claim a timbre.
        #expect(a.melProfile.isEmpty || abs(a.melProfile.reduce(0, +)) < 1e-3)
    }

    // MARK: - Vocal activity

    /// 220 Hz "voice": formant-weighted harmonics to ~3.4 kHz, 5 Hz vibrato
    /// and a 4 Hz syllable envelope.
    private func vocalLike(seconds: Double, sampleRate sr: Double) -> [Float] {
        let n = Int(seconds * sr)
        var x = [Float](repeating: 0, count: n)
        var phase = [Double](repeating: 0, count: 12)
        let f0 = 220.0
        for i in 0..<n {
            let t = Double(i) / sr
            let vibrato = 1 + 0.03 * sin(2 * .pi * 5 * t)
            let syllable = 0.5 + 0.5 * pow(max(0, sin(2 * .pi * 4 * t)), 2)
            var v = 0.0
            for h in 1...12 {
                let f = f0 * Double(h) * vibrato
                if f > 3400 { break }
                phase[h - 1] += 2 * .pi * f / sr
                let weight = 1.0 / (1 + pow((f - 900) / 900, 2))
                v += weight * sin(phase[h - 1])
            }
            x[i] = Float(0.3 * syllable * v)
        }
        return x
    }

    /// Plucked 80 Hz bass line; its only harmonic (160 Hz) also stays below
    /// the 200 Hz vocal band edge.
    private func bassLine(seconds: Double, sampleRate sr: Double) -> [Float] {
        let n = Int(seconds * sr)
        var x = [Float](repeating: 0, count: n)
        let noteSamples = Int(0.5 * sr)
        var idx = 0
        while idx < n {
            for s in 0..<noteSamples where idx + s < n {
                let t = Double(s) / sr
                let env = exp(-t / 0.25) * (1 - exp(-t / 0.004))
                let v = sin(2 * .pi * 80 * t) + 0.3 * sin(2 * .pi * 160 * t)
                x[idx + s] += Float(0.4 * env * v)
            }
            idx += noteSamples
        }
        return x
    }

    private func meanVocalActivity(_ a: TrackAnalysis) -> Float {
        guard !a.vocalActivity.isEmpty else { return 0 }
        return a.vocalActivity.reduce(0, +) / Float(a.vocalActivity.count)
    }

    @Test func vocalActivityRanksVoiceAboveBassAndNoise() {
        let sr = 22_050.0
        let voice = TrackAnalyzer.analyze(
            samples: vocalLike(seconds: 40, sampleRate: sr), sampleRate: sr)
        let bass = TrackAnalyzer.analyze(
            samples: bassLine(seconds: 40, sampleRate: sr), sampleRate: sr)
        let noise = TrackAnalyzer.analyze(
            samples: whiteNoise(seconds: 40, sampleRate: sr), sampleRate: sr)

        let vVoice = meanVocalActivity(voice)
        let vBass = meanVocalActivity(bass)
        let vNoise = meanVocalActivity(noise)

        #expect(vVoice > 0.6, "voice score \(vVoice)")
        #expect(vBass < 0.25, "bass score \(vBass)")
        #expect(vNoise < 0.25, "noise score \(vNoise)")
        #expect(vVoice > vBass + 0.4)
        #expect(vVoice > vNoise + 0.4)

        print(String(format: "[vad] voice %.3f, bass %.3f, noise %.3f",
                     vVoice, vBass, vNoise))
    }

    @Test func vocalActivityMatchesEnvelopeGrid() {
        let sr = 22_050.0
        for seconds in [31.0, 45.5] {
            let a = TrackAnalyzer.analyze(
                samples: vocalLike(seconds: seconds, sampleRate: sr), sampleRate: sr)
            #expect(a.vocalActivity.count == a.rmsEnvelope.count,
                    "\(a.vocalActivity.count) vs \(a.rmsEnvelope.count) at \(seconds)s")
            #expect(a.vocalActivity.allSatisfy { $0 >= 0 && $0 <= 1 })
        }
    }

    @Test func vocalActivityIsZeroInSilentSections() {
        // 20 s of voice, then 20 s of silence.
        let sr = 22_050.0
        var x = vocalLike(seconds: 20, sampleRate: sr)
        x.append(contentsOf: [Float](repeating: 0, count: Int(20 * sr)))
        let a = TrackAnalyzer.analyze(samples: x, sampleRate: sr)
        #expect(a.vocalActivity.count == a.rmsEnvelope.count)
        let head = a.vocalActivity.prefix(18)
        let tail = a.vocalActivity.suffix(15)
        #expect(head.allSatisfy { $0 > 0.5 }, "head \(Array(head))")
        #expect(tail.allSatisfy { $0 < 0.1 }, "tail \(Array(tail))")
    }

    // MARK: - v5 cue: stereo mid/side centre share

    /// A pure tone at `hz`.
    private func tone(_ hz: Double, seconds: Double, sampleRate sr: Double,
                      amplitude: Float = 0.5) -> [Float] {
        let n = Int(seconds * sr)
        return (0..<n).map { Float(Double(amplitude) * sin(2 * .pi * hz * Double($0) / sr)) }
    }

    /// Mid/side energy: a centred vocal-band tone (L = R) reads as fully
    /// centred; the same tone panned to pure side (L = −R) reads as fully wide.
    @Test func midShareSeparatesCentredFromSide() {
        let sr = 22_050.0
        let l = tone(1_000, seconds: 2, sampleRate: sr)

        // Centred: L = R → mid = L, side = 0.
        let centredMid = l
        let centredSide = [Float](repeating: 0, count: l.count)
        let cMidE = TrackAnalyzer.voiceBandEnergyPerFrame(centredMid, sampleRate: sr)
        let cSideE = TrackAnalyzer.voiceBandEnergyPerFrame(centredSide, sampleRate: sr)
        let cShare = TrackAnalyzer.midSharePerFrame(
            mid: cMidE, side: cSideE, frames: cMidE.count)
        let cMean = cShare.reduce(0, +) / Float(cShare.count)
        #expect(cMean > 0.95, "centred mid-share \(cMean)")

        // Pure side: L = −R → mid = 0, side = L.
        let sideMid = [Float](repeating: 0, count: l.count)
        let sideSide = l
        let sMidE = TrackAnalyzer.voiceBandEnergyPerFrame(sideMid, sampleRate: sr)
        let sSideE = TrackAnalyzer.voiceBandEnergyPerFrame(sideSide, sampleRate: sr)
        let sShare = TrackAnalyzer.midSharePerFrame(
            mid: sMidE, side: sSideE, frames: sMidE.count)
        let sMean = sShare.reduce(0, +) / Float(sShare.count)
        #expect(sMean < 0.05, "pure-side mid-share \(sMean)")
    }

    /// The stereo-centre cue lifts a marginal, centred vocal-band second and
    /// leaves a wide one untouched — the fusion's intended effect.
    @Test func midShareLiftsCentredVocalSecond() {
        let fps = TrackAnalyzer.analysisSampleRate / Double(TrackAnalyzer.hopSize)
        let framesPerSec = Int(fps)
        let seconds = 6
        let n = framesPerSec * seconds

        // A middling mono second: some band energy, moderately tonal — enough
        // to pass the presence gate but not saturate on its own.
        let bandRatio = [Float](repeating: 0.45, count: n)
        let flatness = [Float](repeating: 0.45, count: n)
        let bandEnvelope = [Float](repeating: 1.0, count: n)
        let rms = [Float](repeating: 1.0, count: seconds)

        func score(mid: [Float]?) -> Float {
            let v = TrackAnalyzer.vocalActivity(
                bandRatio: bandRatio, flatness: flatness, bandEnvelope: bandEnvelope,
                midShare: mid, fps: fps, rmsEnvelope: rms)
            return v.reduce(0, +) / Float(v.count)
        }

        let centred = score(mid: [Float](repeating: 0.95, count: n))
        let wide = score(mid: [Float](repeating: 0.50, count: n))
        let mono = score(mid: nil)

        #expect(centred > wide + 0.05, "centred \(centred) vs wide \(wide)")
        #expect(wide <= mono + 0.001, "wide \(wide) should not exceed mono \(mono)")
    }
}
