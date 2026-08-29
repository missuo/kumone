# AutoMix 技术规格

> 状态：草案 v1（2026-08-27）
> 分支：`worktree-automix`

Kumone 的 AutoMix：队列自动衔接时，在乐句边界做节拍对齐的无缝过渡——BPM 相近时变速对拍混音，不适合时自动退化为普通交叉淡出，再不行则无缝硬切（gapless）。对标 Apple Music AutoMix 的完整形态。

## 已对齐的决策

| 决策点 | 结论 |
|---|---|
| 引擎策略 | **全量替换**：所有播放走 AVAudioEngine，删除 AVPlayer 路径 |
| 缓存层 | **完整缓存层**：所有播放先落磁盘缓存（LRU，上限可设，默认 2 GB） |
| 平台 | **macOS 先行**：引擎代码两端编译，AutoMix 功能开关先只在 macOS 启用 |
| 过渡深度 | **完整 AutoMix**：BPM/downbeat 分析 + 乐句选点 + 变速对拍，含自动退化链 |
| 节拍分析 | **Accelerate/vDSP 自研**，零新依赖。aubio/BTrack 等均为 GPL，与本项目 LGPL-3.0-only 不兼容 |

## 1. 总体架构

```
PlayerService（队列/模式/scrobble，保持现有 API 面不变）
   │
   ├─ PlaybackPipeline        每首歌的 resolve → download → analyze 流水线
   │    ├─ AudioCache         磁盘缓存（音频文件 + 分析 sidecar）
   │    ├─ ProgressiveLoader  边下边播解码器（启播用）
   │    └─ TrackAnalyzer      vDSP 节拍/能量分析（后台，一次性）
   │
   ├─ TransitionPlanner       纯函数：两份分析结果 → 过渡方案
   │
   └─ PlaybackEngine          AVAudioEngine + 双 deck，样本精度调度
```

原则：`PlayerService` 对 UI 暴露的 `@Published` 状态和方法签名不变（`play/pause/next/seek/…`），改造只发生在它的私有引擎部分。渲染线程相关代码不进 MainActor。

## 2. PlaybackEngine（Core/Player/Engine/）

双 deck 结构，A/B 轮换：

```
deckA: AVAudioPlayerNode → AVAudioUnitTimePitch → AVAudioUnitEQ ┐
                                                                ├→ mainMixerNode → output
deckB: AVAudioPlayerNode → AVAudioUnitTimePitch → AVAudioUnitEQ ┘
```

- **音量分层**：用户音量挂 `mainMixerNode.outputVolume`（对应现有 `volume` 属性）；过渡淡入淡出用各 deck 自己的 `playerNode.volume`，互不干扰。
- **变速**：`AVAudioUnitTimePitch.rate`（变速不变调），仅在对拍过渡的重叠区内做 ±8% 以内的缓变（线性 ramp 到目标 rate，过渡结束后新曲 ramp 回 1.0）。
- **EQ**：每 deck 一个低架滤波，用于对拍过渡时的低频交接（bass swap，见 §5），普通 crossfade 不启用。
- **格式**：per-deck 按文件的 `processingFormat` connect，采样率差异由 mixer 自动转换。
- **时钟**：以 `playerNode.playerTime`（sampleTime/sampleRate）为准换算进度，替代现有 `addPeriodicTimeObserver`；对 UI 仍以 0.2s 间隔（`CADisplayLink`/Timer）推送到 `PlaybackClock`。
- **seek**：`stop()` + 从新位置重新 `scheduleSegment`。过渡窗口内（重叠已开始）seek 则取消过渡、目标 deck 独占。
- **调度 API**（示意）：

```swift
final class PlaybackEngine {          // 内部专用串行队列，非 MainActor
    func load(_ source: DeckSource, on deck: Deck)   // 完整文件或渐进流
    func play(deck: Deck, from: TimeInterval)
    func scheduleTransition(_ plan: TransitionPlan,  // 样本时间轴上预排
                            from: Deck, to: Deck)
    func cancelScheduledTransition()
    var position: (deck: Deck, seconds: TimeInterval) { get }
}
```

事件回调（曲目自然结束、过渡中点已过）通过 `AsyncStream` 发回 MainActor，替代 `didPlayToEndTimeNotification`。

## 3. AudioCache 与加载（Core/Storage/、Core/Player/Engine/）

### AudioCache

- 目录：`~/Library/Caches/Kumone/Audio/`（可被系统清理，符合"缓存"语义）。
- Key：`trackID + servedLevel + 音源标识（netease / unblock:源名）`。**不缓存 URL**（NetEase 直链有时效），每次未命中都重新 resolve 后立刻下载。
- 写入：`.part` 临时文件 → 完成后原子 rename；同 key 并发请求合并为一次下载。
- LRU：按 mtime 淘汰，上限默认 2 GB，设置页可调（512 MB / 2 GB / 8 GB / 不限）。
- Sidecar：`<key>.analysis.json` 存分析结果，随音频一起淘汰。
- 试听片段（`isTrial`）**不缓存**——避免完整版权限变化后命中残缺文件。

