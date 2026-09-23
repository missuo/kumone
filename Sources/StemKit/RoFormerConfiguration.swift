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

    /// **How the spectrum is cut into the transformer's bands.**
    ///
    /// The one architectural axis on which the Mel-Band and BS families
    /// differ. See ``BandPlan``.
    public enum BandLayout: Sendable, Equatable {
        /// Binarized librosa mel filterbank of ``numBands`` overlapping bands.
        case mel
        /// An explicit table of band widths in FFT bins that partitions the
        /// spectrum — the checkpoint config's `freqs_per_bands`.
        case fixed([Int])
    }

    public var bandLayout: BandLayout = .mel

    /// Number of mel bands for band splitting. Read only under
    /// ``BandLayout/mel``; a fixed layout carries its own count.
    public var numBands: Int = 60

    /// Whether the checkpoint has an RMSNorm between the transformer stack and
    /// the mask estimators (`final_norm.gamma`).
    ///
    /// Present in current lucidrains BS-/Mel-Band RoFormer, absent from the
    /// older Kim Vocal 2-era checkpoints. It is not optional-with-a-default in
    /// the "harmless if unused" sense: lucidrains' RMSNorm is
    /// `l2normalize(x) · √dim · gamma`, which is not the identity at `gamma =
    /// 1`, so running it on a checkpoint that has none would scale every band
    /// feature. Hence a flag rather than a leniently-loaded parameter.
    public var hasFinalNorm: Bool = false

    /// Whether each per-axis `Transformer` ends in an RMSNorm
    /// (`layers.{i}.{axis}.norm.gamma`).
    ///
    /// True for the Mel-Band checkpoints, false for BS-RoFormer, which builds
    /// its transformers with `norm_output=False` and normalises once at the end
    /// (``hasFinalNorm``) instead. Getting this wrong is silent and ruinous —
    /// see the note on ``Transformer``.
    public var transformerNormOutput: Bool = true

    /// **Which stems this checkpoint emits, in the order its mask estimators
    /// are indexed.**
    ///
    /// `mask_estimators.{i}` in the checkpoint is `stemOrder[i]`, so this is
    /// the one place a reader has to look to know what comes out of index 2.
    /// Single-stem vocals checkpoints are `[.vocals]`; every four-stem
    /// Mel-Band RoFormer trained on MUSDB18 is `[.vocals, .drums, .bass,
    /// .other]`.
    public var stemOrder: [StemLane] = .vocalsOnly

    /// Number of output stems (1 = vocals only). Derived — the order is the
    /// source of truth, so the two can never disagree.
    public var numStems: Int { stemOrder.count }

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

    /// **BS-RoFormer, ZFTurbo v1.0.12 — the four-stem preset.**
    ///
    /// `model_bs_roformer_ep_17_sdr_9.6568.ckpt`, MIT, drums/bass/other/vocals
    /// in that order. 131 M parameters against the vocals model's 34 M, and
    /// 264 MiB of fp16 weights against 64 MiB.
    ///
    /// **Why this checkpoint and not a Mel-Band four-stem.** The only four-stem
    /// Mel-Band RoFormer weights in existence all descend from ZFTurbo's
    /// `model_mel_band_roformer_ep_5_sdr_8.9443`: 941 M parameters, 3.5 GiB to
    /// download and 1.9 GiB resident, because 96 % of that model is its four
    /// mask-estimator heads. For a music player that is not a trade — this one
    /// scores *higher* (MUSDB18 SDR 9.66 vs 8.99) at a seventh of the weights,
    /// under the same MIT licence as the vocals preset, and the only thing it
    /// asks for is a band table instead of a mel filterbank (``BandLayout``).
    ///
    /// A cascade of per-instrument single-stem models was the other candidate
    /// and is simply not available: the entire mel-roformer checkpoint
    /// ecosystem is vocals / instrumental / karaoke / dereverb variants, with
    /// no drums-only or bass-only model in this architecture at all.
    ///
    /// Config values are taken from the release's own
    /// `config_bs_roformer_384_8_2_485100.yaml`:
    /// - `dim: 384`, `depth: 8`, `heads: 8`, `dim_head: 64`
    /// - `n_fft: 2048`, `hop: 441`, `win: 2048` — the Kim Vocal 2 STFT
    /// - `mlp_expansion_factor: 2` (vocals-v1 and Kim use 4)
    /// - `mask_estimator_depth: 2` in lucidrains' counting, which counts
    ///   `Linear`s; ours counts `Tanh`s, hence `1` here. Two linears either way.
    /// - `chunk_size: 485100`, `num_overlap: 2` — kept as trained.
    public static let bsRoformerFourStem: RoFormerConfiguration = {
        var config = RoFormerConfiguration()
        config.dim = 384
        config.depth = 8
        config.hopLength = 441
        config.maskEstimatorDepth = 1
        config.mlpExpansionFactor = 2
        config.hasFinalNorm = true
        config.transformerNormOutput = false
        config.stemOrder = [.drums, .bass, .other, .vocals]
        config.bandLayout = .fixed(Self.bsRoformerBands)
        config.chunkSize = 485_100
        return config
    }()

    /// `freqs_per_bands` from `config_bs_roformer_384_8_2_485100.yaml`: 62
    /// bands widening from 2 bins at DC to 129 at Nyquist, summing to the 1025
    /// bins of a 2048-point FFT.
    static let bsRoformerBands: [Int] =
        Array(repeating: 2, count: 24)
        + Array(repeating: 4, count: 12)
        + Array(repeating: 12, count: 8)
        + Array(repeating: 24, count: 8)
        + Array(repeating: 48, count: 8)
        + [128, 129]

    public init() {}
}
