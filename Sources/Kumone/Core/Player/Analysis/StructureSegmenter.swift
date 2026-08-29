import Accelerate
import Foundation

// Beat-synchronous structure segmentation (predev §2.1). Pure vDSP, no model,
// and — this is the constraint that shapes everything below — **no second pass
// over the audio**. Every number here is derived from the per-frame log-mel,
// chroma and low-band arrays `TrackAnalyzer.stftFeatures` already produced, plus
// the beat grid it already tracked.
//
// Pipeline (Foote 2000, with the usual modern trimmings):
//   1. pool the per-frame features by beat and z-score each dimension, so a
//      4-minute song becomes a ~500-row matrix and everything after this is
//      microseconds;
//   2. beat × beat cosine self-similarity, timbre and chroma weighted equally
//      (after z-scoring they are already on a common scale);
//   3. slide a Gaussian-tapered checkerboard kernel down the diagonal → a
//      novelty curve whose peaks are "the music changed here";
//   4. peak-pick, snap to downbeats, cluster the resulting spans by their mean
//      feature vector (threshold-based agglomeration — the number of distinct
//      section *types* is what we are trying to learn, so fixing k is wrong);
//   5. label the clusters by repetition × energy × vocal density.
//
// The output is deliberately fragile-by-default: anything the confidence blend
// does not clear comes back as *no sections at all*, because a wrong boundary is
// worse for cue selection than no boundary (predev §4.1) — a mislabelled "chorus
// ends here" cuts a song off mid-climax, while an absent one just falls back to
// the energy heuristics that shipped before this existed.
enum StructureSegmenter {

    // MARK: - Tunables
    //
    // Beat counts rather than seconds throughout: the whole point of the
    // beat-synchronous pooling is that a bar is a bar at any tempo.

    /// Below this many tracked beats there is not enough matrix to find
    /// structure in (~35 s at 110 BPM). Short interludes and broken beat
    /// tracking both land here, and both should produce nothing.
    private static let minimumBeats = 64
    /// Checkerboard kernel half-width, in beats: 8 → a 16-beat (4-bar) kernel.
    /// Wider smears real 8-bar boundaries together; narrower starts firing on
    /// fills and one-bar drum variations.
    private static let kernelHalfBeats = 8
    /// No two boundaries closer than 8 bars, and no section shorter than that.
    /// Real sections are 8–16 bars; at 4 bars the segmenter carves a chorus into
    /// its own two halves and the labels stop meaning anything.
    private static let minimumSectionBeats = 32
    /// A novelty peak counts only if it stands this far above the mean of its
    /// own neighbourhood — the same ratio doubles as the confidence input, so
    /// it is a significance measure first and a threshold second.
    private static let peakSignificance = 1.25
    /// Neighbourhood half-width (beats) the significance ratio is measured over.
    private static let significanceHalfBeats = 24
    /// How far above `peakSignificance` the mean peak has to be for the novelty
    /// half of the confidence to max out. Set from the tuning corpus, where a
    /// clearly-structured track's mean significance runs 2.0–3.2 — anything
    /// tighter pinned every real song at 1.0 and made the number useless for
    /// telling "this is solid" from "this barely held together".
    private static let noveltySpan = 1.5
    /// …and how far apart the clusters have to be (mean between-cluster minus
    /// mean within-cluster cosine distance) for the other half to max out. Same
    /// corpus, same reason: real tracks land at 0.6–1.2.
    private static let separationSpan = 1.2
    /// Average-linkage cosine distance below which two sections are the same
    /// section type. Fitted on the tuning corpus: verse-vs-chorus pairs sit
    /// around 0.6–1.0, two verses around 0.1–0.35.
    private static let clusterMergeDistance: Float = 0.45
    /// A cluster is a `drop` when its mean energy exceeds the track mean by this
    /// factor *and* its sections open on a low-frequency jump. Both numbers are
    /// deliberately conservative: at 1.15 / 1.5 the rule relabelled the choruses
    /// of two ballads in the corpus as drops (a ballad chorus does bring the
    /// bass in), and a wrong `drop` is worse than a missing one — it is the one
    /// label that will later change the shape of a transition.
    private static let dropEnergyFactor: Float = 1.35
    /// …that jump being this ratio of low-band energy just after the boundary
    /// against just before it.
    private static let dropLowJump: Float = 2.0
    /// Below this the sections are discarded. The corpus's structured pop sits
    /// at 0.61–0.97, so this is a floor against genuinely broken input (failed
    /// beat tracking, ambient/through-composed material), not a percentile cut.
    static let confidenceGate = 0.35

