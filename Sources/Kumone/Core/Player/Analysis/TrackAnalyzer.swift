import Accelerate
import AVFoundation
import Foundation

// Beat/energy analysis, pure vDSP/Accelerate (spec §4). No third-party code.
//
// Pipeline: STFT (1024/256, Hann) → 40-band log-mel → spectral flux onset
// envelope → autocorrelation + log-normal tempo prior → BPM, then dynamic
// programming (Ellis 2007) for the beat grid, low-frequency voting for
// downbeats, and RMS-based structure features (phrases, intro, outro).
//
// The same pass also feeds `StructureSegmenter` (v7), which turns the per-beat
// log-mel/chroma into a self-similarity matrix and hands back `sections` —
// intro/verse/chorus/… — or nothing at all when it is not confident.
//
// The same STFT pass also feeds two tonal/timbral estimators: a peak-picked
// chromagram → Krumhansl-Schmuckler template matching for the key, and a
// four-feature vocal-activity detector.
//
// Vocal activity (v5). The three mono-spectral cues that shipped in v4 —
// vocal-band energy share, band spectral flatness, 2–8 Hz syllable/vibrato
// modulation — could not tell "a harmonic instrument sitting in the mid band"
// (sax, distorted guitar, a synth lead) from "someone singing"; validated
// against StemKit separation on the eval corpus, v4's top-scored windows often
// held essentially no real vocal energy. v5 adds one cheap, orthogonal cue
// (docs/automix-stems-predev.md §7.3), pure vDSP:
//   • Mid/side centre ratio — lead vocals sit at the stereo centre (mid=L+R),
//     accompaniment and effects spread wider (side=L−R); the vocal band's mid
//     share is high when a centred voice is present. Needs the stereo signal,
//     so `analyze(fileAt:)` decodes L/R in parallel with the mono pass (a
//     second, band-energy-only FFT sweep — see `stereoVoiceEnergies`). The
//     mono `analyze(samples:)` test entry has no stereo image and skips it.
//
// §7.3's other proposal, an HPSS harmonic share (Fitzgerald 2010 median-filter
// harmonic/percussive separation over the vocal band), was implemented and
// measured against the same ground truth and did NOT survive: its standalone
// correlation with per-second vocal/mix energy was +0.015, and a weight search
// under leave-one-playlist-out CV drove its weight to ~0 in all six folds.
// Sustained harmonic energy in 200 Hz–4 kHz is as much guitar/synth/strings as
// voice, so it adds nothing the band and tonality cues do not already carry. It
// was removed rather than left at weight 0 because it was by far the most
// expensive part of the analysis (a per-bin double median filter, plus
// retaining the whole vocal-band spectrogram). Recoverable from git history if
// a future cue wants it.
enum TrackAnalyzer {
    static let analysisSampleRate: Double = 22_050

    enum AnalyzerError: Error {
        case unsupportedFormat
    }

    // MARK: - Entry points

    /// Decode to 22.05 kHz mono, then analyze. CPU-bound; callers run this
    /// off the main thread.
    static func analyze(fileAt url: URL) throws -> TrackAnalysis {
        let samples = try decodeMono(url: url, targetRate: analysisSampleRate)
        // Second, stereo decode for the mid/side vocal cue. Best-effort: a
        // failure (or a truly mono master) simply drops the cue, and the three
        // mono-spectral features carry the estimate on their own.
        let midSide = try? stereoVoiceEnergies(url: url, targetRate: analysisSampleRate)
        return analyze(samples: samples, sampleRate: analysisSampleRate, midSide: midSide)
    }

    /// In-memory entry point (used by tests with synthetic signals).
    /// `samples` is mono; any sample rate is accepted and resampled.
    static func analyze(samples: [Float], sampleRate: Double) -> TrackAnalysis {
        analyze(samples: samples, sampleRate: sampleRate, midSide: nil)
    }

    /// S0.5 validation hook (offline `vocaleval` only, never the app).
    ///
    /// Runs one decode + one STFT pass and returns the per-second cue vectors
    /// together with both fusions: `v4` replays the three-cue weighting that
    /// shipped before this change, `v5` is what the analyzer now produces. Both
    /// therefore rest on byte-identical features, so a correlation difference
    /// between them is attributable to the fusion weights and the new mid/side
    /// cue alone — not to decode or windowing drift.
    static func vocalActivityAB(fileAt url: URL) throws -> VocalActivityAB {
        let sr = analysisSampleRate
        let x = try decodeMono(url: url, targetRate: sr)
        let rmsEnvelope = rmsPerSecond(x, sampleRate: sr)
        let duration = Double(x.count) / sr
        guard x.count >= windowSize * 4 else {
            return VocalActivityAB(
                v4: [], v5: [], cues: [], rmsEnvelope: rmsEnvelope,
                duration: duration, hadStereo: false)
        }
        let features = stftFeatures(x, sampleRate: sr)
        let midSide = try? stereoVoiceEnergies(url: url, targetRate: sr)
        let midShare: [Float]? = midSide.map {
            midSharePerFrame(mid: $0.mid, side: $0.side, frames: features.bandRatio.count)
        }
        let cues = vocalCues(
            bandRatio: features.bandRatio,
            flatness: features.flatness,
            bandEnvelope: features.bandEnvelope,
            midShare: midShare,
            fps: sr / Double(hopSize),
            rmsEnvelope: rmsEnvelope)
        return VocalActivityAB(
            v4: fuseVocalCues(cues, legacyV4: true),
            v5: fuseVocalCues(cues),
            cues: cues,
            rmsEnvelope: rmsEnvelope,
            duration: duration,
            hadStereo: midShare != nil)
    }

    struct VocalActivityAB: Sendable {
        let v4: [Float]
        let v5: [Float]
        let cues: [VocalCues]
        let rmsEnvelope: [Float]
        let duration: Double
        /// False for a genuinely mono master — the mid/side cue is inert there.
        let hadStereo: Bool
    }

