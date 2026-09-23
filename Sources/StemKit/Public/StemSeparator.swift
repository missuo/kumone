import Foundation
import MLX

/// The separated stems of one window, deinterleaved into per-channel buffers.
///
/// **Two different truths live in here and the difference matters.**
///
/// ``lanes`` is what the checkpoint actually estimated — for a four-stem model,
/// four independently masked signals. Those do **not** sum back to the mixture:
/// the per-stem complex masks are estimated independently and nothing in the
/// architecture constrains them to partition the input. Whatever is left over
/// is ``residual``, and `Σ lanes + residual == mixture` exactly, by
/// construction.
///
/// ``accompaniment`` is the other truth: `mixture − vocals`, which is exact by
/// definition and is what makes the two-stem branch artifact-tolerant — whatever
/// the separator leaks out of the vocal stem lands back in the accompaniment
/// rather than disappearing. A mixer that rebuilds a buffer out of stems needs a
/// *partition*, not four estimates, which is why Kumone's four-lane consumers
/// use `mixture − vocals − drums − bass` as their "other" rather than the
/// model's own — see `partition(mixture:)`.
public struct SeparatedStems: Sendable {
    /// What the checkpoint estimated, keyed by lane. A single-stem vocals model
    /// has exactly one entry.
    public let lanes: [StemLane: [[Float]]]
    /// `mixture − Σ lanes`, one array per channel. Zero for a single-stem model
    /// only if you also count the accompaniment as a lane, which we do not:
    /// with one estimated lane this is simply the accompaniment.
    public let residual: [[Float]]
    /// Vocal stem, one array per channel.
    public var vocals: [[Float]] { lanes[.vocals] ?? [] }
    /// Accompaniment stem (`mixture - vocals`), one array per channel.
    public let accompaniment: [[Float]]
    /// Sample rate of both stems.
    public let sampleRate: Double
    /// Wall-clock seconds spent inside the model (excludes I/O).
    public let separationSeconds: Double

    public init(lanes: [StemLane: [[Float]]], residual: [[Float]],
                accompaniment: [[Float]], sampleRate: Double,
                separationSeconds: Double) {
        self.lanes = lanes
        self.residual = residual
        self.accompaniment = accompaniment
        self.sampleRate = sampleRate
        self.separationSeconds = separationSeconds
    }

    /// The lanes rewritten as an exact partition of the mixture: `vocals`,
    /// `drums` and `bass` as the model estimated them, and `other` as
    /// everything the three of them do not account for (the model's own `other`
    /// plus ``residual``).
    ///
    /// **Why not the model's `other`.** Every consumer downstream rebuilds a
    /// buffer as `Σ laneᵢ × gainᵢ(t)`, and the whole design rests on that sum
    /// being the untouched mixture when every gain is unity — that invariant is
    /// what lets a stem envelope compose with the fader, the EQ hand-over and
    /// the outro effect instead of competing with them. Four independent mask
    /// estimates do not have it; this does, exactly, sample for sample.
    public func partition() -> [StemLane: [[Float]]] {
        guard lanes.count > 1, let other = lanes[.other] else { return lanes }
        var result = lanes
        result[.other] = Self.sum(other, residual)
        return result
    }

    private static func sum(_ a: [[Float]], _ b: [[Float]]) -> [[Float]] {
        guard a.count == b.count else { return a }
        return zip(a, b).map { left, right in
            guard left.count == right.count else { return left }
            return (0..<left.count).map { left[$0] + right[$0] }
        }
    }

    /// Frames per channel.
    public var frameCount: Int { vocals.first?.count ?? residual.first?.count ?? 0 }

    /// Duration in seconds.
    public var duration: Double { Double(frameCount) / sampleRate }

    /// Realtime factor: audio seconds processed per wall-clock second.
    public var realtimeFactor: Double {
        guard separationSeconds > 0 else { return 0 }
        return duration / separationSeconds
    }
}

/// Errors surfaced by ``StemSeparator``.
public enum StemSeparatorError: Error, CustomStringConvertible, Sendable {
    case unsupportedChannelCount(Int)
    case raggedChannels
    case unsupportedSampleRate(Double)
    case empty

    public var description: String {
        switch self {
        case .unsupportedChannelCount(let count):
            return "StemSeparator expects 1 or 2 channels, got \(count)"
        case .raggedChannels:
            return "StemSeparator expects every channel to have the same frame count"
        case .unsupportedSampleRate(let rate):
            return """
                StemSeparator expects \(RoFormerConfiguration.zfturboVocalsV1.sampleRate) Hz \
                input, got \(rate) Hz. Resample before calling.
                """
        case .empty:
            return "StemSeparator was given no samples"
        }
    }
}

