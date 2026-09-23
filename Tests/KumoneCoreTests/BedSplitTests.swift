import AVFoundation
import Foundation
import Testing

@testable import KumoneCore

// The four-lane bed: its curves, its cache, and — the load-bearing half — that
// every path through it collapses back onto the two-lane one when there is no
// four-stem model, sample for sample rather than approximately.

@Suite("Four-lane bed split")
struct BedSplitTests {

    // MARK: - The gesture's curves

    /// A bed long enough to say all three things: 8 bars of 2 s each, the
    /// singer joining at the end, the plan swapping the bass a third of the
    /// way in.
    private func split(landing: TimeInterval = 16, overlap: TimeInterval = 16,
                       bar: TimeInterval = 2, bassSwap: TimeInterval = 6)
        -> StemEnvelope.BedSplit? {
        ScoreCompiler.bedSplit(landing: landing, overlap: overlap,
                               bar: bar, bassSwap: bassSwap)
    }

    @Test("drums play from the top, and say so by saying nothing")
    func drumsAreUnity() throws {
        let bed = try #require(split())
        // An empty lane is unity, and unity is "whatever the bed lane was going
        // to do here" — which is exactly what the layer that enters first wants.
        #expect(bed.drums.isEmpty)
        for t in stride(from: 0.0, through: 16.0, by: 0.5) {
            #expect(bed.gain(.drums, at: t) == 1)
        }
    }

    @Test("the bass arrives on the plan's own swap point, not before")
    func bassLandsOnTheSwap() throws {
        let bed = try #require(split(bassSwap: 6))
        // Held all the way down until the ramp starts…
        #expect(bed.gain(.bass, at: 0) < 0.002)
        #expect(bed.gain(.bass, at: 5.5) < 0.002)
        // …and at unity from the swap point on. Two basslines under one another
        // is the thing this whole lane exists to prevent, so "before the swap"
        // being inaudible is the assertion, not the ramp's shape.
        #expect(bed.gain(.bass, at: 6) == 1)
        #expect(bed.gain(.bass, at: 12) == 1)
    }

    @Test("the harmony swells over the last two bars and arrives with the singer")
    func otherSwellsIn() throws {
        let bed = try #require(split(landing: 16, bar: 2))
        #expect(bed.gain(.other, at: 0) < 0.002)
        // Two bars = 4 s before the landing.
        #expect(bed.gain(.other, at: 11.9) < 0.002)
        #expect(bed.gain(.other, at: 14) > bed.gain(.other, at: 12.5))
        #expect(bed.gain(.other, at: 16) == 1)
    }

    @Test("a bed with no room for three entrances asks for one")
    func refusesWhenTooShort() {
        // Landing inside the swell the gesture wants: three curves nobody could
        // hear apart, so the compiler writes none and the bed plays whole.
        #expect(split(landing: 3, overlap: 8, bar: 2, bassSwap: 1) == nil)
        // A swap at or past the singer's entrance is not a bass entrance.
        #expect(split(landing: 16, bassSwap: 16) == nil)
    }

    @Test("an envelope without a split is byte-identical to what it always was")
    func nilSplitChangesNothing() {
        var envelope = StemEnvelope()
        envelope.incomingVocal = [.init(t: 0, gainDB: -60), .init(t: 4, gainDB: 0)]
        let signature = envelope.signature
        #expect(!envelope.hasIncomingBedSplit)

        // A split whose lanes are all pass-through renders identically, so it
        // must not move the render filename either.
        envelope.incomingBedSplit = StemEnvelope.BedSplit()
        #expect(!envelope.hasIncomingBedSplit)
        #expect(envelope.signature == signature)

        envelope.incomingBedSplit = split()
        #expect(envelope.hasIncomingBedSplit)
        #expect(envelope.signature != signature)
    }