    // MARK: - Entry point

    /// Segment a track from features the analyzer already has in hand.
    ///
    /// `mel`, `chroma` and `low` are on the STFT frame grid (`fps` frames per
    /// second); `rmsEnvelope` and `vocalActivity` are on the 1 s grid.
    /// Returns empty sections whenever the result would not be trustworthy.
    static func segment(
        mel: [[Float]], chroma: [[Float]], low: [Float], fps: Double,
        beats: [TimeInterval], downbeats: [TimeInterval],
        rmsEnvelope: [Float], vocalActivity: [Float], duration: TimeInterval
    ) -> (sections: [TrackAnalysis.Section], confidence: Double) {
        let empty: ([TrackAnalysis.Section], Double) = ([], 0)
        guard beats.count >= minimumBeats, downbeats.count >= 4,
              mel.count > kernelHalfBeats * 2, fps > 1, duration > 0
        else { return empty }

        let pooled = poolByBeat(
            mel: mel, chroma: chroma, low: low, fps: fps,
            beats: beats, rmsEnvelope: rmsEnvelope, vocalActivity: vocalActivity)
        let n = pooled.count
        guard n >= minimumBeats, pooled.dimensions > 0 else { return empty }

        let ssm = selfSimilarity(pooled)
        let novelty = noveltyCurve(ssm, count: n)
        let peaks = pickPeaks(novelty)
        guard !peaks.isEmpty else { return empty }

        // Boundaries live in beat indices until the very end, where they snap to
        // downbeats — the grid a cue has to land on to sound intentional.
        let bounds = boundaries(peaks.map(\.index), beatCount: n)
        guard bounds.count >= 4 else { return empty }   // ≥3 sections

        let spans = bounds.indices.dropLast().map { bounds[$0]..<bounds[$0 + 1] }
        let profiles = spans.map { sectionProfile(pooled, span: $0) }
        let clusters = cluster(profiles)
        let separation = clusterSeparation(profiles, clusters: clusters)

        let noveltyTerm = clamp01((peaks.map(\.significance).reduce(0, +)
            / Double(peaks.count) - peakSignificance) / noveltySpan)
        let separationTerm = clamp01(separation / separationSpan)
        let confidence = clamp01(0.6 * noveltyTerm + 0.4 * separationTerm)
        guard confidence >= confidenceGate else { return ([], confidence) }

        let sections = label(
            spans: spans, clusters: clusters, pooled: pooled,
            beats: beats, downbeats: downbeats, duration: duration)
        return (sections, confidence)
    }

    // MARK: - Beat-synchronous pooling

    /// Per-beat feature rows plus the scalars the labeller needs. The feature
    /// block is `[timbre(40) | chroma(12)]`, z-scored per dimension and then
    /// L2-normalized *within each block* and scaled by √½, so a plain dot
    /// product of two rows is the equal-weight mean of the two blocks' cosines.
    struct Pooled {
        var rows: [Float] = []          // row-major, count × dimensions
        var count = 0
        var dimensions = 0
        var rms: [Float] = []           // per beat, track-peak-relative
        var vocal: [Float] = []         // per beat, raw 0–1
        var low: [Float] = []           // per beat, raw low-band magnitude
        var times: [TimeInterval] = []  // beat start times (count entries)
    }

