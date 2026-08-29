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

/// # Mel-RoFormer Weight Key Map
///
/// Documents the complete mapping from the Kim Vocal 2 PyTorch checkpoint
/// to the MLX module tree used in `SwiftRoFormer`.
///
/// ## Source: Kim Vocal 2 Checkpoint (pre-v1.1.0 architecture)
///
/// The Kim Vocal 2 checkpoint was trained with an older version of
/// lucidrains BS-RoFormer that predates v1.1.0. Key differences:
/// - **No HyperConnections** (num_residual_streams=1 → Residual wrapper only)
/// - **No value residual** (add_value_residual=False)
/// - **No linear transformer** (linear_transformer_depth=0)
/// - **2-element layer structure**: `layers.{depth}.{0=time, 1=freq}`
/// - **228,203,172 total parameters**
///
/// ## Checkpoint Architecture
///
/// ### Attention (per transformer block)
/// ```
/// PyTorch: to_qkv = nn.Linear(dim, dim_inner * 3, bias=False)  # PACKED Q+K+V
///          to_gates = nn.Linear(dim, heads)                       # per-head sigmoid gates
///          to_out = nn.Sequential(nn.Linear(dim_inner, dim, bias=False), nn.Dropout())
///          norm = RMSNorm(dim)                                    # pre-attention norm (inside Attention)
///          rotary_embed = RotaryEmbedding(dim=dim_head)           # from rotary_embedding_torch
/// ```
///
/// Conversion:
/// - `to_qkv.weight [3*dim_inner, dim]` → split into `to_q.weight`, `to_k.weight`, `to_v.weight` each `[dim_inner, dim]`
/// - `to_out.0.weight` → `to_out.weight` (unwrap Sequential, skip Dropout at index 1)
/// - `to_gates.weight`, `to_gates.bias` → kept as-is
/// - `norm.gamma` → kept as-is (RMSNorm parameter)
/// - `rotary_embed.freqs` → kept as-is (precomputed RoPE frequency bases, shape [dim_head//2])
///
/// ### FeedForward (per transformer block)
/// ```
/// PyTorch: net = nn.Sequential(
///              RMSNorm(dim),        # index 0 → net.0.gamma
///              nn.Linear(dim, ff),  # index 1 → net.1.weight, net.1.bias
///              nn.GELU(),           # index 2 (no params)
///              nn.Dropout(),        # index 3 (no params)
///              nn.Linear(ff, dim),  # index 4 → net.4.weight, net.4.bias
///              nn.Dropout()         # index 5 (no params)
///          )
/// ```
///
/// ### Transformer (single depth per axis)
/// ```
/// PyTorch: Transformer(depth=1)
///          .layers = ModuleList[
///              ModuleList[
///                  Residual(branch=Attention),   # index 0 → adds x + attn(x)
///                  Residual(branch=FeedForward)   # index 1 → adds x + ff(x)
///              ]
///          ]
///          .norm = RMSNorm(dim)  # output norm
/// ```
///
/// Note: When num_residual_streams=1, Residual is a simple wrapper:
///   - For Attention: returns (x + attn_output, orig_values) via tree_flatten
///   - For FeedForward: returns x + ff_output
///
/// ### Top-level layer structure
/// ```
/// PyTorch checkpoint: layers = ModuleList[
///     ModuleList[
///         time_transformer,   # index 0  ← no linear_transformer
///         freq_transformer    # index 1
///     ]
/// ] × depth=6
/// ```
///
/// ### BandSplit
/// ```
/// PyTorch: band_split.to_features = ModuleList[
///              nn.Sequential(
///                  RMSNorm(dim_in),        # index 0 → to_features.{i}.0.gamma
///                  nn.Linear(dim_in, dim)  # index 1 → to_features.{i}.1.weight, .bias
///              )
///          ] × 60 bands
/// ```
///
/// Per-band input dimensions (with stereo complex = freqs_per_band × 2 × 2):
/// [28, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24,
///  28, 28, 28, 36, 36, 36, 40, 40, 44, 52, 52, 52, 60, 64, 68,
///  76, 80, 80, 88, 96, 104, 112, 116, 124, 132, 144, 156, 164,
///  176, 188, 200, 216, 228, 244, 264, 284, 304, 320, 344, 372,
///  396, 420, 452, 488, 520]
///
/// ### MaskEstimator
/// ```
/// PyTorch: mask_estimators.{stem}.to_freqs = ModuleList[
///              nn.Sequential(
///                  MLP(dim=384, dim_out=band_dim*2, dim_hidden=1536, depth=2),
///                  nn.GLU(dim=-1)
///              )
///          ] × 60 bands
///
///          MLP(depth=2) = nn.Sequential(
///              nn.Linear(384, 1536),    # index 0.0 → 0.0.weight, 0.0.bias
///              nn.Tanh(),               # index 0.1 (no params)
///              nn.Linear(1536, 1536),   # index 0.2 → 0.2.weight, 0.2.bias
///              nn.Tanh(),               # index 0.3 (no params)
///              nn.Linear(1536, dim_out) # index 0.4 → 0.4.weight, 0.4.bias
///          )
///          # dim_out = band_input_dim * 2 (for GLU), output after GLU = band_input_dim
/// ```
///
/// ## Safetensors Key Paths (after conversion)
///
/// Total: 708 keys (after QKV split + to_out unwrap)
///
/// ```
/// band_split.to_features.{0-59}.0.gamma                           # BandSplit: RMSNorm [dim_in]
/// band_split.to_features.{0-59}.1.weight                          # BandSplit: Linear [384, dim_in]
/// band_split.to_features.{0-59}.1.bias                            # BandSplit: Linear [384]
///
/// layers.{0-5}.{0=time,1=freq}.layers.0.0.norm.gamma              # Attention pre-norm [384]
/// layers.{0-5}.{0,1}.layers.0.0.rotary_embed.freqs                # RoPE frequencies [32]
/// layers.{0-5}.{0,1}.layers.0.0.to_q.weight                       # Q projection [512, 384]
/// layers.{0-5}.{0,1}.layers.0.0.to_k.weight                       # K projection [512, 384]
/// layers.{0-5}.{0,1}.layers.0.0.to_v.weight                       # V projection [512, 384]
/// layers.{0-5}.{0,1}.layers.0.0.to_gates.weight                   # Gate projection [8, 384]
/// layers.{0-5}.{0,1}.layers.0.0.to_gates.bias                     # Gate bias [8]
/// layers.{0-5}.{0,1}.layers.0.0.to_out.weight                     # Output projection [384, 512]
/// layers.{0-5}.{0,1}.layers.0.1.net.0.gamma                       # FF RMSNorm [384]
/// layers.{0-5}.{0,1}.layers.0.1.net.1.weight                      # FF expand Linear [1536, 384]
/// layers.{0-5}.{0,1}.layers.0.1.net.1.bias                        # FF expand bias [1536]
/// layers.{0-5}.{0,1}.layers.0.1.net.4.weight                      # FF compress Linear [384, 1536]
/// layers.{0-5}.{0,1}.layers.0.1.net.4.bias                        # FF compress bias [384]
/// layers.{0-5}.{0,1}.norm.gamma                                    # Output RMSNorm [384]
///
/// mask_estimators.0.to_freqs.{0-59}.0.0.weight                    # MLP Linear 0 [1536, 384]
/// mask_estimators.0.to_freqs.{0-59}.0.0.bias                      # MLP Linear 0 bias [1536]
/// mask_estimators.0.to_freqs.{0-59}.0.2.weight                    # MLP Linear 1 [1536, 1536]
/// mask_estimators.0.to_freqs.{0-59}.0.2.bias                      # MLP Linear 1 bias [1536]
/// mask_estimators.0.to_freqs.{0-59}.0.4.weight                    # MLP Linear 2 [dim_out, 1536]
/// mask_estimators.0.to_freqs.{0-59}.0.4.bias                      # MLP Linear 2 bias [dim_out]
/// ```
///
/// ## Key Counts
///
/// | Component | Keys | Per-unit |
/// |-----------|------|----------|
/// | band_split | 180 | 3 per band × 60 bands |
/// | layers | 168 | 14 per transformer × 2 axes × 6 depths |
/// | mask_estimators | 360 | 6 per band × 60 bands |
/// | **Total** | **708** | |
///
/// Per transformer block (14 keys after conversion):
/// - Attention: norm.gamma, rotary_embed.freqs, to_q.weight, to_k.weight, to_v.weight, to_gates.weight, to_gates.bias, to_out.weight (8)
/// - FeedForward: net.0.gamma, net.1.weight, net.1.bias, net.4.weight, net.4.bias (5)
/// - Output: norm.gamma (1)
///
/// ## RMSNorm Implementation
///
/// lucidrains uses a custom RMSNorm:
/// ```
/// def forward(self, x):
///     return F.normalize(x, dim=-1) * self.scale * self.gamma
/// ```
/// where `scale = dim ** 0.5` (square root of dimension).
///
/// This is L2-normalize then scale, NOT the standard 1/sqrt(mean(x²)) formulation.
/// The MLX implementation must match this exactly.
///
/// ## RoPE Implementation
///
/// The rotary_embedding_torch library stores precomputed frequency bases:
///   `freqs[i] = 1.0 / (10000 ** (2i / dim_head))`
/// Shape: [dim_head // 2] = [32]
///
/// At position p, angles = p * freqs[i]
/// Applied as: (x₁·cos - x₂·sin, x₂·cos + x₁·sin) for paired dimensions.
///
/// ## Kim Vocal 2 Configuration
///
/// | Parameter | Value |
/// |-----------|-------|
/// | dim | 384 |
/// | depth | 6 |
/// | stereo | true |
/// | num_stems | 1 |
/// | time_transformer_depth | 1 |
/// | freq_transformer_depth | 1 |
/// | linear_transformer_depth | 0 (not used) |
/// | num_bands | 60 |
/// | dim_head | 64 |
/// | heads | 8 |
/// | stft_n_fft | 2048 |
/// | stft_hop_length | 441 |
/// | stft_win_length | 2048 |
/// | mask_estimator_depth | 2 |
/// | num_residual_streams | 1 (no HyperConnections) |
/// | add_value_residual | false |
/// | ff_mult | 4 |
/// | mlp_expansion_factor | 4 |
///
/// dim_inner = heads × dim_head = 8 × 64 = 512
/// ff_dim = dim × ff_mult = 384 × 4 = 1536
/// mlp_hidden = dim × mlp_expansion_factor = 384 × 4 = 1536
///
/// ## Critical Implementation Notes
///
/// 1. **No HyperConnections**: The checkpoint uses simple Residual wrappers (x + module(x)),
///    NOT the multi-stream HyperConnection expansion/reduction from v1.1.0.
///
/// 2. **Residual connections**: Both attention and feedforward have residual connections
///    applied externally (by the Residual wrapper), NOT inside their forward methods.
///    Attention.forward returns (output, orig_values) and FeedForward.forward returns output.
///
/// 3. **Band indexing**: Frequencies are gathered via scatter/gather indices built from the
///    binarized mel filterbank. For stereo, indices are interleaved: freq*2+ch.
///    Total gathered features = sum(freqs_per_band) × 2(stereo) = 1979 × 2 = 3958.
///
/// 4. **Mask averaging**: Overlapping mel bands produce duplicate mask values for shared
///    frequencies. These are scatter_added and then divided by num_bands_per_freq.
///
/// 5. **Complex multiplication**: Masks and STFT are both complex. The model operates on
///    real-valued representations (CaC) but applies masks as complex multiplication.

// This file is documentation-only. No executable code.
// It serves as the reference for weight loading validation in SwiftRoFormer.
