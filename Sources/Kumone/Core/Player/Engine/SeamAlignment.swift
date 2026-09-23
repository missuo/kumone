#if os(macOS)
import Accelerate
import AVFoundation
import Foundation

/// **Where a captured seam actually sits on the songs it was made from.**
///
/// The splice plays three sources through one mixer — the outgoing deck, a
/// pre-rendered segment, the incoming deck — and hands over between them with
/// two *identity* crossfades: half a second in which two of the three carry the
/// same music, so the swap is `(1-u)·x + u·x` and inaudible. That identity is
/// the whole design, and it is also the whole failure mode: if the two copies
/// are not sample-aligned, the crossfade is not an identity but a comb filter,
/// and the listener hears the flam that was reported as 两段没拼好、有重叠.
///
/// Nothing in the engine could say whether they *were* aligned. The clocks all
/// agree with each other by construction (the segment is released at the host
/// time the outgoing deck's player clock says `spliceStart` lands), so every
/// number the engine can print is a tautology; the only honest witness is the
/// audio that left the mixer. That is what this measures, from the six-second
/// output taps the engine already records at each end of a splice:
///
/// 1. take a window of the capture from *before* the crossfade and a window
///    from *after* it — one source alone in each;
/// 2. find where each window really sits on the source file it came from, by
///    normalised cross-correlation around the position the engine believed it
///    was at;
/// 3. the difference of the two residuals is the seam offset — how far apart
///    the two copies of the identity window were, in milliseconds of the
///    listener's own time base.
///
/// The value of measuring the *difference* rather than either residual alone is
/// that everything common to both — the capture's own start timestamp, the
/// output device's latency, the tap's position in the graph — cancels exactly.
/// A 50 ms error in when we think the capture started moves the two residuals
/// together and changes the difference by `(rate − 1)·50 ms`, i.e. by a third
/// of a millisecond on the ±1 % bends a tempo glide asks for.
///
/// Everything here is pure and file-level: no engine state, no audio clock, and
/// therefore testable against synthetic signals with a known offset.
enum SeamAlignment {

    /// One window's verdict: where the audio really was, and how much the
    /// correlator believes it.
    struct Match: Equatable, Sendable {
        /// Seconds by which the played audio ran *ahead* of where the engine
        /// thought it was. Positive means it was further into the song.
        var offsetSeconds: TimeInterval
        /// Peak normalised correlation, −1…1. Above ~0.9 the two signals are
        /// the same music; below ~0.5 the answer is noise wearing a number.
        var correlation: Double
    }

    /// First difference, applied to both sides of every correlation.
    ///
    /// Music is dominated by low frequencies whose period is longer than the
    /// offsets we are looking for, and a correlation of two bass-heavy signals
    /// has a peak tens of milliseconds wide — precise to the width of the peak,
    /// which is exactly the resolution we cannot afford to lose. Differencing
    /// tilts the spectrum +6 dB/octave, which sharpens the peak to the width of
    /// the transients, and it removes DC and any slow gain difference between
    /// the tap (post-trim, post-ride, post-limiter) and the raw file.
    ///
    /// Applied to *both* signals it introduces no relative shift of its own:
    /// `y[i] = x[i+1] − x[i]` moves both by the same half sample.
    static func preEmphasised(_ x: [Float]) -> [Float] {
        guard x.count > 1 else { return [] }
        var out = [Float](repeating: 0, count: x.count - 1)
        for i in 0..<out.count { out[i] = x[i + 1] - x[i] }
        return out
    }

