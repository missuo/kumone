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
/// norm = RMSNorm(dim)
/// ```
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
    @ModuleInfo var norm: RoFormerRMSNorm

    init(dim: Int, depth: Int, heads: Int, dimHead: Int, ffMult: Int) {
        // depth=1: `layers.0` = [Attention, FFN]
        self._layers.wrappedValue = (0..<depth).map { _ -> [Module] in
            [
                RoFormerAttention(dim: dim, heads: heads, dimHead: dimHead),
                RoFormerFFN(dim: dim, ffMult: ffMult),
            ]
        }
        self._norm.wrappedValue = RoFormerRMSNorm(dim: dim)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var out = x
        for pair in layers {
            let attention = pair[0] as! RoFormerAttention
            let ffn = pair[1] as! RoFormerFFN
            out = out + attention(out)
            out = out + ffn(out)
        }
        return norm(out)
    }
}
