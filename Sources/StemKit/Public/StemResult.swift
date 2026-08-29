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

/// Result of a vocal separation operation.
///
/// Contains URLs to the separated audio files, timing information,
/// and performance metrics.
///
/// ```swift
/// let result = try await separator.separateVocals(from: inputURL, to: outputURL)
/// print("Vocals at: \(result.vocalsURL)")
/// print("Processing took \(result.processingTime)s (\(result.realtimeFactor)x realtime)")
/// ```
public struct StemResult: Sendable {

    /// URL to the separated vocals WAV file.
    public let vocalsURL: URL

    /// URL to the accompaniment (everything except vocals) WAV file.
    public let accompanimentURL: URL

    /// Sample rate of the output files (Hz).
    public let sampleRate: Double

    /// Duration of the source audio in seconds.
    public let durationSeconds: Double

    /// Total processing time in milliseconds (includes I/O and inference).
    public let inferenceTimeMs: Double

    // MARK: - Convenience Properties

    /// URL to the primary output file (same as ``vocalsURL``).
    public var outputURL: URL { vocalsURL }

    /// Total processing time in seconds.
    public var processingTime: Double { inferenceTimeMs / 1000.0 }

    /// Real-time factor: how many times faster than real-time.
    ///
    /// Values greater than 1.0 indicate faster-than-realtime processing.
    public var realtimeFactor: Double {
        guard inferenceTimeMs > 0 else { return 0 }
        return (durationSeconds * 1000.0) / inferenceTimeMs
    }
}
