import Foundation

/// **Which frequency bins each band of the transformer sees.**
///
/// The two RoFormer families in this repository differ in exactly one place,
/// and this is it:
///
/// - **Mel-Band RoFormer** derives its bands from a binarized librosa mel
///   filterbank. Bands *overlap*, so a frequency can belong to several of them
///   and the mask merge has to average.
/// - **BS-RoFormer** is handed an explicit table of band widths
///   (`freqs_per_bands` in the config) that partitions the spectrum exactly
///   once. Nothing overlaps and the merge is a plain concatenation.
///
/// Both produce the same four facts, so `BandSplit`, `MaskEstimator` and the
/// merge arithmetic are shared verbatim — the mel path's scatter-add with a
/// divisor of one *is* the band-split path's concatenation. Keeping one merge
/// rather than two is what made supporting a second architecture a table
/// change instead of a fork.
struct BandPlan {

    /// Number of FFT bins in each band.
    let numFreqsPerBand: [Int]

    /// Stereo-interleaved gather indices, all bands concatenated: for each bin
    /// `f` of each band, `[f*2, f*2+1]`.
    let freqIndices: [Int32]

    /// How many bands cover each stereo-interleaved bin — the merge's divisor.
    /// All ones for a partitioning plan.
    let numBandsPerFreq: [Float]

    /// Per-band input width: `numFreqsPerBand[i] × 2 (stereo) × 2 (complex)`.
    let bandDims: [Int]

    /// Total gathered entries.
    let totalGathered: Int

    private init(numFreqsPerBand: [Int], freqIndices: [Int32], bandsPerStereoFreq: [Float]) {
        self.numFreqsPerBand = numFreqsPerBand
        self.freqIndices = freqIndices
        self.numBandsPerFreq = bandsPerStereoFreq
        self.bandDims = numFreqsPerBand.map { $0 * 2 * 2 }
        self.totalGathered = freqIndices.count
    }

    /// A mel plan: binarized `librosa.filters.mel(sr, n_fft, n_mels)`, bands
    /// overlapping.
    static func mel(sampleRate: Double, nFFT: Int, numBands: Int) -> BandPlan {
        let membership = MelFilterbank.binarizedMembership(
            sampleRate: sampleRate, nFFT: nFFT, numBands: numBands)
        let freqBins = nFFT / 2 + 1

        var freqsPerBand = [Int](repeating: 0, count: numBands)
        var indices: [Int32] = []
        var bandsPerStereoFreq = [Float](repeating: 0, count: freqBins * 2)
        for band in 0..<numBands {
            for bin in 0..<freqBins where membership[band][bin] {
                freqsPerBand[band] += 1
                indices.append(Int32(bin * 2))
                indices.append(Int32(bin * 2 + 1))
                bandsPerStereoFreq[bin * 2] += 1
                bandsPerStereoFreq[bin * 2 + 1] += 1
            }
        }
        return BandPlan(numFreqsPerBand: freqsPerBand, freqIndices: indices,
                        bandsPerStereoFreq: bandsPerStereoFreq)
    }

    /// A fixed plan: consecutive runs of `widths`, partitioning `freqBins`.
    ///
    /// The table comes straight out of the checkpoint's config
    /// (`freqs_per_bands`) and must add up to the bin count, which is checked —
    /// a table that does not is a config/checkpoint mismatch, and finding that
    /// out here beats finding it out as a shape error 62 linear layers later.
    static func fixed(widths: [Int], freqBins: Int) -> BandPlan {
        precondition(widths.reduce(0, +) == freqBins,
                     "band widths sum to \(widths.reduce(0, +)), expected \(freqBins) bins")
        var indices: [Int32] = []
        indices.reserveCapacity(freqBins * 2)
        var bin = 0
        for width in widths {
            for _ in 0..<width {
                indices.append(Int32(bin * 2))
                indices.append(Int32(bin * 2 + 1))
                bin += 1
            }
        }
        return BandPlan(numFreqsPerBand: widths, freqIndices: indices,
                        bandsPerStereoFreq: [Float](repeating: 1, count: freqBins * 2))
    }

    /// The plan a configuration asks for.
    static func forConfiguration(_ config: RoFormerConfiguration) -> BandPlan {
        switch config.bandLayout {
        case .mel:
            return .mel(sampleRate: config.sampleRate, nFFT: config.nFFT,
                        numBands: config.numBands)
        case .fixed(let widths):
            return .fixed(widths: widths, freqBins: config.freqBins)
        }
    }
}
