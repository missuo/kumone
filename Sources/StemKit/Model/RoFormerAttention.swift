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
import MLXFast
import MLXNN

/// Container for stored RoPE frequencies from the checkpoint.
///
/// Weight key: `freqs` (shape `[dimHead/2]`)
class RotaryEmbedding: Module {
    /// Precomputed frequency bases, loaded from checkpoint.
    /// Shape: `[dimHead/2]` (e.g., `[32]` for dimHead=64).
    let freqs: MLXArray

    init(dimHead: Int) {
        self.freqs = MLXArray.zeros([dimHead / 2])
    }
}

/// Multi-head attention with Rotary Position Embeddings and per-head sigmoid gates.
///
/// Weight keys (per attention block):
/// - `norm.gamma` — Pre-attention RMSNorm
/// - `rotary_embed.freqs` — Stored RoPE frequencies
/// - `to_q.weight` — Query projection `[dimInner, dim]`
/// - `to_k.weight` — Key projection `[dimInner, dim]`
/// - `to_v.weight` — Value projection `[dimInner, dim]`
/// - `to_gates.weight/bias` — Per-head sigmoid gates `[heads, dim]`
/// - `to_out.weight` — Output projection `[dim, dimInner]`
class RoFormerAttention: Module {
    @ModuleInfo var norm: RoFormerRMSNorm
    @ModuleInfo(key: "rotary_embed") var rotaryEmbed: RotaryEmbedding
    @ModuleInfo(key: "to_q") var toQ: Linear
    @ModuleInfo(key: "to_k") var toK: Linear
    @ModuleInfo(key: "to_v") var toV: Linear
    @ModuleInfo(key: "to_gates") var toGates: Linear
    @ModuleInfo(key: "to_out") var toOut: Linear

    let numHeads: Int
    let dimHead: Int
    let scale: Float

    init(dim: Int, heads: Int, dimHead: Int) {
        self.numHeads = heads
        self.dimHead = dimHead
        self.scale = 1.0 / Float(dimHead).squareRoot()

        let dimInner = heads * dimHead

        self._norm.wrappedValue = RoFormerRMSNorm(dim: dim)
        self._rotaryEmbed.wrappedValue = RotaryEmbedding(dimHead: dimHead)
        self._toQ.wrappedValue = Linear(dim, dimInner, bias: false)
        self._toK.wrappedValue = Linear(dim, dimInner, bias: false)
        self._toV.wrappedValue = Linear(dim, dimInner, bias: false)
        self._toGates.wrappedValue = Linear(dim, heads)
        self._toOut.wrappedValue = Linear(dimInner, dim, bias: false)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let B = x.shape[0]
        let T = x.shape[1]
        let normed = norm(x)

        // Project to Q, K, V and reshape for multi-head: [B, T, H, D_h]
        var q = toQ(normed).reshaped([B, T, numHeads, dimHead])
        var k = toK(normed).reshaped([B, T, numHeads, dimHead])
        let v = toV(normed).reshaped([B, T, numHeads, dimHead])

        // Apply Rotary Position Embeddings
        q = RoFormerAttention.applyRoPE(q, freqs: rotaryEmbed.freqs)
        k = RoFormerAttention.applyRoPE(k, freqs: rotaryEmbed.freqs)

        // Transpose to [B, H, T, D_h] for attention
        let qT = q.transposed(0, 2, 1, 3)
        let kT = k.transposed(0, 2, 1, 3)
        let vT = v.transposed(0, 2, 1, 3)

        // Scaled dot-product attention.
        //
        // Fused kernel rather than the explicit matmul/softmax/matmul chain: attention is
        // where essentially all of this model's time goes (16 dual-axis transformers per
        // 8 s chunk), and the fused path never materialises the [B, H, T, T] score matrix.
        let attended = MLXFast.scaledDotProductAttention(
            queries: qT, keys: kT, values: vT, scale: scale, mask: nil)  // [B, H, T, D_h]

        // Per-head sigmoid gates: [B, T, H] → [B, H, T, 1]
        let gates = sigmoid(toGates(normed))  // [B, T, H]
        let gatesReshaped = gates.transposed(0, 2, 1).expandedDimensions(axis: -1)  // [B, H, T, 1]
        let gated = attended * gatesReshaped

        // Transpose back and project: [B, T, H*D_h]
        let output = gated.transposed(0, 2, 1, 3).reshaped([B, T, numHeads * dimHead])
        return toOut(output)
    }

    /// Apply Rotary Position Embeddings.
    ///
    /// - Parameters:
    ///   - x: Input tensor `[B, T, H, D_h]`.
    ///   - freqs: Frequency bases `[D_h/2]` from checkpoint.
    /// - Returns: Rotated tensor `[B, T, H, D_h]`.
    static func applyRoPE(_ x: MLXArray, freqs: MLXArray) -> MLXArray {
        // INTERLEAVED-PAIR RoPE — matches `rotary_embedding_torch` (the package the
        // checkpoints were trained with), which rotates adjacent dimension pairs
        // (x[2i], x[2i+1]). The earlier "halved" convention ((x[:half], x[half:]))
        // is a mathematically valid RoPE but does NOT match training: q/k rotate
        // about different planes and attention decorrelates from the reference —
        // energies stay healthy while features (and the estimated masks) collapse.
        // Mirrors `_apply_rope` in the Python mlx-audio reference.
        let B = x.shape[0]
        let seqLen = x.shape[1]
        let H = x.shape[2]
        let dimHead = x.shape[3]
        let halfDim = dimHead / 2

        // Angles per (position, base frequency): [T, halfDim]
        let positions = MLXArray(Array(0..<seqLen).map { Float($0) })
        let angles = positions.reshaped([seqLen, 1]) * freqs.reshaped([1, halfDim])
        // Duplicate each frequency for its pair: [f0, f0, f1, f1, …] → [T, dimHead]
        let cosDup = stacked([cos(angles), cos(angles)], axis: -1).reshaped([seqLen, dimHead])
        let sinDup = stacked([sin(angles), sin(angles)], axis: -1).reshaped([seqLen, dimHead])
        let cos4d = cosDup.reshaped([1, seqLen, 1, dimHead])
        let sin4d = sinDup.reshaped([1, seqLen, 1, dimHead])

        // rotate_pairs(x): (x[2i], x[2i+1]) → (−x[2i+1], x[2i])
        let pairs = x.reshaped([B, seqLen, H, halfDim, 2])
        let xEven = pairs[0..., 0..., 0..., 0..., 0]   // [B, T, H, halfDim]
        let xOdd = pairs[0..., 0..., 0..., 0..., 1]
        let rotated = stacked([-xOdd, xEven], axis: -1).reshaped([B, seqLen, H, dimHead])

        return x * cos4d + rotated * sin4d
    }
}