    @Test("bed sub-lanes are validated like every other lane")
    func validation() {
        var envelope = StemEnvelope()
        envelope.incomingBedSplit = StemEnvelope.BedSplit(
            bass: [.init(t: 0, gainDB: -60), .init(t: 99, gainDB: 0)])
        #expect(throws: StemEnvelope.ValidationFailure.self) {
            try envelope.validate(overlap: 10)
        }
    }

    // MARK: - What it costs the pre-render

    @Test("a four-lane bed is charged the Metal time it actually takes")
    func runwayKnowsAboutFourLanes() {
        let twoLane = PlayerService.stemPrerenderRunway(
            overlapDuration: 12, separatesStems: true, sides: 1)
        let fourLane = PlayerService.stemPrerenderRunway(
            overlapDuration: 12, separatesStems: true, sides: 1, fourLane: true)
        // The four-stem checkpoint runs a 12 s window in 21.7 s on an M4
        // against the vocals model's 5.5 s. A runway that charged them alike
        // would start renders that get abandoned at the guard with the time
        // already spent.
        #expect(fourLane > twoLane + 11)
        // A score-only segment separates nothing and is unaffected either way.
        #expect(PlayerService.stemPrerenderRunway(overlapDuration: 12, separatesStems: false)
                == PlayerService.stemPrerenderRunway(overlapDuration: 12, separatesStems: false,
                                                     sides: 1, fourLane: true))
    }

    // MARK: - The cache

    @Test("four-lane sidecars are their own generation, and v1 still hits")
    func cacheLayout() {
        let source = URL(fileURLWithPath: "/tmp/song.mp3")
        let vocalOnly = VocalStemCache.cacheURL(for: VocalStemRequest(
            source: source, start: 12.5, duration: 8, sampleRate: 44_100, samples: [[]]))
        #expect(vocalOnly.lastPathComponent == "song.mp3.stems-v1-12500-8000.caf")

        let request = StemRequest(source: source, start: 12.5, duration: 8,
                                  sampleRate: 44_100, samples: [[]])
        #expect(VocalStemCache.cacheURL(for: request, lane: .drums).lastPathComponent
                == "song.mp3.stems-v2-12500-8000-drums.caf")
        // Three lanes on disk, not four: `other` is a subtraction.
        #expect(VocalStemCache.storedLanes == [.vocals, .drums, .bass])
        #expect(!VocalStemCache.storedLanes.contains(.other))
        // Both generations are still swept by the same marker, so one `rm`
        // clears the lot.
        #expect(VocalStemCache.isSidecar(vocalOnly))
        #expect(VocalStemCache.isSidecar(VocalStemCache.cacheURL(for: request, lane: .bass)))
    }

    @Test("the derived other makes the four lanes sum back to the mixture exactly")
    func partitionIsExact() {
        let mixture: [[Float]] = [(0..<512).map { Float(sin(Double($0) * 0.05)) }]
        let drums: [[Float]] = [(0..<512).map { Float(0.31 * cos(Double($0) * 0.11)) }]
        let bass: [[Float]] = [(0..<512).map { Float(0.17 * sin(Double($0) * 0.007)) }]
        let vocals: [[Float]] = [(0..<512).map { Float(0.23 * sin(Double($0) * 0.3)) }]
        // A model's own `other` that is deliberately wrong: `completing` must
        // overwrite it rather than trust it.
        let lanes = VocalStemCache.completing(
            [.vocals: vocals, .drums: drums, .bass: bass,
             .other: [[Float](repeating: 99, count: 512)]],
            mixture: mixture)

        let other = try! #require(lanes[.other])
        for i in 0..<512 {
            let sum = vocals[0][i] + drums[0][i] + bass[0][i] + other[0][i]
            #expect(abs(sum - mixture[0][i]) < 1e-6)
        }
    }

    // MARK: - The fallback

    /// A four-lane stub that partitions the mixture the way a real provider
    /// must: vocals from ground truth, drums and bass split off the rest, and
    /// `other` derived so the four sum back.
    private func stubFull(vocalFraction: Float = 0.4) -> FullStemProvider {
        { request in
            var lanes: [StemLane: [[Float]]] = [:]
            lanes[.vocals] = request.samples.map { $0.map { $0 * vocalFraction } }
            lanes[.drums] = request.samples.map { $0.map { $0 * 0.2 } }
            lanes[.bass] = request.samples.map { $0.map { $0 * 0.1 } }
            return Stems(lanes: VocalStemCache.completing(lanes, mixture: request.samples))
        }
    }

    private func stubVocals(vocalFraction: Float = 0.4) -> VocalStemProvider {
        { request in
            VocalStem(channels: request.samples.map { $0.map { $0 * vocalFraction } })
        }
    }

    @Test("once every entrance has landed, four lanes and one bed are the same audio")
    func unitySubLanesAreTransparent() throws {
        // `drums + bass + other == mixture − vocals` by construction, so past
        // the last entrance — where all three sub-gains are unity — the split
        // bed must reproduce the undivided one. This is the invariant that lets
        // a bed split compose with the fader and the EQ hand-over rather than
        // compete with them, and it is why `other` is a residual and not the
        // model's fourth estimate.
        var envelope = StemEnvelope()
        envelope.incomingVocal = [.init(t: 0, gainDB: -60), .init(t: 2, gainDB: 0)]
        envelope.incomingBedSplit = ScoreCompiler.bedSplit(
            landing: 2, overlap: 4, bar: 0.5, bassSwap: 1)
        #expect(envelope.hasIncomingBedSplit)

        let whole = try apply(envelope, fullProvider: nil)
        let split = try apply(envelope, fullProvider: stubFull())
        #expect(whole.count == split.count)
        // From the singer's entrance onward. Before it the two renders differ
        // on purpose — that difference *is* the gesture.
        for i in Int(2 * 44_100)..<whole.count {
            #expect(abs(whole[i] - split[i]) < 1e-5)
        }
    }

    @Test("no four-stem model means the whole bed, the gesture, and a note saying so")
    func degradesWithoutAFullProvider() throws {
        var envelope = StemEnvelope()
        envelope.incomingVocal = [.init(t: 0, gainDB: -60), .init(t: 2, gainDB: 0)]
        envelope.incomingBedSplit = ScoreCompiler.bedSplit(
            landing: 2, overlap: 4, bar: 0.5, bassSwap: 1)

        // The same envelope, once with a four-lane provider and once without.
        // The undivided render must be exactly what the two-stem path always
        // produced — the split lanes are the only thing that changes.
        let degraded = try apply(envelope, fullProvider: nil)
        var plain = envelope
        plain.incomingBedSplit = nil
        let reference = try apply(plain, fullProvider: nil)
        #expect(degraded.count == reference.count)
        for i in 0..<degraded.count {
            #expect(degraded[i] == reference[i])
        }

        // And with four lanes it is genuinely a different render.
        let split = try apply(envelope, fullProvider: stubFull())
        #expect(zip(split, degraded).contains { abs($0 - $1) > 1e-4 })
    }

    /// Run one envelope over a synthetic incoming buffer and hand back the
    /// overlap window's first channel.
    private func apply(_ envelope: StemEnvelope,
                       fullProvider: FullStemProvider?) throws -> [Float] {
        let sampleRate = 44_100.0
        let overlap: TimeInterval = 4
        let frames = Int(overlap * sampleRate)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!

        func buffer() -> AVAudioPCMBuffer {
            let b = AVAudioPCMBuffer(pcmFormat: format,
                                     frameCapacity: AVAudioFrameCount(frames))!
            b.frameLength = AVAudioFrameCount(frames)
            for channel in 0..<2 {
                for i in 0..<frames {
                    b.floatChannelData![channel][i] =
                        Float(sin(Double(i) * 0.01) * 0.5 + sin(Double(i) * 0.13) * 0.2)
                }
            }
            return b
        }

        let incoming = buffer()
        let outgoing = buffer()
        let plan = TransitionPlan.crossfade(duration: overlap, outPoint: 30, inPoint: 5)
        let geometry = TransitionAutomation.Geometry(plan: plan)
        _ = try StemTechniqueLayer.apply(
            envelope: envelope,
            outgoing: StemTechniqueLayer.Side(
                buffer: outgoing, source: URL(fileURLWithPath: "/tmp/out.wav"),
                windowStart: 0, overlapStartFrame: 0, rate: 1),
            incoming: StemTechniqueLayer.Side(
                buffer: incoming, source: URL(fileURLWithPath: "/tmp/in.wav"),
                windowStart: 0, overlapStartFrame: 0, rate: 1),
            geometry: geometry, provider: stubVocals(), fullProvider: fullProvider)

        return (0..<frames).map { incoming.floatChannelData![0][$0] }
    }
}