/// Offline vocal/accompaniment separation for AutoMix stem transitions.
///
/// Deliberately offline-only. AutoMix knows its cut point roughly 60 s ahead, so
/// separation runs as background batch work on a ~30 s window and its output is
/// pre-rendered to PCM — the realtime `AVAudioEngine` graph is never touched.
///
/// The separator owns model residency: the checkpoint is loaded once at
/// ``prepare(modelStore:descriptor:progress:)`` and stays warm across calls, because
/// one transition needs two separations (outgoing window and incoming window) and
/// paging 64 MB of weights twice is pure waste.
///
/// ```swift
/// let separator = try await StemSeparator.prepare()
/// let stems = try await separator.separate(samples: channels, sampleRate: 44_100)
/// ```
public final class StemSeparator: @unchecked Sendable {

    private let separator: RoFormerSeparator
    private let configuration: RoFormerConfiguration

    /// Sample rate this separator requires its input to be at.
    public var requiredSampleRate: Double { configuration.sampleRate }

    /// Which lanes this separator's checkpoint emits, in output order.
    public var stemOrder: [StemLane] { configuration.stemOrder }

    // MARK: - Lifecycle

    /// Load the model, downloading the checkpoint on first use, and warm it up.
    ///
    /// - Parameters:
    ///   - modelStore: Where checkpoints live. Defaults to
    ///     `~/Library/Application Support/Kumone/Models/`.
    ///   - descriptor: Which checkpoint to use.
    ///   - warmUp: Run one tiny forward pass so the first real separation does not pay
    ///     Metal pipeline construction. Cheap (well under a second) and worth it.
    ///   - downloadProgress: 0...1 fraction while the checkpoint downloads.
    public static func prepare(
        modelStore: ModelStore = ModelStore(),
        descriptor: ModelDescriptor = .zfturboVocalsV1,
        warmUp: Bool = true,
        downloadProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> StemSeparator {
        let weights = try await modelStore.ensureAvailable(descriptor, progress: downloadProgress)
        let separator = try await RoFormerSeparator(
            weightsFile: weights,
            configuration: descriptor.configuration
        )
        let stemSeparator = StemSeparator(
            separator: separator,
            configuration: descriptor.configuration
        )
        if warmUp {
            try await stemSeparator.warmUp()
        }
        return stemSeparator
    }

    init(separator: RoFormerSeparator, configuration: RoFormerConfiguration) {
        self.separator = separator
        self.configuration = configuration
    }

    /// Push one short buffer through the model to build Metal pipelines ahead of time.
    public func warmUp() async throws {
        let frames = configuration.hopLength * 8
        let silence = MLXArray.zeros([1, 2, frames])
        _ = try await separator.separate(samples: silence)
    }

    // MARK: - Separation

    /// Separate a window of audio into vocals and accompaniment.
    ///
    /// - Parameters:
    ///   - samples: Per-channel deinterleaved samples. 1 channel (duplicated to stereo for
    ///     the model, then folded back to mono) or 2 channels.
    ///   - sampleRate: Must equal ``requiredSampleRate``; resample upstream if it does not.
    /// - Returns: Vocals and accompaniment at the same channel count and length as the input.
    public func separate(
        samples: [[Float]],
        sampleRate: Double
    ) async throws -> SeparatedStems {
        guard sampleRate == configuration.sampleRate else {
            throw StemSeparatorError.unsupportedSampleRate(sampleRate)
        }
        guard (1...2).contains(samples.count) else {
            throw StemSeparatorError.unsupportedChannelCount(samples.count)
        }
        let frameCount = samples[0].count
        guard frameCount > 0 else { throw StemSeparatorError.empty }
        guard samples.allSatisfy({ $0.count == frameCount }) else {
            throw StemSeparatorError.raggedChannels
        }

        let inputChannels = samples.count
        let left = samples[0]
        let right = inputChannels == 2 ? samples[1] : samples[0]

        let mixture = stacked([MLXArray(left), MLXArray(right)], axis: 0)
            .expandedDimensions(axis: 0)  // [1, 2, frames]

        let start = CFAbsoluteTimeGetCurrent()
        // [1, stems, 2, frames], stem index following `configuration.stemOrder`.
        let stemsArray = try await separator.separate(samples: mixture)
        let order = configuration.stemOrder
        let vocalsIndex = order.firstIndex(of: .vocals) ?? 0
        let vocalsArray = stemsArray[0..., vocalsIndex]
        let accompanimentArray = mixture - vocalsArray
        // `mixture − Σ lanes`: what no estimated stem accounts for.
        let residualArray = mixture - stemsArray.sum(axis: 1)
        MLX.eval(stemsArray, accompanimentArray, residualArray)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        var lanes: [StemLane: [[Float]]] = [:]
        for (index, lane) in order.enumerated() {
            lanes[lane] = Self.channels(of: stemsArray[0..., index], count: inputChannels)
        }

        let stems = SeparatedStems(
            lanes: lanes,
            residual: Self.channels(of: residualArray, count: inputChannels),
            accompaniment: Self.channels(of: accompanimentArray, count: inputChannels),
            sampleRate: sampleRate,
            separationSeconds: elapsed
        )
        // The stems are Swift arrays now — nothing MLX-side is live but the
        // weights, so this is the window's real completion point.
        Self.trimCache(after: String(format: "%.1fs window", stems.duration))
        return stems
    }

    // MARK: - GPU cache

    /// Hand the MLX allocator's cached Metal buffers back after a window.
    ///
    /// **Why this is not optional.** MLX pools freed device buffers and only
    /// reclaims them lazily, when a later allocation would breach
    /// ``RoFormerConfiguration/gpuCacheLimit``. Since a separation transiently
    /// touches ~1.6 GB, the pool saturates at the limit on the very first window
    /// and stays there for the life of the process: measured on an M4, a player
    /// that had separated once sat at **0.79 GB** physical footprint with
    /// **0.50 GB** of it pure cache, against **0.06 GB** of genuinely live model
    /// weights. Nothing gives it back, because nothing ever asks.
    ///
    /// **Why clearing outright, rather than a smaller limit.** A lower
    /// ``RoFormerConfiguration/gpuCacheLimit`` would only trim on the *next*
    /// allocation, so the memory stays held for exactly as long as it is a
    /// problem — the idle stretch between two seams. Dropping the pool costs
    /// nothing to rebuild: over four 12 s windows on an M4, separations that
    /// started from an empty cache ran in **5.587 s** mean against **5.600 s**
    /// warm — a 0.2 % difference, inside the run-to-run noise. The buffers come
    /// back out of the Metal heap; only the pooling is discarded, not the
    /// weights, and not the compiled pipelines.
    ///
    /// So the ceiling stays where it is for the duration of a window — the
    /// chunked forward pass genuinely reuses those buffers — and the pool is
    /// dropped the moment the window is done.
    private static func trimCache(after context: String) {
        let before = MLX.Memory.cacheMemory
        guard before > 0 else { return }
        MLX.Memory.clearCache()
        report(freed: before, remaining: MLX.Memory.cacheMemory, context: context)
    }

    /// Where a trim gets announced.
    ///
    /// StemKit cannot see `PlaybackJournal` — KumoneCore is deliberately
    /// MLX-free and the dependency only runs the other way — so the host wires
    /// this up (`StemSetup`) and StemKit stays a library that
    /// separates audio. Unset, a trim is silent, which is what a plain library
    /// caller wants.
    public static var onCacheTrim: (@Sendable (String) -> Void)? {
        get { hook.withLock { $0 } }
        set { hook.withLock { $0 = newValue } }
    }

    private static let hook = Mutex<(@Sendable (String) -> Void)?>(nil)

    private static func report(freed: Int, remaining: Int, context: String) {
        guard let sink = onCacheTrim else { return }
        let megabytes = { (bytes: Int) in Double(bytes) / (1024 * 1024) }
        sink(String(format: "mlx cache trimmed to %.0fMB after %@ (freed %.0fMB)",
                    megabytes(remaining), context, megabytes(freed)))
    }

    /// Convenience overload for interleaved stereo input.
    ///
    /// - Parameters:
    ///   - interleaved: `L R L R …` samples.
    ///   - channelCount: Number of interleaved channels (1 or 2).
    ///   - sampleRate: Must equal ``requiredSampleRate``.
    public func separate(
        interleaved: [Float],
        channelCount: Int,
        sampleRate: Double
    ) async throws -> SeparatedStems {
        guard (1...2).contains(channelCount) else {
            throw StemSeparatorError.unsupportedChannelCount(channelCount)
        }
        let frames = interleaved.count / channelCount
        var deinterleaved = [[Float]](
            repeating: [Float](repeating: 0, count: frames), count: channelCount)
        for frame in 0..<frames {
            for channel in 0..<channelCount {
                deinterleaved[channel][frame] = interleaved[frame * channelCount + channel]
            }
        }
        return try await separate(samples: deinterleaved, sampleRate: sampleRate)
    }

    // MARK: - Private

    /// Pull `[1, 2, frames]` back out to per-channel Swift arrays, folding to mono when
    /// the caller gave us mono (the two model channels are identical in that case, so
    /// averaging is a no-op that also cancels any channel-asymmetric numerical drift).
    private static func channels(of array: MLXArray, count: Int) -> [[Float]] {
        let squeezed = array.squeezed(axis: 0)  // [2, frames]
        if count == 1 {
            let mono = squeezed.mean(axis: 0)
            MLX.eval(mono)
            return [mono.asArray(Float.self)]
        }
        return (0..<2).map { channel in
            let slice = squeezed[channel]
            MLX.eval(slice)
            return slice.asArray(Float.self)
        }
    }
}

/// A lock around one value. `NSLock` plus a stored property, spelled once.
///
/// Swift's own `Mutex` is in `Synchronization` and needs macOS 15; StemKit
/// still builds for 14.
private final class Mutex<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
