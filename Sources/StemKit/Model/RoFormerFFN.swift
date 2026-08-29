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

/// Standard feed-forward network (NOT GLU-gated).
///
/// `RMSNorm → Linear(dim→ffDim) → GELU → Linear(ffDim→dim)`
///
/// Matches PyTorch `FeedForward` which wraps an `nn.Sequential` inside `net`:
/// ```
/// net = Sequential(RMSNorm, Linear, GELU, Dropout, Linear, Dropout)
///                    ^0       ^1     ^2     ^3      ^4      ^5
/// ```
///
/// Only indices 0, 1, 4 have learnable parameters.
/// The `net` property stores a 5-element `[Module]` array to match the Sequential.
///
/// Weight key prefix: `net.{0,1,4}.*`
class RoFormerFFN: Module {
    @ModuleInfo var net: [Module]

    init(dim: Int, ffMult: Int = 4) {
        let ffDim = dim * ffMult
        self._net.wrappedValue = [
            RoFormerRMSNorm(dim: dim),  // 0: norm
            Linear(dim, ffDim),          // 1: expand
            NoOpModule(),                // 2: GELU placeholder
            NoOpModule(),                // 3: Dropout placeholder
            Linear(ffDim, dim),          // 4: compress
        ]
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let norm = net[0] as! RoFormerRMSNorm
        let expand = net[1] as! Linear
        let compress = net[4] as! Linear
        var out = norm(x)
        out = gelu(expand(out))
        out = compress(out)
        return out
    }
}
