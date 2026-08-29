import Accelerate
import Foundation

/// ITU-R BS.1770-4 gated integrated loudness, in LUFS. Pure vDSP, no
/// third-party code (docs/automix-research-notes.md §2.2a).
///
/// Why BS.1770 and not walkywalker's "mean RMS of the frames above 80 % of the
/// track's RMS peak" (`bass_detector.cpp:46-57`, described in §1.2):
///
///  * We need an **absolute** per-track number. The compensation trim has to be
///    computable from one track alone — a deck is loaded before we know what
///    plays after it, and the trim must not jump mid-song when the neighbour
///    changes. That only works against a fixed target (−14 LUFS), which in turn
///    only means anything on a calibrated perceptual scale. An 80 %-peak RMS is
///    a relative proxy: fine for "which of these two is louder", useless as
///    "how far is this from the house level".
///  * The one thing the 80 % trick buys — ignoring intro/outro/quiet passages —
///    is exactly what BS.1770's two-stage gate does, and does better: an
///    absolute −70 LUFS gate drops silence, then a relative −10 LU gate drops
///    everything well under the track's own body. The 80 % rule is a
///    hand-picked constant doing the same job with no defence.
///  * RMS is frequency-flat and the ear is not. A bass-forward master reads
///    several dB louder on RMS than it sounds; K-weighting (a +4 dB high shelf
///    and a 38 Hz high-pass — two biquads) is the whole correction, and it is
///    cheap. Since the compensation directly changes playback level, being
///    wrong here is audible, so we pay the two biquads.
///
/// Both were considered; only this one is computed. The 80 %-peak RMS would
/// have needed the same decode and the same gating discussion to end up a worse
/// estimate of the same quantity.
///
/// **Mono input.** The analyzer works on a 22.05 kHz mono downmix. BS.1770 sums
/// weighted channel powers (G = 1.0 for L and R), so a centred stereo master and
/// its mono downmix differ by exactly 3.01 dB. We therefore report the mono
/// signal *as if duplicated to both channels* (`+10·log10(2)`), which makes the
/// number directly comparable to the ITU value a stereo meter would print for
/// the same master. Off-centre content reads slightly low, which is the
/// conservative direction for a boost.
enum LoudnessMeter {

    /// Block length and hop of the BS.1770 sliding window (400 ms, 75 % overlap).
    private static let blockSeconds = 0.400
    private static let hopSeconds = 0.100
    /// Absolute silence gate, and the relative gate below the ungated mean.
    private static let absoluteGateLUFS = -70.0
    private static let relativeGateLU = -10.0
    /// BS.1770's channel-summation offset.
    private static let offsetDB = -0.691

    /// Gated integrated loudness of a mono signal, in LUFS.
    ///
    /// Returns nil when the input is shorter than one 400 ms block, or when
    /// every block falls under the absolute gate (digital silence) — "no
    /// opinion" rather than a fabricated −∞.
    static func integratedLUFS(_ x: [Float], sampleRate: Double) -> Double? {
        guard sampleRate > 0 else { return nil }
        let blockLength = Int(blockSeconds * sampleRate)
        let hop = Int(hopSeconds * sampleRate)
        guard blockLength > 0, hop > 0, x.count >= blockLength else { return nil }

        let weighted = kWeighted(x, sampleRate: sampleRate)

        // Mean square per 400 ms block, hopped by 100 ms.
        var powers: [Double] = []
        powers.reserveCapacity((weighted.count - blockLength) / hop + 1)
        weighted.withUnsafeBufferPointer { wb in
            var start = 0
            while start + blockLength <= weighted.count {
                var meanSquare: Float = 0
                vDSP_measqv(wb.baseAddress! + start, 1, &meanSquare, vDSP_Length(blockLength))
                powers.append(Double(meanSquare))
                start += hop
            }
        }
        guard !powers.isEmpty else { return nil }

        /// Block (or gated-mean) power → loudness, mono counted as two channels.
        func loudness(_ power: Double) -> Double {
            guard power > 0 else { return -.infinity }
            return offsetDB + 10 * log10(2 * power)
        }

        let aboveAbsolute = powers.filter { loudness($0) > absoluteGateLUFS }
        guard !aboveAbsolute.isEmpty else { return nil }

        let ungatedMean = aboveAbsolute.reduce(0, +) / Double(aboveAbsolute.count)
        let relativeGate = loudness(ungatedMean) + relativeGateLU
        let gated = aboveAbsolute.filter { loudness($0) > relativeGate }
        // The relative gate can in principle empty the set (a signal whose
        // blocks all sit within 10 LU below their own mean cannot, but guard
        // anyway); fall back to the ungated mean rather than returning nil.
        let kept = gated.isEmpty ? aboveAbsolute : gated
        let result = loudness(kept.reduce(0, +) / Double(kept.count))
        return result.isFinite ? result : nil
    }

