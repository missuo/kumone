import Testing
@testable import KumoneCore
import Foundation

// Structure segmentation (predev §2.1). The synthetic material here is built so
// the right answer is known by construction: a steady beat carries alternating
// blocks of two very different timbres, so every block edge is a true boundary
// and every other block is the same "section type". Nothing in this suite
// touches a `PlaybackEngine`.

@Suite struct StructureSegmenterTests {

    // MARK: - Synthetic material

    /// Deterministic noise (LCG) — the analyzer must be reproducible run to run.
    private struct Noise {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        mutating func next() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int32(truncatingIfNeeded: Int64(bitPattern: seed >> 33)))
                / Float(Int32.max)
        }
    }

    /// A kick train at `bpm` with `blocks` fixed-length sections layered on top.
    /// `timbres` gives each block's partial set; a block repeated later in the
    /// list is literally the same material, which is what "the chorus comes
    /// back" looks like to a self-similarity matrix.
    private func blockedTrack(
        bpm: Double, blockSeconds: Double, timbres: [[Double]], sampleRate sr: Double
    ) -> [Float] {
        let seconds = blockSeconds * Double(timbres.count)
        let n = Int(seconds * sr)
        var x = [Float](repeating: 0, count: n)
        var noise = Noise()
        for i in 0..<n { x[i] = 0.004 * noise.next() }

        // Beat grid: the segmenter needs tracked beats before it will do
        // anything at all, so the material has to be genuinely metrical.
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
                x[start + s] += amp * Float(exp(-t / 0.02)) * Float(sin(2 * .pi * 55 * t))
            }
            for s in 0..<clickLength where start + s < n {
                x[start + s] += 0.4 * amp * Float(exp(-Double(s) / (0.002 * sr))) * noise.next()
            }
            beat += 1
        }

        for (b, partials) in timbres.enumerated() {
            let from = Int(Double(b) * blockSeconds * sr)
            let to = min(n, Int(Double(b + 1) * blockSeconds * sr))
            guard from < to else { continue }
            for i in from..<to {
                let t = Double(i) / sr
                var v = 0.0
                for f in partials { v += sin(2 * .pi * f * t) }
                x[i] += Float(0.22 * v / Double(max(1, partials.count)))
            }
        }
        return x
    }

    /// Low harmonic stack vs. a bright upper-mid one: far apart in log-mel *and*
    /// in chroma, which is exactly what the two halves of the feature row see.
    private let lowTimbre = [220.0, 330.0, 440.0]
    private let highTimbre = [1_600.0, 2_100.0, 2_700.0]

    // MARK: - Boundaries and clustering

    @Test func alternatingTimbreBlocksAreSegmentedAndClustered() throws {
        let sr = 22_050.0
        let bpm = 120.0
        let block = 20.0     // 40 beats — comfortably over the 8-bar minimum
        let pattern = [lowTimbre, highTimbre, lowTimbre, highTimbre, lowTimbre, highTimbre]
        let x = blockedTrack(bpm: bpm, blockSeconds: block, timbres: pattern, sampleRate: sr)
        let a = TrackAnalyzer.analyze(samples: x, sampleRate: sr)

        #expect(a.structureConfidence > StructureSegmenter.confidenceGate,
                "confidence \(a.structureConfidence) on clearly blocked material")
        #expect(a.sections.count >= 4 && a.sections.count <= 8,
                "\(a.sections.count) sections for a 6-block track")
        try #require(a.sections.count >= 4)

        // Every interior block edge has a boundary within a bar (2 s at 120 BPM).
        let found = a.sections.map(\.start) + [a.sections.last!.end]
        for b in 1..<pattern.count {
            let truth = Double(b) * block
            let nearest = found.map { abs($0 - truth) }.min() ?? .infinity
            let shown = found.map { String(format: "%.1f", $0) }.joined(separator: " ")
            #expect(nearest <= 2.0,
                    "block edge \(truth)s: nearest boundary is \(nearest)s away (\(shown))")
        }

        // The repeated material clusters: the section covering each block is the
        // same kind as the section covering the block two along, and both know
        // they are not unique. Intro/outro overrides make the first and last
        // block unusable for this, so the check runs on the interior.
        func section(coveringSecond s: Double) throws -> TrackAnalysis.Section {
            try #require(a.sections.first { $0.start <= s && $0.end > s })
        }
        let b1 = try section(coveringSecond: 1.5 * block)   // high
        let b2 = try section(coveringSecond: 2.5 * block)   // low
        let b3 = try section(coveringSecond: 3.5 * block)   // high
        let b4 = try section(coveringSecond: 4.5 * block)   // low
        #expect(b1.kind == b3.kind, "\(b1.kind) vs \(b3.kind) for two identical blocks")
        #expect(b2.kind == b4.kind, "\(b2.kind) vs \(b4.kind) for two identical blocks")
        #expect(b1.repetition >= 2 && b2.repetition >= 2,
                "repetitions \(b1.repetition)/\(b2.repetition) for repeated blocks")

        // Contiguous cover, in order, inside the track.
        for (i, s) in a.sections.enumerated() {
            #expect(s.end > s.start)
            if i > 0 { #expect(abs(s.start - a.sections[i - 1].end) < 1e-9) }
            #expect(s.energy >= 0)
            #expect(s.vocalDensity >= 0)
        }
        #expect(a.sections.first?.start == 0)
        #expect(abs((a.sections.last?.end ?? 0) - a.duration) < 1e-9)
    }

    // MARK: - The gate

    @Test func homogeneousTrackYieldsNoSections() {
        let sr = 22_050.0
        // Same timbre for all six blocks: there is no structure to find, and
        // inventing one here is the failure mode the confidence gate exists for.
        let pattern = [[Double]](repeating: lowTimbre, count: 6)
        let x = blockedTrack(bpm: 120, blockSeconds: 20, timbres: pattern, sampleRate: sr)
        let a = TrackAnalyzer.analyze(samples: x, sampleRate: sr)
        #expect(a.sections.isEmpty,
                "invented \(a.sections.count) sections at confidence \(a.structureConfidence)")
        #expect(a.structureConfidence < StructureSegmenter.confidenceGate)
    }

    @Test func shortTrackYieldsNoSections() {
        // 25 s at 120 BPM is 50 beats — under the 64-beat floor, so the matrix
        // never gets built and the fields come back inert.
        let sr = 22_050.0
        let x = blockedTrack(
            bpm: 120, blockSeconds: 12.5, timbres: [lowTimbre, highTimbre], sampleRate: sr)
        let a = TrackAnalyzer.analyze(samples: x, sampleRate: sr)
        #expect(a.sections.isEmpty)
        #expect(a.structureConfidence == 0)
    }

    @Test func silenceYieldsNoSections() {
        let a = TrackAnalyzer.analyze(
            samples: [Float](repeating: 0, count: Int(90 * 22_050)), sampleRate: 22_050)
        #expect(a.sections.isEmpty)
        #expect(a.structureConfidence == 0)
    }

    // MARK: - Sidecar compatibility

    /// A v6 sidecar carries no `sections` key. Both cache readers
    /// (`AudioCache`, `Audition.analysis`) spell the same contract — `try?
    /// decode` and then `version == currentVersion` — so a stale sidecar has two
    /// independent ways to end up re-analyzed and no way to be *used*. This
    /// pins that: whatever the decoder does with the missing key, the result is
    /// never a usable current-version analysis.
    @Test func preV7SidecarIsNeverUsedAsIs() {
        let json = """
        {"version":6,"bpm":120,"bpmConfidence":0.8,"beats":[],"downbeats":[],
         "phraseBoundaries":[],"rmsEnvelope":[],"introEnd":0,"duration":180,
         "melProfile":[],"keyIsMinor":false,"keyConfidence":0,"vocalActivity":[]}
        """
        let decoded = try? JSONDecoder().decode(TrackAnalysis.self, from: Data(json.utf8))
        #expect(decoded?.version != TrackAnalysis.currentVersion)
        #expect(decoded?.sections.isEmpty ?? true)
    }

    @Test func sectionsRoundTripThroughJSON() throws {
        let section = TrackAnalysis.Section(
            start: 12, end: 34, kind: .chorus, repetition: 4, energy: 0.8, vocalDensity: 1.2)
        let data = try JSONEncoder().encode(section)
        #expect(try JSONDecoder().decode(TrackAnalysis.Section.self, from: data) == section)
    }
}
