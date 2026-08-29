import AVFoundation
import Foundation
import Testing

@testable import KumoneCore

// The stem layer, pinned without a model.
//
// `StemTechniqueLayer` takes its vocal stem from an injected closure, so the
// recipes can be tested against a *synthetic* separation whose ground truth is
// exact: a "vocal" of harmonic sine partials plus an "accompaniment" of noise,
// summed into the source file. A stub provider hands back the vocal it knows
// is there, and the assertions are about what the technique does to it — which
// is the part that has to be right. Whether the RoFormer finds that vocal in a
// real mixture is StemKit's problem, and `stemtool`'s.
@Suite struct StemTechniqueTests {

    // MARK: - Contract

    /// The whole point of the default: every style that existed before stems
    /// still means exactly what it meant.
    @Test func styleDefaultsToNoStemTechnique() {
        #expect(TransitionStyle.plain.stemTechnique == nil)
        #expect(TransitionStyle(outroEffect: .filterSweep, stagedEQ: true).stemTechnique == nil)
        #expect(TransitionStyle(outroEffect: .echoOut, stagedEQ: false,
                                echoDelayTime: 0.37).stemTechnique == nil)
        // …and adding the field did not disturb equality of the old ones.
        #expect(TransitionStyle(outroEffect: .fade, stagedEQ: false) == .plain)
        var stemmed = TransitionStyle.plain
        stemmed.stemTechnique = .vocalDuck(depthDB: -9)
        #expect(stemmed != .plain)
    }

    @Test func stemOverrideParsing() {
        #expect(Audition.StemOverride.parse("acapella") == .acapella)
        #expect(Audition.StemOverride.parse("instrumental") == .instrumental)
        #expect(Audition.StemOverride.parse("duck")
                == .duck(depthDB: Audition.StemOverride.defaultDuckDepthDB))
        // Nobody means "boost the vocal 9 dB", so either spelling attenuates.
        #expect(Audition.StemOverride.parse("duck:6") == .duck(depthDB: -6))
        #expect(Audition.StemOverride.parse("duck:-6") == .duck(depthDB: -6))
        #expect(Audition.StemOverride.parse("stagedStemSwap") == nil)
        #expect(Audition.StemOverride.parse("duck:loud") == nil)
    }

    @Test func techniqueLabelsAreStable() {
        #expect(StemTechnique.acapellaOver.label == "acapellaOver")
        #expect(StemTechnique.instrumentalOut.label == "instrumentalOut")
        #expect(StemTechnique.vocalDuck(depthDB: -9).label == "vocalDuck(-9.0dB)")
    }

    // MARK: - Gain curves

    private let crossfade = TransitionPlan.crossfade(duration: 8, outPoint: 60, inPoint: 0)

    private func envelopes(_ technique: StemTechnique, frames: Int = 8 * 44_100)
        -> (vocal: [Float], accompaniment: [Float]) {
        StemTechniqueLayer.envelopes(
            technique, frames: frames, sampleRate: 44_100, rate: 1,
            plan: crossfade, style: .plain,
            geometry: TransitionAutomation.Geometry(plan: crossfade))
    }

    /// S1's `B_vocalduck`: the vocal sits `depthDB` down for the whole overlap
    /// and the accompaniment is untouched — the crossfade does the rest.
    @Test func vocalDuckHoldsOneLevel() {
        let g = envelopes(.vocalDuck(depthDB: -9))
        let target = pow(10, Float(-9) / 20)
        #expect(abs(g.vocal[0] - 1) < 0.02)            // starts at the mix level
        for fraction in [0.2, 0.5, 0.9] {
            let i = Int(Double(g.vocal.count - 1) * fraction)
            #expect(abs(g.vocal[i] - target) < 0.001)
            #expect(abs(g.accompaniment[i] - 1) < 0.001)
        }
    }

    /// S1's `B_instrumental_out`: the vocal is gone 12 % into the overlap.
    @Test func instrumentalOutWipesTheVocalEarly() {
        let g = envelopes(.instrumentalOut)
        let at = { (f: Double) in g.vocal[Int(Double(g.vocal.count - 1) * f)] }
        #expect(at(0) > 0.98)
        #expect(at(0.06) < 0.7 && at(0.06) > 0.3)      // mid-ramp
        #expect(at(0.13) < 0.02)
        #expect(at(0.5) < 0.001)
        #expect(g.accompaniment.allSatisfy { abs($0 - 1) < 0.001 })
    }

    /// S1's `B_acapella`: the accompaniment is gone by 28 %, the vocal holds
    /// until 72 % and has retired by 96 %.
    @Test func acapellaOverDropsTheBedThenTheVocal() {
        let g = envelopes(.acapellaOver)
        let inst = { (f: Double) in g.accompaniment[Int(Double(g.vocal.count - 1) * f)] }
        let voc = { (f: Double) in g.vocal[Int(Double(g.vocal.count - 1) * f)] }
        #expect(inst(0) > 0.98)
        #expect(inst(0.29) < 0.01)
        #expect(voc(0.99) < 0.05)
        // The vocal is exempted from the outgoing fade, so its stem gain rises
        // as the fader falls — that is the technique, not a bug.
        #expect(voc(0.5) > 1)
        #expect(g.vocal.allSatisfy { $0 <= StemTechniqueLayer.acapellaGainCeiling + 0.001 })
    }

    // MARK: - High-pass

    /// The acapella's 100 Hz high-pass has to remove low end without phase-
    /// smearing the vocal (it is summed back against unfiltered material), so
    /// it runs forwards and backwards.
    @Test func highPassRemovesLowEndAndKeepsMids() {
        func tone(_ hz: Double) -> [Float] {
            (0..<44_100).map { Float(sin(2 * .pi * hz * Double($0) / 44_100)) }
        }
        func rms(_ x: [Float]) -> Double {
            (x.reduce(0.0) { $0 + Double($1 * $1) } / Double(x.count)).squareRoot()
        }
        // Ignore the settling edges; a filtfilt's interior is what matters.
        func interior(_ x: [Float]) -> [Float] { Array(x[4_410..<39_690]) }

        let low = StemTechniqueLayer.zeroPhaseHighPass(tone(40), cutoff: 100,
                                                       sampleRate: 44_100)
        let mid = StemTechniqueLayer.zeroPhaseHighPass(tone(1_000), cutoff: 100,
                                                       sampleRate: 44_100)
        #expect(rms(interior(low)) < 0.12)              // ≥ 18 dB down at 40 Hz
        #expect(abs(rms(interior(mid)) - rms(interior(tone(1_000)))) < 0.02)
    }

    // MARK: - End to end, against a synthetic separation

    /// A 44.1 kHz stereo file whose content is known exactly: `vocal` is a
    /// three-partial sine stack from 220 Hz, `bed` is band-unremarkable noise.
    private struct Synthetic {
        let url: URL
        let vocal: [Float]
        let frames: Int
    }

    private func makeSynthetic(seconds: Double = 40) throws -> Synthetic {
        let sampleRate = 44_100.0
        let frames = Int(seconds * sampleRate)
        var generator = SystemRandomNumberGenerator()
        var vocal = [Float](repeating: 0, count: frames)
        var mixture = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            let t = Double(i) / sampleRate
            let v = Float(0.25 * (sin(2 * .pi * 220 * t)
                                  + 0.5 * sin(2 * .pi * 440 * t)
                                  + 0.25 * sin(2 * .pi * 880 * t)))
            vocal[i] = v
            mixture[i] = v + Float.random(in: -0.15...0.15, using: &generator)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stem-synth-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                      frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<2 {
            mixture.withUnsafeBufferPointer {
                buffer.floatChannelData![channel].update(from: $0.baseAddress!, count: frames)
            }
        }
        try file.write(from: buffer)
        return Synthetic(url: url, vocal: vocal, frames: frames)
    }

    /// A provider that "separates" by reading the ground-truth vocal back out
    /// of the window it is handed — the exact stem, so the assertions are
    /// about the recipe rather than about separation quality.
    private func stubProvider(_ synthetic: Synthetic) -> VocalStemProvider {
        let vocal = synthetic.vocal
        return { request in
            let start = Int((request.start * request.sampleRate).rounded())
            let count = request.samples[0].count
            let slice = (0..<count).map { i -> Float in
                let index = start + i
                return index < vocal.count ? vocal[index] : 0
            }
            return VocalStem(channels: request.samples.map { _ in slice }, cached: false)
        }
    }

    /// Energy in a 1/3-octave band around `hz`, by Goertzel-ish correlation.
    private func bandEnergy(_ url: URL, from: TimeInterval, seconds: TimeInterval,
                            hz: Double) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        file.framePosition = AVAudioFramePosition(from * rate)
        let count = AVAudioFrameCount(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                      frameCapacity: count)!
        try file.read(into: buffer, frameCount: count)
        let frames = Int(buffer.frameLength)
        let samples = buffer.floatChannelData![0]
        var real = 0.0, imaginary = 0.0
        for i in 0..<frames {
            let phase = 2 * Double.pi * hz * Double(i) / rate
            real += Double(samples[i]) * cos(phase)
            imaginary += Double(samples[i]) * sin(phase)
        }
        return (real * real + imaginary * imaginary).squareRoot() / Double(max(frames, 1))
    }

    private func render(_ technique: StemTechnique?, _ synthetic: Synthetic,
                        provider: VocalStemProvider?) throws
        -> OfflineTransitionRenderer.Result {
        var style = TransitionStyle.plain
        style.stemTechnique = technique
        let plan = TransitionPlan.crossfade(duration: 8, outPoint: 20, inPoint: 0)
        var options = OfflineTransitionRenderer.Options()
        options.preRoll = 4
        options.postRoll = 4
        options.vocalStemProvider = provider
        // These tests compare absolute band energy *between* two renders, so the
        // blind-test output normalization has to be off: it deliberately scales
        // each file to the same loudness, which is precisely the level
        // difference a duck is supposed to produce.
        options.normalizeToLUFS = nil
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("stem-render-\(UUID().uuidString).wav")
        return try OfflineTransitionRenderer.render(
            PlannedTransition(plan: plan, style: style),
            outgoing: synthetic.url, incoming: synthetic.url,
            to: output, options: options)
    }

    /// The renderer's stem path end to end: a duck really does pull the
    /// outgoing vocal down inside the overlap, and leaves the pre-roll alone.
    @Test func duckingLowersTheVocalBandInsideTheOverlapOnly() throws {
        let synthetic = try makeSynthetic()
        defer { try? FileManager.default.removeItem(at: synthetic.url) }

        let plain = try render(nil, synthetic, provider: nil)
        let ducked = try render(.vocalDuck(depthDB: -12), synthetic,
                                provider: stubProvider(synthetic))
        defer {
            try? FileManager.default.removeItem(at: plain.outputURL)
            try? FileManager.default.removeItem(at: ducked.outputURL)
        }

        #expect(ducked.stemTechnique == "vocalDuck(-12.0dB)")
        #expect(ducked.stemFallbackReason == nil)
        #expect(abs(ducked.duration - plain.duration) < 0.05)

        // Pre-roll is untouched: the buffer is only rewritten from the overlap on.
        let preRollPlain = try bandEnergy(plain.outputURL, from: 1, seconds: 2, hz: 220)
        let preRollDucked = try bandEnergy(ducked.outputURL, from: 1, seconds: 2, hz: 220)
        #expect(abs(preRollPlain - preRollDucked) / max(preRollPlain, 1e-9) < 0.05)

        // Inside the overlap the 220 Hz fundamental is measurably weaker.
        // (Both decks carry the same track here, so the incoming one keeps some
        // of it — the point is the direction and that it is not marginal.)
        let start = plain.overlapStart + 1
        let overlapPlain = try bandEnergy(plain.outputURL, from: start, seconds: 3, hz: 220)
        let overlapDucked = try bandEnergy(ducked.outputURL, from: start, seconds: 3, hz: 220)
        #expect(overlapDucked < overlapPlain * 0.85)
    }

    /// No provider, no silent surprise: the render still happens, still
    /// sounds like the old whole-mix one, and says why.
    @Test func missingProviderDegradesAndExplainsItself() throws {
        let synthetic = try makeSynthetic(seconds: 40)
        defer { try? FileManager.default.removeItem(at: synthetic.url) }
        let result = try render(.acapellaOver, synthetic, provider: nil)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        #expect(result.stemTechnique == nil)
        #expect(result.stemFallbackReason?.contains("stem separator") == true)
        #expect(result.duration > 0)
    }

    /// A provider that throws (no model, no network, a cancelled run) is a
    /// degradation, not a render failure.
    @Test func failingProviderDegrades() throws {
        struct Boom: LocalizedError {
            var errorDescription: String? { "the checkpoint could not be loaded" }
        }
        let synthetic = try makeSynthetic()
        defer { try? FileManager.default.removeItem(at: synthetic.url) }
        let result = try render(.instrumentalOut, synthetic, provider: { _ in throw Boom() })
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        #expect(result.stemTechnique == nil)
        #expect(result.stemFallbackReason == "the checkpoint could not be loaded")
    }

    /// A provider returning the wrong shape must not be trusted into the mix.
    @Test func mismatchedStemShapeDegrades() throws {
        let synthetic = try makeSynthetic()
        defer { try? FileManager.default.removeItem(at: synthetic.url) }
        let result = try render(.vocalDuck(depthDB: -9), synthetic,
                                provider: { _ in VocalStem(channels: [[0, 0, 0]]) })
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        #expect(result.stemTechnique == nil)
        #expect(result.stemFallbackReason?.contains("expected") == true)
    }
}