    /// Linear resampling, by hand and on purpose.
    ///
    /// `AVAudioConverter` would do this better, but it has a latency of its own
    /// that Core Audio does not publish — and a resampler that silently shifts
    /// its output by an unknown number of samples is the one tool a *latency*
    /// measurement may not use. Linear interpolation is a mild low-pass and
    /// nothing else: sample `i` of the output is exactly `i·source/target`
    /// samples into the input, by construction, which is the only property this
    /// measurement asks of it. The correlation is run on differenced signals
    /// whose peak is many samples wide, so the interpolation's error costs
    /// confidence, not position.
    static func resampled(_ x: [Float], from source: Double, to target: Double) -> [Float] {
        guard source > 0, target > 0, x.count > 1 else { return x }
        if abs(source - target) < 1e-9 { return x }
        let step = source / target
        let count = Int((Double(x.count - 1) / step).rounded(.down)) + 1
        guard count > 1 else { return [] }
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let position = Double(i) * step
            let index = min(Int(position), x.count - 2)
            let fraction = Float(position - Double(index))
            out[i] = x[index] + (x[index + 1] - x[index]) * fraction
        }
        return out
    }

    /// Slide `probe` over `reference` around `expectedIndex` and report the
    /// best normalised match.
    ///
    /// Normalised per lag — the denominator uses the energy of *this* window of
    /// the reference, not of the whole of it — so the peak cannot be bought by
    /// sliding onto a louder passage, and the returned correlation is directly
    /// comparable between seams, tracks and levels. That comparability is what
    /// the calibration gate (`SeamLatencyCalibration.minCorrelation`) spends.
    ///
    /// The peak is refined by fitting a parabola through it and its two
    /// neighbours, which is the standard sub-sample interpolation for a
    /// correlation maximum. Without it the answer is quantised to a sample
    /// (23 µs at 44.1 kHz) — already far finer than the millisecond the seam is
    /// reported in, so this is belt and braces rather than a necessity.
    ///
    /// - Parameters:
    ///   - expectedIndex: index into `reference` where `probe` would start if
    ///     the engine's clocks were telling the truth.
    ///   - radiusSamples: how far either side of that to look.
    ///   - sampleRate: of `probe` — the rate the answer is expressed in.
    /// - Returns: nil when there is nothing to measure (an empty probe, a
    ///   silent one, a reference too short to hold the search).
    static func match(probe: [Float], reference: [Float],
                      expectedIndex: Int, radiusSamples: Int,
                      sampleRate: Double) -> Match? {
        let n = probe.count
        guard n > 8, sampleRate > 0, radiusSamples >= 0, reference.count >= n else {
            return nil
        }
        var probeEnergy: Float = 0
        vDSP_svesq(probe, 1, &probeEnergy, vDSP_Length(n))
        guard probeEnergy > 0 else { return nil }

        let lowest = max(-radiusSamples, -expectedIndex)
        let highest = min(radiusSamples, reference.count - n - expectedIndex)
        guard lowest <= highest else { return nil }

        var values = [Double](repeating: -1, count: highest - lowest + 1)
        var bestLag = lowest
        var bestValue = -Double.infinity
        reference.withUnsafeBufferPointer { ref in
            guard let base = ref.baseAddress else { return }
            for lag in lowest...highest {
                let window = base + (expectedIndex + lag)
                var dot: Float = 0
                var energy: Float = 0
                vDSP_dotpr(probe, 1, window, 1, &dot, vDSP_Length(n))
                vDSP_svesq(window, 1, &energy, vDSP_Length(n))
                let denominator = (Double(probeEnergy) * Double(energy)).squareRoot()
                let value = denominator > 0 ? Double(dot) / denominator : 0
                values[lag - lowest] = value
                if value > bestValue {
                    bestValue = value
                    bestLag = lag
                }
            }
        }
        guard bestValue > -.infinity else { return nil }

        var fraction = 0.0
        let peak = bestLag - lowest
        if peak > 0, peak < values.count - 1 {
            let left = values[peak - 1]
            let right = values[peak + 1]
            let curvature = left - 2 * bestValue + right
            if curvature < 0 {
                fraction = max(-0.5, min(0.5, 0.5 * (left - right) / curvature))
            }
        }
        return Match(offsetSeconds: (Double(bestLag) + fraction) / sampleRate,
                     correlation: bestValue)
    }
}

/// One side of a seam capture: a stretch of the recorded output, and where the
/// engine believes it sits on one of the two songs.
struct SeamOffsetWindow: Equatable, Sendable {
    /// Seconds into the capture file.
    var captureStart: TimeInterval
    /// How much of it to correlate.
    var duration: TimeInterval
    /// Source-track position the engine believes `captureStart` is playing.
    var expectedSource: TimeInterval
    /// Source seconds consumed per second of wall clock while this window
    /// plays — the deck's time-pitch rate, or the segment's rendered tempo map
    /// slope. The reference is resampled by this so that one reference sample
    /// is one *wall* sample and the answer comes out in the listener's time
    /// base rather than the song's.
    var sourceRate: Double = 1
}

/// The finished comparison of a seam's two sides.
struct SeamOffsetMeasurement: Equatable, Sendable {
    /// How far the source taking over ran ahead of the one handing off, in
    /// milliseconds. Positive at the head means the segment was ahead of the
    /// live outgoing deck; positive at the tail means the live incoming deck
    /// was ahead of the segment. Either way: positive means the new arrival is
    /// early and should be released later.
    var offsetMilliseconds: Double
    var beforeCorrelation: Double
    var afterCorrelation: Double

    /// Whether both halves found their music. The calibration only ever moves
    /// on a measurement that passes this.
    var isTrusted: Bool {
        min(beforeCorrelation, afterCorrelation) >= SeamLatencyCalibration.minCorrelation
    }

    /// `+19.2ms (corr 0.98/0.97)` — the journal's and the panel's shared
    /// spelling, so a field line and a debug row can never disagree.
    var summary: String {
        String(format: "%+.1fms (corr %.2f/%.2f)",
               offsetMilliseconds, beforeCorrelation, afterCorrelation)
    }
}

/// Turns a finished output-tap capture plus two expectations into a seam
/// offset. The only part of the measurement that touches the file system.
enum SeamOffsetMeter {

