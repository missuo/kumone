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

/// Splits a stereo complex spectrogram into mel bands and projects to hidden dim.
///
/// **Split**: Gathers stereo-interleaved frequency bins per mel band,
/// applies per-band `Sequential(RMSNorm, Linear)` projection.
///
/// **Merge**: Scatters per-band masks back to the full spectrum using
/// `scatter_add` with overlap averaging.
///
/// Weight keys:
/// - `to_features.{0-59}.0.gamma` — per-band RMSNorm
/// - `to_features.{0-59}.1.weight/bias` — per-band Linear
///
/// Each entry in `to_features` is stored as a `[Module]` array
/// `[RoFormerRMSNorm, Linear]` matching PyTorch's `nn.Sequential(norm, linear)`
/// where indices 0 and 1 are the array positions.
class BandSplit: Module {
    @ModuleInfo(key: "to_features") var toFeatures: [[Module]]

    /// Mel filterbank data (not learnable).
    let filterbank: MelFilterbank

    /// Hidden dimension for transformer.
    let dim: Int

    init(config: RoFormerConfiguration) {
        self.dim = config.dim

        // Build mel filterbank to determine per-band dimensions
        let fb = MelFilterbank(
            sampleRate: config.sampleRate,
            nFFT: config.nFFT,
            numBands: config.numBands
        )
        self.filterbank = fb

        // Create per-band projections as [RoFormerRMSNorm, Linear] arrays
        // This matches PyTorch Sequential(norm, linear) with indices 0 and 1
        self._toFeatures.wrappedValue = fb.bandDims.map { bandDim -> [Module] in
            [
                RoFormerRMSNorm(dim: bandDim),
                Linear(bandDim, config.dim),
            ]
        }
    }

    /// Apply a per-band projection (norm → linear).
    private func projectBand(_ x: MLXArray, band: Int) -> MLXArray {
        let norm = toFeatures[band][0] as! RoFormerRMSNorm
        let linear = toFeatures[band][1] as! Linear
        return linear(norm(x))
    }

    /// Split a stereo complex spectrogram into mel bands.
    ///
    /// - Parameter stftRepr: CaC representation `[batch, freqBins*2, frames, 2]`
    ///   where the second-to-last dim is stereo-interleaved frequencies
    ///   and the last dim is real/imaginary.
    /// - Returns: Band features `[batch, frames, numBands, dim]`.
    func split(_ stftRepr: MLXArray) -> MLXArray {
        let batch = stftRepr.shape[0]
        let frames = stftRepr.shape[2]

        // Gather by stereo-interleaved frequency indices
        // stftRepr: [batch, 2050, frames, 2]
        // After gather: [batch, totalGathered, frames, 2]
        let gathered = stftRepr[0..., filterbank.freqIndices, 0..., 0...]

        // Rearrange to [batch, frames, totalGathered * 2]
        // Flatten the freq and complex dims: totalGathered entries × 2 (re/im)
        let flatGathered = gathered.transposed(0, 2, 1, 3)  // [batch, frames, totalGathered, 2]
        let flattened = flatGathered.reshaped([batch, frames, -1])  // [batch, frames, totalGathered*2]

        // Split into per-band slices and apply projections
        var bandOutputs = [MLXArray]()
        bandOutputs.reserveCapacity(toFeatures.count)
        var offset = 0
        for i in 0..<toFeatures.count {
            let bandDim = filterbank.bandDims[i]
            let bandSlice = flattened[0..., 0..., offset..<(offset + bandDim)]  // [batch, frames, bandDim]
            let projected = projectBand(bandSlice, band: i)  // [batch, frames, dim]
            bandOutputs.append(projected.expandedDimensions(axis: 2))  // [batch, frames, 1, dim]
            offset += bandDim
        }

        // Concatenate along band axis: [batch, frames, numBands, dim]
        return concatenated(bandOutputs, axis: 2)
    }

    /// Merge per-band masks back to the full stereo spectrum using scatter_add.
    ///
    /// - Parameters:
    ///   - bandMasks: Per-band mask outputs, concatenated `[batch, frames, totalBandDim]`
    ///     where totalBandDim is the sum of all bandDims.
    ///   - freqBinsTimesTwo: Total stereo frequency entries (freqBins × 2 = 2050).
    /// - Returns: Full-spectrum mask `[batch, freqBinsTimesTwo, frames, 2]`.
    func merge(bandMasks: MLXArray, freqBinsTimesTwo: Int) -> MLXArray {
        let batch = bandMasks.shape[0]
        let frames = bandMasks.shape[1]

        // bandMasks: [batch, frames, totalBandDim]
        // Split back into per-band chunks of bandDim each
        // Each bandDim = numFreqsPerBand[i] * 2(stereo) * 2(complex)
        // Reshape each chunk to [batch, frames, numFreqsPerBand[i]*2(stereo), 2(complex)]
        // Then scatter to full spectrum positions

        // Initialize output: [batch, freqBinsTimesTwo, frames, 2]
        var output = MLXArray.zeros([batch, freqBinsTimesTwo, frames, 2])

        var maskOffset = 0
        var indexOffset = 0
        for i in 0..<filterbank.numFreqsPerBand.count {
            let bandDim = filterbank.bandDims[i]
            let numStereoFreqs = filterbank.numFreqsPerBand[i] * 2  // stereo pairs

            // Extract this band's mask: [batch, frames, bandDim]
            let bandMask = bandMasks[0..., 0..., maskOffset..<(maskOffset + bandDim)]

            // Reshape to [batch, frames, numStereoFreqs, 2]
            let reshaped = bandMask.reshaped([batch, frames, numStereoFreqs, 2])

            // Transpose to [batch, numStereoFreqs, frames, 2] for scatter
            let transposed = reshaped.transposed(0, 2, 1, 3)

            // Get the frequency indices for this band
            let bandIndices = filterbank.freqIndices[indexOffset..<(indexOffset + numStereoFreqs)]

            // Scatter-add using at[] operator for the entire band at once
            // This processes all frequencies in the band in one operation per frequency
            // (still O(numStereoFreqs) per band, but O(1) memory allocation per band)
            for j in 0..<numStereoFreqs {
                let freqIdx = Int(bandIndices[j].item(Int32.self))
                let contribution = transposed[0..., j, 0..., 0...]  // [batch, frames, 2]
                // Use at[].add() for scatter-add (single allocation per frequency)
                output = output.at[0..., freqIdx, 0..., 0...].add(contribution)
            }

            maskOffset += bandDim
            indexOffset += numStereoFreqs
        }

        // Divide by overlap count to average overlapping bands
        // numBandsPerFreq: [2050], broadcast to [1, 2050, 1, 1]
        let divisor = clip(
            filterbank.numBandsPerFreq.reshaped([1, freqBinsTimesTwo, 1, 1]),
            min: 1.0
        )
        output = output / divisor

        return output
    }
}
