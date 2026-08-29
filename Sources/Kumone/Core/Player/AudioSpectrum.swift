import Accelerate
import AVFoundation
import Foundation

/// Real-time band levels pulled out of the playing audio.
///
/// `PlaybackEngine` hands us every buffer of its final mixed output (see
/// `setOutputSampleSink`) and we run a small FFT over it. That callback is a
/// real-time audio thread: everything it touches below is preallocated,
/// lock-free and allocation-free.
///
/// The mixer's tap hears whatever the listener hears — both decks and a
/// pre-rendered segment during a hand-over — so there is nothing to re-wire per
/// track. See `tapState`, which callers use to decide between real levels,
/// holding still, and the decorative fallback.
@MainActor
final class AudioSpectrum {
    static let shared = AudioSpectrum()

    /// Number of frequency bands published to the UI. Read from the audio thread
    /// too, so it stays outside the actor's isolation.
    nonisolated static let bandCount = 4

    /// One store for the life of the process: the engine's tap is installed
    /// once on a mixer that never goes away, so — unlike a per-item player tap —
    /// there is no outgoing analyzer to leave writing over the new track. It is
    /// cleared at the points where silence is correct instead of replaced.
    ///
    /// `nonisolated` because the audio thread writes into it directly; every
    /// field it exposes is a plain slot, so a torn read costs one stale bar.
    private nonisolated let store = SpectrumStore()
    private init() {}

    /// True while the tap is actually delivering samples for the current track.
    var isLive: Bool { store.isLive }

    /// What is known about the current track's tap.
    ///
    /// Three states rather than a flag, because there is a stretch after the
    /// user hits play where the answer isn't known yet: the track's URL is still
    /// being resolved. Treating that as "untappable" flashes the decorative
    /// animation for a moment right as a song starts, and treating it as
    /// "tapped" would freeze the previous track's last frame under it.
    enum TapState {
        /// Nothing playing.
        case idle
        /// Resolving the source; it isn't known yet whether it can be tapped.
        case preparing
        /// A tap is attached. `isLive` says whether samples have arrived yet.
        case tapped
        /// This source can't be tapped — the decorative fallback belongs here.
        case untappable
    }

    private(set) var tapState: TapState = .idle

    /// Latest level for one band, already smoothed and normalized to `0...1`.
    /// A single pointer read — cheap enough to call per bar, per frame.
    func level(at index: Int) -> Float {
        store.level(at: index)
    }


    /// One buffer of the engine's final output. Called on a real-time audio
    /// thread — allocates nothing, locks nothing, hops no actor.
    nonisolated func ingest(_ buffer: AVAudioPCMBuffer) {
        store.ingest(buffer)
    }

    /// Call once a deck is actually carrying the track: the mixer's tap is
    /// permanent, so every source the engine can play is a tapped one.
    func markTapped() {
        tapState = .tapped
    }

    /// Call as soon as a track is chosen — before its URL is resolved — so the
    /// bars hold still instead of falling back while the answer is unknown.
    func beginPreparing() {
        tapState = .preparing
        store.reset()
    }

    /// Call once it's settled that this source can't be tapped.
    func markUntappable() {
        tapState = .untappable
        store.reset()
    }

    /// Call when playback stops entirely.
    func markIdle() {
        tapState = .idle
        store.reset()
    }

    /// Silences the bands without forgetting that the current item is tapped —
    /// pausing shouldn't make a tapped track look untappable when it resumes.
    func reset() {
        store.reset()
    }
}

// MARK: - Lock-free store shared with the audio thread

/// Backing storage for the tap. Read by `AudioSpectrum` on the main actor and
/// written from the engine's audio thread; every field it exposes is a plain
/// `Float` slot, so a torn read costs at most one slightly stale bar.
private final class SpectrumStore: @unchecked Sendable {
    /// FFT window. 512 samples ≈ 12ms at 44.1kHz — fast enough to feel reactive,
    /// long enough to resolve bass.
    private static let fftSize = 512
    private static let log2n = vDSP_Length(9)   // 2^9 == 512
    private static let binCount = fftSize / 2

    /// Published band levels, written by the audio thread, read by the UI.
    private let levels: UnsafeMutablePointer<Float>
    /// Whether the tap has produced audio recently.
    private let liveFlag: UnsafeMutablePointer<Int32>