    private static func poolByBeat(
        mel: [[Float]], chroma: [[Float]], low: [Float], fps: Double,
        beats: [TimeInterval], rmsEnvelope: [Float], vocalActivity: [Float]
    ) -> Pooled {
        let melBands = mel.first?.count ?? 0
        let chromaBins = chroma.first?.count ?? 0
        guard melBands > 0, chromaBins > 0 else { return Pooled() }
        let dims = melBands + chromaBins
        let frames = mel.count

        var p = Pooled()
        p.dimensions = dims
        // The last beat has no successor to bound it, so the grid is the
        // half-open intervals between consecutive beats.
        let n = beats.count - 1
        p.rows = [Float](repeating: 0, count: n * dims)
        p.rms = [Float](repeating: 0, count: n)
        p.vocal = [Float](repeating: 0, count: n)
        p.low = [Float](repeating: 0, count: n)
        p.times = Array(beats.prefix(n))
        p.count = n

        for i in 0..<n {
            let lo = min(frames - 1, max(0, Int(beats[i] * fps)))
            let hi = min(frames, max(lo + 1, Int(beats[i + 1] * fps)))
            let inv = 1 / Float(hi - lo)
            let base = i * dims
            for t in lo..<hi {
                let m = mel[t]
                let c = chroma[t]
                for b in 0..<melBands { p.rows[base + b] += m[b] }
                for b in 0..<chromaBins { p.rows[base + melBands + b] += c[b] }
                if t < low.count { p.low[i] += low[t] }
            }
            for d in 0..<dims { p.rows[base + d] *= inv }
            p.low[i] *= inv
            p.rms[i] = meanOverSeconds(rmsEnvelope, from: beats[i], to: beats[i + 1])
            p.vocal[i] = meanOverSeconds(vocalActivity, from: beats[i], to: beats[i + 1])
        }

        zscoreColumns(&p.rows, count: n, dimensions: dims)
        normalizeBlocks(&p.rows, count: n, split: melBands, dimensions: dims)
        return p
    }

    /// Mean of a 1 s-grid envelope over `[from, to)`, at least the second the
    /// span starts in (a beat is shorter than a second at every sane tempo).
    private static func meanOverSeconds(
        _ grid: [Float], from: TimeInterval, to: TimeInterval
    ) -> Float {
        guard !grid.isEmpty else { return 0 }
        let lo = min(grid.count - 1, max(0, Int(from)))
        let hi = min(grid.count, max(lo + 1, Int(to.rounded(.up))))
        var sum: Float = 0
        for s in lo..<hi { sum += grid[s] }
        return sum / Float(hi - lo)
    }

    /// Zero mean, unit variance per feature dimension across beats. Without it
    /// the mel bands (order ~1) would drown the L1-normalized chroma bins
    /// (order ~0.08) in every cosine.
    private static func zscoreColumns(_ rows: inout [Float], count: Int, dimensions: Int) {
        guard count > 1 else { return }
        for d in 0..<dimensions {
            var mean: Float = 0
            var std: Float = 0
            vDSP_normalize(
                Array(stride(from: d, to: count * dimensions, by: dimensions).map { rows[$0] }),
                1, nil, 1, &mean, &std, vDSP_Length(count))
            let scale: Float = std > 1e-6 ? 1 / std : 0
            for i in 0..<count {
                rows[i * dimensions + d] = (rows[i * dimensions + d] - mean) * scale
            }
        }
    }

    /// L2-normalize the timbre and chroma halves of every row separately and
    /// scale both by √½. The dot product of two such rows is then exactly
    /// `½·cos(timbre) + ½·cos(chroma)` — equal weighting, which is where §2.1
    /// says to start, and the only weighting that needs no justification once
    /// both halves are z-scored.
    private static func normalizeBlocks(
        _ rows: inout [Float], count: Int, split: Int, dimensions: Int
    ) {
        let half = (0.5 as Float).squareRoot()
        for i in 0..<count {
            let base = i * dimensions
            for block in [base..<(base + split), (base + split)..<(base + dimensions)] {
                var norm: Float = 0
                for k in block { norm += rows[k] * rows[k] }
                let scale = norm > 1e-12 ? half / norm.squareRoot() : 0
                for k in block { rows[k] *= scale }
            }
        }
    }

    // MARK: - Self-similarity and novelty

