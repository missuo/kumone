// Adapted from xocialize/mel-roformer-mlx-swift (MIT License)
//   https://github.com/xocialize/mel-roformer-mlx-swift
//   Copyright (c) 2026 Xocialize
// Modifications for Kumone StemKit: dependency on huggingface/swift-transformers
// removed, mlx-swift 0.30.x API drift fixed, defaults retargeted to the
// MIT-licensed ZFTurbo vocals-v1 checkpoint.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import Foundation
import MLX
import MLXNN
import os

// MARK: - Error Types

/// Errors that can occur during RoFormer vocal separation.
public enum RoFormerError: Error, Sendable, LocalizedError {
    case weightsNotFound(String)
    case audioReadFailed(Error)
    case mlxInferenceFailed(Error)
    case outputWriteFailed(Error)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .weightsNotFound(let path):
            return "RoFormer weights not found at: \(path)"
        case .audioReadFailed(let error):
            return "Failed to read audio file: \(error.localizedDescription)"
        case .mlxInferenceFailed(let error):
            return "MLX inference failed: \(error.localizedDescription)"
        case .outputWriteFailed(let error):
            return "Failed to write output file: \(error.localizedDescription)"
        case .cancelled:
            return "Separation was cancelled"
        }
    }
}

// MARK: - Progress Types

/// Processing stages for progress reporting.
public enum RoFormerStage: String, Sendable {
    case loading = "Loading audio"
    case stft = "STFT"
    case bandSplit = "Band split"
    case transformer = "Transformer"
    case maskEstimate = "Mask estimation"
    case reconstruct = "Reconstruction"
    case writing = "Writing output"
}

/// Progress update during vocal separation.
public struct RoFormerProgress: Sendable {
    /// Overall progress fraction from 0.0 to 1.0.
    public let fraction: Float

    /// Current processing stage.
    public let stage: RoFormerStage

    /// Elapsed time since separation started (seconds).
    public let elapsedSeconds: Double
}

// MARK: - RoFormerSeparator

/// Kim Mel-RoFormer vocal separator.
///
/// Separates vocals from music using the Kim Vocal 2 Mel-RoFormer model
/// (228M parameters, ~12.6 dB SDR). Processes audio in 8-second chunks
/// with 50% overlap for seamless results.
///
/// The one entry point is ``separate(samples:)``: samples in, stems out, with
/// the caller owning file I/O. `StemSeparator` wraps it.
public final class RoFormerSeparator: @unchecked Sendable {

    private let model: MelRoFormer
    private let config: RoFormerConfiguration
    private let cancelFlag: OSAllocatedUnfairLock<Bool>

    // MARK: - Initialization

    /// Create a separator from an explicit safetensors file path.
    ///
    /// Kumone resolves checkpoints through ``ModelStore``, which names files itself and
    /// verifies them by digest.
    public init(
        weightsFile: URL,
        configuration: RoFormerConfiguration
    ) async throws {
        self.config = configuration
        self.cancelFlag = OSAllocatedUnfairLock(initialState: false)
        MLX.Memory.cacheLimit = configuration.gpuCacheLimit

        let model = MelRoFormer(config: configuration)
        do {
            try WeightLoader.loadWeights(into: model, from: weightsFile)
        } catch {
            throw RoFormerError.weightsNotFound(weightsFile.path)
        }
        self.model = model
    }

    // MARK: - Public API: Raw Samples

    /// Separate vocals from raw audio samples (in-memory).
    ///
    /// - Parameter samples: Stereo audio `[1, 2, samples]` at 44.1kHz.
    /// - Returns: Separated stems `[1, stems, 2, samples]`, stem index
    ///   following ``RoFormerConfiguration/stemOrder``.
    /// - Throws: `RoFormerError` on failure or cancellation.
    public func separate(samples: MLXArray) async throws -> MLXArray {
        cancelFlag.withLock { $0 = false }
        let startTime = CFAbsoluteTimeGetCurrent()
        return try await separateChunked(
            samples,
            sampleCount: samples.shape[2],
            startTime: startTime,
            progressHandler: nil
        )
    }

    // MARK: - Cancellation

    /// Cancel the current separation operation.
    ///
    /// Stops at the next checkpoint (between chunks). The operation will throw
    /// `RoFormerError.cancelled`.
    public func cancel() {
        cancelFlag.withLock { $0 = true }
    }

    // MARK: - Private: Chunked Processing

