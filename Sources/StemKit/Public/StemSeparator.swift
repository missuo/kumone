import Foundation
import MLX

/// A pair of separated stems, deinterleaved into per-channel sample buffers.
///
/// `vocals` and `accompaniment` sum back to the input sample-for-sample: the model
/// estimates vocals, and the accompaniment is the residual `mixture - vocals`. That
/// identity is what makes the instrumental branch cheap and artifact-tolerant — whatever
/// the separator leaks out of the vocal stem lands back in the accompaniment.
public struct SeparatedStems: Sendable {
    /// Vocal stem, one array per channel.
    public let vocals: [[Float]]
    /// Accompaniment stem (`mixture - vocals`), one array per channel.
    public let accompaniment: [[Float]]
    /// Sample rate of both stems.
    public let sampleRate: Double
    /// Wall-clock seconds spent inside the model (excludes I/O).
    public let separationSeconds: Double

    /// Frames per channel.
    public var frameCount: Int { vocals.first?.count ?? 0 }

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

    /// Configuration the resident model was built with.
    public var modelConfiguration: RoFormerConfiguration { configuration }

    /// Sample rate this separator requires its input to be at.
    public var requiredSampleRate: Double { configuration.sampleRate }

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
        let vocalsArray = try await separator.separate(samples: mixture)
        let accompanimentArray = mixture - vocalsArray
        MLX.eval(vocalsArray, accompanimentArray)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        return SeparatedStems(
            vocals: Self.channels(of: vocalsArray, count: inputChannels),
            accompaniment: Self.channels(of: accompanimentArray, count: inputChannels),
            sampleRate: sampleRate,
            separationSeconds: elapsed
        )
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
