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

/// Mel filterbank construction matching `librosa.filters.mel` with binarization.
///
/// Produces the *membership* table a mel band plan is built from: which FFT
/// bins each of the `numBands` triangular filters touches, after binarizing
/// every non-zero weight to 1. Used by ``BandPlan/mel(sampleRate:nFFT:numBands:)``.
///
/// No learnable parameters, and no stored state — the plan owns the tensors.
enum MelFilterbank {

    /// `[numBands][freqBins]`: true where the band's triangular filter is
    /// non-zero.
    ///
    /// The two corner corrections match the reference implementation: the very
    /// first and very last FFT bin fall outside every triangle at some
    /// band counts, and a bin no band owns is a bin the mask can never write.
    static func binarizedMembership(
        sampleRate: Double, nFFT: Int, numBands: Int
    ) -> [[Bool]] {
        let freqBins = nFFT / 2 + 1
        var filterbank = buildMelFilterbank(
            sampleRate: sampleRate, nFFT: nFFT, numBands: numBands)

        if filterbank[0][0] == 0.0 {
            filterbank[0][0] = filterbank[0][1] * 0.25
        }
        if filterbank[numBands - 1][freqBins - 1] == 0.0 {
            filterbank[numBands - 1][freqBins - 1] = filterbank[numBands - 1][freqBins - 2] * 0.25
        }

        return filterbank.map { band in band.map { $0 > 0 } }
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
