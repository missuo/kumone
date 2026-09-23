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

/// Errors that can occur during weight loading.
public enum WeightLoadingError: Error, CustomStringConvertible {
    case weightsDirectoryNotFound(String)
    case weightsFileNotFound(String)
    case keyMismatch(String)
    case loadFailed(String)

    public var description: String {
        switch self {
        case .weightsDirectoryNotFound(let path):
            return "Weights directory not found: \(path)"
        case .weightsFileNotFound(let path):
            return "Weights file not found: \(path). Run the conversion script first."
        case .keyMismatch(let detail):
            return "Weight key mismatch: \(detail)"
        case .loadFailed(let detail):
            return "Failed to load weights: \(detail)"
        }
    }
}

/// Loads safetensors weight files into MLX Module parameter trees.
public struct WeightLoader {

    /// Expected weight file name for the Kim Vocal 2 Mel-RoFormer model.
    static let vocalsWeightsFile = "mel_roformer_vocals.safetensors"

    /// Sanitize raw safetensors keys to match the Swift module tree.
    ///
    /// Partial mirror of the Python `MelRoFormer.sanitize()` in mlx-audio —
    /// applies the remappings that Swift's module tree requires:
    ///
    /// - Unwraps `to_out.0.weight` → `to_out.weight` (PyTorch wraps output
    ///   projection in `Sequential(Linear, Dropout)`; Swift uses bare Linear).
    ///
    /// Differences from the Python sanitize:
    /// - **`rotary_embed.freqs` is preserved** — Swift's `RotaryEmbedding`
    ///   module keeps the precomputed frequency buffer as a loadable
    ///   parameter, unlike the Python port which recomputes at runtime.
    /// - **`.gamma` is preserved** — Swift's `RoFormerRMSNorm` uses `gamma`
    ///   as its property name (matching PyTorch), so no rename is needed.
    /// - **QKV split is not performed here** — the `convert.py` script
    ///   splits `to_qkv.weight` → `to_q/to_k/to_v.weight` at conversion time.
    ///
    /// The Kim Vocal 2 `mel_roformer_vocals.safetensors` file shipped with
    /// this package was already fully Swift-ready. The `convert.py` output
    /// leaves `to_out.0.weight` wrapped, so this pass is what lets Swift
    /// load converted-from-PyTorch files directly.
    public static func sanitize(_ arrays: [String: MLXArray]) -> [String: MLXArray] {
        var result: [String: MLXArray] = [:]
        result.reserveCapacity(arrays.count)
        for (key, value) in arrays {
            result[sanitizedKey(key)] = value
        }
        return result
    }

    /// The key rewriting, on its own.
    ///
    /// Split out from ``sanitize(_:)`` so it can be checked without an
    /// `MLXArray` in hand: constructing one needs a Metal device, and a machine
    /// without `mlx.metallib` does not fail that politely — MLX's C error
    /// handler calls `exit`, which takes the whole test process with it.
    public static func sanitizedKey(_ key: String) -> String {
        guard key.hasSuffix("to_out.0.weight") else { return key }
        return String(key.dropLast(".0.weight".count)) + ".weight"
    }

    /// Load weights from a safetensors file into a Module.
    ///
    /// - Parameters:
    ///   - module: The MLX Module to load weights into.
    ///   - url: Path to the `.safetensors` file.
    /// - Throws: `WeightLoadingError` if the file is missing or keys don't match.
    public static func loadWeights(into module: Module, from url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WeightLoadingError.weightsFileNotFound(url.path)
        }

        do {
            let rawArrays = try MLX.loadArrays(url: url)
            let arrays = sanitize(rawArrays)
            let parameters = ModuleParameters.unflattened(arrays)
            try module.update(parameters: parameters, verify: .noUnusedKeys)
            MLX.eval(module.parameters())
        } catch let error as WeightLoadingError {
            throw error
        } catch {
            throw WeightLoadingError.loadFailed(error.localizedDescription)
        }
    }
}
