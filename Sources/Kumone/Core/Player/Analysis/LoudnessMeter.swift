#if os(macOS)
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

    /// **Plain, unweighted RMS of a signal, in dBFS** — not LUFS, no gating,
    /// no K-weighting, nothing frequency-dependent at all.
    ///
    /// It exists for the output-tap instrument (`PlaybackEngine`'s capture
    /// journal line), where the question is not "how loud does this master
    /// sound" but "did these eight seconds of the mixer's output leave the
    /// engine at the same level as those eight seconds". That is a question
    /// about *this* signal chain's gain, and the honest answer to it is the
    /// one with the fewest opinions in it: a K-weighted gated number would
    /// also move when the *music* changed, which is exactly the confound the
    /// seam-versus-body comparison must not have. The gated LUFS figure is
    /// journalled alongside it, so a reader who wants the perceptual number
    /// has it — but the two answer different questions and the line says
    /// which is which.
    ///
    /// Nil for an empty or digitally silent buffer: "no opinion", the same
    /// contract `integratedLUFS` and `peakDBFS` keep.
    static func rmsDBFS(_ x: [Float]) -> Double? {
        guard !x.isEmpty else { return nil }
        var meanSquare: Float = 0
        vDSP_measqv(x, 1, &meanSquare, vDSP_Length(x.count))
        guard meanSquare > 0 else { return nil }
        return 10 * log10(Double(meanSquare))
    }

    /// Coherent mono downmix — the mean of the channels, sample by sample.
    ///
    /// The same downmix `TrackAnalyzer` gets from `AVAudioConverter` when it
    /// decodes a file for analysis, and deliberately so: a tap measured this
    /// way is directly comparable to the `referenceLoudness` of the track that
    /// produced it, which is the whole point of measuring taps. Its one failure
    /// mode is the usual one — anti-phase stereo content cancels and reads low
    /// — and it is the same failure the analysis numbers already carry, so the
    /// *difference* between a tap and its source is still clean.
    static func monoDownmix(_ channels: [[Float]]) -> [Float] {
        guard let first = channels.first else { return [] }
        guard channels.count > 1 else { return first }
        let length = channels.reduce(Int.max) { Swift.min($0, $1.count) }
        guard length > 0 else { return [] }
        var sum = [Float](repeating: 0, count: length)
        for channel in channels {
            channel.withUnsafeBufferPointer { source in
                vDSP_vadd(sum, 1, source.baseAddress!, 1, &sum, 1, vDSP_Length(length))
            }
        }
        var scale = 1 / Float(channels.count)
        var out = [Float](repeating: 0, count: length)
        vDSP_vsmul(sum, 1, &scale, &out, 1, vDSP_Length(length))
        return out
    }

    /// Peak sample magnitude in dBFS, or nil for an all-zero/empty signal.
    static func peakDBFS(_ x: [Float]) -> Double? {
        guard !x.isEmpty else { return nil }
        var peak: Float = 0
        vDSP_maxmgv(x, 1, &peak, vDSP_Length(x.count))
        guard peak > 0 else { return nil }
        return 20 * log10(Double(peak))
    }

    /// **True peak** in dBTP: the largest magnitude the *continuous* waveform
    /// reaches between samples, not just at them.
    ///
    /// BS.1770-4's method — oversample 4× through a windowed-sinc interpolator
    /// and take the peak of that. It matters here because the two numbers can
    /// differ by a dB or more on limited material: a peak limiter holds sample
    /// values at its ceiling and, in doing so, produces exactly the flat-topped
    /// runs whose reconstructed waveform bulges above them. So a capture whose
    /// `peak` sits at the ceiling and whose `truePeak` sits a little over it is
    /// a limiter working as designed, while a `peak` over the ceiling is a
    /// limiter that is not in circuit.
    ///
    /// 4× and a 48-coefficient kernel are the spec's own minimum, and enough
    /// for what this decides. A kernel that short leaves a couple of tenths of
    /// a dB of error either way near the top of the band — a full-scale
    /// quarter-rate tone whose samples all land 45° off the crest comes back at
    /// −0.17 dBTP rather than 0 — which is an order of magnitude under the dB
    /// the journal is read for, and the same accuracy any 4× meter has.
    ///
    /// Nil for an empty or digitally silent signal, the same "no opinion"
    /// contract as `peakDBFS`.
    /// **Is this signal the same audio twice, a fraction of a millisecond
    /// apart?** The normalised autocorrelation of the second difference over
    /// lags of 0.05–12 ms, and the lag of its highest local maximum.
    ///
    /// Two copies of one signal summed with a short delay — the signature of
    /// a graph that reaches the output by two paths — produce a sharp peak at
    /// the delay that music itself does not have: on the corpus, bodies and
    /// their source files sit at or below ~0.2, and the one field capture
    /// that listened "underwater" read 0.62 at 0.40 ms. Whitening by the
    /// second difference is what makes that threshold hold — the raw
    /// autocorrelation of anything with bass is near 1 at every short lag.
    static func combPeak(_ x: [Float], sampleRate: Double) -> (delayMilliseconds: Double, value: Double)? {
        let n = x.count
        let start = Int(sampleRate * 0.5)
        let length = min(Int(sampleRate * 6), n - start - Int(sampleRate * 0.012) - 4)
        guard length > Int(sampleRate) else { return nil }
        var d = [Float](repeating: 0, count: n)
        for i in 2..<n { d[i] = x[i] - 2 * x[i - 1] + x[i - 2] }
        var e0: Float = 0
        d.withUnsafeBufferPointer { p in
            vDSP_svesq(p.baseAddress! + start, 1, &e0, vDSP_Length(length))
        }
        guard e0 > 0 else { return nil }
        let minLag = max(2, Int(sampleRate * 0.00005)), maxLag = Int(sampleRate * 0.012)
        var rows: [Float] = []
        rows.reserveCapacity(maxLag - minLag + 1)
        d.withUnsafeBufferPointer { p in
            for lag in minLag...maxLag {
                var dot: Float = 0
                vDSP_dotpr(p.baseAddress! + start, 1, p.baseAddress! + start + lag, 1,
                           &dot, vDSP_Length(length))
                rows.append(dot / e0)
            }
        }
        var best: (Int, Float)?
        for i in 1..<(rows.count - 1)
        where rows[i] > rows[i - 1] && rows[i] >= rows[i + 1] {
            if best == nil || rows[i] > best!.1 { best = (i + minLag, rows[i]) }
        }
        guard let (lag, value) = best else { return nil }
        return (Double(lag) / sampleRate * 1000, Double(value))
    }

    static func truePeakDBTP(_ x: [Float]) -> Double? {
        guard let samplePeak = peakDBFS(x) else { return nil }
        let phases = 4, taps = 12
        let length = phases * taps
        let centre = Double(length - 1) / 2
        var kernel = [Float](repeating: 0, count: length)
        for n in 0..<length {
            let t = (Double(n) - centre) / Double(phases)
            let sinc = abs(t) < 1e-12 ? 1 : sin(.pi * t) / (.pi * t)
            let phase = 2 * Double.pi * Double(n) / Double(length - 1)
            let window = 0.42 - 0.5 * cos(phase) + 0.08 * cos(2 * phase)
            kernel[n] = Float(sinc * window)
        }
        // Unity DC per phase: every interpolated sample has to reproduce a
        // constant input exactly, or the "peak" would be a gain error.
        for phase in 0..<phases {
            var sum: Float = 0
            for tap in 0..<taps { sum += kernel[tap * phases + phase] }
            guard sum != 0 else { continue }
            for tap in 0..<taps { kernel[tap * phases + phase] /= sum }
        }
        // Only positions whose whole kernel window lies inside the signal.
        // The alternative — zero-padding the ends — makes the buffer's own
        // first and last sample a step discontinuity, and a sinc interpolator
        // rings on a step: on a constant 0.5 that alone reads +1 dB, which
        // would be a fabricated over on every capture. Six samples at each end
        // of an eight-second window cost nothing.
        var peak: Float = 0
        for i in (taps - 1)..<x.count {
            for phase in 0..<phases {
                var accumulator: Float = 0
                for tap in 0..<taps {
                    accumulator += kernel[tap * phases + phase] * x[i - tap]
                }
                peak = Swift.max(peak, abs(accumulator))
            }
        }
        guard peak > 0 else { return samplePeak }
        // Never below the samples themselves: the interpolator is an estimate
        // and the sample values are ground truth.
        return Swift.max(samplePeak, 20 * log10(Double(peak)))
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
#endif