    /// Beat × beat similarity, row-major. `M · Mᵀ` with the rows prepared as
    /// above; a few hundred squared, so one `vDSP_mmul` and done.
    private static func selfSimilarity(_ p: Pooled) -> [Float] {
        var s = [Float](repeating: 0, count: p.count * p.count)
        var transposed = [Float](repeating: 0, count: p.count * p.dimensions)
        vDSP_mtrans(p.rows, 1, &transposed, 1,
                    vDSP_Length(p.dimensions), vDSP_Length(p.count))
        vDSP_mmul(p.rows, 1, transposed, 1, &s, 1,
                  vDSP_Length(p.count), vDSP_Length(p.count), vDSP_Length(p.dimensions))
        return s
    }

    /// Foote's checkerboard correlation along the diagonal. The kernel is the
    /// outer product of a sign pattern (`+` on the two on-diagonal quadrants,
    /// `−` on the two off-diagonal ones) with a Gaussian taper, so a boundary —
    /// two internally-similar blocks that are dissimilar to each other — peaks
    /// and a homogeneous stretch cancels to ~0.
    private static func noveltyCurve(_ ssm: [Float], count n: Int) -> [Float] {
        let L = kernelHalfBeats
        let width = 2 * L
        var kernel = [Float](repeating: 0, count: width * width)
        let sigma = Float(L) / 2
        for a in 0..<width {
            for b in 0..<width {
                let da = Float(a - L) + 0.5, db = Float(b - L) + 0.5
                let sign: Float = (da < 0) == (db < 0) ? 1 : -1
                kernel[a * width + b] = sign * exp(-(da * da + db * db) / (2 * sigma * sigma))
            }
        }

        var novelty = [Float](repeating: 0, count: n)
        guard n > width else { return novelty }
        for i in L..<(n - L) {
            var acc: Float = 0
            for a in 0..<width {
                let row = (i - L + a) * n + (i - L)
                var partial: Float = 0
                vDSP_dotpr(Array(ssm[row..<(row + width)]), 1,
                           Array(kernel[(a * width)..<(a * width + width)]), 1,
                           &partial, vDSP_Length(width))
                acc += partial
            }
            novelty[i] = max(0, acc)
        }
        // Scale to 0–1 so the significance ratio and the thresholds below are
        // comparable across tracks.
        let peak = novelty.max() ?? 0
        guard peak > 1e-9 else { return novelty }
        return novelty.map { $0 / peak }
    }

    struct NoveltyPeak {
        var index: Int
        /// Peak height over the mean of its neighbourhood; 1 = indistinguishable
        /// from the surrounding wobble.
        var significance: Double
    }

    /// Local maxima at least `minimumSectionBeats` apart, each clearing the
    /// significance ratio, greedily taken tallest-first so a genuine boundary
    /// is never suppressed by a shoulder next to it.
    private static func pickPeaks(_ novelty: [Float]) -> [NoveltyPeak] {
        let n = novelty.count
        var candidates: [Int] = []
        for i in 1..<max(1, n - 1) where novelty[i] > novelty[i - 1] && novelty[i] >= novelty[i + 1] {
            candidates.append(i)
        }
        var out: [NoveltyPeak] = []
        for i in candidates.sorted(by: { novelty[$0] > novelty[$1] }) {
            guard novelty[i] > 1e-6 else { break }
            guard !out.contains(where: { abs($0.index - i) < minimumSectionBeats }) else { continue }
            let lo = max(0, i - significanceHalfBeats)
            let hi = min(n, i + significanceHalfBeats + 1)
            var sum: Float = 0
            for k in lo..<hi { sum += novelty[k] }
            let mean = sum / Float(hi - lo)
            let ratio = mean > 1e-9 ? Double(novelty[i] / mean) : 0
            guard ratio >= peakSignificance else { continue }
            out.append(NoveltyPeak(index: i, significance: ratio))
        }
        return out.sorted { $0.index < $1.index }
    }

