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
import Foundation

/// Mel filterbank construction matching `librosa.filters.mel` with binarization.
///
/// Produces a binarized mel-scale filterbank for splitting a spectrogram
/// into overlapping frequency bands. Used by ``BandSplit``.
///
/// The filterbank is constructed at initialization and stored as constant tensors.
/// No learnable parameters.
struct MelFilterbank {

    /// Binarized filterbank matrix: `[numBands, freqBins]` (1.0 where band covers frequency, 0.0 otherwise).
    let binaryFilterbank: MLXArray

    /// Number of frequency bins per band.
    let numFreqsPerBand: [Int]

    /// Stereo-interleaved gather indices for band splitting: `[totalGathered]`.
    let freqIndices: MLXArray

    /// Number of bands covering each gathered frequency (for overlap averaging).
    let numBandsPerFreq: MLXArray

    /// Per-band input dimensions (numFreqsPerBand[i] × 2 stereo × 2 complex).
    let bandDims: [Int]

    /// Total number of gathered frequency entries (sum of stereo-interleaved freqs across all bands).
    let totalGathered: Int

    /// Create a mel filterbank matching `librosa.filters.mel(sr, n_fft, n_mels)` with binarization.
    ///
    /// - Parameters:
    ///   - sampleRate: Audio sample rate in Hz (default 44100).
    ///   - nFFT: FFT size (default 2048).
    ///   - numBands: Number of mel bands (default 60).
    init(sampleRate: Double = 44100.0, nFFT: Int = 2048, numBands: Int = 60) {
        let freqBins = nFFT / 2 + 1  // 1025

        // Build mel filterbank (librosa equivalent)
        var filterbank = MelFilterbank.buildMelFilterbank(
            sampleRate: sampleRate, nFFT: nFFT, numBands: numBands
        )

        // Corner corrections: ensure first and last freq bins are assigned
        if filterbank[0][0] == 0.0 {
            filterbank[0][0] = filterbank[0][1] * 0.25
        }
        if filterbank[numBands - 1][freqBins - 1] == 0.0 {
            filterbank[numBands - 1][freqBins - 1] = filterbank[numBands - 1][freqBins - 2] * 0.25
        }

        // Binarize: all non-zero values → 1.0
        var binaryFB = [[Float]](repeating: [Float](repeating: 0.0, count: freqBins), count: numBands)
        for b in 0..<numBands {
            for f in 0..<freqBins {
                binaryFB[b][f] = filterbank[b][f] > 0 ? 1.0 : 0.0
            }
        }

        // Compute per-band frequency counts
        var freqsPerBand = [Int](repeating: 0, count: numBands)
        for b in 0..<numBands {
            freqsPerBand[b] = binaryFB[b].reduce(0) { $0 + ($1 > 0 ? 1 : 0) }
        }

        // Build stereo-interleaved gather indices
        // For each band, for each frequency in that band, add stereo pairs
        // Final ordering: all bands concatenated, each freq → [freq*2, freq*2+1]
        var indices = [Int32]()
        for b in 0..<numBands {
            for f in 0..<freqBins {
                if binaryFB[b][f] > 0 {
                    indices.append(Int32(f * 2))      // Left channel
                    indices.append(Int32(f * 2 + 1))  // Right channel
                }
            }
        }

        // Compute how many bands cover each stereo-interleaved frequency
        // Total stereo entries = freqBins * 2 = 2050
        var bandsPerStereoFreq = [Float](repeating: 0.0, count: freqBins * 2)
        for b in 0..<numBands {
            for f in 0..<freqBins {
                if binaryFB[b][f] > 0 {
                    bandsPerStereoFreq[f * 2] += 1.0      // Left
                    bandsPerStereoFreq[f * 2 + 1] += 1.0  // Right
                }
            }
        }

        // Per-band input dimensions: freqsPerBand × 2(stereo) × 2(complex re/im)
        let dims = freqsPerBand.map { $0 * 2 * 2 }

        self.binaryFilterbank = MLXArray(binaryFB.flatMap { $0 }).reshaped([numBands, freqBins])
        self.numFreqsPerBand = freqsPerBand
        self.freqIndices = MLXArray(indices)
        self.numBandsPerFreq = MLXArray(bandsPerStereoFreq)
        self.bandDims = dims
        self.totalGathered = indices.count
    }

