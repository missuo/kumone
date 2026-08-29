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

/// Configuration for the Kim Vocal 2 Mel-RoFormer model.
///
/// Default values match the Kim Vocal 2 checkpoint (228M parameters):
/// - dim=384, depth=6, heads=8, dimHead=64
/// - 60 mel bands, n_fft=2048, hop_length=441
/// - 44.1kHz stereo input
public struct RoFormerConfiguration: Sendable {

    // MARK: - Model Architecture

    /// Hidden dimension of the transformer.
    public var dim: Int = 384

    /// Number of dual-axis transformer depth levels.
    public var depth: Int = 6

    /// Number of attention heads.
    public var heads: Int = 8

    /// Dimension per attention head.
    public var dimHead: Int = 64

    /// Number of mel bands for band splitting.
    public var numBands: Int = 60

    /// Number of output stems (1 = vocals only).
    public var numStems: Int = 1

    /// Feed-forward expansion multiplier.
    public var ffMult: Int = 4

    /// MLP expansion factor in mask estimator.
    public var mlpExpansionFactor: Int = 4

    /// Depth of MLP in mask estimator (number of hidden layers).
    public var maskEstimatorDepth: Int = 2

    // MARK: - STFT Parameters

    /// FFT size.
    public var nFFT: Int = 2048

    /// Hop length between STFT frames.
    public var hopLength: Int = 441

    /// Window length for STFT.
    public var winLength: Int = 2048

    /// Sample rate in Hz.
    public var sampleRate: Double = 44100.0

    // MARK: - Derived Properties

    /// Inner dimension of attention (heads × dimHead).
    public var dimInner: Int { heads * dimHead }  // 512

    /// Feed-forward hidden dimension (dim × ffMult).
    public var ffDim: Int { dim * ffMult }  // 1536

    /// MLP hidden dimension in mask estimator.
    public var mlpHidden: Int { dim * mlpExpansionFactor }  // 1536

    /// Number of frequency bins from STFT (nFFT/2 + 1).
    public var freqBins: Int { nFFT / 2 + 1 }  // 1025

    // MARK: - Processing

    /// Run the transformer body in fp16 instead of letting MLX promote to fp32.
    ///
    /// Off, because measuring it settled the question. The checkpoint is fp16, so casting
    /// activations down to match looked like free speed — it is not. On an M4 it produced
    /// no measurable speedup at all (17.2 s vs 17.4 s on a 30 s window: the model is not
    /// matmul-throughput-bound here), while parity against the S1 Python/MLX reference
    /// stem fell from **37.6 dB SNR to 20.7 dB**.
    ///
    /// Kept as a knob rather than deleted so the finding stays reproducible, but there is
    /// currently no reason to turn it on. STFT, mask application and iSTFT are fp32 either
    /// way.
    public var halfPrecisionCompute: Bool = false

    /// GPU memory cache limit in bytes.
    public var gpuCacheLimit: Int = 512 * 1024 * 1024  // 512 MB

    /// Chunk size in samples for chunked processing (8 seconds at 44.1kHz).
    public var chunkSize: Int = 352_800

    /// Number of overlap regions (2 = 50% overlap).
    public var numOverlap: Int = 2

    // MARK: - Presets

    /// Kim Vocal 2 checkpoint defaults (GPL-3.0 weights).
    ///
    /// 228 M parameters. dim=384, depth=6, mask_estimator_depth=2, hop=441.
    public static let kimVocal2 = RoFormerConfiguration()

    /// ZFTurbo v1.0.0 vocals checkpoint — the MIT-licensed preset.
    ///
    /// Matches release asset `model_vocals_mel_band_roformer_sdr_8.42.ckpt`
    /// from ZFTurbo/Music-Source-Separation-Training v1.0.0. Smaller than
    /// Kim Vocal 2 (~128 MB) with a narrower transformer and single-hidden
    /// mask estimator MLP — runs faster and is redistributable under MIT.
    ///
    /// Architecture differences vs `kimVocal2`:
    /// - `dim: 192` (vs 384)
    /// - `depth: 8` (vs 6)
    /// - `hopLength: 512` (vs 441)
    /// - `maskEstimatorDepth: 1` (vs 2)
    public static let zfturboVocalsV1: RoFormerConfiguration = {
        var config = RoFormerConfiguration()
        config.dim = 192
        config.depth = 8
        config.hopLength = 512
        config.maskEstimatorDepth = 1
        return config
    }()

    public init() {}
}