    /// Core analysis. `midSide`, when present, carries per-STFT-frame vocal-band
    /// magnitude of the mid (L+R) and side (L−R) channels for the stereo-centre
    /// vocal cue; it is `nil` for the mono test entry and for mono masters.
    static func analyze(
        samples: [Float], sampleRate: Double, midSide: (mid: [Float], side: [Float])?
    ) -> TrackAnalysis {
        let sr = analysisSampleRate
        let x = resample(samples, from: sampleRate, to: sr)
        let duration = Double(x.count) / sr
        let rmsEnvelope = rmsPerSecond(x, sampleRate: sr)

        guard x.count >= windowSize * 4 else {
            return TrackAnalysis(
                version: TrackAnalysis.currentVersion,
                bpm: 0, bpmConfidence: 0,
                beats: [], downbeats: [], phraseBoundaries: [],
                rmsEnvelope: rmsEnvelope,
                outroFadeStart: nil, introEnd: 0, duration: duration,
                melProfile: [],
                keyPitchClass: nil, keyIsMinor: false, keyConfidence: 0,
                vocalActivity: [],
                referenceLoudness: LoudnessMeter.integratedLUFS(x, sampleRate: sr),
                peakDBFS: LoudnessMeter.peakDBFS(x))
        }

        let features = stftFeatures(x, sampleRate: sr)
        let mel = features.mel
        let lowEnergy = features.low
        let onset = onsetEnvelope(mel)
        let fps = sr / Double(hopSize)

        let tempo = estimateTempo(onset: onset, fps: fps)
        var bpm = tempo.bpm
        let confidence = tempo.confidence

        var beats: [TimeInterval] = []
        if bpm > 0, bpm.isFinite {
            beats = trackBeats(onset: onset, fps: fps, bpm: bpm)
            // Refine BPM from the tracked grid: the total span is robust to
            // per-beat frame quantization when tracking is clean.
            if beats.count >= 8, let first = beats.first, let last = beats.last, last > first {
                let spanBPM = 60.0 * Double(beats.count - 1) / (last - first)
                if abs(spanBPM - bpm) / bpm < 0.05 { bpm = spanBPM }
            }
        }

        let downbeats = estimateDownbeats(
            beats: beats, onset: onset, lowEnergy: lowEnergy, fps: fps)
        let phrases = phraseBoundaries(
            downbeats: downbeats, rmsEnvelope: rmsEnvelope)
        let outro = outroFadeStart(rmsEnvelope: rmsEnvelope)
        let intro = introEnd(
            rmsEnvelope: rmsEnvelope, downbeats: downbeats, beats: beats)

        let key = detectKey(
            chromaFrames: features.chroma, frameEnergy: features.chromaEnergy)
        // Align the (independently decoded) stereo envelopes to the mono frame
        // count; the two decode paths can differ by a frame at the tail.
        let midShare: [Float]? = midSide.map { ms in
            midSharePerFrame(mid: ms.mid, side: ms.side, frames: features.bandRatio.count)
        }
        let vocals = vocalActivity(
            bandRatio: features.bandRatio,
            flatness: features.flatness,
            bandEnvelope: features.bandEnvelope,
            midShare: midShare,
            fps: fps,
            rmsEnvelope: rmsEnvelope)

        // Structure segmentation rides on the features already in hand — no
        // second sweep over the audio — and returns nothing at all when it is
        // not confident, so everything downstream keeps its pre-v7 behaviour
        // unless the track is one the segmenter is sure about.
        let structure = StructureSegmenter.segment(
            mel: mel, chroma: features.chroma, low: lowEnergy, fps: fps,
            beats: beats, downbeats: downbeats,
            rmsEnvelope: rmsEnvelope, vocalActivity: vocals, duration: duration)

        return TrackAnalysis(
            version: TrackAnalysis.currentVersion,
            bpm: bpm,
            bpmConfidence: confidence,
            beats: beats,
            downbeats: downbeats,
            phraseBoundaries: phrases,
            rmsEnvelope: rmsEnvelope,
            outroFadeStart: outro,
            introEnd: intro,
            duration: duration,
            melProfile: timbreProfile(from: mel),
            keyPitchClass: key.pitchClass,
            keyIsMinor: key.isMinor,
            keyConfidence: key.confidence,
            vocalActivity: vocals,
            // Mastered loudness for cross-track gain compensation. Measured on
            // the same resampled mono signal every other feature uses, so it
            // costs one extra pass of two biquads and no extra decode.
            referenceLoudness: LoudnessMeter.integratedLUFS(x, sampleRate: sr),
            peakDBFS: LoudnessMeter.peakDBFS(x),
            sections: structure.sections,
            structureConfidence: structure.confidence)
    }