    /// Peak indices → the closed beat-index boundary list `[0, …, n]`, with
    /// anything that would leave a stub section dropped.
    private static func boundaries(_ peaks: [Int], beatCount n: Int) -> [Int] {
        var out = [0]
        for p in peaks where p - out.last! >= minimumSectionBeats && n - p >= minimumSectionBeats {
            out.append(p)
        }
        out.append(n)
        return out
    }

    // MARK: - Clustering

    /// The mean (re-normalized) feature vector of one span — what "this section
    /// sounds like", stripped of where it sits in time.
    private static func sectionProfile(_ p: Pooled, span: Range<Int>) -> [Float] {
        var v = [Float](repeating: 0, count: p.dimensions)
        for i in span {
            let base = i * p.dimensions
            for d in 0..<p.dimensions { v[d] += p.rows[base + d] }
        }
        var norm: Float = 0
        for x in v { norm += x * x }
        guard norm > 1e-12 else { return v }
        let scale = 1 / norm.squareRoot()
        for d in 0..<p.dimensions { v[d] *= scale }
        return v
    }

    private static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(min(a.count, b.count)))
        return 1 - dot
    }

    /// Average-linkage agglomeration to a distance threshold, not to a fixed k:
    /// how many *kinds* of section a song has is the thing being measured, and a
    /// song with one riff and a song with six passages both exist.
    private static func cluster(_ profiles: [[Float]]) -> [Int] {
        var members: [[Int]] = profiles.indices.map { [$0] }
        while members.count > 1 {
            var best = (i: -1, j: -1, d: Float.greatestFiniteMagnitude)
            for i in 0..<(members.count - 1) {
                for j in (i + 1)..<members.count {
                    var sum: Float = 0
                    for a in members[i] {
                        for b in members[j] { sum += cosineDistance(profiles[a], profiles[b]) }
                    }
                    let d = sum / Float(members[i].count * members[j].count)
                    if d < best.d { best = (i, j, d) }
                }
            }
            guard best.d < clusterMergeDistance, best.i >= 0 else { break }
            members[best.i].append(contentsOf: members[best.j])
            members.remove(at: best.j)
        }
        var labels = [Int](repeating: 0, count: profiles.count)
        for (c, group) in members.enumerated() {
            for i in group { labels[i] = c }
        }
        return labels
    }

    /// Mean between-cluster distance minus mean within-cluster distance, mapped
    /// to 0–1. A track whose "sections" are all the same thing scores ~0, which
    /// is precisely the track whose boundaries should not be believed.
    private static func clusterSeparation(_ profiles: [[Float]], clusters: [Int]) -> Double {
        var within: Float = 0, withinN = 0
        var between: Float = 0, betweenN = 0
        for i in 0..<profiles.count {
            for j in (i + 1)..<profiles.count {
                let d = cosineDistance(profiles[i], profiles[j])
                if clusters[i] == clusters[j] { within += d; withinN += 1 }
                else { between += d; betweenN += 1 }
            }
        }
        guard betweenN > 0 else { return 0 }
        let b = Double(between) / Double(betweenN)
        // A single-cluster track has no within-distance to subtract; treat its
        // (nonexistent) internal spread as the neutral 0.
        let w = withinN > 0 ? Double(within) / Double(withinN) : 0
        return b - w
    }

    // MARK: - Labelling

    private static func label(
        spans: [Range<Int>], clusters: [Int], pooled p: Pooled,
        beats: [TimeInterval], downbeats: [TimeInterval], duration: TimeInterval
    ) -> [TrackAnalysis.Section] {
        let peakRMS = max(p.rms.max() ?? 0, 1e-9)
        let meanVocal = p.vocal.reduce(0, +) / Float(max(1, p.vocal.count))
        let trackMeanEnergy = p.rms.reduce(0, +) / Float(max(1, p.rms.count)) / peakRMS

        func mean(_ grid: [Float], _ span: Range<Int>) -> Float {
            var sum: Float = 0
            for i in span { sum += grid[i] }
            return sum / Float(max(1, span.count))
        }

        let energy = spans.map { mean(p.rms, $0) / peakRMS }
        let vocalDensity = spans.map {
            meanVocal > 1e-6 ? mean(p.vocal, $0) / meanVocal : 0
        }
        var repetition = [Int](repeating: 1, count: spans.count)
        var clusterMembers: [Int: [Int]] = [:]
        for (i, c) in clusters.enumerated() { clusterMembers[c, default: []].append(i) }
        for (_, group) in clusterMembers {
            for i in group { repetition[i] = group.count }
        }

        // A drop opens with the low end arriving: the bass jump is what tells a
        // build's climax from a chorus that is merely loud.
        func opensOnLowJump(_ span: Range<Int>) -> Bool {
            let k = 4
            guard span.lowerBound >= k, span.lowerBound + k <= p.low.count else { return false }
            var before: Float = 0, after: Float = 0
            for i in (span.lowerBound - k)..<span.lowerBound { before += p.low[i] }
            for i in span.lowerBound..<(span.lowerBound + k) { after += p.low[i] }
            guard before > 1e-9 else { return false }
            return after / before >= dropLowJump
        }

        var kinds = [TrackAnalysis.Section.Kind](repeating: .verse, count: spans.count)

        // Drops first: an EDM drop cluster would otherwise win the chorus vote
        // and lose the one label that carries the gesture.
        var dropClusters: Set<Int> = []
        for (c, group) in clusterMembers {
            let e = group.map { energy[$0] }.reduce(0, +) / Float(group.count)
            guard e >= trackMeanEnergy * dropEnergyFactor else { continue }
            let jumps = group.filter { opensOnLowJump(spans[$0]) }.count
            if jumps * 2 >= group.count { dropClusters.insert(c) }
        }

        // Chorus: the most-repeated cluster, energy × vocal density breaking the
        // tie. "Most repeated" is the whole reason this works without a model —
        // the passage a song comes back to is the passage it is about.
        let maxRepetition = clusterMembers.values.map(\.count).max() ?? 1
        var chorusCluster: Int?
        if maxRepetition >= 2 {
            var bestScore = -Float.greatestFiniteMagnitude
            for (c, group) in clusterMembers
            where group.count == maxRepetition && !dropClusters.contains(c) {
                let score = group.map { energy[$0] * max(vocalDensity[$0], 0.05) }
                    .reduce(0, +) / Float(group.count)
                if score > bestScore { bestScore = score; chorusCluster = c }
            }
        }

        for i in spans.indices {
            if dropClusters.contains(clusters[i]) { kinds[i] = .drop }
            else if clusters[i] == chorusCluster { kinds[i] = .chorus }
            else if repetition[i] == 1 { kinds[i] = .bridge }
            else { kinds[i] = .verse }
        }

        // Intro/outro override everything: the first and last spans are those
        // when they are quiet or musically unlike anything else in the track.
        if let first = spans.indices.first,
           energy[first] < trackMeanEnergy || repetition[first] == 1 {
            kinds[first] = .intro
        }
        if let last = spans.indices.last, last != spans.indices.first,
           energy[last] < trackMeanEnergy || repetition[last] == 1 {
            kinds[last] = .outro
        }

        // Beat index → seconds, snapped to the nearest downbeat so a boundary is
        // a bar line. The track's own ends are never moved.
        func time(_ beatIndex: Int) -> TimeInterval {
            guard beatIndex < p.times.count else { return duration }
            let t = p.times[beatIndex]
            guard let nearest = downbeats.min(by: { abs($0 - t) < abs($1 - t) }) else { return t }
            return nearest
        }

        var out: [TrackAnalysis.Section] = []
        for (i, span) in spans.enumerated() {
            let start = i == 0 ? 0 : time(span.lowerBound)
            let end = i == spans.count - 1 ? duration : time(span.upperBound)
            guard end > start else { continue }
            out.append(TrackAnalysis.Section(
                start: start, end: end, kind: kinds[i], repetition: repetition[i],
                energy: energy[i], vocalDensity: vocalDensity[i]))
        }
        // Snapping can collapse a boundary onto its neighbour; drop the empties
        // rather than emit a zero-length section a consumer would trip over.
        return out.count >= 3 ? out : []
    }

    private static func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }
}
