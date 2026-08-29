# AutoMix Stem Separation 预研

> 状态：预研（2026-08-27） · 纯调研，未写任何产品代码
> 前置阅读：[`automix-spec.md`](automix-spec.md)
> 结论标注了来源链接；无来源的判断标注为**推测**。

---

## 0. 一页摘要

**要解决的问题**：现有 AutoMix 的过渡手法都作用在"整首混音"上——音量、变速、EQ 低频交接、滤波扫、echo out。要做到 Neural Mix 级别的交接（前一首的 acapella 飘在后一首的新伴奏上、先换鼓再换贝斯、双人声自动避让），必须先把混音拆成人声/鼓/贝斯/其他四轨。

**本项目的结构优势**：切点在 ~60s 前已由 `TransitionPlanner` 算出，**分离不需要实时**。只需对两首歌各约 20–30s 的重叠窗口做一次离线分离。这把"端上实时分离"这个业界最难的问题降级成了"有 60 秒预算的后台批处理"——**耗时几乎不是约束，许可证和集成成本才是**。

### 推荐路线

| 维度 | 结论 |
|---|---|
| **架构** | **方案 A：离线预渲染**。后台分离 overlap 窗口 → 用一个 manual-rendering 模式的离线 `AVAudioEngine` 把手法混好 → 渲染成一段成品 PCM → 过渡时当作普通 buffer 调度进现有 deck。**不动实时图**。 |
| **推理运行时** | **Core ML**，且 **STFT/iSTFT 留在 Swift/vDSP 侧**，模型只吃频谱出 mask。系统框架，零新 SPM 依赖，与 spec 的"零新依赖"原则一致。 |
| **模型** | 优先 **MIT 权重**：Mel-Band RoFormer（vocals-only，67 MB fp16，MIT）先行；4-stem 待 htdemucs 权重许可核实后再定。 |
| **分发** | **首次启用时下载**，不内置。GitHub Releases 托管 + 硬编码 SHA-256 校验 + 版本化 URL。 |
| **第一步** | **不是分离**。先用已实现的 `TrackAnalysis.vocalActivity` 做人声避让选点——零模型、零风险、当天可听出差别。 |

### 最大风险（按严重度）

1. **权重许可证**（红线级）。Kumone 是 LGPL-3.0-only，LGPL 授予下游包括商业在内的一切使用权；而**几乎所有主流分离模型的权重都是 CC BY-NC-SA 或许可不明**。htdemucs 代码是 MIT，但权重是否 MIT **有实质争议**（§2.1）。这一条不解决，整个方向不成立。
2. **Core ML 缺 iSTFT**。`coremltools` 至今没有 `complex_istft`，feature request 自 2023-10 开着未合并（§3.1）。绕法明确（把 STFT/iSTFT 挪到 vDSP），但意味着模型不能整个丢给 coremltools，需要改写 PyTorch 前向再转，是本方向工作量最大的一块。
3. **分离质量决定手法上限**。SDR 8–11 dB 的分离残留在**独奏暴露**（acapella 飘在新伴奏上）时会被听出来。必须在投入工程前先用离线原型做人耳 A/B，确认"值不值得"。

---

## 1. 现状盘点与目标

### 1.1 已有的东西（本 worktree 实测）

| 组件 | 位置 | 与 stem 相关的现状 |
|---|---|---|
| `PlaybackEngine` | `Core/Player/Engine/PlaybackEngine.swift` | 双 deck，每 deck 链路 `player → timePitch → EQ(4 band) → delay → mainMixer`；**固定 44.1 kHz 立体声 `graphFormat`**；所有节点 init 时 attach + connect，注释明写"运行中重连另一 deck 的图会抛 NSException"。 |
| `FileFeeder` | 同上目录 | 非标准格式（Hi-Res/单声道）时**分块转换后 `scheduleBuffer`**，而不是重连图。这是喂任意 PCM 进 deck 的现成插口。 |
| `TrackAnalysis` | `Core/Player/AutoMixTypes.swift` | 已含 `melProfile`、`keyPitchClass`、**`vocalActivity: [Float]`（1s 粒度）**。 |
| `TrackAnalyzer.vocalActivity` | `Core/Player/Analysis/TrackAnalyzer.swift:843` | **已实现的纯 DSP 启发式**：200 Hz–4 kHz 带能量占比 + 带内谱平坦度 + 2–8 Hz 调制能量，三路融合 + 响度门控 + 3s 中值平滑。 |
| `TransitionPlanner` | `Core/Player/Analysis/TransitionPlanner.swift` | 纯函数 `plan(outgoing:incoming:) -> PlannedTransition`；三档兼容度 `compatible/neutral/clash`（响度差 + 音色余弦距离 + 折算 BPM 差）。 |
| `TransitionStyle` | `AutoMixTypes.swift:55` | 已是"手法词汇表"：`outroEffect(.fade/.filterSweep/.echoOut)` + `stagedEQ`。**stem 手法天然是这个 enum 的扩容。** |

**关键发现**：`vocalActivity` 已经算好了但 `TransitionPlanner` 还没有消费它（全文件搜索 `vocalActivity` 只有 analyzer 内部引用）。这是最低垂的果子。

### 1.2 目标手法（stem 解锁的东西）

| 手法 | 需要的 stem | 说明 |
|---|---|---|
| **人声避让 / vocal ducking** | 仅需 vocals 的**存在与否** | 双方人声重叠时压低一侧。**不需要分离，只需要 `vocalActivity`。** |
| **Acapella over new bed** | 出曲 vocals + 入曲 (drums+bass+other) | 出曲只留人声飘在入曲伴奏上，DJ 的招牌手法。**对分离质量最敏感。** |
| **分阶段换轨（先鼓后贝斯）** | 双方 drums / bass | 比现有 `bassSwapAt` 单点低架交接精细一档。 |
| **Instrumental outro** | 出曲去人声 | 出曲人声抹掉，只留伴奏收尾，入曲人声进。 |
| **Stem-level EQ** | 全部 4 轨 | 现有 `stagedEQ` 的 stem 版，交接更干净。 |

---

## 2. 模型与许可证

### 2.1 许可证：本项目的红线

Kumone 是 **LGPL-3.0-only**（`LICENSE`，随附 GPL-3.0 文本）。这带来一个和商业 App 不同的约束：

> **LGPL 要求向下游授予包括商业用途在内的全部权利。CC BY-NC-SA 的"禁止商业使用"与之直接冲突。**
> 因此 **NC 权重不能内置进 Kumone 的分发包**——不是"风险较高"，是不兼容。

这条同样堵死了一些常见的绕法："权重是数据不是代码，所以不受 LGPL 约束"——但只要我们在 Release 里分发它、且核心功能依赖它，分发的整体就带上了 NC 限制。**唯一干净的绕法是让 App 在首次启用时从上游原始地址下载，Kumone 自身不分发任何权重**（§6）。

### 2.2 各模型许可证核实结果