    /// Peak sample magnitude in dBFS, or nil for an all-zero/empty signal.
    static func peakDBFS(_ x: [Float]) -> Double? {
        guard !x.isEmpty else { return nil }
        var peak: Float = 0
        vDSP_maxmgv(x, 1, &peak, vDSP_Length(x.count))
        guard peak > 0 else { return nil }
        return 20 * log10(Double(peak))
    }

    // MARK: - K-weighting

    /// The two BS.1770 pre-filter stages, applied in order.
    ///
    /// The spec tabulates coefficients at 48 kHz only; both stages are ordinary
    /// biquads, so they are re-derived here at the caller's rate by the
    /// bilinear transform (the standard design that reproduces the tabulated
    /// 48 kHz numbers exactly). We run at 22.05 kHz, so this is not optional.
    private static func kWeighted(_ x: [Float], sampleRate fs: Double) -> [Float] {
        biquad(biquad(x, shelfCoefficients(fs: fs)), highPassCoefficients(fs: fs))
    }

    /// Stage 1: the "head effect" high shelf, +3.9998 dB above ~1682 Hz.
    private static func shelfCoefficients(fs: Double) -> [Float] {
        let gainDB = 3.999843853973347
        let q = 0.7071752369554196
        let fc = 1681.974450955533
        let k = tan(.pi * fc / fs)
        let vh = pow(10.0, gainDB / 20.0)
        let vb = pow(vh, 0.4996667741545416)
        let a0 = 1 + k / q + k * k
        return coefficients(
            b0: (vh + vb * k / q + k * k) / a0,
            b1: 2 * (k * k - vh) / a0,
            b2: (vh - vb * k / q + k * k) / a0,
            a1: 2 * (k * k - 1) / a0,
            a2: (1 - k / q + k * k) / a0)
    }

    /// Stage 2: the RLB high-pass at ~38 Hz.
    private static func highPassCoefficients(fs: Double) -> [Float] {
        let q = 0.5003270373238773
        let fc = 38.13547087602444
        let k = tan(.pi * fc / fs)
        let denominator = 1 + k / q + k * k
        return coefficients(
            b0: 1, b1: -2, b2: 1,
            a1: 2 * (k * k - 1) / denominator,
            a2: (1 - k / q + k * k) / denominator)
    }

    private static func coefficients(
        b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    ) -> [Float] {
        [Float(b0), Float(b1), Float(b2), Float(a1), Float(a2)]
    }

    /// Direct-form-I biquad over the whole signal, zero initial state.
    ///
    /// `vDSP_deq22` wants two samples of history in front of both the input and
    /// the output, so both buffers are padded by two zeros and the padding is
    /// dropped on the way out.
    private static func biquad(_ x: [Float], _ coefficients: [Float]) -> [Float] {
        guard !x.isEmpty else { return x }
        var input = [Float](repeating: 0, count: x.count + 2)
        input.replaceSubrange(2..<input.count, with: x)
        var output = [Float](repeating: 0, count: x.count + 2)
        vDSP_deq22(input, 1, coefficients, &output, 1, vDSP_Length(x.count))
        return Array(output[2...])
    }
}
