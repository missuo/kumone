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

import MLX
import MLXNN

/// Kim Mel-RoFormer model for vocal source separation.
///
/// Full inference pipeline:
/// ```
/// [B, 2, samples] → STFT → CaC interleave → BandSplit → 6× DualAxis →
/// MaskEstimate → scatter_add merge → complex multiply → iSTFT → [B, 2, samples]
/// ```
///
/// Weight key structure (708 total):
/// ```
/// band_split.to_features.{0-59}.{0,1}.*               (180 keys)
/// layers.{0-5}.{0,1}.layers.0.{0,1}.*                  (168 keys)
/// layers.{0-5}.{0,1}.norm.gamma
/// mask_estimators.0.to_freqs.{0-59}.0.{0,2,4}.*       (360 keys)
/// ```
public class MelRoFormer: Module {

    @ModuleInfo(key: "band_split") var bandSplit: BandSplit
    @ModuleInfo var layers: [[Transformer]]
    @ModuleInfo(key: "mask_estimators") var maskEstimators: [MaskEstimator]

    let config: RoFormerConfiguration

    /// Hann window for STFT/iSTFT (not learnable).
    let window: MLXArray

    public init(config: RoFormerConfiguration = .kimVocal2) {
        self.config = config
        self.window = WindowFunctions.hannWindow(size: config.nFFT)

        // BandSplit: 60 per-band projections
        self._bandSplit.wrappedValue = BandSplit(config: config)

        // DualAxisTransformer layers: 6 depth × [time, freq]
        // We store directly as [[Transformer]] to match key paths:
        //   layers.{0-5}.{0=time, 1=freq}.*
        self._layers.wrappedValue = (0..<config.depth).map { _ in
            [
                Transformer(
                    dim: config.dim, depth: 1,
                    heads: config.heads, dimHead: config.dimHead,
                    ffMult: config.ffMult
                ),
                Transformer(
                    dim: config.dim, depth: 1,
                    heads: config.heads, dimHead: config.dimHead,
                    ffMult: config.ffMult
                )
            ]
        }

        // MaskEstimator: 1 stem (vocals only), 60 bands
        let bandDims = self._bandSplit.wrappedValue.filterbank.bandDims
        self._maskEstimators.wrappedValue = [
            MaskEstimator(config: config, bandDims: bandDims)
        ]
    }