### 启播路径（ProgressiveLoader）

全量替换后没有 AVPlayer 的流式兜底，启播延迟必须自己解决（hires FLAC 可达 40–80 MB，等全量下载不可接受）：

- `URLSession` 数据流 → `AudioFileStream`（AudioToolbox 解析包）→ `AVAudioConverter` 解码为 PCM → 按 ~0.5s 块 `scheduleBuffer` 进当前 deck；同一份字节流同步写入缓存 `.part` 文件。
- 下载完成后 rename 落缓存；**下一次**播放（含过渡调度中的"下一曲"）即走 `AVAudioFile` + `scheduleSegment` 的精确路径。
- 缓存命中时跳过 Loader，直接 `AVAudioFile`。
- 边界：流式 deck 也维护样本计数，进度/seek 语义与文件路径一致（流式态 seek = 断流重连 Range 请求；M1 可先简化为等待缓存完成再允许精确 seek，按实测体验定）。

### 预取流水线（PlaybackPipeline）

- 当前曲开播成功后，立即对**下一曲**（`upcomingTracks.first`，含 FM 的 `fmUpcoming`）执行：resolve URL → 下载落缓存 → 触发分析。
- 当前曲剩余 ≤ 30s 时若下一曲仍未就绪，过渡自动退化（见 §5 退化链）。
- 队列变化（jumpTo/addToPlayNext/removeFromUpcoming/toggleShuffle）时重新计算预取目标，取消过期任务（沿用现有 `resolveGeneration` 思路，扩展为 pipeline generation）。

## 4. TrackAnalyzer（Core/Player/Analysis/）

纯 vDSP/Accelerate 实现，后台执行（`Task.detached`，utility QoS），每曲一次、结果持久化 sidecar。

**输入**：缓存音频 → `AVAudioFile` 读取 → 混单声道、重采样到 22 050 Hz。
**流程**：

1. **Onset 检测**：STFT（窗 1024、hop 256，vDSP FFT）→ mel 压缩 → spectral flux（半波整流一阶差分）→ onset envelope。
2. **BPM 估计**：onset envelope 自相关 + 对数正态先验（中心 ~120 BPM），输出 BPM 及置信度；同时保留 ×2/÷2 候选（double/half-time）。
3. **Beat tracking**：动态规划（Ellis 2007 风格）在 onset envelope 上求最优拍点序列 → beat grid。
4. **Downbeat 估计**：假设 4/4，按每拍低频能量 + flux 周期性投票选小节起点。
5. **乐句边界**：downbeat 网格上取 8/16 小节格点，结合 RMS 能量包络的显著跃变（段落切换）打分排序。
6. **结构特征**：整曲 RMS 包络（1s 粒度）、尾部渐弱检测（outro fade 起点）、首个有效乐句起点（intro 结束点）。

**输出**：

```swift
struct TrackAnalysis: Codable {
    let bpm: Double
    let bpmConfidence: Double        // 0–1
    let beats: [TimeInterval]
    let downbeats: [TimeInterval]
    let phraseBoundaries: [TimeInterval]   // 按适合度排序前 N 个
    let rmsEnvelope: [Float]         // 1s 粒度
    let outroFadeStart: TimeInterval?
    let introEnd: TimeInterval
    let version: Int                 // 算法版本，不匹配则重分析
}
```

**验证**：分析器配套一个离线 CLI 入口（`swift run` 子命令或测试 target），对本地文件输出 BPM/拍点，用一组已知 BPM 的歌曲做回归断言（±2 BPM、拍点相位误差 < 70 ms 视为通过）。这是 M3 的验收依据。

## 5. TransitionPlanner（Core/Player/Analysis/）

纯函数：`plan(outgoing: TrackAnalysis?, incoming: TrackAnalysis?, context) -> TransitionPlan`。

```swift
enum TransitionPlan {
    case beatMatched(BeatMatchedPlan)   // 变速对拍
    case crossfade(duration: TimeInterval, outPoint: TimeInterval, inPoint: TimeInterval)
    case gapless                        // 尾对头无缝硬切
}

struct BeatMatchedPlan {
    let outPoint: TimeInterval      // 出曲乐句边界（含出曲 outro 前的最后一个高分边界）
    let inPoint: TimeInterval       // 入曲第一个 downbeat（跳过 intro 静音）
    let overlapBars: Int            // 4 或 8 小节
    let outgoingRate: Float         // 双方各让一半，均 ≤ ±4%
    let incomingRate: Float
    let bassSwapAt: TimeInterval    // 重叠区中点：出曲低架切除、入曲低架恢复
}
```