    private func separateChunked(
        _ audio: MLXArray,
        sampleCount: Int,
        startTime: CFAbsoluteTime,
        progressHandler: ((Float, RoFormerStage) -> Void)?
    ) async throws -> MLXArray {
        let chunkSamples = config.chunkSize  // 352800 (8s at 44.1kHz)
        let stepSize = chunkSamples / config.numOverlap  // 176400 (50% overlap)

        // Single chunk fast path
        if sampleCount <= chunkSamples {
            progressHandler?(0.10, .stft)
            let result = model(audio)
            MLX.eval(result)
            progressHandler?(0.90, .reconstruct)
            return result
        }

        // Multi-chunk overlap-add.
        //
        // `ceil`, not integer division: the old `(N − C) / S + 1` covered the
        // input only when the overshoot happened to be a whole number of steps,
        // and silently left the tail of everything else at zero weight — a
        // 12 s window through a 11 s chunk produced one chunk and a second of
        // silence. Every window the vocals preset has ever been asked for is
        // step-aligned, which is why it went unnoticed; the four-stem preset's
        // 485 100-sample chunk is not.
        let overshoot = sampleCount - chunkSamples
        let totalChunks = (overshoot + stepSize - 1) / stepSize + 1
        let outputLength = sampleCount
        let stemCount = config.numStems

        // Initialize accumulation buffers — [1, stems, 2, N] and a broadcast
        // weight that is flat across both the stem and the channel axis.
        var output = MLXArray.zeros([1, stemCount, 2, outputLength])
        var totalWeight = MLXArray.zeros([1, 1, 1, outputLength])

        for chunkIdx in 0..<totalChunks {
            try checkCancelled()

            let offset = chunkIdx * stepSize
            let end = min(offset + chunkSamples, sampleCount)
            let actualLength = end - offset

            // Extract chunk, pad if needed
            var chunk = audio[0..., 0..., offset..<end]
            if actualLength < chunkSamples {
                let padSize = chunkSamples - actualLength
                let padding = MLXArray.zeros([1, 2, padSize])
                chunk = concatenated([chunk, padding], axis: 2)
            }

            // Report progress
            let chunkFraction = Float(chunkIdx) / Float(totalChunks)
            let overallFraction = 0.10 + chunkFraction * 0.80
            progressHandler?(overallFraction, .transformer)

            // Run model on chunk
            let separated = model(chunk)
            MLX.eval(separated)

            // Trim if padded
            let trimmed = actualLength < chunkSamples
                ? separated[0..., 0..., 0..., ..<actualLength]
                : separated

            // Build crossfade weight window [1, 1, actualLength]
            let weight = buildCrossfadeWeight(
                chunkLength: actualLength,
                overlapLength: chunkSamples - stepSize,
                isFirst: chunkIdx == 0,
                isLast: chunkIdx == totalChunks - 1
            )

            // Accumulate: weighted overlap-add
            // We need to add weighted contribution at [offset:end]
            let weighted = trimmed * weight

            // Accumulate using slice assignment simulation
            // Since MLX doesn't support slice assignment, we use padding + addition
            let leftPad = offset
            let rightPad = outputLength - end

            if leftPad > 0 || rightPad > 0 {
                var weightedParts = [MLXArray]()
                var weightParts = [MLXArray]()

                if leftPad > 0 {
                    weightedParts.append(MLXArray.zeros([1, stemCount, 2, leftPad]))
                    weightParts.append(MLXArray.zeros([1, 1, 1, leftPad]))
                }
                weightedParts.append(weighted)
                weightParts.append(weight)
                if rightPad > 0 {
                    weightedParts.append(MLXArray.zeros([1, stemCount, 2, rightPad]))
                    weightParts.append(MLXArray.zeros([1, 1, 1, rightPad]))
                }

                output = output + concatenated(weightedParts, axis: 3)
                totalWeight = totalWeight + concatenated(weightParts, axis: 3)
            } else {
                output = output + weighted
                totalWeight = totalWeight + weight
            }
        }

        // Normalize by total weight
        let epsilon = MLXArray(Float(1e-8))
        let normalizer = maximum(totalWeight, epsilon)
        let result = output / normalizer
        MLX.eval(result)

        progressHandler?(0.90, .reconstruct)
        return result
    }

    /// Build a linear crossfade weight window for overlap-add.
    ///
    /// - Parameters:
    ///   - chunkLength: Length of this chunk in samples.
    ///   - overlapLength: Number of overlap samples between chunks.
    ///   - isFirst: Whether this is the first chunk.
    ///   - isLast: Whether this is the last chunk.
    /// - Returns: Weight array `[1, 1, 1, chunkLength]`, broadcasting across
    ///   the stem and channel axes.
    private func buildCrossfadeWeight(
        chunkLength: Int,
        overlapLength: Int,
        isFirst: Bool,
        isLast: Bool
    ) -> MLXArray {
        // Start with all ones
        var weights = [Float](repeating: 1.0, count: chunkLength)

        // Apply fade-in at start (except for the first chunk)
        // Use (overlapLength - 1) as divisor to get full range [0, 1]
        if !isFirst && overlapLength > 1 {
            let divisor = Float(overlapLength - 1)
            for i in 0..<min(overlapLength, chunkLength) {
                weights[i] = Float(i) / divisor
            }
        }

        // Apply fade-out at end (except for the last chunk)
        // Use (overlapLength - 1) as divisor to get full range [0, 1]
        if !isLast && overlapLength > 1 {
            let divisor = Float(overlapLength - 1)
            for i in 0..<min(overlapLength, chunkLength) {
                let idx = chunkLength - 1 - i
                weights[idx] = Float(i) / divisor
            }
        }

        return MLXArray(weights).reshaped([1, 1, 1, chunkLength])
    }

    // MARK: - Private: Helpers

    /// Check if cancellation has been requested — either lane.
    ///
    /// Two cancellation lanes, distinct error types by design:
    /// - The wrapping `Task` was cancelled (MLXEngine run-lifecycle / C13 cooperative
    ///   cancellation): throws `CancellationError` UNCHANGED — callers and the engine classify
    ///   cancelled-vs-failed by that type, so it must never be wrapped in `RoFormerError`.
    /// - The explicit `cancel()` API set `cancelFlag`: throws `RoFormerError.cancelled`.
    ///
    /// Called per processed 8 s chunk in `separateChunked` (and between pipeline stages), so a
    /// cancelled separation bails at the next chunk boundary.
    private func checkCancelled() throws {
        try Task.checkCancellation()
        if cancelFlag.withLock({ $0 }) {
            throw RoFormerError.cancelled
        }
    }
}