    /// How far either side of the expected position to search.
    ///
    /// Comfortably wider than anything the seam can plausibly be out by (the
    /// symptom under investigation is ~19 ms, and a whole I/O quantum is 12) and
    /// wide enough to absorb the slop in the capture's own start timestamp,
    /// which is a render timestamp rather than an output one. Wider still would
    /// only buy the correlator more chances to find a spurious peak on
    /// repetitive material.
    static let searchRadius: TimeInterval = 0.08

    /// Shortest window worth correlating. Below this a bar of four-on-the-floor
    /// can match itself at the wrong beat.
    static let minimumWindow: TimeInterval = 0.10

    /// Measure one capture.
    ///
    /// - Parameters:
    ///   - capture: the `.caf` the output tap wrote.
    ///   - source: the track both windows are compared against — the *outgoing*
    ///     track for a head capture, the *incoming* track for a tail one.
    ///   - before / after: the two windows, in that temporal order.
    /// - Returns: nil when either window cannot be read or cannot be matched;
    ///   the caller journals `unmeasured` rather than a fabricated zero.
    static func measure(capture: URL, source: URL,
                        before: SeamOffsetWindow, after: SeamOffsetWindow,
                        radius: TimeInterval = searchRadius) -> SeamOffsetMeasurement? {
        guard let captureFile = try? AVAudioFile(forReading: capture),
              let sourceFile = try? AVAudioFile(forReading: source),
              let first = match(capture: captureFile, source: sourceFile,
                                window: before, radius: radius),
              let second = match(capture: captureFile, source: sourceFile,
                                 window: after, radius: radius)
        else { return nil }
        return SeamOffsetMeasurement(
            offsetMilliseconds: (second.offsetSeconds - first.offsetSeconds) * 1000,
            beforeCorrelation: first.correlation,
            afterCorrelation: second.correlation)
    }

    /// One window against its source file.
    ///
    /// The reference is read at the file's own rate and resampled to
    /// `captureRate / sourceRate`, so that one reference sample advances the
    /// *song* by `sourceRate/captureRate` seconds and the *wall clock* by
    /// exactly one capture sample. A lag in samples is then a lag in the
    /// listener's seconds with no further arithmetic, and a deck bent 0.7 % by
    /// a tempo glide does not quietly bias the answer by the 2 ms it drifts
    /// across a 0.3 s window.
    private static func match(capture: AVAudioFile, source: AVAudioFile,
                              window: SeamOffsetWindow,
                              radius: TimeInterval) -> SeamAlignment.Match? {
        let captureRate = capture.processingFormat.sampleRate
        let sourceFileRate = source.processingFormat.sampleRate
        guard captureRate > 0, sourceFileRate > 0,
              window.duration >= minimumWindow, window.sourceRate > 0 else { return nil }

        guard let probeRaw = mono(of: capture, from: window.captureStart,
                                  duration: window.duration) else { return nil }

        // The reference has to cover the window plus the search either side of
        // it, measured on the *song's* clock — the window spans
        // `duration · sourceRate` seconds of song, not `duration`.
        let referenceStart = window.expectedSource - radius * window.sourceRate
        let referenceSpan = window.duration * window.sourceRate + 2 * radius * window.sourceRate
        guard referenceStart >= 0 else { return nil }
        guard let referenceRaw = mono(of: source, from: referenceStart,
                                      duration: referenceSpan + 2 / sourceFileRate)
        else { return nil }

        let referenceRate = captureRate / window.sourceRate
        let reference = SeamAlignment.preEmphasised(
            SeamAlignment.resampled(referenceRaw, from: sourceFileRate, to: referenceRate))
        let probe = SeamAlignment.preEmphasised(probeRaw)
        // `mono` rounds its start to a whole source frame; that residual is
        // under half a sample and is folded in here rather than ignored.
        let actualStart = (referenceStart * sourceFileRate).rounded() / sourceFileRate
        let expectedIndex = Int(((window.expectedSource - actualStart) * referenceRate).rounded())
        return SeamAlignment.match(probe: probe, reference: reference,
                                   expectedIndex: expectedIndex,
                                   radiusSamples: Int((radius * captureRate).rounded()),
                                   sampleRate: captureRate)
    }

    /// A mono window of a file, at the file's own rate. Nil past either end.
    static func mono(of file: AVAudioFile, from seconds: TimeInterval,
                     duration: TimeInterval) -> [Float]? {
        let rate = file.processingFormat.sampleRate
        guard rate > 0, duration > 0 else { return nil }
        let start = AVAudioFramePosition((seconds * rate).rounded())
        let frames = AVAudioFrameCount((duration * rate).rounded())
        guard start >= 0, frames > 0, start + AVAudioFramePosition(frames) <= file.length,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: frames)
        else { return nil }
        file.framePosition = start
        guard (try? file.read(into: buffer, frameCount: frames)) != nil,
              buffer.frameLength == frames,
              let data = buffer.floatChannelData else { return nil }
        let channels = (0..<Int(buffer.format.channelCount)).map {
            Array(UnsafeBufferPointer(start: data[$0], count: Int(frames)))
        }
        guard !channels.isEmpty else { return nil }
        return LoudnessMeter.monoDownmix(channels)
    }
}
#endif