**决策规则**（自上而下，第一个命中即止）：

1. 双方分析齐备、`bpmConfidence ≥ 0.6`、BPM 差（含 double/half-time 折算）≤ 8% → **beatMatched**。重叠区默认 4 小节，双方能量包络都平稳则 8 小节。
2. 分析齐备但不满足对拍条件 → **crossfade**。时长按能量定：出曲有 `outroFadeStart`（本身渐弱）→ 短淡入（2s，出曲不再压低）；否则 5s 等功率曲线（equal-power）。
3. 任一侧分析/下载未就绪、或 `duration < 45s` → **gapless**。
4. 完全不参与过渡的情形（planner 之外拦截）：`repeatMode == .one`、试听片段（裁剪尾部不属于原曲）、AutoMix 设置关闭。

**手动切歌**（next/jumpTo）：不走 planner，固定 0.8s 快速 crossfade（下一曲已缓存时），否则立即硬切——保持"手动切就是要立刻换"的直觉。

**FM 模式**：正常参与 AutoMix（`fmUpcoming` 首曲进预取管线）。

## 6. PlayerService 改造

- `startPlaying` → 调 pipeline：resolve（沿用现有 songURL + unblock 逻辑，不动）→ 缓存命中或 ProgressiveLoader → deck 播放。
- `handleItemEnded` → 改为引擎回调：自然衔接时曲目状态切换发生在**过渡中点**（beatMatched 为 bassSwapAt，crossfade 为重叠中点）：`currentTrack`/歌词/NowPlaying metadata/scrobble 均以中点为界。
- **Scrobble**：出曲被裁掉尾部仍按"完整播放"上报（seconds = 原 duration），与 Apple Music 行为一致。
- 失败链（`consecutiveFailures`）、`resolveGeneration` 防竞态、状态持久化逻辑保留，generation 扩展覆盖 pipeline。
- iOS 的 AVAudioSession/中断处理迁到引擎层，行为不变（本期不启用 AutoMix，但引擎必须在 iOS 正常工作——全量替换意味着 iOS 也跑新引擎）。

## 7. 设置与 UI

- `SettingsManager` 新增：
  - `automixEnabled: Bool`（默认 **开**，macOS；iOS 本期隐藏且强制 gapless 路径）
  - `audioCacheLimit`（枚举，默认 2 GB）+ 设置页显示当前占用、一键清空。
- NowPlaying/PlayerBar：过渡进行中显示轻量指示（如进度条尾部渐变或小图标），不做复杂动效，具体样式实现时定。
- 调试面板（DEBUG only）：当前曲 BPM/置信度、下一过渡的 plan 类型与选点，便于调参。

## 8. 里程碑

| 阶段 | 内容 | 验收 |
|---|---|---|
| **M1 引擎替换** | PlaybackEngine + AudioCache + ProgressiveLoader，单 deck 使用，行为与现状完全对齐（播放/暂停/seek/音量/试听/unblock/失败跳曲/状态恢复/NowPlaying/scrobble/iOS 会话） | 现有全部播放场景手测无回归；曲间为 gapless |
| **M2 Crossfade** | 双 deck 过渡 + 预取流水线 + 设置开关 + 手动切歌快淡 | 队列连播无缝淡出；下一曲未就绪时正确退化 |
| **M3 分析器** | TrackAnalyzer + sidecar + 离线验证 CLI | 回归集：BPM ±2、拍点相位 <70ms |
| **M4 真 AutoMix** | TransitionPlanner + 变速对拍 + bass swap + 乐句选点 + 调试面板 | 同 BPM 段电子/流行歌单上过渡对拍不跑偏；混合歌单正确退化 |

每个里程碑独立可合并、可发布（M1/M2 本身就是用户可感知的改进）。

## 9. 风险与对策

- **渐进解码复杂度**（M1 最大风险）：AudioFileStream 对 mp3/aac 成熟，FLAC 需走 `AudioFileStreamOpen` 的 FLAC 支持（macOS 15 可用）；若某格式流式解码不稳，兜底为"该格式等缓存完成再播 + 播放前提示缓冲中"。
- **Swift 6 并发**：引擎与分析器不进 MainActor，deck 状态由引擎内部串行队列守护，对外只暴露 `Sendable` 值和 AsyncStream；language mode v5 下先以 `@unchecked Sendable` + 断言过渡。
- **NetEase URL 时效**：resolve 与下载原子化在同一 pipeline task 内，URL 永不落盘。
- **分析准确度**：自研 beat tracking 对无鼓点/自由节拍曲目会低置信，退化链保证听感底线——置信度阈值宁高勿低。
- **许可证**：全部自研 + 系统框架，无新第三方依赖，LGPL-3.0-only 不受影响。
