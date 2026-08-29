import Foundation

/// Offline validation surface for the vocal-activity detector (S0.5).
///
/// Exists only so the `vocaleval` executable — which lives outside KumoneCore —
/// can drive `TrackAnalyzer`'s internals and score them against StemKit
/// separation. Nothing in the shipping app calls this; it is deliberately kept
/// in its own file, separate from the analyzer, so it is obvious that removing
/// it costs the app nothing.
public enum VocalActivityEval {
    /// Both the pre-change (v4, three-cue) and current (v5, five-cue) per-second
    /// vocal-activity curves, plus the raw cue matrix, from a single decode.
    public struct Curves: Sendable {
        /// Pre-change fusion, replayed on identical features.
        public let v4: [Float]
        /// Current fusion.
        public let v5: [Float]
        /// Per-second cue rows, column order matching `cueNames`.
        public let cues: [[Double]]
        public let rmsEnvelope: [Float]
        public let duration: Double
        /// False when the source is single-channel, where the mid/side cue is
        /// inert by construction.
        public let hadStereo: Bool
    }

    /// Column labels for `Curves.cues`.
    public static let cueNames = ["band", "tonal", "mod", "mid", "presence", "gate"]

    public static func curves(fileAt url: URL) throws -> Curves {
        let ab = try TrackAnalyzer.vocalActivityAB(fileAt: url)
        return Curves(
            v4: ab.v4,
            v5: ab.v5,
            cues: ab.cues.map {
                [$0.band, $0.tonal, $0.mod, $0.mid, $0.presence, $0.gate]
            },
            rmsEnvelope: ab.rmsEnvelope,
            duration: ab.duration,
            hadStereo: ab.hadStereo)
    }

    /// Re-fuse a cue matrix under caller-supplied weights, so the harness can
    /// sweep candidate weightings without re-running the DSP. `weights` is
    /// `[band, tonal, mod]` (renormalised) and `midWeight` blends the
    /// stereo-centre cue in on top.
    public static func refuse(
        cues: [[Double]], weights: [Double], midWeight: Double, hasMid: Bool
    ) -> [Float] {
        guard weights.count == 3 else { return [] }
        let norm = max(weights.reduce(0, +), 1e-9)
        let raw = cues.map { row -> Float in
            guard row.count >= 6 else { return 0 }
            let mono = (weights[0] * row[0] + weights[1] * row[1]
                + weights[2] * row[2]) / norm
            let combined = hasMid
                ? (1 - midWeight) * mono + midWeight * row[3]
                : mono
            return Float(max(0, min(1, row[4] * combined * row[5])))
        }
        // Same 3-second median smoothing the real fusion ends with, so a swept
        // weighting is scored exactly as it would behave if adopted.
        guard raw.count >= 3 else { return raw }
        var out = raw
        for i in 1..<(raw.count - 1) {
            var w = [raw[i - 1], raw[i], raw[i + 1]]
            w.sort()
            out[i] = w[1]
        }
        return out
    }
}
