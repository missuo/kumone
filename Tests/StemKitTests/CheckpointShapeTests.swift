import Foundation
import Testing

@testable import StemKit

// What a checkpoint *must* look like for a preset to be able to load it, asked
// without downloading one. Every check here is arithmetic over a
// `RoFormerConfiguration`: no weights, no MLX kernels, no network.
//
// Nothing here may touch `MLXArray`. Constructing one needs a Metal device, and
// a machine without `mlx.metallib` does not fail that politely: MLX's C error
// handler calls `exit(-1)`, which takes the whole test process — every other
// suite included — down with it. `BandPlan` and `WeightLoader.sanitizedKey`
// are MLX-free for exactly this reason.
//
// This is the layer where the four-stem port's one real bug would have been
// caught in half a second instead of an afternoon — `transformerNormOutput`
// disagreeing with the checkpoint is invisible at load (the loader only
// complains about keys it was *given* and could not use) and produces plausible
// audio. Pinning the key set makes the disagreement a failing test.

@Suite("StemKit checkpoint shape")
struct CheckpointShapeTests {

    @Test("the four-stem preset predicts the converted checkpoint's key count exactly")
    func fourStemKeyCount() {
        let keys = RoFormerWeightKeyMap.expectedKeys(for: .bsRoformerFourStem)
        // 1387 is not a guess: it is what
        // `Scripts/convert-roformer-checkpoint.py` reports for
        // model_bs_roformer_ep_17_sdr_9.6568.ckpt after the QKV split
        // (1355 packed keys → 1387 with q/k/v separated).
        #expect(keys.count == 1387)
        #expect(Set(keys).count == keys.count)

        // 62 bands × 3, 8 levels × 2 axes × 13 (no per-axis output norm),
        // 4 stems × 62 bands × 4, and the single final norm.
        #expect(keys.filter { $0.hasPrefix("band_split.") }.count == 186)
        #expect(keys.filter { $0.hasPrefix("layers.") }.count == 208)
        #expect(keys.filter { $0.hasPrefix("mask_estimators.") }.count == 992)
        #expect(keys.contains("final_norm.gamma"))
        // The flag that matters: BS-RoFormer's per-axis transformers end in
        // nothing at all, so there must be no `layers.N.M.norm.gamma`.
        #expect(!keys.contains("layers.0.0.norm.gamma"))
    }

    @Test("the vocals preset is unchanged by the four-stem work")
    func vocalsKeySet() {
        let keys = RoFormerWeightKeyMap.expectedKeys(for: .zfturboVocalsV1)
        #expect(keys.filter { $0.hasPrefix("mask_estimators.") }
            .allSatisfy { $0.hasPrefix("mask_estimators.0.") })
        // The Mel-Band family *does* norm each axis, and does not have a final
        // norm — the mirror image of the preset above.
        #expect(keys.contains("layers.0.0.norm.gamma"))
        #expect(!keys.contains("final_norm.gamma"))
        #expect(RoFormerConfiguration.zfturboVocalsV1.numStems == 1)
    }

    @Test("stem order and count cannot drift apart")
    func stemOrder() {
        #expect(RoFormerConfiguration.bsRoformerFourStem.numStems == 4)
        #expect(RoFormerConfiguration.bsRoformerFourStem.stemOrder
            == [.drums, .bass, .other, .vocals])
        #expect(Set(RoFormerConfiguration.bsRoformerFourStem.stemOrder)
            == Set(StemLane.allCases))
    }

    @Test("a fixed band table partitions the spectrum")
    func fixedBandPlan() {
        let widths = RoFormerConfiguration.bsRoformerBands
        #expect(widths.count == 62)
        #expect(widths.reduce(0, +) == RoFormerConfiguration.bsRoformerFourStem.freqBins)

        let plan = BandPlan.fixed(widths: widths, freqBins: 1025)
        #expect(plan.numFreqsPerBand == widths)
        #expect(plan.bandDims == widths.map { $0 * 4 })
        // Every stereo-interleaved bin gathered exactly once, in order — which
        // is what makes the mel path's averaging merge degenerate to the band
        // split path's concatenation.
        #expect(plan.totalGathered == 1025 * 2)
        #expect(plan.freqIndices == (0..<2050).map(Int32.init))
    }

    @Test("a mel band plan overlaps and covers every bin")
    func melBandPlan() {
        let plan = BandPlan.mel(sampleRate: 44_100, nFFT: 2048, numBands: 60)
        #expect(plan.numFreqsPerBand.count == 60)
        // Overlapping, so more gathered entries than there are bins.
        #expect(plan.totalGathered > 1025 * 2)
        #expect(plan.numBandsPerFreq.allSatisfy { $0 >= 1 })
    }
}

@Suite("StemKit model manifest")
struct ModelManifestTests {

    @Test("digests are lowercase hex of the right length")
    func digestFormat() {
        for descriptor in [ModelDescriptor.zfturboVocalsV1, .bsRoformerFourStem] {
            #expect(descriptor.sha256.count == 64)
            #expect(descriptor.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase })
            #expect(descriptor.byteCount > 0)
        }
    }

    @Test("the four-stem checkpoint is never fetched automatically")
    func fourStemNeedsConversion() async throws {
        guard case .convertedLocally(let sourceSHA, let sourceBytes, let recipe) =
                ModelDescriptor.bsRoformerFourStem.acquisition else {
            #expect(Bool(false), "the four-stem checkpoint must not be a plain download")
            return
        }
        #expect(sourceSHA.count == 64)
        #expect(sourceBytes == 527_385_512)
        #expect(recipe.hasSuffix(".sh"))

        // And the store refuses rather than downloading a PyTorch pickle it
        // could not read anyway. Pointed at an empty directory, this must throw
        // `conversionRequired` and touch the network not at all.
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("stemkit-test-\(UUID().uuidString)")
        let store = ModelStore(directory: empty)
        await #expect(throws: ModelStoreError.self) {
            _ = try await store.ensureAvailable(.bsRoformerFourStem)
        }
    }

    @Test("the vocals checkpoint still downloads itself")
    func vocalsIsADownload() {
        if case .download = ModelDescriptor.zfturboVocalsV1.acquisition { return }
        #expect(Bool(false), "the vocals preset must stay a plain download")
    }
}

@Suite("StemKit weight loading")
struct WeightLoaderTests {

    @Test("the output projection's Sequential wrapper is unwrapped")
    func sanitizeUnwrapsToOut() {
        #expect(WeightLoader.sanitizedKey("layers.0.0.layers.0.0.to_out.0.weight")
                == "layers.0.0.layers.0.0.to_out.weight")
        // Everything else survives untouched — including the key the four-stem
        // preset added, which an over-eager sanitizer could easily eat.
        for key in ["layers.0.0.layers.0.0.to_q.weight", "final_norm.gamma",
                    "mask_estimators.3.to_freqs.61.0.2.bias",
                    "band_split.to_features.0.1.weight"] {
            #expect(WeightLoader.sanitizedKey(key) == key)
        }
    }
}