| 模型 | 代码许可 | 权重许可 | 核实状态 |
|---|---|---|---|
| **Demucs / htdemucs** (Meta) | **MIT**（[LICENSE](https://github.com/adefossez/demucs/blob/main/LICENSE) 明确，Copyright Meta Platforms） | **争议 / 不明** | README 只说"Demucs is released under the MIT license"，**没有单独声明权重**。[Issue #327](https://github.com/facebookresearch/demucs/issues/327)（2022-05 开）正是在问这件事；检索摘要显示维护者回复过"model weights are not covered by the MIT license, and are provided only for scientific purposes"，但**我直接 fetch 该 issue 页面时没有拿到任何维护者回复**（可能被折叠/已删）。**⚠️ 必须实际打开 issue 或发邮件确认后才能用。** |
| **Open-Unmix** (sigsep) | MIT | `umx` / `umxhq`：随代码 MIT；**`umxl`：CC BY-NC-SA 4.0**（README [明确声明](https://github.com/sigsep/open-unmix-pytorch)） | 已核实。**umxl 不可用**，umxhq 可用但 SDR 低（vocals 6.25）。 |
| **Spleeter** (Deezer) | MIT | **不明** | [Issue #898](https://github.com/deezer/spleeter/issues/898)（2024-04）问权重许可，**至今无 Deezer 官方回复**。且 Spleeter 质量已明显落后，不建议。 |
| **BS-RoFormer / Mel-Band RoFormer** | 架构实现 [lucidrains/BS-RoFormer](https://github.com/lucidrains/BS-RoFormer) MIT；论文出自 ByteDance | ByteDance 官方权重**未公开发布**；社区权重出自 [ZFTurbo/Music-Source-Separation-Training](https://github.com/ZFTurbo/Music-Source-Separation-Training)（仓库 **MIT**，checkpoint 挂在该仓库 Releases） | 部分核实。仓库 MIT 且 checkpoint 由该仓库分发 → 继承 MIT 是最自然的解读，但**多数 checkpoint 由第三方（viperx / gabox / Kimberley Jensen）训练后贡献，各自未单独声明**。 |
| **MDX-Net / UVR** | [Anjok07/ultimatevocalremovergui](https://github.com/Anjok07/ultimatevocalremovergui) **MIT** | 社区训练，逐个模型许可不一 | 需逐个核实。 |
| **Essentia 分类模型** | 库本身 **AGPLv3** | **CC BY-NC-SA 4.0**（MTG 官方声明，可另谈商业授权） | 已核实。**不可用**（AGPL 对 native app 分发也是障碍）。 |
| **madmom models** | 代码 BSD | **CC BY-NC-SA 4.0**（[madmom_models](https://github.com/CPJKU/madmom_models) README 明确要求商业使用联系 Gerhard Widmer） | 已核实。**不可用**。 |

### 2.3 一个全行业的灰区：训练数据传染性

几乎所有开源分离模型的训练集都包含 **MUSDB18 / MUSDB18-HQ**，而该数据集本身是 **CC BY-NC-SA**（46 首来自 MedleyDB CC BY-NC-SA 4.0，2 首 CC BY-NC-SA 3.0，[sigsep 官方说明](https://sigsep.github.io/datasets/musdb.html)），Zenodo 上还要求申请访问并声明"仅供学术用途"。

"用 NC 数据训练出的权重是否是数据的衍生作品"在法律上**没有定论**，这是整个 MSS 领域的共同灰区。本项目的务实态度：

- 不去赌这个灰区的解释；
- 选择**上游明确写了 MIT 的权重**；
- 采用 §6 的"不分发、只下载"策略，把这个不确定性留在上游而非 Kumone 的 Release 里。

### 2.4 质量与体积对照

SDR 数据来自 [ZFTurbo MSST 的 pretrained_models 文档](https://github.com/ZFTurbo/Music-Source-Separation-Training/blob/main/docs/pretrained_models.md)（MUSDB18-HQ 测试集，dB，越高越好）：

| 模型 | vocals | drums | bass | other | 体积 |
|---|---|---|---|---|---|
| **BS-RoFormer** | 11.08 | 11.61 | 8.48 | 7.44 | 大（>300 MB） |
| **Mel-Band RoFormer**（Kimberley Jensen 版，vocals-only） | 10.98 | — | — | — | 中 |
| **Mel-Band RoFormer**（ZFTurbo v1，vocals-only） | 8.42（训练时自报） | — | — | — | **67.4 MB fp16 / 33.7M 参数**（[mlx-community 模型卡](https://huggingface.co/mlx-community/mel-roformer-zfturbo-vocals-v1-mlx)，MIT） |
| **htdemucs4** | 8.24 | 10.88 | 11.76 | 5.74 | .th 约 80 MB / ONNX fp32 316 MB、fp16 166 MB |
| **htdemucs_ft**（4 模型 bag） | — | — | — | — | .th 约 320 MB / ONNX 约 1.26 GB |
| **MDX23C** | 9.23 | 7.93 | 5.77 | 5.68 | 中 |
| **Open-Unmix umxhq**（可商用） | 6.25 | 6.04 | 5.07 | 4.28 | 136 MB（4 target 合计） |
| **Open-Unmix umxl**（**NC，不可用**） | 7.21 | 7.15 | 6.02 | 4.89 | 432 MB |

**读法**：
- **vocals** 是 RoFormer 系列的强项（11 dB 级），**bass/drums** 是 htdemucs 的强项。
- 若最终要做 4-stem，htdemucs 在 drums/bass 上明显更好，且它是唯一有成熟端上移植生态的模型。
- 若只做人声相关手法（acapella / instrumental outro / ducking），**vocals-only 的 Mel-Band RoFormer 用 1/5 的体积拿到更高的 vocals SDR** —— 这是性价比最优点。

---

## 3. Core ML 落地路径

### 3.1 coremltools 现状：STFT 有，iSTFT 没有

- `coremltools` **7.0**（2023-09）[release notes](https://github.com/apple/coremltools/releases/tag/7.0) 新增了 PyTorch op `stft`、`view_as_real`。
- 实现方式是 **complex dialect**：[`complex_dialect_ops.py`](https://github.com/apple/coremltools/blob/main/coremltools/converters/mil/mil/ops/defs/complex_dialect_ops.py) 定义 `complex`、`complex_fft/ifft/rfft/irfft`、`complex_stft` 等，由 `lower_complex_dialect_ops` pass 在**转换期**拆成实部/虚部两路实数张量。**Core ML runtime 本身没有复数 dtype。**
- **`complex_istft` 不存在**。[Issue #2016](https://github.com/apple/coremltools/issues/2016)（2023-10 开）至今 open，对应 [PR #2029](https://github.com/apple/coremltools/pull/2029) 最后活动 2025-10-29 仍未合并。
- coremltools **9.0**（2025-11）release notes 未提及任何 complex/FFT/iSTFT 增强。

### 3.2 推荐做法：把 STFT/iSTFT 移出模型

三种绕法，本项目选第三种：

| 做法 | 描述 | 评价 |
|---|---|---|
| 图内 Conv1d 替代 | 用预计算 sin/cos DFT basis 的 `Conv1d` 做正变换、`ConvTranspose1d` + envelope 归一化做逆变换（[StemSplit/demucs-onnx](https://github.com/StemSplit/demucs-onnx) 的 ONNX 导出方案，与 PyTorch fp32 最大绝对误差 < 1.7e-4） | 可行，但把 FFT 塞进卷积算子，白白消耗 GPU 时间和模型体积 |
| 自写 MIL iSTFT | 手写 MIL op | 工作量大、脆弱 |
| **STFT/iSTFT 放 Swift 侧** | 模型只吃 spectrogram、只出 mask；正逆变换用 Accelerate/vDSP | **推荐**。[有实战记录](https://web.navan.dev/posts/2025-10-26-vocal-separation-and-rvc-onnx-coreml.html)（MDX-Net → Core ML）采用此法 |

**为什么这条对 Kumone 特别合适**：`TrackAnalyzer` 已经有一套成熟的 vDSP STFT（窗 1024 / hop 256，spec §4.1）。做分离只需要换参数（RoFormer 系典型 `n_fft=2048`，htdemucs `n_fft=4096 / hop=1024`）并补一个 overlap-add 的 iSTFT。**这是本项目相对通用 App 的第二个结构优势。**

### 3.3 其他已知的转换坑

| 坑 | 说明 | 来源 |
|---|---|---|
| **Fused MHA 无法 trace** | htdemucs 的 cross-domain transformer 和整个 RoFormer 家族都会命中；必须手工拆成基础 op | [dexxdean/htdemucs-coreml](https://github.com/dexxdean/htdemucs-coreml)、[StemSplit/demucs-onnx](https://github.com/StemSplit/demucs-onnx) 都独立记录了这一点；相关 [coremltools #1763](https://github.com/apple/coremltools/issues/1763) |
| **ANE 上输出不可靠** | dexxdean 明写 "HTDemucs is not stable on the Apple Neural Engine"，强制 `.all` / `.cpuAndNeuralEngine` 会在某些输入形状下产生 "silent garbage"，推荐 `.cpuAndGPU` | [dexxdean/htdemucs-coreml](https://github.com/dexxdean/htdemucs-coreml) |
| **flexible shape 与 ANE 互斥** | `RangeDim` 会引入 dynamic layer 导致掉出 ANE；`EnumeratedShapes` 在 iOS 18 前**多输入模型只允许一个输入用** | [Flexible Input Shapes 指南](https://apple.github.io/coremltools/docs-guides/source/flexible-inputs.html)、[#2370](https://github.com/apple/coremltools/issues/2370) |
| **必须自己做 chunking + overlap-add** | Demucs 原生是 segment（7.8s / 10s）+ 25% overlap + transition weight 加窗；Core ML 的 scatter op 在这里脆弱，dexxdean 用**预计算索引 buffer** 替代 | 同上 |
| **fp16 精度** | LayerNorm 在 fp16 下动态范围不足会掉精度；dexxdean 称 fp16 "inaudible in practice" 但**无客观 SDR 指标** | 需自测 |
| **首次编译慢** | Core ML 模型首次在设备上运行时 ANE 服务要编译成设备专用格式，whisper.cpp 文档明确记录此现象 | [whisper.cpp](https://github.com/ggml-org/whisper.cpp) |

**因此**：Core ML 相对 MLX/Metal 的最大卖点（ANE）**在这类模型上基本拿不到**。选 Core ML 的理由不是速度，而是**零依赖 + 系统框架 + 双平台**。

### 3.4 现成的社区转换产物

| 项目 | 语言 | 许可 | 成熟度（实测 GitHub API） | 评价 |
|---|---|---|---|---|
| [dexxdean/htdemucs-coreml](https://github.com/dexxdean/htdemucs-coreml) | Python 转换脚本（~600 行）+ Swift 示例 | **NOASSERTION**（README 自称 MIT，仓库无标准 LICENSE 文件） | **1 star，1 commit**，最后 push 2026-04-26 | **唯一直接针对 htdemucs 的 Core ML 转换器**。不提供预构建 .mlpackage，需自己跑。当作**参考实现**读，不要当依赖 |
| [StemSplit/demucs-onnx](https://github.com/StemSplit/demucs-onnx) | Python 导出 + 推理 | MIT | 4 stars，最后 push 2026-05-22 | 记录了 4 个导出阻塞点及解法，**文档价值最高** |
| [sevagh/demucs.onnx](https://github.com/sevagh/demucs.onnx) | C++ ONNX Runtime | MIT | — | 同样把 STFT/iSTFT 移出模型 |
| [sevagh/demucs.cpp](https://github.com/sevagh/demucs.cpp) | C++17 + Eigen（header-only） | MIT | **175 stars**，最后 push **2024-12-01**（已停更） | 无 GPU、无转换、纯 CPU；"为低内存环境设计，牺牲速度"。**给 60s 预算的场景是黑马**（§4.3） |
| [ssmall256/demucs-mlx](https://github.com/ssmall256/demucs-mlx) | Python + MLX | MIT | 36 stars，2026-08-12 | 最快，但**是 Python** |
| [ssmall256/mlx-audio-separator](https://github.com/ssmall256/mlx-audio-separator) | Python + MLX | MIT | 13 stars，2026-08-12 | 覆盖 Demucs/MDX/MDXC/VR/RoFormer 五类架构 |
| `iky1e/demucs-mlx-swift` | — | — | **不存在** | HF 模型卡链接到它，但 `gh api` 返回 **404**。⚠️ **今天没有可直接用的 Swift MLX 分离实现。** |

**Apple 官方 `apple/ml-*` 仓库中没有任何音乐分轨模型**（已检索）。
**BS-RoFormer / Mel-Band RoFormer 的 Core ML 转换：未找到任何公开实现**，属于要从零做的工作量。

### 3.5 ONNX 备选路径评估

- **ONNX → Core ML 不推荐**：coremltools 自 6.0 起**已移除 ONNX 前端**，官方推荐 PyTorch 直转。
- **直接跑 ONNX Runtime**：macOS 上可用 CoreML EP，但[官方文档](https://onnxruntime.ai/docs/execution-providers/CoreML-ExecutionProvider.html)说明其算子覆盖极窄（NeuralNetwork format 约 40 个、MLProgram 约 50 个），Demucs/RoFormer 会大量 fallback 到 CPU EP，实际加速有限；且默认 NeuralNetwork format **会静默把模型转成 fp16**。
- 更重要的是：**ONNX Runtime 是一个几十 MB 的预编译 C++ 二进制，没有像样的 SwiftPM 集成**，对一个只依赖 Sparkle 的项目是巨大的依赖负担。

**结论：ONNX 只作为"转换中间格式 + 参考实现"使用，不进产品。** demucs-onnx 那套 Conv1d-STFT 改写可以直接搬到 coremltools 的 torch 转换路径上。

### 3.6 第三条路：MLX Swift（记录但不推荐为首选）

[ml-explore/mlx-swift](https://github.com/ml-explore/mlx-swift) **MIT，2006 stars，2026-08-24 仍在活跃开发**，Apple 官方出品，走 Metal。

- **优点**：绕开所有 Core ML 转换坑（复数、iSTFT、MHA trace 全部不是问题）；权重直接吃 safetensors；性能最好（§4.1）。
- **致命缺点**：
  1. **没有现成的 Swift 分离实现**（`demucs-mlx-swift` 404）。要把 htdemucs 或 RoFormer 的前向逐层用 MLX Swift 重写，**数周量级**。
  2. `Package.swift` 实测 `platforms: [.macOS("14.0"), .iOS(.v17), ...]` —— **Kumone 支持 iOS 16，MLX Swift 直接排除 iOS 16**。（AutoMix 本身目前 macOS 先行，影响可控，但会永久限制 iOS 下限。）
  3. 引入一个包含大量 C++/Metal 源码的重量级 SPM 依赖，与 spec 的"零新依赖"决策冲突。

**保留位置**：如果 Core ML 转换在 M2 阶段卡死（iSTFT/MHA 改写不收敛），MLX Swift 是明确的 plan B。

---

## 4. 端上成本

### 4.1 已知基准（M4 Max，3:15 立体声 44.1 kHz，htdemucs 默认参数）

来源：[ssmall256/demucs-mlx README](https://github.com/ssmall256/demucs-mlx/)

| 实现 | 后端 | 耗时 | realtime factor |
|---|---|---|---|
| demucs 4.0.1 | PyTorch **CPU** | 52.3 s | ~3.7× |
| demucs 4.0.1 | PyTorch **MPS** | 6.9 s | ~28× |
| demucs-mlx 1.1.0 | **MLX + Metal** | 2.7 s | ~73× |

同作者的 [Medium 文章](https://medium.com/@andradeolivier/i-ported-demucs-to-apple-silicon-it-separates-a-7-minute-song-in-12-seconds-6c4e5cffb5c3)称 7 分钟歌 12 秒（约 35×）。**推测**：README 的 2.7s 很可能不含模型加载/IO，Medium 的 12s 是端到端；做预算时按端到端算。

### 4.2 30 秒片段的推算

从 195 s → 30 s 线性缩放（htdemucs 分段处理，基本线性）：

| 路径 | 30s 片段（M4 Max，稳态） | 备注 |
|---|---|---|
| PyTorch CPU | ~8.0 s | |
| PyTorch MPS | ~1.1 s | |
| MLX/Metal | ~0.4 s | |
| Core ML `.cpuAndGPU` | **未找到公开 benchmark** | **推测**介于 MPS 与 MLX 之间，1–3 s 量级 |
| demucs.cpp（纯 CPU + Eigen） | **未找到 benchmark**；**推测**慢于 PyTorch CPU，10–30 s 量级 | 但仍在 60 s 预算内 |

M1/M2/M3 上没有找到直接数据。**推测**基础款 M1 约为 M4 Max 的 3–5 倍慢 → MLX 路径 1–2 s、Core ML 路径 3–10 s。**全部在 60 秒预算内，且都是两首歌各一次。**

**固定开销才是主导项**（本项目要特别注意）：
1. 模型权重加载（67–320 MB）；
2. Metal shader / Core ML 首次编译（whisper.cpp 记录 ANE 首跑显著慢）；
3. Core ML `MLModel` 实例化。

**工程对策**：**AutoMix 开启时就常驻 `MLModel` 实例**，不要每次过渡才加载。30 s 片段太短，冷启动开销会完全主导。

### 4.3 一个被低估的结论

> 因为有 60 秒预算，**"最慢的方案也够用"**。

这意味着选型应当**完全由许可证、依赖负担和可维护性驱动，而不是由 realtime factor 驱动**。这也让 `demucs.cpp`（MIT、纯 C++17 + header-only Eigen、无转换、无 GPU、低内存）从"太慢所以出局"变成了一个真实候选——它的唯一问题是仓库自 2024-12 起停更，且给 SPM 加 C++ target 有工程成本。

### 4.4 内存

- htdemucs 处理 1 小时音频约 **7 GB**，4 小时超 **34 GB**（[demucs #498](https://github.com/facebookresearch/demucs/issues/498)），因为它把整段常驻内存做 overlap-add，不是流式。
- BS-RoFormer 处理 13.35 s chunk：MLX **2.7 GB** vs Torch MPS **5.3 GB**（mlx-audio-separator README）。
- **对 30 s 片段，内存不是问题**（按 7 GB/小时线性外推约 60–100 MB 激活 + 权重本身，**推测但方向可靠**）。

### 4.5 ANE vs GPU vs CPU

**结论：这类模型实际上是 GPU-bound，几乎没有走 ANE 的公开实现。**

1. 所有已知的 Apple Silicon 快速实现（demucs-mlx、mlx-audio-separator）都走 **Metal，不是 ANE**。
2. ANE 不支持 **dilated convolution**（[参考](https://fritz.ai/does-my-core-ml-model-run-on-apples-neural-engine/)），而这是 Demucs encoder/decoder 的架构特征。
3. Transformer 要跑 ANE 需要专门的架构改写（Apple 自己的 [Deploying Transformers on the ANE](https://machinelearning.apple.com/research/neural-engine-transformers) 讲的就是这个）。
4. dexxdean 实测 htdemucs 在 ANE 上"unreliable"。

**对比参照**：djay Neural Mix、Moises Live 确实宣称用 ANE/NPU，但用的是**自研的、专为 NPU 设计的小模型**，不是 htdemucs。这个区分很重要——不要拿它们的实时性做我们的预期。

### 4.6 iPhone 可行性（顺带评估）

端上实时分离在 iPhone 上**已被 djay 证明可行且量产多年**（[兼容性表](https://help.algoriddim.com/topic/using-djay/neuralmix-compatibility)：最低到 iPhone 7，按机型分 Maximum/High/Medium 三档质量；Automix 转场需 A12+）。但：

- **没有任何证据表明有人在 iPhone 上跑 htdemucs 或 RoFormer。**
- 对比：Moises 主 App 是**云端**，Moises Live（端上实时）**仅桌面**；LALAL.AI 的本地 Lyra 模型也只在桌面 App / VST 里。
- Logic Pro 11 的 Stem Splitter **仅 Apple Silicon Mac**，Intel Mac 与 Rosetta 下均不可用（[Apple 支持文档](https://support.apple.com/en-sg/guide/logicpro/lgcp61bae908/mac)）。

**Kumone 的判断**：30 s 离线分离在 iPhone 上理论可行（内存不是瓶颈，时间预算充裕），但与 spec 的 iOS 策略一致——**本方向 macOS 先行，iOS 留到 stem 手法在 macOS 上验证成熟之后**。且若选 MLX Swift 路线，iOS 16 直接出局（§3.6）。

---

## 5. 架构方案

### 5.1 方案 A：离线预渲染

```
[切点确定，剩余 ~60s]
        │
        ▼
StemPipeline（后台，utility QoS）
  ├─ 从 AudioCache 读出曲 [outPoint-ε, outPoint+overlap] ≈ 20-30s
  ├─ 从 AudioCache 读入曲 [inPoint-ε, inPoint+overlap]  ≈ 20-30s
  ├─ StemSeparator（Core ML）× 2  →  各 4 轨 PCM
  ├─ 按 TransitionStyle 的 stem 手法，用一个 manual-rendering 模式的
  │  离线 AVAudioEngine 混成一段成品 PCM（与实时图同构的节点类型）
  └─ 落 sidecar 缓存 <keyOut>+<keyIn>.transition.caf
        │
        ▼
[到达 outPoint]
PlaybackEngine 把这段 PCM 当普通 buffer 调度进 deck，
入曲 deck 在 overlap 结束点接管。
```

**为什么推荐 A**：

| 理由 | 说明 |
|---|---|
| **不动实时图** | `PlaybackEngine.swift:26-28` 明写运行中重连图会抛 NSException。方案 A 完全不新增/不重连任何实时节点，这个最大的运行时地雷被绕开了。 |
| **复用现有插口** | `FileFeeder` 已经在做"分块转换 + `scheduleBuffer`"。喂一段预渲染 PCM 走的是同一条已验证的路径。 |
| **手法代码可复用** | 离线 `AVAudioEngine` 用 `enableManualRenderingMode(.offline, ...)`，节点类型与实时图完全一致（`timePitch` / `EQ` / `delay`），`TransitionStyle` 的执行逻辑一份代码两处用。 |
| **失败降级极其干净** | 分离失败/超时/渲染失败 → 缓冲区不存在 → 完全走现有 `PlannedTransition`。降级是"不做额外的事"，不是"回滚已做的事"。 |
| **可离线验收** | 渲染产物是文件，可以在 CLI 里批量生成、人耳 A/B、回归比对。与 spec §4"离线验证 CLI"的验收哲学一致。 |
| **播放期零成本** | 过渡时没有任何神经网络在跑，不占实时线程预算。 |

**方案 A 的难点（必须正视）**：

1. **时钟与位置语义**。overlap 期间引擎播的是"第三段音频"，不是任一首歌。需要给 `PlaybackEngine` 加一个 **transition 位置模式**：在 `[t0, t0+overlap)` 内，对外报告的位置 = `outgoing.outPoint + elapsed`，过中点后切成 `incoming.inPoint + (elapsed - midpoint)`，同时触发现有的 `currentTrack`/歌词/NowPlaying/scrobble 中点切换（spec §6 已有这套中点语义，是扩展不是新建）。
2. **两个拼接点必须样本精确**。入口：出曲 deck 在 `outPoint` 恰好停止、预渲染 buffer 恰好接上。出口：入曲 deck 从 `inPoint + overlapDuration` 恰好开始。渲染时**必须用与实时完全一致的采样率和相位**（graphFormat 已固定 44.1 kHz，这点是幸运的）。
3. **变速被烘焙进去**。`BeatMatchedPlan` 的 `outgoingRate`/`incomingRate` 在渲染时已应用，出口处入曲 deck 的 `timePitch.rate` 必须从 `incomingRate` 起步再 ramp 回 1.0，而不是从 1.0 起步。
4. **overlap 内 seek/切歌**。现有引擎已有"过渡窗口内 seek 则取消过渡"的语义（spec §2），直接沿用——取消 = 丢弃 buffer + 目标 deck 独占。
5. **`AVAudioEngine` offline manual rendering 的实际速度**需实测。有[开发者论坛帖子](https://developer.apple.com/forums/thread/8289)称 offline render 不会快于实时——**推测**这是在讲 `.realtime` manual rendering 模式，`.offline` 模式应显著快于实时，但**必须实测确认**。若真的只有 1× 实时，渲染 30 s 就要 30 s，加上分离仍在 60 s 预算内但余量变薄；届时改为纯 vDSP 手写混音（不用 AVAudioEngine）即可，代价是手法代码不能两处共用。

### 5.2 方案 B：stem 实时重放

每 deck 扩成 4 条播放路径：

```
deckA.vocals → tp → eq ┐
deckA.drums  → tp → eq ├→ deckA.submixer ┐
deckA.bass   → tp → eq │                 ├→ mainMixer → output
deckA.other  → tp → eq ┘                 │
deckB.（同上 4 条）─────────────────────┘
```

**优点**：灵活。手法可以在播放中实时调整、可以对用户暴露实时 stem 推子（djay Neural Mix 的交互形态）、可以响应 overlap 期间的 seek。

**代价**：

1. **节点数从 8 涨到 32**。而且因为运行中重连会抛 NSException，**所有 32 个节点必须 init 时就 attach + connect**，即使 99% 的时间它们是静音的。
2. **中途切换播放源是最难的部分**。stem 只在 overlap 窗口存在，窗口外还是整轨播放。也就是说 deck 必须在 `outPoint` 那一刻从"1 个 player 播整轨"无缝切换到"4 个 player 播 4 轨"，**5 个 player node 的样本时钟要对齐到样本级**。这比方案 A 的两个拼接点难一个数量级。
3. **4 个 player 的漂移**。`AVAudioPlayerNode` 各自维护 `playerTime`，同时 `scheduleSegment` 理论上同步，但任一 player 的 buffer 欠载都会造成相位漂移，且漂移不可恢复（听感是"回声/相位感"）。
4. **降级链复杂**。分离失败要在"已经切成 4 轨模式"之后回退，涉及运行中状态回滚。
5. **实时线程压力**。4 轨 × 2 deck 的 timePitch 都在渲染线程上跑。

**结论：方案 B 是 A 的超集，但它的收益（实时可调）目前对 Kumone 没有用户价值**——AutoMix 是自动的，用户不操作推子。**推荐先做 A，把方案 B 的能力留给未来的"手动 stem 推子"功能，那时它才有独立的产品理由。**

### 5.3 与现有契约的衔接

**`TransitionStyle` 扩容**（最小侵入）：

```swift
struct TransitionStyle: Sendable, Equatable {
    let outroEffect: OutroEffect
    let stagedEQ: Bool
    // 新增：需要 stem 才能执行的手法。nil = 不需要 stem。
    let stemTechnique: StemTechnique?
}

enum StemTechnique: Sendable, Equatable {
    case acapellaOver          // 出曲只留 vocals，飘在入曲伴奏上
    case instrumentalOut       // 出曲抹掉 vocals 收尾
    case stagedStemSwap        // drums 先换，bass 后换，other/vocals 最后
    case vocalDuck(depthDB: Float)  // 双人声时压低一侧
}
```

**`TransitionPlanner` 的签名扩展**：保持纯函数性质，把"stem 是否可用"作为显式输入而非隐式副作用：

```swift
static func plan(outgoing: TrackAnalysis?,
                 incoming: TrackAnalysis?,
                 stems: StemAvailability = .none) -> PlannedTransition
```

规则上叠一层：只有在 `tier == .compatible` **且** `stems == .ready` **且** overlap 足够长时，才升级到 stem 手法；否则输出与今天完全相同的结果。**这保证了 stem 分支是纯增量，不会改变任何现有过渡的行为。**

**Sidecar 缓存策略**（沿用 spec §3 的 `<key>.analysis.json` 模式）：

| 缓存什么 | Key | 大小 | 淘汰 |
|---|---|---|---|
| **不缓存原始 4 轨 PCM** | — | 30 s × 4 轨 × 立体声 × 44.1 kHz float32 ≈ **42 MB/首** | 太大，且只用一次 |
| **缓存预渲染的过渡片段** | `<outKey>+<inKey>+<styleHash>+<plannerVersion>.transition.caf` | 30 s 立体声，压成 ALAC 约 **3–5 MB** | 随任一侧音频被 LRU 淘汰而失效 |

**为什么只缓存成品**：队列顺序会变，(出曲, 入曲) 这个 pair 复用率低；但同一 pair 在循环播放/重复队列时会复用，且成品体积只有原始 stem 的 1/10。**推测**：命中率不会很高，缓存的主要价值是"用户 seek 回去再听一遍"和"上一次算过就不用重算"。

**降级链**（自上而下，第一个命中即止，是 spec §5 现有链条的前置扩展）：

```
1. stem 手法：模型就绪 + 分离成功 + 预渲染成功 + 在 outPoint 前完成
2. 现有 beatMatched（含 bassSwap / stagedEQ / filterSweep / echoOut）
3. 现有 crossfade（按 tier 定时长）
4. 现有 gapless
```

任何一步失败（模型未下载、分离超时、渲染失败、预算不足）**都只是不进第 1 档**，后面三档完全不受影响。这是方案 A 最大的工程价值。

超时预算建议：`outPoint - now - 5s` 作为硬 deadline，超时直接取消 `Task` 并降级。

---

## 6. 模型分发

### 6.1 体积现实

| 方案 | 体积 |
|---|---|
| Mel-Band RoFormer vocals-only fp16 | **67 MB** |
| htdemucs 单模型 fp16（Core ML） | **约 200 MB**（dexxdean 数据：fp32 400 MB / fp16 200 MB / 7.8s segment fp32 310 MB） |
| htdemucs_ft bag | 320 MB（.th）～1.26 GB（ONNX） |

### 6.2 业界惯例

| 产品 | 做法 |
|---|---|
| **Algoriddim djay** | App Store 上架体积 **约 277–285 MB**（iPhone/iPad/Mac 通用），完全离线实时工作，无首次使用下载提示 → **推测模型是内置的且相当小（几十 MB 量级）**。这反过来印证：他们用的不是 htdemucs 级别的模型。 |
| **Logic Pro 11 Stem Splitter** | 完全本地、仅 Apple Silicon。**是否为独立可下载内容包未找到明确证据**（Logic 的 Sound Library 机制是"核心内置 + 其余按包下载"，**推测**走同一机制）。 |
| **Moises** | 主 App **云端**；Moises Live 端上但仅桌面。 |
| **LALAL.AI** | 桌面 App / VST 有本地 Lyra 模型，Pro 订阅解锁；移动端云端为主。 |
| **Serato / VirtualDJ** | 桌面直装，模型随 App 分发。 |

### 6.3 Apple 平台的分发机制（供参考，Kumone 大部分用不上）

- iOS App bundle 上限：iOS 18+ 为 **4 GB**（thinned）；蜂窝下载限制约 200 MB（数据来自 2017–2019 报道，**Apple 近年未公开更新，需自行确认**）。
- **On-Demand Resources 已在 iOS 27 弃用**，Apple 推荐迁移到 **[Background Assets](https://developer.apple.com/documentation/BackgroundAssets)**（[官方 ODR 限制页明确说明](https://developer.apple.com/help/app-store-connect/reference/app-uploads/on-demand-resources-size-limits)）。**新项目不要用 ODR。**
- **macOS 不支持 ODR**。

**但 Kumone 不在 App Store**（README：macOS 走 Developer ID + 公证 + Sparkle；iOS 走侧载 IPA）。所以上述限制**全部不适用**，我们可以自由选择。

### 6.4 推荐：首次启用时下载，Kumone 不内置也不托管权重

理由有三层，**第一层是决定性的**：

1. **许可证隔离**（§2.1）。Kumone 的 Release 里不出现任何模型权重，就不会把 NC/许可不明的权重带进 LGPL 的分发范围。App 从**上游原始地址**（HF / 上游仓库的 Releases）拉取，责任留在上游。
2. **分发体积**。macOS 用 Sparkle，[delta updates](https://sparkle-project.org/documentation/delta-updates/) 确实不会重传未变文件，内置 200 MB 模型对增量更新影响可控；但 **iOS 是手工侧载 IPA**，200 MB 直接体现在每次侧载的等待时间上，体验很差。
3. **产品定位**。Stem 是 AutoMix 的可选进阶档，不是所有用户都开。让不开的人零成本，是对的默认。

**实现要点**：

| 项 | 做法 |
|---|---|
| 完整性 | SHA-256 摘要**硬编码在二进制里**（不从服务器取），下载后校验，不匹配即删除重试 |
| 版本化 | URL 含内容哈希或版本号，路径 immutable |
| Manifest | App 内置 `{模型名 → 版本 → URL → sha256 → 体积}`，随 App 更新而更新 |
| 下载 | `URLSession` background configuration，支持断点续传 |
| 预热 | 下载完成后**立刻后台实例化 `MLModel`** 触发首次编译并缓存，不要留到用户第一次过渡那一刻 |
| 存放 | `~/Library/Application Support/Kumone/Models/`（**不是** Caches——不能被系统随手清掉） |
| 失败 | 明确 UI + 重试；无模型时 AutoMix 静默走现有手法，绝不崩溃或卡住 |
| 设置项 | `stemSeparationEnabled: Bool`（默认 **关**），设置页显示模型状态/体积/一键删除 |

---

## 7. 轻量替代品

### 7.1 关键判断

> **如果只想知道"人声在哪"，跑分离模型是极大的浪费。**
> 分离模型解决的是"重建干净的 vocal 波形"；vocal ducking 只需要一条 0–1 的时间曲线。
> **只有真要在转场中"抽掉"或"独奏"人声（acapella / instrumental outro），分离才值得。**

### 7.2 Kumone 已经有了

`TrackAnalyzer.vocalActivity`（`TrackAnalyzer.swift:843`）已实现且已在 `TrackAnalysis` 里持久化：200 Hz–4 kHz 带能量占比 + 带内谱平坦度 + 2–8 Hz 调制（音节/颤音率）三路融合，响度门控 + 3 s 中值平滑。

这套特征选择与学术界的 Lehner 手工特征集（fluctogram / spectral flatness / spectral contraction / vocal variance + MFCC，见 [ISMIR 2018 论文](https://ismir2018.ismir.net/doc/pdfs/38_Paper.pdf)）**同源**——那套特征正是为了压制弦乐/木管造成的误报而设计的。

**所以本项目在这一项上没有欠债，只是还没消费它。**

### 7.3 可以补强的两个便宜信号（纯 vDSP，无模型）

1. **Mid/Side 中置能量比**。主唱几乎总在正中：`mid=(L+R)/2`、`side=(L-R)/2`，取 mid 在 200 Hz–4 kHz 的能量占比。
   注意：作为**分离器**它很差（[Sound on Sound 的说明](https://www.soundonsound.com/sound-advice/q-can-remove-vocals-track-using-phase)：这是相位抵消不是源分离，居中的 kick/snare/bass 会一起消失，人声的立体声混响尾会留下）。**但作为特征它完全可用**——检测比分离宽容得多，artifact 无所谓。这是 automix 相对卡拉OK的优势。
2. **HPSS residual**。Fitzgerald (2010) 的中值滤波 HPSS 极便宜（纯 FFT + 中值）；Driedger/Müller/Disch 的[三分量扩展](https://www.audiolabs-erlangen.de/resources/2014-ISMIR-ExtHPSep/2014_DriedgerMuellerDisch_ExtensionsHPSeparation_ISMIR.pdf)（ISMIR 2014）指出：人声既不是稳态谐波（有颤音/滑音，横向不稳）也不是瞬态打击（纵向不稳），因此**落在 residual 里**。对 residual 取带能量，是一个正交于现有三路特征的强信号。

有先例：[Zehren et al., Automatic Detection of Cue Points for DJ Mixing (2020)](https://arxiv.org/abs/2007.08411) 明确用 HPSS 分离后分别算 loudness novelty，称"提供了更精细的粒度"。该论文**没有做 vocal detection**——这正是我们的差异化空间；它引用 Lin et al. (2015) 时提到 *"cuts in vocals can be prevented by extracting phrase structures through voice detection"*，说明这条路有文献支撑。

### 7.4 小模型选项评估

| 方案 | 结论 |
|---|---|
| **Silero-VAD** | **不推荐**。MIT、<1 MB、极快，但**是为语音设计的**。[官方 discussion #546](https://github.com/snakers4/silero-vad/discussions/546) 有人正是问"能否检测音乐中的歌唱"，报告有伴奏的歌曲返回**空的 speech timestamps**。可作为 spoken-word intro / DJ drop 的辅助检测，不能当主检测器。 |
| **Apple SoundAnalysis `SNClassifySoundRequest(.version1)`** | **值得实测**。内置分类器的 `knownClassifications` 含 `singing`、`choir_singing`、`rapping`、`humming`、`yodeling`。零模型体积、零许可证问题、离线、系统级优化。**但 Apple 没有公开它在"带满编制伴奏的商业混音"上的精度**——**推测** `music` 会长期霸占 top-1 而 `singing` 只是并行的中低置信分数，实用做法是取 `singing`+`choir_singing`+`rapping` 的**分数之和作为连续曲线**再平滑阈值化，而不是看 argmax。**必须在自己曲库上实测，不能假设。** |
| **Create ML `MLSoundClassifier`** | 若上面两条都不够，这是最优的自训路线。用 Jamendo（93 首、约 6 小时、有 vocal activation 标注、copyright-free）+ 自标数据训二分类，**产出权重归自己，无许可证问题**。注意：MLSoundClassifier 训练时**只用第一个声道**，学不到 mid/side 立体声线索，M/S 特征必须在外面自己做。 |
| **Essentia `voice_instrumental` 分类头** | **不可用**。分类头本身小得惊人（YAMNet 版 412 KB、VGGish 版 53 KB），但**权重 CC BY-NC-SA 4.0 + 库 AGPLv3**。**推测**可以用 Apache-2.0 的 YAMNet 做 embedding 前端、自己训一个同构的头来绕开——技术上应可行，但没找到有人这么做的公开记录。 |
| **YAMNet** | Apache-2.0 **代码和权重都宽松**，3.7 M 参数，AudioSet 521 类含 `Singing`/`Choir`/`Rapping`。是这一档里唯一许可干净且足够小的。局限同 SoundAnalysis：满编制混音上 `Singing` 置信度会被 `Music` 压过。 |
| **madmom / PANNs** | madmom 权重 CC BY-NC-SA（**不可用**，且它没有 SVD 模型）；PANNs CNN14 权重 CC-BY-4.0 但 80 M 参数太重。 |

### 7.5 小结

**第 0 阶段的正确做法不是加模型，是消费已有的 `vocalActivity`**，并（可选）用 mid/side + HPSS residual 补强它。这是唯一一个"零风险、零体积、零许可证问题、当天可听出差别"的改进。

---

## 8. 分阶段落地计划

| 阶段 | 内容 | 验收 | 粗估 |
|---|---|---|---|
| **S0 人声避让** | `TransitionPlanner` 消费 `vocalActivity`：选点时避开"双方人声都活跃"的重叠；`TransitionStyle` 加 `vocalDuck`（用现有 EQ 的中频参数带做，不需要 stem）；调试面板显示两首歌的 vocal 曲线与所选窗口 | 人声撞车的过渡明显减少；回归集上选点变化可解释 | **1–3 天** |
| **S0.5 特征补强**（可选） | vDSP 加 mid/side 中置比 + HPSS residual 带能量，融进 `vocalActivity`；`TrackAnalysis.currentVersion` 递增触发重分析 | 手标一小组"清唱/纯伴奏/满编制"片段，AUC 相对现状提升 | **3–5 天** |
| **S1 离线可行性原型**（**不进产品**） | `Scripts/` 里一个 Python 脚本：调 `mlx-audio-separator` 分离 overlap 窗口 → 用现有 `TransitionPlan` 参数把 acapella-over / staged-swap 混出来 → 生成 20–30 组 A/B 音频。**决策门：人耳能否听出比现有手法好，且分离残留能否接受。** | 盲听对比，若不明显更好则**此处终止整个方向** | **3–5 天** |
| **S2 Core ML 推理管线**（**风险最高**） | 改写模型前向把 STFT/iSTFT 移出图 → `coremltools` 转换（手拆 MHA，固定 segment）→ Swift `StemSeparator`：vDSP STFT → `MLModel` → mask → vDSP iSTFT + overlap-add；模型下载/校验/预热；CLI 验收入口（对本地文件输出 4 轨 WAV，跑 SDR 对比 PyTorch 参考） | 转换后与 PyTorch fp32 的 SDR 差 < 0.3 dB；M 系列上 30 s 片段稳态 < 10 s | **2–3 周** |
| **S3 预渲染与引擎接入** | `StemPipeline`（预算/超时/取消，沿用 `resolveGeneration` 思路）+ 离线 `AVAudioEngine` manual rendering 混音 + `PlaybackEngine` 的 transition 位置模式 + 拼接点样本对齐 + 完整降级链 + sidecar 缓存 | 混合歌单连播：stem 过渡拼接无爆音/无相位感；拔掉模型文件后行为与今天完全一致 | **2 周** |
| **S4 手法扩展** | `StemTechnique` 四种手法落地 + `TransitionPlanner` 的升级规则 + 设置开关 + 调试面板显示所选手法 | 电子/流行歌单上 acapella-over 与 staged swap 听感成立；clash 档正确不升级 | **1.5–2 周** |
| **S5 可选** | iOS 启用；或方案 B（实时 stem 重放）配合手动 stem 推子 UI | — | 另行评估 |

**合计到 S4：约 7–9 周**（单人，含调参与听感迭代）。

**分阶段的价值**：S0 独立可发布、独立有收益；**S1 是明确的 kill gate**——用 3–5 天决定是否投入后面的 6–8 周。**强烈建议不要跳过 S1。**

---

## 9. 风险与对策

| 风险 | 严重度 | 对策 |
|---|---|---|
| **htdemucs 权重许可不明**（§2.1） | 🔴 阻塞级 | 先走**明确 MIT** 的 Mel-Band RoFormer vocals-only（67 MB），它恰好覆盖价值最高的人声类手法；4-stem 手法等许可核实后再上。同时通过 issue/邮件向 Meta 求证。 |
| **Core ML 无 iSTFT + MHA 无法 trace** | 🔴 高 | STFT/iSTFT 移出模型（复用现有 vDSP）；MHA 手工拆解（dexxdean 与 StemSplit 两份独立参考实现）。**若 S2 两周内不收敛，切 MLX Swift plan B**（代价：iOS 16 出局 + 重量级依赖）。 |
| **分离残留在独奏时被听出** | 🟡 中高 | S1 的 kill gate 就是为此设。另外把 acapella-over 限制在 `tier == .compatible` 且 vocals SDR 高的曲目上，其余只做 ducking/staged swap 这类"残留被伴奏掩蔽"的手法。 |
| **拼接点爆音/相位** | 🟡 中 | graphFormat 已固定 44.1 kHz 是有利条件；渲染时在两端各留 5–10 ms 的等功率淡入淡出；CLI 里对拼接点做样本级断言（不连续量 < 阈值）。 |
| **`AVAudioEngine` offline 渲染速度未知** | 🟡 中 | S3 第一天就实测。若不及预期，改为纯 vDSP 手写混音（代价：手法逻辑不能两处共用）。 |
| **首次编译/加载开销主导 30 s 任务** | 🟢 低 | AutoMix 开启时常驻 `MLModel`；下载完成后立刻后台预热。 |
| **模型下载失败** | 🟢 低 | 降级链保证无模型 = 今天的行为。设置页显式状态，不做隐式重试风暴。 |
| **专利风险** | 🟡 中 | 检索到相关专利（如 US 12106011 "Method and device for audio crossfades using decomposed signals"、US 12531042），描述了"分离人声 + 交叉推子避免人声撞车"。Kumone 是非商业开源项目，风险较低，但**若做 stem-level 交叉推子，建议做一次 FTO 检索**。 |
| **LGPL 与新依赖** | 🟢 低 | 推荐路线（Core ML + vDSP + 下载式权重）**零新 SPM 依赖**，与 spec 的既有决策一致。MLX Swift plan B 是 MIT，与 LGPL 兼容，但破坏"零依赖"原则。 |

---

## 10. 待验证清单

以下条目在本次调研中**未能确证**，落地前必须实测或求证：

1. **htdemucs 预训练权重的确切许可条款**——Issue #327 的维护者回复未能直接读到。**这是第一优先。**
2. ZFTurbo MSST 仓库里由第三方贡献的 checkpoint（viperx / gabox / Kimberley Jensen 版）是否各自继承仓库 MIT。
3. ~~`AVAudioEngine.enableManualRenderingMode(.offline,)` 在 M 系列上的实际渲染倍速。~~
   **✅ 已实测（Apple M4，release build）：72×–206× 实时，15 对真实曲目平均 154×。**
   测量方式见 `docs/audition.md`：与实时图同构的双 deck 图
   （player → timePitch → EQ(4band) → delay → mixer ×2，44.1 kHz 立体声），
   按 50 Hz 粒度写参数、逐帧 `renderOffline`，渲染 27–41 s 的过渡片段耗时 0.13–0.36 s。
   §5.1「方案 A：离线预渲染」的时间预算因此**不是约束**（§9 的 🟡 风险可关闭）：
   30 s 混音只需 ~0.2 s，60 s 预算几乎全部可以留给 stem 分离本身。
   论坛帖里"offline render 不快于实时"的说法确实只适用于 `.realtime` manual rendering 模式。
4. Apple `SNClassifySoundRequest(.version1)` 的 `singing` 类在带满编制伴奏的商业混音上的召回率/精度（Apple 无公开数据）。
5. Core ML `.cpuAndGPU` 路径上 htdemucs / Mel-Band RoFormer 处理 30 s 片段的实际耗时与内存（无公开 benchmark）。
6. M1/M2/M3 基础款的绝对耗时（本文全部从 M4 Max 外推）。
7. fp16 量化对分离 SDR 的实际影响（dexxdean 称"inaudible"但无客观指标）。
8. Mel-Band RoFormer 的 Core ML 转换可行性——**目前没有任何公开实现**，S2 的实际难度可能高于 htdemucs（RoFormer 全是 attention + STFT）。
9. Spleeter 权重许可（Deezer 至今未回复 issue #898）。
10. Logic Pro Stem Splitter 是否为独立可下载内容包。

---

## 附：来源索引

**模型与许可**
[demucs](https://github.com/adefossez/demucs) ·
[demucs LICENSE](https://github.com/adefossez/demucs/blob/main/LICENSE) ·
[demucs #327 权重许可](https://github.com/facebookresearch/demucs/issues/327) ·
[open-unmix](https://github.com/sigsep/open-unmix-pytorch) ·
[spleeter #898](https://github.com/deezer/spleeter/issues/898) ·
[lucidrains/BS-RoFormer](https://github.com/lucidrains/BS-RoFormer) ·
[Mel-Band RoFormer 论文](https://arxiv.org/abs/2310.01809) ·
[ZFTurbo MSST](https://github.com/ZFTurbo/Music-Source-Separation-Training) ·
[MSST pretrained_models（SDR 表）](https://github.com/ZFTurbo/Music-Source-Separation-Training/blob/main/docs/pretrained_models.md) ·
[MUSDB18 数据集许可](https://sigsep.github.io/datasets/musdb.html) ·
[UVR GUI](https://github.com/Anjok07/ultimatevocalremovergui) ·
[madmom_models 许可](https://github.com/CPJKU/madmom_models)

**Core ML / ONNX / MLX**
[coremltools 7.0 release](https://github.com/apple/coremltools/releases/tag/7.0) ·
[complex_dialect_ops.py](https://github.com/apple/coremltools/blob/main/coremltools/converters/mil/mil/ops/defs/complex_dialect_ops.py) ·
[coremltools #2016（ISTFT）](https://github.com/apple/coremltools/issues/2016) ·
[coremltools PR #2029](https://github.com/apple/coremltools/pull/2029) ·
[coremltools #1763（MHA flexible shape）](https://github.com/apple/coremltools/issues/1763) ·
[Flexible Input Shapes 指南](https://apple.github.io/coremltools/docs-guides/source/flexible-inputs.html) ·
[dexxdean/htdemucs-coreml](https://github.com/dexxdean/htdemucs-coreml) ·
[StemSplit/demucs-onnx](https://github.com/StemSplit/demucs-onnx) ·
[sevagh/demucs.onnx](https://github.com/sevagh/demucs.onnx) ·
[sevagh/demucs.cpp](https://github.com/sevagh/demucs.cpp) ·
[MDX-Net → Core ML 实战记录](https://web.navan.dev/posts/2025-10-26-vocal-separation-and-rvc-onnx-coreml.html) ·
[ONNX Runtime CoreML EP](https://onnxruntime.ai/docs/execution-providers/CoreML-ExecutionProvider.html) ·
[ml-explore/mlx-swift](https://github.com/ml-explore/mlx-swift) ·
[ssmall256/demucs-mlx](https://github.com/ssmall256/demucs-mlx) ·
[ssmall256/mlx-audio-separator](https://github.com/ssmall256/mlx-audio-separator) ·
[mel-roformer-zfturbo-vocals-v1-mlx](https://huggingface.co/mlx-community/mel-roformer-zfturbo-vocals-v1-mlx)

**性能与端上**
[demucs #498（内存）](https://github.com/facebookresearch/demucs/issues/498) ·
[Demucs-GUI usage（MPS 对旧模型反而慢）](https://github.com/CarlGao4/Demucs-Gui/blob/main/usage.md) ·
[Does my Core ML model run on the ANE?](https://fritz.ai/does-my-core-ml-model-run-on-apples-neural-engine/) ·
[Apple: Transformers on the ANE](https://machinelearning.apple.com/research/neural-engine-transformers) ·
[whisper.cpp（Core ML 首跑编译）](https://github.com/ggml-org/whisper.cpp)

**分发**
[Apple: ODR 体积限制 / 弃用公告](https://developer.apple.com/help/app-store-connect/reference/app-uploads/on-demand-resources-size-limits) ·
[Apple: Background Assets](https://developer.apple.com/documentation/BackgroundAssets) ·
[Sparkle delta updates](https://sparkle-project.org/documentation/delta-updates/) ·
[Algoriddim Neural Mix 兼容性](https://help.algoriddim.com/topic/using-djay/neuralmix-compatibility) ·
[Logic Pro Stem Splitter](https://support.apple.com/en-sg/guide/logicpro/lgcp61bae908/mac) ·
[LALAL.AI Lyra 本地模型](https://www.lalal.ai/blog/lyra-local-stem-separation-in-lalalai-desktop-app-and-vst-plugin/)

**轻量检测**
[Silero-VAD](https://github.com/snakers4/silero-vad) ·
[Silero discussion #546（唱歌不适用）](https://github.com/snakers4/silero-vad/discussions/546) ·
[SNClassifySoundRequest](https://developer.apple.com/documentation/soundanalysis/snclassifysoundrequest) ·
[MLSoundClassifier](https://developer.apple.com/documentation/createml/mlsoundclassifier) ·
[Lehner 特征集（ISMIR 2018）](https://ismir2018.ismir.net/doc/pdfs/38_Paper.pdf) ·
[f0k/ismir2015（Schlüter CNN）](https://github.com/f0k/ismir2015) ·
[Extending HPSS（ISMIR 2014）](https://www.audiolabs-erlangen.de/resources/2014-ISMIR-ExtHPSep/2014_DriedgerMuellerDisch_ExtensionsHPSeparation_ISMIR.pdf) ·
[DJ Cue Point 检测（2020）](https://arxiv.org/abs/2007.08411) ·
[SoS: 相位抵消不是源分离](https://www.soundonsound.com/sound-advice/q-can-remove-vocals-track-using-phase) ·
[YAMNet](https://github.com/tensorflow/models/tree/master/research/audioset/yamnet)
