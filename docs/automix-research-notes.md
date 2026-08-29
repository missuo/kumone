# AutoMix 外部项目调研 — walkywalker/automix 与 sony/fxnorm-automix

> 状态：调研（2026-08-28） · 纯阅读，未写任何产品代码
> 前置阅读：[`automix-spec.md`](automix-spec.md) · [`audition.md`](audition.md) · [`automix-stems-predev.md`](automix-stems-predev.md)
> 对照基准：`Sources/Kumone/Core/Player/Analysis/TransitionPlanner.swift` · `TrackAnalyzer.swift`
> 所有结论标注来源（文件:行）；无来源的判断标注为**推测**。

---

## 0. 一页摘要

调研了两个开源 automix 项目。**它们不是同一类东西**，把它们放在一起看恰好补上了我们的两个短板：

| | [walkywalker/automix](https://github.com/walkywalker/automix) | [sony/fxnorm-automix](https://github.com/sony/fxnorm-automix) |
|---|---|---|
| 是什么 | C++ 自动 DJ：一个目录的歌 → 一个连续 mix 的 MP3 | ISMIR 2022 论文配套：深度学习**混音**（多轨 stem → 母带） |
| 与我们的关系 | **同类问题**，比我们粗，但选点思路完全不同 | **不同问题**，但它的归一化与评估方法论正对我们痛点 |
| 许可证 | **GPL-2.0**（含改造过的 QM-DSP 与 Mixxx 代码） | **MIT** |
| 红线 | ❌ 代码不可用，**只能看思路** | ✅ 代码可用（但主要价值在 ~200 行特征数学，不在模型） |
| 规模 / 活跃度 | 5.3k LOC，24 star，末次 push 2023-03 | 9.0k LOC，149 star，末次 push 2024-03 |

**四个已知痛点的现成答案盘点：**

| 痛点 | 有无现成答案 | 出处 |
|---|---|---|
| ① 人声活动信号弱相关 | **无**。walkywalker 把 "Detect vocals" 列在 *Further Work* 里（`developer.rst`）；Sony 全程用 ground-truth stem，从不需要检测。Mel-Band RoFormer 路线仍是唯一真答案 | — |
| ② 选点（入点锁死 introEnd） | **有，且是本次调研最大收获**。walkywalker 的入点是**曲内的第一个 drop**，不是 intro 结束；重叠长度由入曲结构决定而非固定小节数 | `dj.cpp:82-101`、`analyzer.cpp:77-115` |
| ③ beatMatched 真实曲库 0/47 | **无**。两个仓库都绕过了这个问题（一个把所有歌重采样到全局 BPM，一个根本不做过渡）。但可以先把"哪一道门槛在拦"做成统计 | 见 §4 第 9 条 |
| ④ 过渡响度不一致 | **有，且两边互补**。walkywalker 给廉价可落地的 per-track 参考电平 + 全局增益 trim；Sony 给正确的度量（BS.1770 LUFS）、不削顶的写法、以及把它变成**可回归客观指标**的完整方法论 | `dj.cpp:18-24` + `bass_detector.cpp:46-57`；`utils_data_normalization.py:69-87` |

**如果只做三件事**：①《参考响度 + 全局增益补偿》（半天到一天，直接消灭痛点④）；②《渲染做电平匹配后再盲听》（一小时，我们现有的 A/B 盲听结论都可能被响度偏置污染）；③《选点改为结构事件驱动》（3–5 天，痛点②）。

---

## 1. walkywalker/automix

### 1.1 它解决什么问题

命令行工具：输入一个装满 mp3/m4a 的目录，输出一个连续 DJ mix 的 MP3。README 明说风格偏向 **DnB / Jungle / Breakbeat**。三阶段：Analysis → Mix → Perform（[`developer.rst`](https://github.com/walkywalker/automix/blob/master/developer.rst)）。

关键背景差异：**它是离线渲染整份 mix，不是实时播放器**。所以它可以把每首歌重采样到一个全局输出 BPM（`-ot`，默认 87.5），让"能不能混"这个问题**从根上消失**。我们不能这么做。

### 1.2 pipeline

**Analysis**（`src/analyzer.cpp`）

1. 三个 detector 并行喂同一份单声道流（`analyzer::run`，`analyzer.cpp:131`）：QM `beat_tracker`（broadband 检测函数，dftype=4）、QM `onset_detector`（"Percussive onsets" program）、自写 `bass_detector`。
2. **BPM**（`analyzer.cpp:269`）：拍间隔集合 → mean±1sd 截尾均值 → **四舍五入到 0.25 BPM**（作者注：电子乐 BPM 基本是 0.25 的倍数）。
3. **网格相位**：找一段 **40 拍**全部落在 2sd 内的窗口（`consecutive_beat_threshold = 40`，`analyzer.cpp:308`），构造理想等间隔网格，用原始的一维局部搜索（`minimise_distance`，`analyzer.cpp:544`，步长 1 ms，L1 距离）滑到最优。
4. **1/8 拍相位歧义消解**（`align_beat_grid`，`analyzer.cpp:366`）：把"疑似 kick"（onset 强度 > mean+0.5sd）相对网格的偏移量按 1/8 拍分桶做直方图；用"第一声"或"第一个 onset"推出候选平移量，**再用 kick 直方图验证**这个平移量所在的桶高于均值，否则整首歌分析失败。
5. **drop 检测**（`analyzer.cpp:77-115`）：低频带（bessel 带通 ~50–100 Hz）RMS 按**每 4 小节**积分；凡是 `max - value < 0.4 * range` 的 4 小节段落判为处在 drop 内；连续段落合并成 `(start_bar, end_bar)` 对。
6. **鼓密度**（`analyzer.cpp:60-66`）：每 4 小节的 percussive onset 计数。
7. **参考音量**（`bass_detector.cpp:46-57`）：`get_vol()` = **只对超过全曲 RMS 峰值 80% 的帧取 RMS 均值**。

结果写进 `tmp/automix.xml` 做缓存（等价于我们的 `.analysis.json` sidecar）。

**Mix**（`src/dj.cpp`）

- 曲序：`std::random_shuffle`（`dj.cpp:15`）。**没有任何配对兼容度判断**——详见 §1.5。
- 三种过渡（`dj.cpp:82 / 164 / 191`）：`normal_mix`、`breakdown_mix`、`double_drop_mix`，按概率参数 `-dd` / `-bd` 抽签。
- 输出是一个带时间戳的 action 栈（LOAD / PLAY / PAUSE / VOL / LPF / TEMPO）。

**Perform**（`src/mixer.cpp`、`channel.cpp`、`recorder.cpp`）：6 个虚拟 deck 通道按时间戳执行 action，编码成 MP3。变速用 libsamplerate 重采样（`tempo.cpp:59`，`src_process`）。

### 1.3 选点：与我们最大的差异

这是本次调研最值得记的一节。

**它的 `normal_mix`（`dj.cpp:82-101`）：**

```
出点 = 出曲第一个 drop 的【结束小节】       get_drop_bars(0).second
入点 = 入曲第一个 drop 的【起始小节】       get_drop_bars(0).first
bar_to_start = 出点小节 - 入点小节          （可以是负数）
```

三个和我们不一样的地方：

1. **入点在曲内，不在 intro 末尾。** 入曲的 intro + buildup **整段都在出曲底下播放**——听众听到的是出曲的最后一个 drop 之上，慢慢浮起下一首的铺垫，然后两首在下一首的 drop 处交接。我们的 `beatMatchedPlan` 是 `incoming.downbeats.first(where: { $0 >= incoming.introEnd })`（`TransitionPlanner.swift:512`），`crossfadePlan` 直接 `let inPoint = incoming.introEnd`（`:668`）。**入曲永远从"第一声"开始，永远不提前进场**，这正是痛点②的原话。
2. **重叠长度由结构算出，不是固定小节数。** 他们没有"overlap"这个变量；重叠时长天然等于"入曲从起播到它自己的 drop 之间有多长"。我们是先定 16/8/4 小节再找容得下的边界（`TransitionPlanner.swift:540-564`）。
3. **出点是"最后一个高能段落的结束"，不是"outro fade 起点"。** 我们的 crossfade 出点在有 `outroFadeStart` 时被钉死在渐弱起点（`TransitionPlanner.swift:680-684`）——stem 层的注释里已经自己发现了这个问题（"14/16 首有 outroFadeStart，切点被钉在渐弱里，分离出来几乎是空的"，`TransitionPlanner.swift:218-230`）。walkywalker 的做法是：**在最后一个 drop 结束的那一拍直接停掉出曲**（`current_tune->pause(...)`，`dj.cpp:98`），根本不播 outro。

**`breakdown_mix`（`dj.cpp:164`）+ `find_buildup_no_drums`（`dj.cpp:147`）：**

从入曲第一个 drop 往前、以 8 小节为步长倒着找，第一个"每 4 小节 onset 数 < 16"的段落，作为入点。这是一个**用鼓密度而不是 RMS 定义的"这里安静，适合进场"**的判据。我们只有 RMS 包络（`TrackAnalyzer.rmsPerSecond`，`:933`）——RMS 说"响不响"，onset 密度说"忙不忙"，一个稀疏但响的段落和一个密集但轻的段落在 RMS 上无法区分。

**`position_breakdown_transitions`（`dj.cpp:103-145`）：** 先扫全库找出"有合适 breakdown 段"的歌，取 `ceil(N * bd%)` 首，**用 `iter_swap` 把它们均匀插到曲序的 1/(k+1), 2/(k+1)... 位置上**，让整份 mix 有起伏节奏。这是 mix 级编排，我们的队列是用户驱动的，大部分不适用（见 §4 第 10 条）。

### 1.4 过渡编排：EQ / 音量曲线

**"LPF" 其实是 50 Hz 峰值滤波器。** `channel.cpp:4-14`：`kStartupLoFreq = 50.0`、`kQKill = 0.9`，`biquad::set_coefs` 用 fidlib 的 `PkBq`（peaking biquad）规格（`filter.cpp:22`）。所谓 "set LPF gain to -23" 就是在 50 Hz 挖 -23 dB 的坑 = bass kill。

**低频交接是"事件跳变"，不是"重叠中点渐变"：**

- 每首歌载入时默认 **bass 全杀**（`tune::set_initial_controls`，`tune.cpp:65-67`，LPF = -23）。
- 入曲的低频在**它自己的 drop 那一拍**恢复到 0 dB（`dj.cpp:93-94`）。
- 出曲的低频在**它自己的交接小节**被杀掉，0.1 秒后 pause（`dj.cpp:96-99`）。
- 全程**没有 ramp**，是阶跃。

我们的 `bassSwapOffset = overlap / 2`（`TransitionPlanner.swift:575`）是几何中点。他们的规则是**"低频属于正在自己 drop 里的那一首"**——这是一条音乐语义规则而不是几何规则。

**音量曲线：** `tune::set_volume_ramp`（`tune.cpp:122-135`）= **16 个离散台阶、线性幅度、跨 4 小节**。不是等功率，不是曲线，就是 16 步阶梯。这一条是**反面参考**：我们的 `TransitionAutomation` 在这个维度上明显更讲究。

**变速：** `tempo.cpp` 用 libsamplerate 重采样（`src_ratio`），**音高跟着变**——传统黑胶/turntable 惯例。我们用 `AVAudioUnitTimePitch` 变速不变调（`automix-spec.md` §2）。在 ±4% 这个量级上，DJ 界的惯例其实是音高跟随；时间拉伸在整首混音（而非单轨）上做会有相位涂抹感。**推测**：这值得一次盲测（见 §4 第 7 条）。

### 1.5 它怎么处理"哪两首能混"

**诚实的答案：它不处理。**

- 曲序完全随机（`dj.cpp:15`）。
- 兼容性靠**把所有歌重采样到同一个输出 BPM** 强行制造（`dj::mix` 的 `tempo` 参数，默认 87.5）。
- 没有调性、没有音色、没有响度的配对级判断。
- 唯一的曲目级筛选是"分析是否成功"（`automix.cpp:122-138`：分析失败的歌**整首排除出 mix**）。

也就是说，**我们的三档兼容度门（响度/音色/节奏/调性/人声五信号，`TransitionPlanner.tier`）在这个维度上严格领先于这个仓库**。唯一值得借的配对级思路是 mix 编排的起伏节奏（§1.3 末）。

顺带一条哲学：`developer.rst` 写"分析有若干 sanity check，任一失败就不用这首歌——**这好过让 mix 'clang'（撞车）**"。我们的等价物是退化链（beatMatched → crossfade → gapless），方向一致；但**播放器不能拒绝播一首歌**，所以"整首排除"这个形态对我们不适用。

### 1.6 代码质量与可复用性

| 维度 | 评价 |
|---|---|
| 规模 | 2.9k LOC 自写 + 2.4k LOC vendored QM-DSP（`src/qm/`） |
| 质量 | 业余项目水准：`throw;`（无异常对象，`automix.cpp:34`）、生产路径上 `assert(drops.size() > 0)`（`analyzer.cpp:115`）、`std::random_shuffle`（C++17 已移除）、44100 硬编码遍布、`bass_detector.cpp:14-15` 自注 "doesn't do anything, parameters are hard coded in filter"、全局 `std::mutex` |
| 平台 | 仅 64-bit Linux；依赖 ffmpeg / libsamplerate / fidlib / pugixml / vamp-plugin-sdk 五个子模块 |
| 库接口 | 无。是个 `main()` 程序 |
| **可复用性** | **0**。许可证 + 平台 + 无库接口，三重不可用 |

**许可证（红线）**：`COPYING` 是 **GPL-2.0**；`src/qm/*` 是改造过的 QM Vamp Plugins（GPLv2，头注释见 `beat_track.cpp:1-20`）；`filter.cpp:1` 明写 "Modified from Mixxx (GNU GPLv2)"。Kumone 是 **LGPL-3.0-only**，与 GPL-2.0-only **双向不兼容**。

> **操作纪律**：本文档里所有 walkywalker 的内容都是**行为描述与算法思路**，不含可复制的代码片段。落地时应当从 `developer.rst` 的散文描述（它把 §1.2–§1.4 的绝大部分都用自然语言讲了一遍）出发独立实现，不要照着 `.cpp` 抄。

---

## 2. sony/fxnorm-automix

### 2.1 它解决什么问题（以及不解决什么）

**它不是 DJ 工具，和"两首歌怎么衔接"零关系。** 它做的是：给定一首歌的 vocals/bass/drums/other 四轨，用深度模型输出一份**混音成品**（ISMIR 2022，[arXiv:2208.11428](https://arxiv.org/abs/2208.11428)）。

它要解决的真问题是**训练数据污染**：自动混音模型需要"干"（未处理）的分轨，但现实中能拿到的多轨素材（MUSDB18 之类）都是**已经处理过的湿轨**——每一轨都自带前一位混音师的 EQ、压缩、声像、混响指纹。直接拿去训练，模型学到的是"把已经混好的东西再混一遍"。

**Effect normalization = 把所有输入轨在若干个"效果特征"维度上归一到数据集平均值**，抹掉前人指纹，模型才被迫真的学混音。归一化的六个效果（`evaluate.py:72`）：`prereverb, reverb, eq, compression, panning, loudness`。

**这对我们意味着什么**：思想是"**跨素材做目标空间归一化**"——正是痛点④"两首歌母带响度差没有做增益补偿"的一般化形式。我们的问题只是它的一个子集（只需要 loudness，可选 eq）。

### 2.2 三个可直接借鉴的实现细节

**(a) `lufs_normalize`（`utils_data_normalization.py:69-87`）**

```
meter = pyln.Meter(sr)                       # BS.1770-4 积分响度
loudness = meter.integrated_loudness(x)
y = pyln.normalize.loudness(x, loudness, target_lufs)
y /= max(1.0, 1e-6 + max|y|)                 # ← 削顶保护
```

最后那行是关键细节：**归一化后如果峰值超过 1.0，整体缩回去**。做增益补偿时必然遇到"把一首母带响度低的歌往上推 5 dB 结果削顶"，这两行就是答案。BS.1770 K 加权的正确度量在此，比 RMS 好；代价是要实现 K 加权滤波（一个高架 + 一个高通）+ 门限逻辑。

**(b) `get_eq_matching`（`utils_data_normalization.py:89-131`）— 音色矫正而非仅降级**

```
diff_dB   = dB(参考平均幅度谱) - dB(本轨平均幅度谱)
diff_amp  = sqrt(10^(diff_dB/20))       # sqrt 因为 filtfilt 前后各滤一次
filter    = scipy.signal.firwin2(1001 taps, freqs, diff_amp)
output    = filtfilt(filter, 1, audio)  # 零相位
```

配套的 `smooth_feature`（`evaluate.py:316-340`）在匹配**之前**先对参考谱做 Savitzky-Golay 平滑（vocals/other 401 阶、bass/drums 151 阶）——**不平滑就会把梳状结构烙进滤波器**。

对我们的意义：现在的 `timbreDistance`（`TransitionPlanner.swift:478`）只会把音色差大的配对**降级**（compatible → neutral → clash，缩短重叠）。EQ matching 提供了第三条路：**在重叠窗口内把入曲往出曲的音色上拉一点**，让本来只配 6 秒快切的配对也能吃长混。我们每 deck 已经有 4-band EQ（`automix-stems-predev.md` §1.1）。

**(c) 压缩匹配 `get_comp_matching`（`:386`）+ `get_mean_peak`（`:309`）**

用 HFC onset 检测取瞬态峰值分布的 75 分位，把本轨的峰值上界压到"数据集均值 + 标准差"。**对我们价值低**（我们不做动态处理），但 `get_mean_peak` 用到了 `aubio`（**GPL-3.0**）——如果把 Sony 的评估脚本搬进 `Scripts/`，这一函数要避开或替换。

### 2.3 客观评估指标体系 — 直接对我们"全靠人耳"

这是 Sony 仓库对我们**第二大**的价值。`evaluate.py:675-847` 组织了四组客观指标，实现全在 `utils_data_normalization.py`：

| 组 | 特征 | 实现 |
|---|---|---|
| **Loudness** | 积分 LUFS 差、峰值 dB 差 | `compute_loudness_features:523` |
| **Spectral** | 谱质心、带宽、谱对比度（`fmin=250, n_bands=4, quantile=0.02`，再拆 low/mid/high）、rolloff(0.85)、平坦度 | `compute_spectral_features:556` |
| **Panning** | SPS 立体声声像谱 `phi = 2|L·conj(R)|/(|L|²+|R|²)`，按频带聚合成 Panning RMS | `get_SPS:133` / `compute_panning_features:817` |
| **Dynamic** | 逐帧 RMS(dB)、**dynamic spread** `mean(dB|x| - RMS_dB)`、**crest factor** `dB(max|x|)/RMS_dB`、**低频占比** `Σ(1kHz 低通谱 / 全谱)` | `get_rms_dynamic_crest:899` / `get_low_freq_weighting:945` |

**统一的聚合套路**（这才是方法论）：逐帧算特征 → `get_running_stats` 取 N 帧滑动均值（`:44`，N=40；论文里写 0.5 s）→ 与参考序列算 **MAPE**（平均绝对百分比误差）→ 按组求平均。

两个前置处理值得单独记：
- 算频谱与动态特征之前先 `pyln.normalize.peak(x, -1.0)`（`evaluate.py:566-567`、`:981-982`）——**把电平从频谱/动态指标里解耦**，否则一切指标都在测响度。
- `rms/dyn` 在算 MAPE 前做了 `(-1*x) + 1.0` 变换（`:1007-1010`），因为 dB 值是负数，MAPE 对零附近和符号敏感。

**怎么套到我们身上**：我们没有"目标混音"，但**有天然参考——过渡本身不应该在音色/动态上偏离它连接的两首歌**。`audition batch` 已经把每对渲染成 `renders/NN-a__b.wav`（`audition.md` §2），每个渲染是 `preRoll(出曲稳态) + 交接 + postRoll(入曲稳态)`。于是：

> 对每个渲染，在时间轴上算特征序列，把**重叠区**分别对 **pre-roll** 与 **post-roll** 做比较。

四个立刻有用的数：

1. **响度连续性**：短时 RMS-dB 轨迹相对"pre-roll 电平 → post-roll 电平"线性插值的最大偏离，以及交接点的阶跃量。crossfade 中间掉坑（等功率不匹配）或交接处跳一档，都变成一个数。**这就是能自动抓住痛点④的那个指标。**
2. **低频占比**（`get_low_freq_weighting`）：重叠区 vs 两侧。两条 bassline 叠在一起会让这个数显著抬高——**bass swap 存在的全部意义就是防止这件事，而我们今天没有任何手段验证它有没有生效**。
3. **crest factor / dynamic spread**：重叠区 vs 两侧，抓"重叠听起来糊/被压扁"。
4. **谱质心**轨迹：抓 staged EQ 与 filter sweep 有没有把交接做出音色断层。

聚合成 MAPE 后按语料分布打表，直接并进 `decisions.md` 现有的分布摘要。

### 2.4 盲听方法论（论文，非代码）

论文重新设计了混音系统的听测协议（[ar5iv 全文](https://ar5iv.labs.arxiv.org/html/2208.11428)）：

- **14 名被试，平均 11.6 年混音工程经验**。
- 每首歌 6 个版本对比（4 个模型 + 专业人声混音 + 基线），素材是 **25 秒、取自 chorus-to-verse 的过渡段**。
- 评分是**三个具名维度**：Production Value / Clarity / Excitement——不是笼统的"哪个更好"。
- **所有刺激统一归一到 −23 dBFS** 后再播放。
- 提供四条干轨作参考，**不设 low anchor**。
- 统计：Mann-Whitney U + Bonferroni 校正。

**最该抄的一条是 −23 dBFS 归一化。** 响度偏置是听测里最强的混杂因素——两个渲染只要一个更响，它就更"好听"。我们 S1 的 stem 手法盲测（`automix-stems-s1-report.md`）以及 `audition` 的 A/B 渲染**都没有做电平匹配**，所以现有的"3/6 对更喜欢 vocalDuck"这类结论**存在被响度偏置污染的可能**。而 vocalDuck 恰恰是一个**会改变电平**的手法（把出曲人声压低 9 dB）——这正是最该担心的情形。

"三个具名维度"也值得抄：把"哪个更好"换成"哪个更干净 / 哪个衔接更自然 / 哪个更有推进感"，能让盲听结论可复述、可回归。

### 2.5 代码质量与可复用性

| 维度 | 评价 |
|---|---|
| 规模 | 9.0k LOC Python，149 star，末次 push 2024-03 |
| 质量 | 研究代码水准：模块级常量满天飞、`exec(open(config_file).read())` 加载配置（`evaluate.py:411`）、大段注释掉的代码、`cuda` 硬编码、`evaluate.py` 末尾 30 行空白 |
| 亮点 | `utils_data_normalization.py` 是干净自洽的特征/DSP 库，是**真正可复用的那部分** |
| 缺口 | 训练/推理用的 IR（脉冲响应）因版权**无法公开**，混响归一化不可复现（README 明写） |
| **可复用性** | **中**。模型对我们无用（它把 stem 混成母带，不是接两首歌）；**价值在 §2.2 的三段特征数学与 §2.3 的评估框架**，约 200 行，可以在 Swift/vDSP 重写，或作为离线脚本放进 `Scripts/` |

**许可证**：**MIT**，与 LGPL-3.0-only 兼容（保留版权声明即可并入）。注意运行时依赖里 **`aubio` 是 GPL-3.0**（仅被 `get_mean_peak` 用到）；若只在 `Scripts/` 里做开发期离线评估、不随 app 分发，风险可忽略，但仍建议避开该函数。`pyloudnorm` MIT、`librosa` ISC，均无问题。

---

## 3. 与我们现状的正面对照

| 维度 | Kumone 现状 | walkywalker | Sony | 谁更强 |
|---|---|---|---|---|
| 节拍分析 | vDSP 自研，Ellis DP 逐拍跟踪 + 自相关 BPM + 对数正态先验 | QM 插件 + **固定 tempo 网格 + 显式 1/8 拍相位消解** | 不做 | 各有所长（见 §4 第 9 条 b） |
| 配对能否混 | **五信号三档门**（响度/音色/BPM/调性/人声） | **不判断**（全局重采样绕过） | 不适用 | **我们** |
| 出点 | 尾窗内最高分乐句边界；有 outro 时钉在渐弱起点 | **最后一个 drop 的结束小节**，outro 不播 | 不适用 | **他们**（对痛点②） |
| 入点 | `introEnd` / 其后第一个 downbeat | **曲内第一个 drop**（或 drop 前的无鼓 buildup），intro 在出曲底下播 | 不适用 | **他们** |
| 重叠长度 | 先定 16/8/4 小节，再找容得下的边界；crossfade 由 tail/intake capacity 算 | 由入曲结构隐含决定 | 不适用 | 打平，思路正交 |
| 低频交接 | `bassSwapOffset = overlap/2`（几何中点） | **在各自 drop 的那一拍阶跃**（音乐事件） | 不适用 | **他们**（思路） |
| 音量曲线 | 分档淡入淡出 + staged EQ + 扫频 + beat-sync echo | 16 级线性台阶 | 不适用 | **我们** |
| 变速 | TimePitch（变速不变调） | 重采样（音高跟随） | 不适用 | 待盲测 |
| 段落特征 | RMS 包络（1s）+ 乐句边界打分 | **每 4 小节低频能量 + onset 密度 → drop/breakdown 段** | 不适用 | **他们** |
| 响度归一 | **无** | per-track 参考电平 + 全局 trim | **BS.1770 LUFS + 削顶保护** | **他们两个** |
| 客观评估 | 无（`decisions.md` 只打印决策信号，不测渲染结果） | 无 | **四组特征 + MAPE 体系** | **Sony** |
| 人声 | 启发式 vocalActivity（修复中）+ Mel-Band RoFormer 分离 | **没有**（列在 Further Work） | 不需要（有 ground truth） | **我们** |

---

## 4. Inspiration 清单

工作量为**推测**，按"一个熟悉本代码库的人"的粒度估。凡涉及 `TrackAnalysis` 新字段的都要**升 `version` 并触发全量重分析**（`automix-spec.md` §4）。

### A. 直接可落地

**1. 参考响度 + 过渡增益补偿 — 消灭痛点④**
出处：`walkywalker/src/bass_detector.cpp:46-57`（参考电平定义）+ `src/dj.cpp:18-24` 与 `src/tune.cpp:153-173`（全局 trim）；削顶保护见 `sony/automix/utils_data_normalization.py:79-80`。
做法：`TrackAnalysis` 增 `referenceLevel: Float` = **超过全曲 RMS 峰值 80% 的那些帧的 RMS 均值**（不是全曲均值——它天然忽略 intro/outro/安静段，是廉价的母带响度代理）。`TransitionPlanner` 据此产出 `incomingTrimDB`，让入曲在**整首**（不只是重叠区）上以一个恒定 deck 增益偏置播放，向出曲/队列基准靠拢；trim 夹在 ±6 dB，并带削顶保护。
额外收益：顺手解决"下一首突然大声 6 dB"这个与过渡无关的日常抱怨。
风险：RMS ≠ 感知响度。先上 RMS 版本，若 audition 显示误差大再考虑 K 加权（§2.2a）。
**工作量：0.5–1 天**（analyzer +15 行、`AutoMixTypes` +1 字段 + version bump、planner/engine +30 行、`decisions.md` 加一列），另加一次语料重跑。

**2. A/B 渲染做电平匹配后再盲听 — 评估卫生**
出处：ISMIR 2022 听测协议（所有刺激归一到 −23 dBFS）。
做法：`audition render` / S1 的 A/B 脚本在落盘前把每个渲染归一到统一积分电平。
为什么急：**现有的盲听结论可能全部带响度偏置**，尤其 vocalDuck 这种直接改电平的手法（§2.4）。
**工作量：~1 小时。**

**3. 响度连续性客观指标进 `decisions.md`**
出处：`sony/automix/utils_data_normalization.py:523`（loudness）、`:899`（dynamic）、`:44`（滑动均值 + MAPE 聚合）。
做法：对 `renders/*.wav` 算短时 RMS-dB 轨迹，报告两个数——**相对 pre-roll→post-roll 线性插值的最大偏离**、**交接点阶跃量**；并入现有分布摘要与 borderline 列表。
价值：把痛点④从"听出来的"变成"可回归的"，也是第 1 条的验收依据。
**工作量：~0.5 天。**

**4. onset 密度特征（每小节 onset 计数）**
出处：`walkywalker/src/analyzer.cpp:60-66` + `dj.cpp:147-162`（"每 4 小节 < 16 个 onset = 可进场"）。
做法：我们已有 `TrackAnalyzer.onsetEnvelope`（`:714`），在其上做峰值计数按小节聚合，存进 `TrackAnalysis`。RMS 说"响不响"，它说"忙不忙"，两个轴。
价值：本身就是第 5、6 条的前置件；单独也能改进 intro/breakdown 判定。
**工作量：~0.5 天**（含 version bump）。

### B. 值得实验

**5. 选点改为结构事件驱动 — 痛点②的核心，本次调研最高价值项**
出处：`walkywalker/src/analyzer.cpp:77-115`（drop 段落检测）+ `src/dj.cpp:82-101`（出点=drop 结束、入点=drop 开始）+ `dj.cpp:147-162`（buildup 入点）。
做法分两步：
 (a) `TrackAnalyzer` 增 `sectionRanges: [(start, end)]`：低频带能量（mel 低段已有）按每 4 小节积分，用"`max - value < 0.4 * range`"规则圈出高能段落并合并。
 (b) `TransitionPlanner` 的出/入点搜索改写：出点 = **最后一个高能段落的结束**（不再钉在 `outroFadeStart`）；入点候选 = **入曲第一个高能段落的起点**，以及它前面 8 小节步长上第一个低 onset 密度的段落；重叠长度由"入点到入曲第一个高能段落"的距离导出，仍受现有 ceiling 约束。
连带修掉 stem 层自己写在注释里的那个问题（切点钉在渐弱里 ⇒ 分离出来是空的，`TransitionPlanner.swift:218-230`）。
风险：这是 planner 的结构性改动，必须靠 `audition batch` 的分布摘要 + 盲听逐步推进；华语流行的段落结构不像 DnB 那样由低频定义，"0.4 × range"这个阈值几乎肯定要重标（**推测**：可能得改用全带 RMS + onset 密度联合判据）。
**工作量：3–5 天**（analyzer +40 行、planner 出入点搜索重写 ~150 行、大量语料调参）。

**6. bassSwap 从几何中点改为音乐事件**
出处：`walkywalker/src/dj.cpp:93-97` + `src/tune.cpp:65-67`（"低频属于正在自己 drop 里的那一首"）。
做法：把 `bassSwapOffset` 从 `overlap/2` 改成"重叠区内入曲第一个高能段落起点对应的 downbeat"；出曲低频在同一点撤走。是否保留 ramp（他们是阶跃）做 A/B。
依赖第 5 条的 `sectionRanges`。用第 3 条的**低频占比指标**验收——这条指标存在的意义就是量化 bass 是否堆叠。
**工作量：0.5 天**（在第 5 条之上）。

**7. 变速改用 Varispeed（音高跟随）盲测**
出处：`walkywalker/src/tempo.cpp`（libsamplerate 重采样，音高随速度变）对比我们的 `AVAudioUnitTimePitch`。
做法：在 `audition` 里加一个 `--style` 开关，同一对渲染两版（TimePitch vs Varispeed，±4% 以内），电平匹配后盲听。
理由：DJ 惯例在小幅变速上就是音高跟随；对**整首已混母带**做时间拉伸比对单轨更容易出相位涂抹。**推测**：Varispeed 更自然，但 ±4% 的音高偏移在人声上可能被察觉。
**工作量：0.5–1 天**（deck 链路换节点是图结构改动，`automix-stems-predev.md` §1.1 提醒过运行中重连会抛异常，需在离线渲染路径先验证）。

**8. EQ 匹配：音色矫正而不是只降级**
出处：`sony/automix/utils_data_normalization.py:89-131` + `evaluate.py:316-340`（先平滑参考谱）。
做法：从两首的 `melProfile` 差值导出 3 段（低/中/高）架式增益偏移，夹在 ±3 dB，在重叠区内 ramp 上去、过渡后释放。用已有的 per-deck 4-band EQ 实现。目标是让部分 `neutral` 配对重新拿到长混。
风险：EQ 抽动会很明显；参考谱必须先平滑（Sony 用 Savitzky-Golay，不平滑会把梳状结构烙进滤波器）。用第 3 条的谱质心轨迹指标把关。
**工作量：~2 天 + 调参。**

**9. 拆解 beatMatched 的门槛统计 — 痛点③**
**两个仓库都没有现成答案**（walkywalker 用全局重采样绕过，Sony 不做过渡）。但调研过程中定位到两个可操作的抓手：
 (a) **先量化再动数字**。0/47 是一串门的**合取**结果：`bpmConfidence ≥ 0.6`（双方）→ 折算 BPM 差 ≤ 8% → `tier == .compatible`（它自己又要求响度差 < 3 dB **且** 音色距离 < 0.25 **且** 调性 3 度以内）→ 双侧 RMS 稳定 → 无人声撞车。在 `decisions.md` 里**逐门统计淘汰数**（多少对死在置信度、多少死在 BPM 差、多少死在 tier、多少死在稳定性），③ 就从猜谜变成一张柱状图。**工作量：~3 小时**，应当排在任何门槛调参之前。
 (b) **更诚实的可网格化置信度**。walkywalker 的"必须存在一段 40 拍全部落在 2sd 内的窗口"（`analyzer.cpp:308-338`）是一个廉价的"这首歌到底能不能上网格"判据，与我们基于自相关峰值的 `bpmConfidence` 正交。以及它的固定 tempo 网格 + 显式相位消解（`analyzer.cpp:366-493`）结构上比逐拍 DP 更适合"在 60 秒之后调度一个 16 小节重叠"——DP 拍点会漂。**注意**：`developer.rst` 的 *Limitations* 里作者自己把节拍网格列为**该项目的首要缺陷**，所以只借结构，别照搬。**工作量：探索性，1–2 天做离线对比。**

### C. 只是有趣

**10. mix 级起伏编排**（`walkywalker/src/dj.cpp:103-145`）：预留 N% 的过渡为 breakdown 型并**均匀铺开**在曲序里，让整份 mix 有拱形结构。我们的队列由用户驱动且可随机，大部分不适用；退化版本"别连着三次都做长混"或许有点意思，但价值低。

**11. double drop 过渡**（`walkywalker/src/dj.cpp:191-217`）：两首歌的 drop 故意叠在一起，中高频留着旧曲再放 16 小节。极度 DnB 专属，对华语流行曲库几乎无意义；而且它自己的代码里就写着 "todo look for a good spot rather than hard code"（+16 小节是写死的）。

**12. Sony 的声像（SPS）与混响归一化**（`utils_data_normalization.py:133`、`:476`）：我们的过渡保持立体声原样、不加混响。SPS 理论上能检出"两首歌立体声像不兼容"，但相对①–④是极罕见的失败模式。混响那部分还因 IR 版权无法复现。

**13. "分析失败就整首排除"**（`walkywalker/src/automix.cpp:122-138`）：对一个离线 mixtape 生成器是对的，对播放器不成立——我们只能用退化链，而这个我们已经有了。

---

## 5. 许可证结论（一句话版）

- **walkywalker/automix = GPL-2.0-only**（且含 GPLv2 的 QM-DSP 与 Mixxx 衍生代码）。与 LGPL-3.0-only **双向不兼容**。**只能看思路，代码一行不能进 repo**；落地实现应从其 `developer.rst` 的自然语言描述出发独立编写。
- **sony/fxnorm-automix = MIT**。可并入（保留版权声明）。但真正想要的只有 `utils_data_normalization.py` 里那几段特征数学，在 Swift/vDSP 重写反而更省事；若作为开发期离线脚本放进 `Scripts/`，注意其依赖 **`aubio` 是 GPL-3.0**（仅 `get_mean_peak` 用到），避开或替换即可。
- 两条路线都不引入新的运行时 SPM 依赖，`automix-spec.md` §9 的"零新依赖"原则不受影响。

---

## 6. 来源

- walkywalker/automix — <https://github.com/walkywalker/automix>（GPL-2.0，24★，末次 push 2023-03-28）
  - 开发者文档：<https://github.com/walkywalker/automix/blob/master/developer.rst>
  - 引用到的文件：`src/analyzer.cpp`、`src/dj.cpp`、`src/tune.cpp`、`src/channel.cpp`、`src/bass_detector.cpp`、`src/filter.cpp`、`src/tempo.cpp`、`src/automix.cpp`
  - 上游：[qm-dsp](https://github.com/c4dm/qm-dsp)（GPLv2）、[Mixxx](https://mixxx.org/)（GPLv2）、[fidlib](https://uazu.net/fidlib/)、[libsamplerate](https://github.com/libsndfile/libsamplerate)
  - 论文背景：Davies & Plumbley, *Context-Dependent Beat Tracking of Musical Audio*（QM BeatTrack 的算法出处）
- sony/fxnorm-automix — <https://github.com/sony/fxnorm-automix>（MIT，149★，末次 push 2024-03-11）
  - 论文：Martínez-Ramírez et al., *Automatic music mixing with deep learning and out-of-domain data*, ISMIR 2022 — <https://arxiv.org/abs/2208.11428>（全文：<https://ar5iv.labs.arxiv.org/html/2208.11428>）
  - 项目页：<https://marco-martinez-sony.github.io/FxNorm-automix/>
  - 引用到的文件：`automix/utils_data_normalization.py`、`automix/evaluate.py`
- 本项目对照：`docs/automix-spec.md`、`docs/audition.md`、`docs/automix-stems-predev.md`、`docs/automix-stems-s1-report.md`、`Sources/Kumone/Core/Player/Analysis/TransitionPlanner.swift`、`Sources/Kumone/Core/Player/Analysis/TrackAnalyzer.swift`