    /// Run the full separation pipeline on a single chunk.
    ///
    /// - Parameter audio: Input audio `[batch, 2, samples]` (stereo, 44.1kHz).
    /// - Returns: Separated vocal audio `[batch, 2, samples]`.
    public func callAsFunction(_ audio: MLXArray) -> MLXArray {
        let originalLength = audio.shape[2]

        // Step 1: STFT → complex spectrogram [B, 2, freqBins, T]
        let stftComplex = STFT.stft(
            audio,
            nFFT: config.nFFT,
            hopLength: config.hopLength,
            window: window
        )

        let B = stftComplex.shape[0]
        let freqBins = stftComplex.shape[2]  // 1025
        let T = stftComplex.shape[3]

        // Step 2: Convert complex to real/imaginary channels
        // stftComplex is complex-valued [B, 2, freqBins, T]
        // Extract real and imaginary parts: each [B, 2, freqBins, T]
        let stftReal = stftComplex.realPart()
        let stftImag = stftComplex.imaginaryPart()

        // Step 3: CaC interleave — rearrange "b s f t -> b (f s) t"
        // Interleave stereo channels per frequency: [f0_L, f0_R, f1_L, f1_R, ...]
        // stftReal/stftImag: [B, 2, freqBins, T]
        // → transpose to [B, freqBins, 2, T] then reshape to [B, freqBins*2, T]
        let realInterleaved = stftReal.transposed(0, 2, 1, 3).reshaped([B, freqBins * 2, T])
        let imagInterleaved = stftImag.transposed(0, 2, 1, 3).reshaped([B, freqBins * 2, T])

        // Stack real/imag as last dim: [B, freqBins*2, T, 2]
        let stftRepr = stacked([realInterleaved, imagInterleaved], axis: -1)

        // Step 4: BandSplit → [B, T, numBands, dim]
        //
        // The checkpoint is fp16. Feeding it fp32 activations makes MLX promote every
        // matmul to fp32 — correct, but it runs the transformer at roughly half speed for
        // precision the weights do not carry. `halfPrecisionCompute` keeps the band-split →
        // transformer → mask-estimator body in fp16 (the dtype the weights were converted
        // and parity-tested at) and returns to fp32 for the mask arithmetic and iSTFT,
        // where the dynamic range actually matters.
        let bodyInput = config.halfPrecisionCompute ? stftRepr.asType(.float16) : stftRepr
        var x = bandSplit.split(bodyInput)

        // Step 5: 6× Dual-axis transformer
        let Nb = x.shape[2]
        let D = x.shape[3]

        for pair in layers {
            let timeTransformer = pair[0]
            let freqTransformer = pair[1]

            // Time attention: [B, T, Nb, D] → [B*Nb, T, D]
            var timeInput = x.transposed(0, 2, 1, 3)  // [B, Nb, T, D]
            timeInput = timeInput.reshaped([B * Nb, T, D])
            let timeOutput = timeTransformer(timeInput)
            x = timeOutput.reshaped([B, Nb, T, D]).transposed(0, 2, 1, 3)

            // Frequency attention: [B, T, Nb, D] → [B*T, Nb, D]
            let freqInput = x.reshaped([B * T, Nb, D])
            let freqOutput = freqTransformer(freqInput)
            x = freqOutput.reshaped([B, T, Nb, D])
        }

        // Step 6: Mask estimation → [B, T, totalBandDim]
        let masks = maskEstimators[0](x)

        // Step 7: Merge masks back to full spectrum → [B, freqBins*2, T, 2]
        var fullMask = bandSplit.merge(bandMasks: masks, freqBinsTimesTwo: freqBins * 2)
        if config.halfPrecisionCompute {
            fullMask = fullMask.asType(.float32)
        }

        // Step 8: Apply mask via complex multiplication
        // stftRepr: [B, freqBins*2, T, 2] (real/imag of input)
        // fullMask: [B, freqBins*2, T, 2] (real/imag of mask)
        // Complex multiply: (a + bi)(c + di) = (ac - bd) + (ad + bc)i
        let inputReal = stftRepr[0..., 0..., 0..., 0]   // [B, freqBins*2, T]
        let inputImag = stftRepr[0..., 0..., 0..., 1]   // [B, freqBins*2, T]
        let maskReal = fullMask[0..., 0..., 0..., 0]     // [B, freqBins*2, T]
        let maskImag = fullMask[0..., 0..., 0..., 1]     // [B, freqBins*2, T]

        let outReal = inputReal * maskReal - inputImag * maskImag
        let outImag = inputReal * maskImag + inputImag * maskReal

        // Step 9: De-interleave CaC back to stereo channels
        // [B, freqBins*2, T] → [B, freqBins, 2, T] → [B, 2, freqBins, T]
        let realDeinterleaved = outReal.reshaped([B, freqBins, 2, T]).transposed(0, 2, 1, 3)
        let imagDeinterleaved = outImag.reshaped([B, freqBins, 2, T]).transposed(0, 2, 1, 3)

        // Step 10: Reconstruct complex spectrogram for iSTFT
        // realDeinterleaved + i * imagDeinterleaved
        // Use asImaginary() to convert imag part, then add
        let maskedComplex = realDeinterleaved.asType(.complex64)
            + imagDeinterleaved.asImaginary()

        // Step 11: iSTFT → [B, 2, samples]
        let separated = ISTFT.istft(
            maskedComplex,
            nFFT: config.nFFT,
            hopLength: config.hopLength,
            window: window,
            length: originalLength
        )

        return separated
    }
}