    /// Whole-track timbre fingerprint for the planner's compatibility gate:
    /// the mean *level-free* mel shape over the loud half of the track,
    /// L2-normalized.
    ///
    /// Three details do the work, and the first is why the previous version of
    /// this function was useless. A log-mel frame is dominated by its DC term
    /// (its mean across bands — MFCC c0, i.e. loudness), which is huge and
    /// near-identical for every mastered record; averaging frames and taking a
    /// cosine therefore compared two vectors that agreed almost perfectly by
    /// construction. Fifteen real adjacent pairs landed in 0.001–0.032, an
    /// order of magnitude below the planner's thresholds — the signal never
    /// fired once. Removing each frame's own mean leaves the spectral *shape*
    /// (bass-forward modern master vs. thin old recording, dense electronic
    /// vs. sparse acoustic), and the cosine becomes a shape correlation.
    ///
    /// Second, the frames are re-compressed relative to their own magnitude
    /// before the mean is removed. `log(1 + m)` is not scale-free — the same
    /// track 26 dB quieter sits in the compressor's linear region and comes
    /// out with a measurably different shape (0.17 away, most of the way to
    /// the neutral line). Normalizing each frame by its mean magnitude first
    /// makes the fingerprint exactly invariant to playback/master gain.
    ///
    /// Third, only frames at or above the track's median frame level count.
    /// Intros, breakdowns and outros otherwise dilute every profile towards a
    /// common near-silence average; gating at the median roughly doubled the
    /// corpus separation between "a track vs. its own other half" and "two
    /// different tracks".
    ///
    /// Per-band temporal variance, spectral contrast and frame-delta blocks
    /// were all measured alongside this on the audition corpus, alone and
    /// mixed in at several weights; none improved the separation and all
    /// raised the distance a track has to its own other half, so the
    /// fingerprint stays the shape alone.
    private static func timbreProfile(from mel: [[Float]]) -> [Float] {
        guard let bands = mel.first?.count, bands > 0, mel.count >= 8 else { return [] }
        var levels = [Float](repeating: 0, count: mel.count)
        for (t, frame) in mel.enumerated() {
            var mean: Float = 0
            vDSP_meanv(frame, 1, &mean, vDSP_Length(bands))
            levels[t] = mean
        }
        let gate = levels.sorted()[levels.count / 2]

        var sum = [Float](repeating: 0, count: bands)
        var shape = [Float](repeating: 0, count: bands)
        var count = Int32(bands)
        var kept = 0
        for (t, frame) in mel.enumerated() where levels[t] >= gate {
            // Back to linear mel magnitudes, normalized by the frame's own
            // mean, then re-compressed: gain-free by construction.
            vvexpf(&shape, frame, &count)
            var minusOne: Float = -1
            vDSP_vsadd(shape, 1, &minusOne, &shape, 1, vDSP_Length(bands))
            var mean: Float = 0
            vDSP_meanv(shape, 1, &mean, vDSP_Length(bands))
            guard mean > 1e-9 else { continue }
            var scale = 1 / mean
            vDSP_vsmul(shape, 1, &scale, &shape, 1, vDSP_Length(bands))
            var one: Float = 1
            vDSP_vsadd(shape, 1, &one, &shape, 1, vDSP_Length(bands))
            vvlogf(&shape, shape, &count)
            // Remove the frame's own mean: what is left is pure shape.
            vDSP_meanv(shape, 1, &mean, vDSP_Length(bands))
            var negMean = -mean
            vDSP_vsadd(shape, 1, &negMean, &shape, 1, vDSP_Length(bands))
            vDSP_vadd(sum, 1, shape, 1, &sum, 1, vDSP_Length(bands))
            kept += 1
        }
        guard kept >= 4 else { return [] }
        var inv = 1 / Float(kept)
        vDSP_vsmul(sum, 1, &inv, &sum, 1, vDSP_Length(bands))
        let norm = sqrt(sum.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm > 1e-6 else { return [] }
        return sum.map { $0 / norm }
    }

    // MARK: - Decoding

    /// Chunked AVAudioFile read + AVAudioConverter to mono float at
    /// `targetRate`, so the full decoded file never lives in memory twice.
    private static func decodeMono(url: URL, targetRate: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let srcFormat = file.processingFormat
        guard let dstFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: targetRate,
            channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: srcFormat, to: dstFormat)
        else { throw AnalyzerError.unsupportedFormat }

        let inCapacity: AVAudioFrameCount = 1 << 16
        let outCapacity: AVAudioFrameCount = 1 << 15
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: inCapacity),
              let outBuf = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: outCapacity)
        else { throw AnalyzerError.unsupportedFormat }

        var out: [Float] = []
        out.reserveCapacity(Int(Double(file.length) * targetRate / srcFormat.sampleRate) + 1024)
        var reachedEnd = false

        while true {
            outBuf.frameLength = 0
            var convError: NSError?
            let status = converter.convert(to: outBuf, error: &convError) { _, outStatus in
                if reachedEnd {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    inBuf.frameLength = 0
                    try file.read(into: inBuf, frameCount: inCapacity)
                } catch {
                    reachedEnd = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if inBuf.frameLength == 0 {
                    reachedEnd = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return inBuf
            }
            if outBuf.frameLength > 0, let data = outBuf.floatChannelData {
                out.append(contentsOf: UnsafeBufferPointer(
                    start: data[0], count: Int(outBuf.frameLength)))
            }
            if status == .error {
                if let convError { throw convError }
                throw AnalyzerError.unsupportedFormat
            }
            if status == .endOfStream { break }
        }
        return out
    }

    /// Decode to `targetRate` two-channel float, deinterleaved as `[L, R]`.
    /// Genuinely mono sources come back with `L == R` (so `side` is zero and
    /// the mid/side cue self-disables). Returns `nil` for a one-channel source.
    private static func decodeStereo(url: URL, targetRate: Double) throws -> [[Float]]? {
        let file = try AVAudioFile(forReading: url)
        let srcFormat = file.processingFormat
        guard srcFormat.channelCount >= 2 else { return nil }
        guard let dstFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: targetRate,
            channels: 2, interleaved: false),
            let converter = AVAudioConverter(from: srcFormat, to: dstFormat)
        else { throw AnalyzerError.unsupportedFormat }

        let inCapacity: AVAudioFrameCount = 1 << 16
        let outCapacity: AVAudioFrameCount = 1 << 15
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: inCapacity),
              let outBuf = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: outCapacity)
        else { throw AnalyzerError.unsupportedFormat }

        var left: [Float] = []
        var right: [Float] = []
        let reserve = Int(Double(file.length) * targetRate / srcFormat.sampleRate) + 1024
        left.reserveCapacity(reserve)
        right.reserveCapacity(reserve)
        var reachedEnd = false

        while true {
            outBuf.frameLength = 0
            var convError: NSError?
            let status = converter.convert(to: outBuf, error: &convError) { _, outStatus in
                if reachedEnd {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    inBuf.frameLength = 0
                    try file.read(into: inBuf, frameCount: inCapacity)
                } catch {
                    reachedEnd = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if inBuf.frameLength == 0 {
                    reachedEnd = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return inBuf
            }
            if outBuf.frameLength > 0, let data = outBuf.floatChannelData {
                let count = Int(outBuf.frameLength)
                left.append(contentsOf: UnsafeBufferPointer(start: data[0], count: count))
                right.append(contentsOf: UnsafeBufferPointer(start: data[1], count: count))
            }
            if status == .error {
                if let convError { throw convError }
                throw AnalyzerError.unsupportedFormat
            }
            if status == .endOfStream { break }
        }
        return [left, right]
    }

    /// Per-STFT-frame vocal-band magnitude of the mid (`L+R`) and side (`L−R`)
    /// channels, on the same window/hop grid as the mono feature pass. Feeds the
    /// stereo-centre vocal cue. Returns `nil` when the source is mono/degenerate.
    ///
    /// This is a second FFT sweep, unavoidable: the mono downmix the rest of the
    /// analysis runs on has already collapsed the stereo image the cue depends
    /// on. It is kept as light as possible — a single band sum per frame, no
    /// mel/chroma/flatness — and mid and side go through the identical routine so
    /// their ratio is method-fair.
    static func stereoVoiceEnergies(
        url: URL, targetRate: Double
    ) throws -> (mid: [Float], side: [Float])? {
        guard let lr = try decodeStereo(url: url, targetRate: targetRate) else { return nil }
        let l = lr[0], r = lr[1]
        let count = min(l.count, r.count)
        guard count >= windowSize else { return nil }
        var mid = [Float](repeating: 0, count: count)
        var side = [Float](repeating: 0, count: count)
        vDSP_vadd(l, 1, r, 1, &mid, 1, vDSP_Length(count))
        // vDSP_vsub(A, B, C) computes C = B − A, so this yields l − r = L − R.
        vDSP_vsub(r, 1, l, 1, &side, 1, vDSP_Length(count))
        var half: Float = 0.5   // (L±R)/2
        vDSP_vsmul(mid, 1, &half, &mid, 1, vDSP_Length(count))
        vDSP_vsmul(side, 1, &half, &side, 1, vDSP_Length(count))
        return (voiceBandEnergyPerFrame(mid, sampleRate: targetRate),
                voiceBandEnergyPerFrame(side, sampleRate: targetRate))
    }

    /// Stripped STFT: per-frame summed magnitude inside the 200 Hz–4 kHz vocal
    /// band, nothing else. Same window/hop as `stftFeatures` so frames align.
    static func voiceBandEnergyPerFrame(_ x: [Float], sampleRate sr: Double) -> [Float] {
        let n = windowSize
        let hop = hopSize
        guard x.count >= n else { return [] }
        let nFrames = 1 + (x.count - n) / hop
        let log2n = vDSP_Length(10)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        let nBins = n / 2 + 1
        let binHz = sr / Double(n)
        let voiceLo = max(1, Int(vocalBandLowHz / binHz))
        let voiceHi = min(nBins - 1, Int(vocalBandHighHz / binHz))
        let voiceCount = max(0, voiceHi - voiceLo + 1)
        guard voiceCount > 0 else { return [Float](repeating: 0, count: nFrames) }

        var out = [Float](repeating: 0, count: nFrames)
        var frame = [Float](repeating: 0, count: n)
        var realp = [Float](repeating: 0, count: n / 2)
        var imagp = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: nBins)

        x.withUnsafeBufferPointer { xb in
            for t in 0..<nFrames {
                let start = t * hop
                vDSP_vmul(xb.baseAddress! + start, 1, window, 1, &frame, 1, vDSP_Length(n))
                realp.withUnsafeMutableBufferPointer { rp in
                    imagp.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(
                            realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        frame.withUnsafeBufferPointer { fb in
                            fb.baseAddress!.withMemoryRebound(
                                to: DSPComplex.self, capacity: n / 2
                            ) {
                                vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                            }
                        }
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        rp.baseAddress![0] = 0
                        ip.baseAddress![0] = 0
                        mags.withUnsafeMutableBufferPointer { mb in
                            vDSP_zvmags(&split, 1, mb.baseAddress!, 1, vDSP_Length(n / 2))
                            var count = Int32(nBins)
                            vvsqrtf(mb.baseAddress!, mb.baseAddress!, &count)
                            var voice: Float = 0
                            vDSP_sve(mb.baseAddress! + voiceLo, 1, &voice, vDSP_Length(voiceCount))
                            out[t] = voice
                        }
                    }
                }
            }
        }
        return out
    }

    /// Linear-interpolation resampler; a 2:1 box prefilter is applied first
    /// for downsampling to tame aliasing. Good enough for beat analysis.
    static func resample(_ x: [Float], from: Double, to: Double) -> [Float] {
        guard abs(from - to) > 0.5, !x.isEmpty else { return x }
        var src = x
        var srcRate = from
        while srcRate / to >= 1.99 {
            var half = [Float](repeating: 0, count: src.count / 2)
            for i in 0..<half.count {
                half[i] = 0.5 * (src[2 * i] + src[2 * i + 1])
            }
            src = half
            srcRate /= 2
        }
        guard abs(srcRate - to) > 0.5 else { return src }
        let ratio = srcRate / to
        let outCount = max(1, Int(Double(src.count) / ratio))
        var out = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let p = Double(i) * ratio
            let j = min(src.count - 1, Int(p))
            let f = Float(p - Double(j))
            out[i] = j + 1 < src.count ? src[j] * (1 - f) + src[j + 1] * f : src[j]
        }
        return out
    }

    // MARK: - STFT + mel features

    static let windowSize = 1024
    static let hopSize = 256
    private static let melBands = 40

    /// Everything a single STFT pass yields. One pass over the file feeds
    /// onset/tempo (mel), downbeats (low), key (chroma) and vocals
    /// (bandRatio/flatness/bandEnvelope) — no second FFT sweep.
    struct STFTFeatures {
        /// Per-frame 40-band log-mel vectors.
        var mel: [[Float]] = []
        /// Per-frame magnitude sum below 200 Hz (downbeat voting).
        var low: [Float] = []
        /// Per-frame L1-normalized 12-bin chroma (all-zero when the frame has
        /// no usable spectral peaks).
        var chroma: [[Float]] = []
        /// Weight of each chroma frame: summed magnitude of its peaks.
        var chromaEnergy: [Float] = []
        /// Per-frame share of magnitude inside the 200 Hz–4 kHz vocal band.
        var bandRatio: [Float] = []
        /// Per-frame spectral flatness inside that band (harmonic → low).
        var flatness: [Float] = []
        /// Per-frame log magnitude of that band — carrier for the 2–8 Hz
        /// syllable-rate modulation measurement.
        var bandEnvelope: [Float] = []
    }

    /// Vocal band edges for the VAD features.
    private static let vocalBandLowHz = 200.0
    private static let vocalBandHighHz = 4_000.0
    /// Chroma analysis range: below ~55 Hz the FFT has no resolution left and
    /// above ~2 kHz partials smear across pitch classes.
    private static let chromaLowHz = 55.0
    private static let chromaHighHz = 2_000.0

    /// Single STFT pass producing every downstream feature.
    private static func stftFeatures(
        _ x: [Float], sampleRate sr: Double
    ) -> STFTFeatures {
        let n = windowSize
        let hop = hopSize
        guard x.count >= n else { return STFTFeatures() }
        let nFrames = 1 + (x.count - n) / hop
        let log2n = vDSP_Length(10)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return STFTFeatures()
        }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))

        let nBins = n / 2 + 1
        let filterbank = melFilterbank(bins: nBins, sampleRate: sr, bands: melBands)
        let binHz = sr / Double(n)
        let lowBinCount = max(1, min(nBins, Int(200.0 / binHz) + 1))

        // Chroma peak-picking range; the parabolic interpolator needs one bin
        // of headroom on each side.
        let chromaLo = max(2, Int(chromaLowHz / binHz))
        let chromaHi = min(nBins - 2, Int(chromaHighHz / binHz))
        // Vocal band bins.
        let voiceLo = max(1, Int(vocalBandLowHz / binHz))
        let voiceHi = min(nBins - 1, Int(vocalBandHighHz / binHz))
        let voiceCount = max(0, voiceHi - voiceLo + 1)

        var out = STFTFeatures()
        var mel = [[Float]]()
        mel.reserveCapacity(nFrames)
        var low = [Float](repeating: 0, count: nFrames)
        var chroma = [[Float]](repeating: [Float](repeating: 0, count: 12), count: nFrames)
        var chromaEnergy = [Float](repeating: 0, count: nFrames)
        var bandRatio = [Float](repeating: 0, count: nFrames)
        var flatness = [Float](repeating: 1, count: nFrames)
        var bandEnvelope = [Float](repeating: 0, count: nFrames)
        var logBuf = [Float](repeating: 0, count: max(1, voiceCount))

        var frame = [Float](repeating: 0, count: n)
        var realp = [Float](repeating: 0, count: n / 2)
        var imagp = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: nBins)

        x.withUnsafeBufferPointer { xb in
            for t in 0..<nFrames {
                let start = t * hop
                vDSP_vmul(xb.baseAddress! + start, 1, window, 1, &frame, 1, vDSP_Length(n))

                realp.withUnsafeMutableBufferPointer { rp in
                    imagp.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(
                            realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        frame.withUnsafeBufferPointer { fb in
                            fb.baseAddress!.withMemoryRebound(
                                to: DSPComplex.self, capacity: n / 2
                            ) {
                                vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                            }
                        }
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        // Packed format: realp[0] = DC, imagp[0] = Nyquist.
                        let dc = rp.baseAddress![0]
                        let nyquist = ip.baseAddress![0]
                        rp.baseAddress![0] = 0
                        ip.baseAddress![0] = 0
                        mags.withUnsafeMutableBufferPointer { mb in
                            vDSP_zvmags(&split, 1, mb.baseAddress!, 1, vDSP_Length(n / 2))
                            mb.baseAddress![0] = dc * dc
                            mb.baseAddress![n / 2] = nyquist * nyquist
                            var count = Int32(nBins)
                            vvsqrtf(mb.baseAddress!, mb.baseAddress!, &count)
                        }
                    }
                }

                var lowSum: Float = 0
                vDSP_sve(mags, 1, &lowSum, vDSP_Length(lowBinCount))
                low[t] = lowSum

                // --- Vocal-band features -------------------------------
                if voiceCount > 0 {
                    var total: Float = 0
                    vDSP_sve(mags, 1, &total, vDSP_Length(nBins))
                    var voice: Float = 0
                    var geoMean: Float = 0
                    mags.withUnsafeBufferPointer { mb in
                        let base = mb.baseAddress! + voiceLo
                        vDSP_sve(base, 1, &voice, vDSP_Length(voiceCount))
                        logBuf.withUnsafeMutableBufferPointer { lb in
                            var eps: Float = 1e-9
                            vDSP_vsadd(base, 1, &eps, lb.baseAddress!, 1,
                                       vDSP_Length(voiceCount))
                            var count = Int32(voiceCount)
                            vvlogf(lb.baseAddress!, lb.baseAddress!, &count)
                            var meanLog: Float = 0
                            vDSP_meanv(lb.baseAddress!, 1, &meanLog,
                                       vDSP_Length(voiceCount))
                            geoMean = exp(meanLog)
                        }
                    }
                    let arith = voice / Float(voiceCount)
                    bandRatio[t] = total > 1e-9 ? voice / total : 0
                    flatness[t] = arith > 1e-9 ? min(1, geoMean / arith) : 1
                    bandEnvelope[t] = log(voice + 1e-9)
                }

                // --- Chroma via parabolic-interpolated spectral peaks ---
                if chromaHi > chromaLo {
                    var frameMax: Float = 0
                    mags.withUnsafeBufferPointer { mb in
                        vDSP_maxv(mb.baseAddress! + chromaLo, 1, &frameMax,
                                  vDSP_Length(chromaHi - chromaLo + 1))
                    }
                    if frameMax > 1e-7 {
                        let floorMag = 0.02 * frameMax
                        var bins = [Float](repeating: 0, count: 12)
                        var weightSum: Float = 0
                        for k in (chromaLo + 1)..<chromaHi {
                            let m = mags[k]
                            guard m > floorMag, m > mags[k - 1], m >= mags[k + 1] else {
                                continue
                            }
                            // Quadratic fit on log magnitudes: sub-bin peak
                            // location recovers pitch accuracy the 1024-point
                            // window alone cannot give at low frequencies.
                            let a = log(mags[k - 1] + 1e-9)
                            let b = log(m + 1e-9)
                            let c = log(mags[k + 1] + 1e-9)
                            let denom = a - 2 * b + c
                            var delta: Float = 0
                            if abs(denom) > 1e-9 {
                                delta = 0.5 * (a - c) / denom
                                if abs(delta) > 0.5 { delta = 0 }
                            }
                            let freq = (Double(k) + Double(delta)) * binHz
                            guard freq >= chromaLowHz, freq <= chromaHighHz else { continue }
                            let midi = 69 + 12 * log2(freq / 440)
                            var pc = Int(midi.rounded()) % 12
                            if pc < 0 { pc += 12 }
                            bins[pc] += m
                            weightSum += m
                        }
                        if weightSum > 1e-9 {
                            let inv = 1 / weightSum
                            for i in 0..<12 { bins[i] *= inv }
                            chroma[t] = bins
                            chromaEnergy[t] = weightSum
                        }
                    }
                }

                var melFrame = [Float](repeating: 0, count: melBands)
                vDSP_mmul(
                    filterbank, 1, mags, 1, &melFrame, 1,
                    vDSP_Length(melBands), 1, vDSP_Length(nBins))
                melFrame.withUnsafeMutableBufferPointer { mp in
                    var one: Float = 1
                    vDSP_vsadd(mp.baseAddress!, 1, &one, mp.baseAddress!, 1, vDSP_Length(melBands))
                    var count = Int32(melBands)
                    vvlogf(mp.baseAddress!, mp.baseAddress!, &count)
                }
                mel.append(melFrame)
            }
        }
        out.mel = mel
        out.low = low
        out.chroma = chroma
        out.chromaEnergy = chromaEnergy
        out.bandRatio = bandRatio
        out.flatness = flatness
        out.bandEnvelope = bandEnvelope
        return out
    }

    /// Triangular mel filterbank, flattened row-major [bands x bins].
    private static func melFilterbank(bins: Int, sampleRate sr: Double, bands: Int) -> [Float] {
        func hzToMel(_ f: Double) -> Double { 2595 * log10(1 + f / 700) }
        func melToHz(_ m: Double) -> Double { 700 * (pow(10, m / 2595) - 1) }
        let mMin = hzToMel(20)
        let mMax = hzToMel(sr / 2)
        let points = (0...(bands + 1)).map {
            melToHz(mMin + (mMax - mMin) * Double($0) / Double(bands + 1))
        }
        var fb = [Float](repeating: 0, count: bands * bins)
        for b in 0..<bands {
            let lo = points[b], mid = points[b + 1], hi = points[b + 2]
            for k in 0..<bins {
                let f = Double(k) * sr / Double((bins - 1) * 2)
                guard f > lo, f < hi else { continue }
                let w = f <= mid ? (f - lo) / max(mid - lo, 1e-9)
                                 : (hi - f) / max(hi - mid, 1e-9)
                fb[b * bins + k] = Float(w)
            }
        }
        return fb
    }

    /// Spectral flux: half-wave-rectified first difference of the log-mel
    /// spectrum, summed over bands.
    private static func onsetEnvelope(_ mel: [[Float]]) -> [Float] {
        guard mel.count > 1 else { return [Float](repeating: 0, count: mel.count) }
        var onset = [Float](repeating: 0, count: mel.count)
        for t in 1..<mel.count {
            var sum: Float = 0
            let cur = mel[t], prev = mel[t - 1]
            for b in 0..<cur.count {
                let d = cur[b] - prev[b]
                if d > 0 { sum += d }
            }
            onset[t] = sum
        }
        return onset
    }

    // MARK: - Tempo estimation

    private static let minBPM = 50.0
    private static let maxBPM = 200.0
    private static let priorCenterBPM = 120.0
    private static let priorSigmaOctaves = 0.9

    /// Autocorrelation of the onset envelope weighted by a log-normal tempo
    /// prior. Confidence combines peak sharpness (peak vs. mean of the lag
    /// range) with raw periodicity strength (r(L)/r(0)).
    private static func estimateTempo(
        onset: [Float], fps: Double
    ) -> (bpm: Double, confidence: Double) {
        let minLag = max(2, Int(fps * 60 / maxBPM))
        let maxLag = Int(fps * 60 / minBPM)
        guard onset.count > maxLag + minLag + 4 else { return (0, 0) }

        // Mean-removed envelope.
        var mean: Float = 0
        vDSP_meanv(onset, 1, &mean, vDSP_Length(onset.count))
        var o = [Float](repeating: 0, count: onset.count)
        var negMean = -mean
        vDSP_vsadd(onset, 1, &negMean, &o, 1, vDSP_Length(onset.count))

        var r0: Float = 0
        vDSP_dotpr(o, 1, o, 1, &r0, vDSP_Length(o.count))
        guard r0 > 1e-6 else { return (0, 0) }

        let lagCount = maxLag - minLag + 1
        var normACF = [Double](repeating: 0, count: lagCount)   // r(lag)/r(0)
        var weighted = [Double](repeating: 0, count: lagCount)  // × prior
        o.withUnsafeBufferPointer { ob in
            for i in 0..<lagCount {
                let lag = minLag + i
                var r: Float = 0
                vDSP_dotpr(
                    ob.baseAddress!, 1, ob.baseAddress! + lag, 1, &r,
                    vDSP_Length(o.count - lag))
                let norm = Double(max(0, r)) / Double(r0)
                let bpm = 60 * fps / Double(lag)
                let dev = log2(bpm / priorCenterBPM) / priorSigmaOctaves
                let prior = exp(-0.5 * dev * dev)
                normACF[i] = norm
                weighted[i] = norm * prior
            }
        }

        guard let bestIdx = weighted.indices.max(by: { weighted[$0] < weighted[$1] }),
              weighted[bestIdx] > 0
        else { return (0, 0) }

        // Parabolic interpolation around the peak for sub-lag precision.
        var lag = Double(minLag + bestIdx)
        if bestIdx > 0, bestIdx < lagCount - 1 {
            let ym = weighted[bestIdx - 1], y0 = weighted[bestIdx], yp = weighted[bestIdx + 1]
            let denom = ym - 2 * y0 + yp
            if abs(denom) > 1e-12 {
                let delta = 0.5 * (ym - yp) / denom
                if abs(delta) <= 1 { lag += delta }
            }
        }
        let bpm = 60 * fps / lag

        let avg = weighted.reduce(0, +) / Double(lagCount)
        let peak = weighted[bestIdx]
        let sharpness = max(0, (peak - avg) / max(peak, 1e-12))
        let strength = min(1.0, normACF[bestIdx] * 2.5)
        let confidence = min(1.0, max(0, sharpness * strength))
        return (bpm, confidence)
    }

    // MARK: - Beat tracking (Ellis 2007 dynamic programming)

    private static let dpTightness: Float = 100

    private static func trackBeats(
        onset: [Float], fps: Double, bpm: Double
    ) -> [TimeInterval] {
        let period = fps * 60 / bpm
        let n = onset.count
        guard n > Int(2 * period) + 2, period > 1 else { return [] }

        // Normalize onset by its standard deviation (librosa-style) so the
        // objective's two terms are on comparable scales.
        var mean: Float = 0
        var std: Float = 0
        vDSP_normalize(onset, 1, nil, 1, &mean, &std, vDSP_Length(n))
        guard std > 1e-9 else { return [] }
        let o = onset.map { $0 / std }

        let windowLo = Int((period * 2).rounded())
        let windowHi = max(1, Int((period / 2).rounded()))
        var cumscore = [Float](repeating: 0, count: n)
        var backlink = [Int](repeating: -1, count: n)

        for i in 0..<n {
            var best: Float = -.greatestFiniteMagnitude
            var bestJ = -1
            let jMin = max(0, i - windowLo)
            let jMax = i - windowHi
            if jMax >= jMin {
                for j in jMin...jMax {
                    let interval = Double(i - j)
                    let logRatio = log(interval / period)
                    let tx = -dpTightness * Float(logRatio * logRatio)
                    let s = cumscore[j] + tx
                    if s > best {
                        best = s
                        bestJ = j
                    }
                }
            }
            if bestJ >= 0, best > 0 {
                cumscore[i] = o[i] + best
                backlink[i] = bestJ
            } else {
                cumscore[i] = o[i]
            }
        }

        // Backtrack from the best-scoring frame near the end.
        let tailStart = max(0, n - Int(2 * period))
        var idx = tailStart
        for i in tailStart..<n where cumscore[i] > cumscore[idx] { idx = i }
        var framesReversed: [Int] = []
        var i = idx
        while i >= 0 {
            framesReversed.append(i)
            i = backlink[i]
        }
        return framesReversed.reversed().map { Double($0) * Double(hopSize) / analysisSampleRate }
    }

    // MARK: - Downbeats

    /// 4/4 assumption: vote among the four phases using per-beat low-frequency
    /// energy plus onset strength; the winning phase's beats become downbeats.
    private static func estimateDownbeats(
        beats: [TimeInterval], onset: [Float], lowEnergy: [Float], fps: Double
    ) -> [TimeInterval] {
        guard beats.count >= 4 else { return [] }
        let maxOnset = max(onset.max() ?? 0, 1e-9)
        let maxLow = max(lowEnergy.max() ?? 0, 1e-9)

        func beatScore(_ time: TimeInterval) -> Double {
            let f = Int((time * fps).rounded())
            guard f >= 0, f < onset.count else { return 0 }
            let hi = min(onset.count, f + 3)
            var low: Float = 0
            var flux: Float = 0
            for k in f..<hi {
                low = max(low, lowEnergy[k])
                flux = max(flux, onset[k])
            }
            return Double(low / maxLow) + Double(flux / maxOnset)
        }

        let scores = beats.map(beatScore)
        var bestPhase = 0
        var bestTotal = -Double.greatestFiniteMagnitude
        for phase in 0..<4 {
            var total = 0.0
            var count = 0
            var i = phase
            while i < scores.count {
                total += scores[i]
                count += 1
                i += 4
            }
            let avg = count > 0 ? total / Double(count) : 0
            if avg > bestTotal {
                bestTotal = avg
                bestPhase = phase
            }
        }
        return stride(from: bestPhase, to: beats.count, by: 4).map { beats[$0] }
    }

    // MARK: - Structure features

    /// Candidate mix points on the 8/16-bar grid, scored by the RMS envelope
    /// jump around them (section changes), best first.
    private static func phraseBoundaries(
        downbeats: [TimeInterval], rmsEnvelope: [Float]
    ) -> [TimeInterval] {
        guard downbeats.count > 8, !rmsEnvelope.isEmpty else { return [] }
        let maxRMS = max(rmsEnvelope.max() ?? 0, 1e-6)
        var scored: [(time: TimeInterval, score: Double)] = []
        for bar in stride(from: 8, to: downbeats.count, by: 8) {
            let t = downbeats[bar]
            let s = Int(t)
            guard s >= 1, s < rmsEnvelope.count else { continue }
            let preRange = max(0, s - 4)..<s
            let postRange = s..<min(rmsEnvelope.count, s + 4)
            guard !preRange.isEmpty, !postRange.isEmpty else { continue }
            let pre = preRange.reduce(Float(0)) { $0 + rmsEnvelope[$1] } / Float(preRange.count)
            let post = postRange.reduce(Float(0)) { $0 + rmsEnvelope[$1] } / Float(postRange.count)
            var score = Double(abs(post - pre) / maxRMS)
            if bar % 16 == 0 { score += 0.15 }
            scored.append((t, score))
        }
        return scored.sorted { $0.score > $1.score }.prefix(10).map(\.time)
    }

    private static func rmsPerSecond(_ x: [Float], sampleRate sr: Double) -> [Float] {
        let secLen = Int(sr)
        guard secLen > 0, !x.isEmpty else { return [] }
        var env: [Float] = []
        env.reserveCapacity(x.count / secLen + 1)
        x.withUnsafeBufferPointer { xb in
            var i = 0
            while i < x.count {
                let count = min(secLen, x.count - i)
                var meanSquare: Float = 0
                vDSP_measqv(xb.baseAddress! + i, 1, &meanSquare, vDSP_Length(count))
                env.append(sqrt(meanSquare))
                i += count
            }
        }
        return env
    }

    /// Start of a sustained, roughly monotonic level drop at the tail, or nil.
    private static func outroFadeStart(rmsEnvelope env: [Float]) -> TimeInterval? {
        guard env.count >= 10 else { return nil }
        let maxRMS = env.max() ?? 0
        guard maxRMS > 1e-5 else { return nil }
        let tolerance = 0.03 * maxRMS
        var start = env.count - 1
        while start > 0, env[start - 1] >= env[start] - tolerance {
            start -= 1
        }
        // The suffix is non-increasing but may begin with a flat plateau;
        // the fade proper starts where the level actually drops.
        let peak = env[start]
        if let dropIdx = (start..<env.count).first(where: { env[$0] < 0.95 * peak }) {
            start = max(start, dropIdx - 1)
        }
        let length = env.count - start
        guard length >= 5 else { return nil }
        let tail = env[env.count - 1]
        guard env[start] > 0.25 * maxRMS, tail < 0.5 * env[start] else { return nil }
        return TimeInterval(start)
    }

    /// First significant energy, snapped to the next downbeat (or beat).
    private static func introEnd(
        rmsEnvelope env: [Float], downbeats: [TimeInterval], beats: [TimeInterval]
    ) -> TimeInterval {
        let maxRMS = env.max() ?? 0
        guard maxRMS > 1e-5 else { return 0 }
        let threshold = 0.25 * maxRMS
        let firstLoud = env.firstIndex { $0 >= threshold } ?? 0
        let t0 = TimeInterval(firstLoud)
        if let db = downbeats.first(where: { $0 >= t0 }) { return db }
        if let b = beats.first(where: { $0 >= t0 }) { return b }
        return t0
    }

    // MARK: - Key detection (Krumhansl-Schmuckler)

    /// Krumhansl-Kessler tone profiles, index 0 = tonic.
    private static let ksMajor: [Double] = [
        6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88,
    ]
    private static let ksMinor: [Double] = [
        6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17,
    ]

    /// Whole-track chroma → best of the 24 major/minor rotations.
    ///
    /// Only frames carrying a decent share of the track's peak chroma energy
    /// vote, so silence and near-silent frames cannot flatten the histogram.
    /// Confidence blends the absolute fit (how tonal the chroma is at all)
    /// with the margin over the runner-up key; the margin is measured against
    /// the best *unrelated* candidate — relative/parallel/dominant keys share
    /// most of their pitch content by construction, and penalising a track for
    /// that would make every well-behaved song look uncertain.
    static func detectKey(
        chromaFrames: [[Float]], frameEnergy: [Float]
    ) -> (pitchClass: Int?, isMinor: Bool, confidence: Double) {
        guard !chromaFrames.isEmpty, frameEnergy.count == chromaFrames.count else {
            return (nil, false, 0)
        }
        let maxEnergy = frameEnergy.max() ?? 0
        guard maxEnergy > 0 else { return (nil, false, 0) }
        let threshold = 0.15 * maxEnergy

        var mean = [Double](repeating: 0, count: 12)
        var used = 0
        for (t, e) in frameEnergy.enumerated() where e >= threshold {
            let frame = chromaFrames[t]
            guard frame.count == 12 else { continue }
            for i in 0..<12 { mean[i] += Double(frame[i]) }
            used += 1
        }
        guard used >= 8 else { return (nil, false, 0) }
        let invUsed = 1 / Double(used)
        for i in 0..<12 { mean[i] *= invUsed }

        let total = mean.reduce(0, +)
        guard total > 1e-9 else { return (nil, false, 0) }
        for i in 0..<12 { mean[i] /= total }

        // A key needs a scale, not a note: a sustained drone or a one-note
        // bass figure correlates well with a rotated profile but says nothing.
        let peak = mean.max() ?? 0
        let active = mean.filter { $0 >= 0.08 * peak }.count
        guard active >= 3 else { return (nil, false, 0) }

        // Candidate scores: Pearson correlation with each rotated profile.
        var scores = [Double](repeating: -1, count: 24)  // 0-11 major, 12-23 minor
        for mode in 0..<2 {
            let profile = mode == 0 ? ksMajor : ksMinor
            for root in 0..<12 {
                var template = [Double](repeating: 0, count: 12)
                for i in 0..<12 { template[i] = profile[((i - root) % 12 + 12) % 12] }
                scores[mode * 12 + root] = correlation(mean, template)
            }
        }

        guard let bestIdx = scores.indices.max(by: { scores[$0] < scores[$1] }) else {
            return (nil, false, 0)
        }
        let bestRoot = bestIdx % 12
        let bestIsMinor = bestIdx >= 12
        let rBest = scores[bestIdx]

        // Keys that legitimately share pitch content with the winner and so
        // must not count against the margin.
        let relatives = relatedKeys(root: bestRoot, isMinor: bestIsMinor)
        var rRival = -1.0
        for i in 0..<24 where i != bestIdx && !relatives.contains(i) {
            rRival = max(rRival, scores[i])
        }

        let fit = clamp01((rBest - 0.25) / 0.40)          // 0.25 → 0, 0.65 → 1
        let margin = clamp01((rBest - rRival) / 0.30)     // 0.30 apart → full
        let confidence = clamp01(0.45 * fit + 0.55 * margin)

        // No tonal centre worth reporting.
        guard rBest > 0.30, confidence >= 0.20 else { return (nil, false, 0) }
        return (bestRoot, bestIsMinor, confidence)
    }

    /// Indices (same encoding as `scores`) of keys that share most of their
    /// scale with the given key: relative, parallel, dominant, subdominant.
    private static func relatedKeys(root: Int, isMinor: Bool) -> Set<Int> {
        func idx(_ r: Int, _ minor: Bool) -> Int { ((r % 12) + 12) % 12 + (minor ? 12 : 0) }
        var s: Set<Int> = [idx(root, !isMinor)]                  // parallel
        s.insert(isMinor ? idx(root + 3, false) : idx(root + 9, true))  // relative
        s.insert(idx(root + 7, isMinor))                         // dominant
        s.insert(idx(root + 5, isMinor))                         // subdominant
        return s
    }

    private static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let n = Double(a.count)
        let ma = a.reduce(0, +) / n
        let mb = b.reduce(0, +) / n
        var num = 0.0, da = 0.0, db = 0.0
        for i in 0..<a.count {
            let u = a[i] - ma, v = b[i] - mb
            num += u * v
            da += u * u
            db += v * v
        }
        guard da > 1e-12, db > 1e-12 else { return 0 }
        return num / (da * db).squareRoot()
    }

    private static func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }

    // MARK: - Vocal activity detection

    /// Per-second vocal-presence likelihood on the `rmsEnvelope` grid (v5).
    ///
    /// Pure DSP heuristic — no model. Four cues, all measured inside or around
    /// the 200 Hz–4 kHz vocal band, are fused:
    ///  1. share of spectral magnitude in the band (`bandRatio`),
    ///  2. spectral flatness inside it — voiced sound is harmonic so flatness
    ///     drops; cymbals/noise stay flat (`flatness`),
    ///  3. 2–8 Hz modulation of the band envelope, the syllable/vibrato rate
    ///     (`bandEnvelope`),
    ///  4. stereo-centre share — the band's mid/(mid+side) energy, high for a
    ///     centred lead vocal (`midShare`, absent for mono input).
    ///
    /// Cue 4 is the fix for v4's shortfall: the three mono-spectral cues cannot
    /// tell "a harmonic instrument sitting in the mid band" (sax, distorted
    /// guitar, synth lead) from "someone singing", and validated against StemKit
    /// separation, v4's top-scored windows often held almost no real vocal
    /// energy. Lead vocals are almost always panned centre while accompaniment
    /// and effects spread wider, which the mono downmix throws away — measuring
    /// it recovers the single most informative cue available without a model.
    ///
    /// Presence is a necessary gate (the other cues are meaningless in a band
    /// holding only leakage); the fused score is gated by the track's own
    /// loudness and 3-second median-smoothed.
    static func vocalActivity(
        bandRatio: [Float], flatness: [Float], bandEnvelope: [Float],
        midShare: [Float]?, fps: Double, rmsEnvelope: [Float]
    ) -> [Float] {
        let cues = vocalCues(
            bandRatio: bandRatio, flatness: flatness, bandEnvelope: bandEnvelope,
            midShare: midShare, fps: fps, rmsEnvelope: rmsEnvelope)
        return fuseVocalCues(cues)
    }

    /// The per-second cue vector behind `vocalActivity`, kept as a named type so
    /// the offline validation harness (`vocaleval`, S0.5) can dump the cues and
    /// re-fuse them under alternative weights without re-running any FFTs — and
    /// so v4's fusion can be replayed on byte-identical features for the A/B.
    /// Each `s*` field is already squashed to 0...1.
    struct VocalCues: Sendable {
        /// Vocal-band energy share (cue 1).
        var band: Double = 0
        /// Band tonality, `1 − flatness` rescaled (cue 2).
        var tonal: Double = 0
        /// 2–8 Hz syllable-rate modulation (cue 3).
        var mod: Double = 0
        /// Stereo-centre share (cue 4); 0 and unused when `hasMid` is false.
        var mid: Double = 0
        /// Necessary-condition multiplier: is there anything in the band at all.
        var presence: Double = 0
        /// Track-relative loudness gate.
        var gate: Double = 0
        var hasMid = false
    }

    /// Per-second cue extraction — everything up to, but not including, the
    /// weighted fusion. Split out of `vocalActivity` so the fusion weights can
    /// be re-fit offline against ground truth.
    static func vocalCues(
        bandRatio: [Float], flatness: [Float], bandEnvelope: [Float],
        midShare: [Float]?, fps: Double, rmsEnvelope: [Float]
    ) -> [VocalCues] {
        let seconds = rmsEnvelope.count
        guard seconds > 0, !bandRatio.isEmpty, fps > 1,
              flatness.count == bandRatio.count,
              bandEnvelope.count == bandRatio.count
        else { return [VocalCues](repeating: VocalCues(), count: seconds) }

        let frames = bandRatio.count
        let hasMid = (midShare?.count ?? 0) == frames
        let maxRMS = max(rmsEnvelope.max() ?? 0, 1e-9)
        var out = [VocalCues](repeating: VocalCues(), count: seconds)

        for s in 0..<seconds {
            let lo = min(frames, Int(Double(s) * fps))
            let hi = min(frames, max(lo + 1, Int(Double(s + 1) * fps)))
            guard lo < hi else { continue }

            var meanRatio: Float = 0
            var meanFlat: Float = 0
            var meanMid: Float = 0
            for t in lo..<hi {
                meanRatio += bandRatio[t]
                meanFlat += flatness[t]
                if hasMid { meanMid += midShare![t] }
            }
            let inv = 1 / Float(hi - lo)
            meanRatio *= inv
            meanFlat *= inv
            meanMid *= inv

            // 2 s window centred on this second for the modulation estimate.
            let wLo = max(0, Int((Double(s) - 0.5) * fps))
            let wHi = min(frames, Int((Double(s) + 1.5) * fps))
            let modRatio = modulationRatio(
                bandEnvelope, range: wLo..<wHi, fps: fps, lowHz: 2, highHz: 8)

            var c = VocalCues()
            c.hasMid = hasMid
            // Energy in the vocal band is a necessary condition: flatness and
            // modulation measured in a band that holds nothing but leakage are
            // meaningless (a bass line reads as perfectly "harmonic" there).
            c.presence = clamp01(Double(meanRatio - 0.15) / 0.20)
            c.band = clamp01(Double(meanRatio - 0.30) / 0.35)
            c.tonal = clamp01(Double(0.55 - meanFlat) / 0.40)
            // The 4× STFT overlap lowpasses the envelope, so even noise puts
            // ~0.3 of its modulation power under 8 Hz; that is the floor.
            c.mod = clamp01((modRatio - 0.35) / 0.35)
            // A wide/off-centre band (uncorrelated stereo, ~0.5) scores 0; a
            // band whose energy is centred pulls the estimate up.
            c.mid = hasMid ? clamp01(Double(meanMid - 0.55) / 0.30) : 0
            c.gate = clamp01(Double(rmsEnvelope[s] / maxRMS - 0.05) / 0.10)
            out[s] = c
        }
        return out
    }

    /// Weighted fusion of the per-second cues, 3-second median smoothed.
    ///
    /// `legacyV4` replays the three-cue fusion that shipped in v4 (ignoring the
    /// mid/side cue, and using v4's weights, even when a stereo image is
    /// present) — used only by the offline harness, so the before/after
    /// comparison runs on identical features.
    static func fuseVocalCues(_ cues: [VocalCues], legacyV4: Bool = false) -> [Float] {
        var raw = [Float](repeating: 0, count: cues.count)
        for (s, c) in cues.enumerated() {
            // Mono-spectral combination; weights sum to 1. This alone governs
            // mono input, where the stereo-centre cue does not exist.
            let monoCombo = legacyV4
                ? v4BandWeight * c.band + v4TonalWeight * c.tonal + v4ModWeight * c.mod
                : bandWeight * c.band + tonalWeight * c.tonal + modWeight * c.mod
            // Stereo-centre share, blended in when available.
            let combined = (!legacyV4 && c.hasMid)
                ? (1 - midWeight) * monoCombo + midWeight * c.mid
                : monoCombo
            raw[s] = Float(clamp01(c.presence * combined * c.gate))
        }
        return medianFilter3(raw)
    }

    // Fusion weights, fit on the eval corpus against StemKit per-second
    // vocal/mix ground truth via the `vocaleval` harness (18 tracks across all
    // six playlists, 3×30 s windows each). The search was run under
    // leave-one-playlist-out CV; band-dominant weights with a ~0.35 centre blend
    // were stable across all six folds. The v4 set is retained verbatim so the
    // harness can reproduce the pre-change curve for the A/B.
    private static let bandWeight = 0.55
    private static let tonalWeight = 0.20
    private static let modWeight = 0.25
    /// Weight of the stereo-centre cue when a stereo image is available.
    private static let midWeight = 0.35
    private static let v4BandWeight = 0.40
    private static let v4TonalWeight = 0.35
    private static let v4ModWeight = 0.25

    /// Per-frame centre share `mid/(mid+side)` of vocal-band energy, aligned to
    /// `frames`. 1 → fully centred (mono-in-stereo), 0 → pure side, 0.5 →
    /// uncorrelated. Neutral 0.5 where the stereo envelopes run short.
    static func midSharePerFrame(mid: [Float], side: [Float], frames: Int) -> [Float] {
        var out = [Float](repeating: 0.5, count: frames)
        let count = min(frames, min(mid.count, side.count))
        for t in 0..<count {
            let denom = mid[t] + side[t]
            out[t] = denom > 1e-9 ? mid[t] / denom : 0.5
        }
        return out
    }

    /// Fraction of the (mean-removed) envelope's power that sits between
    /// `lowHz` and `highHz`, via a direct DFT over the window — a handful of
    /// bins, so cheaper than filtering the whole envelope.
    private static func modulationRatio(
        _ envelope: [Float], range: Range<Int>, fps: Double,
        lowHz: Double, highHz: Double
    ) -> Double {
        let count = range.count
        guard count >= 8 else { return 0 }
        var mean: Float = 0
        envelope.withUnsafeBufferPointer { eb in
            vDSP_meanv(eb.baseAddress! + range.lowerBound, 1, &mean, vDSP_Length(count))
        }
        var y = [Double](repeating: 0, count: count)
        var power = 0.0
        for i in 0..<count {
            let v = Double(envelope[range.lowerBound + i] - mean)
            y[i] = v
            power += v * v
        }
        guard power > 1e-9 else { return 0 }

        let l = Double(count)
        let kLo = max(1, Int((lowHz * l / fps).rounded()))
        let kHi = min(count / 2 - 1, Int((highHz * l / fps).rounded()))
        guard kHi >= kLo else { return 0 }

        var band = 0.0
        for k in kLo...kHi {
            var re = 0.0, im = 0.0
            let w = 2 * Double.pi * Double(k) / l
            for i in 0..<count {
                let a = w * Double(i)
                re += y[i] * cos(a)
                im -= y[i] * sin(a)
            }
            band += 2 * (re * re + im * im) / l
        }
        return clamp01(band / power)
    }

    private static func medianFilter3(_ x: [Float]) -> [Float] {
        guard x.count >= 3 else { return x }
        var out = x
        for i in 1..<(x.count - 1) {
            var t = [x[i - 1], x[i], x[i + 1]]
            t.sort()
            out[i] = t[1]
        }
        return out
    }
}