    /// Scratch buffers — preallocated because the audio thread must not malloc.
    private let window: UnsafeMutablePointer<Float>
    private let mono: UnsafeMutablePointer<Float>
    private let ring: UnsafeMutablePointer<Float>
    private var ringFill = 0
    private let realp: UnsafeMutablePointer<Float>
    private let imagp: UnsafeMutablePointer<Float>
    private let magnitudes: UnsafeMutablePointer<Float>
    private let fftSetup: FFTSetup?

    /// Source format, learned from the buffers themselves.
    private var sampleRate: Double = 44_100
    private var channelCount = 2
    private var isInterleaved = true

    /// Band definitions resolved to bin indices for the current sample rate.
    private let binLo: UnsafeMutablePointer<Int32>
    private let binHi: UnsafeMutablePointer<Int32>
    /// Current window edges in dB, tracking the level this band is producing.
    private let windowHiDB: UnsafeMutablePointer<Float>
    private let windowLoDB: UnsafeMutablePointer<Float>

    init() {
        let n = Self.fftSize
        levels = .allocate(capacity: AudioSpectrum.bandCount)
        levels.initialize(repeating: 0, count: AudioSpectrum.bandCount)
        liveFlag = .allocate(capacity: 1)
        liveFlag.initialize(to: 0)
        window = .allocate(capacity: n)
        mono = .allocate(capacity: n)
        ring = .allocate(capacity: n)
        ring.initialize(repeating: 0, count: n)
        realp = .allocate(capacity: Self.binCount)
        imagp = .allocate(capacity: Self.binCount)
        magnitudes = .allocate(capacity: Self.binCount)
        binLo = .allocate(capacity: AudioSpectrum.bandCount)
        binHi = .allocate(capacity: AudioSpectrum.bandCount)
        windowHiDB = .allocate(capacity: AudioSpectrum.bandCount)
        windowLoDB = .allocate(capacity: AudioSpectrum.bandCount)
        fftSetup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))
        vDSP_hann_window(window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        // Seeded for the common rate; `adopt(format:)` corrects it if the source
        // turns out to be 48kHz or Hi-Res.
        for i in 0..<AudioSpectrum.bandCount {
            let band = Self.bandEdges[i]
            let binWidth = Float(44_100) / Float(n)
            binLo[i] = Int32(max(1, Int(band.low / binWidth)))
            binHi[i] = Int32(min(Self.binCount - 1, Int(band.high / binWidth)))
            windowHiDB[i] = band.ceilingDB
            windowLoDB[i] = band.floorDB
        }
    }

    deinit {
        levels.deallocate()
        liveFlag.deallocate()
        window.deallocate()
        mono.deallocate()
        ring.deallocate()
        realp.deallocate()
        imagp.deallocate()
        magnitudes.deallocate()
        binLo.deallocate()
        binHi.deallocate()
        windowHiDB.deallocate()
        windowLoDB.deallocate()
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    var isLive: Bool { liveFlag.pointee != 0 }

    func level(at index: Int) -> Float {
        guard index >= 0, index < AudioSpectrum.bandCount else { return 0 }
        return levels[index]
    }

    func reset() {
        for i in 0..<AudioSpectrum.bandCount {
            levels[i] = 0
            // Start each track from the calibrated window rather than inheriting
            // the last one's loudness.
            let band = Self.bandEdges[i]
            windowHiDB[i] = band.ceilingDB
            windowLoDB[i] = band.floorDB
        }
        ringFill = 0
        liveFlag.pointee = 0
    }

    // MARK: Tap plumbing

    /// Analyze one buffer from the engine's mixer tap.
    ///
    /// The mixer hands us non-interleaved float in practice; `process` reads the
    /// first buffer of the list either way, which is the left channel there and
    /// the interleaved frames if the format ever changes under us.
    func ingest(_ buffer: AVAudioPCMBuffer) {
        adoptIfNeeded(buffer.format.streamDescription.pointee)
        process(buffer.mutableAudioBufferList, frames: Int(buffer.frameLength))
    }

    /// Re-resolve the band bins when the source format actually changes.
    /// Called per buffer, so the common case must be the early return: `adopt`
    /// also re-seeds the tracking windows, and doing that every buffer would
    /// freeze them at their calibrated defaults.
    private func adoptIfNeeded(_ format: AudioStreamBasicDescription) {
        let interleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        guard format.mSampleRate != sampleRate
            || Int(format.mChannelsPerFrame) != channelCount
            || interleaved != isInterleaved else { return }
        adopt(format: format)
    }

    private func adopt(format: AudioStreamBasicDescription) {
        sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 44_100
        channelCount = max(1, Int(format.mChannelsPerFrame))
        isInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0

        // Resolve each band to bin indices once, here, so the process callback
        // touches nothing but plain buffers — iterating a Swift array of tuples
        // on a real-time thread risks retain traffic and lazy-init locks.
        let binWidth = Float(sampleRate) / Float(Self.fftSize)
        for i in 0..<AudioSpectrum.bandCount {
            let band = Self.bandEdges[i]
            binLo[i] = Int32(max(1, Int(band.low / binWidth)))
            binHi[i] = Int32(min(Self.binCount - 1, Int(band.high / binWidth)))
            windowHiDB[i] = band.ceilingDB
            windowLoDB[i] = band.floorDB
        }
    }

    // MARK: Audio-thread analysis

    /// Frequency bands, each with its own dB window.
    ///
    /// Music falls off steeply with frequency — measured across tracks, presence
    /// sits some 30dB under bass — so one shared window would peg the low bars and
    /// leave the high ones flat on the floor. The windows below were calibrated
    /// from real material so every bar spends its time in the visible middle.
    private static let bandEdges: [(low: Float, high: Float, floorDB: Float, ceilingDB: Float)] = [
        (60, 250, -44, -20),
        (250, 800, -46, -26),
        (800, 2_500, -62, -36),
        (2_500, 8_000, -72, -50),
    ]

    /// Envelope time constants in seconds: rise fast so transients register,
    /// fall slowly so the bars read as motion rather than flicker. A slow release
    /// smears beats together and the bars stop reading as movement at all.
    private static let attackSeconds: Float = 0.03
    private static let releaseSeconds: Float = 0.16

    /// Each band's window tracks both edges of the level it actually sees.
    ///
    /// A fixed window can't serve both a sparse acoustic mix and a dense,
    /// heavily-limited one. The loud mix doesn't merely sit higher — it barely
    /// moves, riding a few dB under its limiter, so any window wide enough for
    /// the acoustic track renders it as four motionless bars. Tracking both
    /// edges lets the window slide *and* close in, so a small dynamic range is
    /// spread across the full height instead of vanishing.
    ///
    /// How fast the window closes back in once the extremes stop arriving. Slow
    /// enough that the window describes the passage, not the current beat.
    private static let windowRelaxDBPerSecond: Float = 1.0

    /// How fast each edge reaches out to a new extreme. Snapping to the exact
    /// min/max instead lets one freak-quiet frame set the floor tens of dB below
    /// anything the music does, and the window then describes that outlier for
    /// the rest of the song. The lower edge is the more exposed of the two, so
    /// it moves more cautiously.
    private static let windowRiseSeconds: Float = 0.15
    private static let windowFallSeconds: Float = 0.5

    /// Never let the window close below this, or a quiet passage gets stretched
    /// until its noise floor looks like music.
    private static let minWindowDB: Float = 6

    /// Nor let it open wider than this. Without a cap, one outlier sets an edge
    /// that takes minutes to relax back, and everything in between reads flat.
    private static let maxWindowDB: Float = 42

    /// Frames below this carry no signal at all — digital silence lands near
    /// -180dB. They must not touch the window, or leading silence drags its
    /// floor to the numeric bottom and the whole track plays out against it.
    private static let noSignalDB: Float = -95

    /// A band whose upper edge sits below this reads as silence.
    private static let silenceDB: Float = -70


    fileprivate func process(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        guard frames > 0 else { return }
        let abl = UnsafeMutableAudioBufferListPointer(bufferList)
        guard let first = abl.first, let raw = first.mData else { return }

        let n = Self.fftSize
        let src = raw.bindMemory(to: Float.self,
                                 capacity: Int(first.mDataByteSize) / MemoryLayout<Float>.size)
        let floatCount = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        let available = isInterleaved && channelCount > 1
            ? min(frames, floatCount / channelCount)
            : min(frames, floatCount)
        guard available > 0 else { return }

        // Walk the whole buffer in FFT-sized blocks. The tap can hand us far more
        // than one window at a time; analyzing only the first block would drop
        // most of the audio and — because the envelope advances once per call —
        // stretch every time constant by however many blocks went unread.
        var offset = 0
        while offset + n <= available {
            if isInterleaved, channelCount > 1 {
                let base = src.advanced(by: offset * channelCount)
                vDSP_vadd(base, vDSP_Stride(channelCount),
                          base.advanced(by: 1), vDSP_Stride(channelCount),
                          ring, 1, vDSP_Length(n))
                var half: Float = 0.5
                vDSP_vsmul(ring, 1, &half, ring, 1, vDSP_Length(n))
            } else {
                memcpy(ring, src.advanced(by: offset), n * MemoryLayout<Float>.size)
            }
            analyze(blockFrames: n)
            offset += n
        }
    }

    /// One FFT over `ring`, folded into the published levels.
    private func analyze(blockFrames: Int) {
        guard let fftSetup else { return }
        let n = Self.fftSize
        let take = blockFrames

        vDSP_vmul(ring, 1, window, 1, mono, 1, vDSP_Length(n))

        var split = DSPSplitComplex(realp: realp, imagp: imagp)
        mono.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { ptr in
            vDSP_ctoz(ptr, 2, &split, 1, vDSP_Length(n / 2))
        }
        vDSP_fft_zrip(fftSetup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
        vDSP_zvabs(&split, 1, magnitudes, 1, vDSP_Length(Self.binCount))

        // vDSP's real FFT returns doubled magnitudes; scale back before dB.
        var scale: Float = 1.0 / Float(2 * n)
        vDSP_vsmul(magnitudes, 1, &scale, magnitudes, 1, vDSP_Length(Self.binCount))

        var sawSignal = false

        // Smoothing coefficients derived from elapsed time, so the envelope
        // behaves the same whatever buffer size the tap hands us.
        let dt = Float(take) / Float(sampleRate)
        let attackCoefficient = 1 - expf(-dt / Self.attackSeconds)
        let releaseCoefficient = 1 - expf(-dt / Self.releaseSeconds)
        let relax = Self.windowRelaxDBPerSecond * dt
        let riseCoefficient = 1 - expf(-dt / Self.windowRiseSeconds)
        let fallCoefficient = 1 - expf(-dt / Self.windowFallSeconds)

        for i in 0..<AudioSpectrum.bandCount {
            let lo = Int(binLo[i])
            let hi = Int(binHi[i])
            guard hi >= lo else { continue }

            var sum: Float = 0
            vDSP_sve(magnitudes.advanced(by: lo), 1, &sum, vDSP_Length(hi - lo + 1))
            let mean = sum / Float(hi - lo + 1)
            if mean > 1e-7 { sawSignal = true }

            let db = 20 * log10f(max(mean, 1e-9))

            // Move the window's edges toward what this band is actually doing:
            // snap out to a new extreme, creep back in otherwise.
            var hiDB = windowHiDB[i]
            var loDB = windowLoDB[i]
            // Reach out toward a new extreme, relax back when none arrives.
            // Silent frames are skipped entirely.
            if db > Self.noSignalDB {
                if db > hiDB { hiDB += (db - hiDB) * riseCoefficient } else { hiDB -= relax }
                if db < loDB { loDB += (db - loDB) * fallCoefficient } else { loDB += relax }
                if hiDB - loDB > Self.maxWindowDB {
                    loDB = hiDB - Self.maxWindowDB
                }
                if hiDB - loDB < Self.minWindowDB {
                    let mid = (hiDB + loDB) * 0.5
                    hiDB = mid + Self.minWindowDB * 0.5
                    loDB = mid - Self.minWindowDB * 0.5
                }
            }
            windowHiDB[i] = hiDB
            windowLoDB[i] = loDB

            var target: Float = 0
            if hiDB > Self.silenceDB {
                target = (db - loDB) / (hiDB - loDB)
                target = min(max(target, 0), 1)
            }

            let previous = levels[i]
            let coefficient = target > previous ? attackCoefficient : releaseCoefficient
            levels[i] = previous + (target - previous) * coefficient
        }

        if sawSignal { liveFlag.pointee = 1 }
    }
}
