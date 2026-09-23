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

/// Single-axis transformer with output norm.
///
/// Matches PyTorch `Transformer(depth=1)` which wraps its blocks in:
/// ```
/// layers = ModuleList[ModuleList[Attention, FeedForward]] × depth
/// norm = RMSNorm(dim) if norm_output else nn.Identity()
/// ```
///
/// **The output norm is not optional in the "harmless if absent" sense.**
/// lucidrains' `RMSNorm` is `l2normalize(x) · √dim · gamma`, which at
/// `gamma = 1` is not the identity — it rescales every token to unit RMS. So
/// building one for a checkpoint that has no `norm.gamma` does not leave the
/// weights unset, it *renormalises the residual stream after every block*.
/// Symptom, when that happened here: activations that should grow ×10 across
/// eight dual-axis blocks stayed flat, the mask estimators saw features from a
/// distribution they were never trained on, and three of the four stems came
/// out as near-silence while the first took the whole mixture. Nothing threw;
/// `noUnusedKeys` only catches the opposite mistake. Hence a flag.
///
/// For Kim Vocal 2 (depth=1), this produces:
/// - `layers.0.0.*` — Attention
/// - `layers.0.1.*` — FeedForward
/// - `norm.gamma` — Output RMSNorm
///
/// The `layers` property is `[[Module]]` — an array of depth levels,
/// each containing `[RoFormerAttention, RoFormerFFN]`.
/// This matches PyTorch's `ModuleList[ModuleList[...]]` exactly.
class Transformer: Module {
    @ModuleInfo var layers: [[Module]]
    @ModuleInfo var norm: RoFormerRMSNorm?

    init(dim: Int, depth: Int, heads: Int, dimHead: Int, ffMult: Int,
         normOutput: Bool) {
        // depth=1: `layers.0` = [Attention, FFN]
        self._layers.wrappedValue = (0..<depth).map { _ -> [Module] in
            [
                RoFormerAttention(dim: dim, heads: heads, dimHead: dimHead),
                RoFormerFFN(dim: dim, ffMult: ffMult),
            ]
        }
        self._norm.wrappedValue = normOutput ? RoFormerRMSNorm(dim: dim) : nil
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var out = x
        for pair in layers {
            let attention = pair[0] as! RoFormerAttention
            let ffn = pair[1] as! RoFormerFFN
            out = out + attention(out)
            out = out + ffn(out)
        }
        guard let norm else { return out }
        return norm(out)
    }
}