    // MARK: - Private Helpers

    /// Build a triangular mel filterbank matching `librosa.filters.mel`.
    ///
    /// Uses the HTK mel scale: `mel = 2595 × log10(1 + f/700)`.
    private static func buildMelFilterbank(
        sampleRate: Double, nFFT: Int, numBands: Int
    ) -> [[Float]] {
        let freqBins = nFFT / 2 + 1

        // Frequency of each FFT bin
        let fftFreqs = (0..<freqBins).map { Double($0) * sampleRate / Double(nFFT) }

        // Mel scale: numBands + 2 edges (including low and high)
        let fMin = 0.0
        let fMax = sampleRate / 2.0
        let melMin = hzToMel(fMin)
        let melMax = hzToMel(fMax)

        // Equally spaced mel points
        let numEdges = numBands + 2
        let melPoints = (0..<numEdges).map { i in
            melMin + Double(i) * (melMax - melMin) / Double(numEdges - 1)
        }
        let hzPoints = melPoints.map { melToHz($0) }

        // Build triangular filters
        var filterbank = [[Float]](repeating: [Float](repeating: 0.0, count: freqBins), count: numBands)

        for band in 0..<numBands {
            let fLow = hzPoints[band]
            let fCenter = hzPoints[band + 1]
            let fHigh = hzPoints[band + 2]

            for bin in 0..<freqBins {
                let freq = fftFreqs[bin]

                if freq >= fLow && freq <= fCenter && fCenter > fLow {
                    // Rising slope
                    filterbank[band][bin] = Float((freq - fLow) / (fCenter - fLow))
                } else if freq > fCenter && freq <= fHigh && fHigh > fCenter {
                    // Falling slope
                    filterbank[band][bin] = Float((fHigh - freq) / (fHigh - fCenter))
                }
            }

            // Normalize by bandwidth (Slaney normalization, matching librosa default)
            let bandwidth = hzPoints[band + 2] - hzPoints[band]
            if bandwidth > 0 {
                let normFactor = Float(2.0 / bandwidth)
                for bin in 0..<freqBins {
                    filterbank[band][bin] *= normFactor
                }
            }
        }

        return filterbank
    }

    // MARK: - Slaney Mel Scale (librosa default)

    /// Frequency spacing for the linear portion of the Slaney mel scale (below 1 kHz).
    private static let slaneySP = 200.0 / 3.0  // ~66.67 Hz

    /// Transition point from linear to log mel scale.
    private static let slaneyMinLogHz = 1000.0

    /// Log mel breakpoint.
    private static let slaneyMinLogMel = slaneyMinLogHz / slaneySP  // 15.0

    /// Step for the log portion of the mel scale.
    private static let slaneyLogStep = log(6.4) / 27.0

    /// Convert frequency in Hz to mel scale (Slaney/librosa default).
    ///
    /// Linear below 1000 Hz, logarithmic above.
    private static func hzToMel(_ hz: Double) -> Double {
        if hz < slaneyMinLogHz {
            return hz / slaneySP
        } else {
            return slaneyMinLogMel + log(hz / slaneyMinLogHz) / slaneyLogStep
        }
    }

    /// Convert mel scale to frequency in Hz (Slaney/librosa default).
    private static func melToHz(_ mel: Double) -> Double {
        if mel < slaneyMinLogMel {
            return slaneySP * mel
        } else {
            return slaneyMinLogHz * exp(slaneyLogStep * (mel - slaneyMinLogMel))
        }
    }
}
