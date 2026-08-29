# AutoMix 结构驱动选点 预研

> 状态:设计(2026-08-28) · 未写任何产品代码,待听感负责人审阅后动工
> 前置阅读:[`automix-spec.md`](automix-spec.md) · [`automix-stems-predev.md`](automix-stems-predev.md)

---

## 0. 一页摘要

**要解决的问题**:人耳对"切点错位"的敏感度远高于对"混音技法粗糙"的敏感度——切在副歌半句上,再完美的 vocal exchange 也救不回来。而现在的出入点来自能量启发式:`phraseBoundaries` 找的是"小节格上能量跳变最大的地方",`introEnd` 找的是"第一处不安静的地方"。它们回答的是**哪里安静**,不是**哪里是乐句的句号**。

**方案**:两条正交的信号补进来,都作用在选点层,不动引擎:

1. **结构分段**(纯 vDSP,零新依赖):在现有单趟 STFT 之上做 beat 同步的自相似矩阵 + novelty 检测,把歌切成 intro/verse/chorus/bridge/outro 段落,副歌靠"重复次数 × 能量 × 人声密度"识别。出点从"能量跳变打分的小节线"升级为"末段副歌唱完的那一刻";入点从"第一处响的 downbeat"升级为"第一个核心段落的起点"。
2. **歌词桥接**(几乎零工作量,单独可先落地):app 已经从 NeteaseAPI 拿到逐行时间戳歌词,但从未落盘——`VocalExchange.compile` 只认音频旁的 `.lrc` sidecar,所以 **app 里的 vocalExchange 今天几乎必然降级到 vocalTrough**。预取时把歌词写成 `.lrc` sidecar,交接点立刻从"人声波谷"变成"这句唱完"。

**不做的事**:不改引擎、不加实时 DSP、不动 stems 链路。结构分段置信度不足时逐字段回退到现有能量启发式——回退路径与今天 byte 级一致。

**代价**:`TrackAnalysis.currentVersion` 要 bump,全库分析 sidecar 作废重算(每首约 1–2 s,预取时后台完成,听感无影响)。

---

## 1. 现状与失效模式

选点相关的信号今天有四个,全部在 `TrackAnalyzer` 里,消费者是 `TransitionPlanner`:

| 信号 | 实现 | 消费点 |
|---|---|---|
| `phraseBoundaries` | 8/16 小节 downbeat 格上,前后 4 s RMS 均值差打分,取前 10 | beat-matched 出点搜索、crossfade 出点、stem 出点 |
| `outroFadeStart` | 尾部单调下降段起点 | crossfade 出点锚定、响度窗口锚定 |
| `introEnd` | 首个 ≥25% 峰值能量的秒,吸附到 downbeat | beat-matched / crossfade 入点 |
| `vocalActivity` | 逐秒人声活跃度(v5,四线索融合) | 人声冲突门、stem 选点 |

### 1.1 出点的失效模式

`phraseBoundaries` 是"能量意义上的段落感",它无法区分:

- **副歌结束** vs **breakdown 开始**——两者都是能量跳变,但一个是完美出点,另一个切进去等于把高潮拦腰斩断;
- **真句号** vs **假句号**——能量平稳的歌(大量流行、R&B)整首 CV 都低,跳变分数全靠噪声排序,top-10 基本随机;
- 且整个格子建立在 downbeat 相位正确、4/4 假设成立之上,相位投票错一拍,全部候选点错一拍。

`outroFadeStart` 只识别"自己淡出的歌"。语料里 14/16 有淡出所以它常在,但**没有淡出的歌**(硬结尾、渐强收尾)会落到 `crossfadeOutPointShare` 之后的 phraseBoundaries 兜底——回到上面的问题。

### 1.2 入点的失效模式

`introEnd` 是"第一处不安静的地方":

- 清唱开场(a cappella intro)第一秒就过 25% 门限——入点落在人声裸露处,是最坏的叠加窗口;
- 慢 build 的电子乐 intro 会把入点推得很晚甚至推过 build,错过"叠在 build 上、在 drop 处交接"这个最经典的 DJ 手势;
- 它对"这段是 intro 还是第一段主歌"没有概念,只有能量。

### 1.3 歌词断链(app 独有,语料上不存在)

调参台语料的音频旁都有 `.lrc`,所以离线试听里 `vocalExchange` 的交接点是"歌词行结束"。但 app 路径:

- `PlayerService.loadLyrics` 从 NeteaseAPI 拉歌词进内存(`ParsedLyrics`),**从不落盘**;
- `Audition.VocalExchange.compile`(`TransitionSegmentRenderer` 调它)只认 `Lyrics.load(for: outgoingURL)`——预取缓存目录里的音频旁边没有 `.lrc`;
- 结果:app 里的 vocalExchange 交接点退化到 `vocalTrough`(人声包络最安静的秒),整个 S2 调出来的"这句唱完再交接"在产品里没生效过。

这是本计划里性价比最高的一条:改动极小,当天可听出差别。

---

## 2. 设计

### 2.1 A 线:结构分段(`TrackAnalyzer` 新增 `sections`)

**输入**:现有单趟 STFT 已经产出逐帧 log-mel(40 band)、chroma(12 bin)、RMS——不加第二趟 FFT。新增的全部计算发生在这些特征之上。

**流程**(Foote 2000 novelty + 聚类标注,全 vDSP 可写):

1. **Beat 同步池化**:逐帧特征按 `beats` 分组取均值,得到每拍一行的特征矩阵(timbre 40 维 + chroma 12 维,各自 z-score)。一首 4 分钟的歌约 400–600 拍——后续所有矩阵都是几百阶,毫秒级。
2. **自相似矩阵 + novelty**:拍×拍余弦相似度矩阵,对角线上滑动棋盘核(checkerboard kernel,核宽约 16 拍)得 novelty 曲线,峰值即边界候选,吸附到最近 downbeat。
3. **段落标注**:边界切出的段落,按段均特征做凝聚聚类(阈值制,不定 k)。同簇 = 同段落类型。然后打标签:
   - **chorus**:重复次数最多的簇中,能量 × 人声密度最高者;
   - **intro/outro**:首/末段,且与其它段落簇距离远或能量低;
   - **drop/高潮**(电子乐语境):簇内能量显著高于全曲、且以低频能量跃升开场的段;
   - 其余为 **verse/bridge**(不强分,planner 只关心"核心段"与否)。
4. **置信度**:novelty 峰的显著度(峰值/邻域均值)+ 聚类分离度合成一个 `structureConfidence`。低于阈值时 `sections` 置空,下游自动走现有路径。

**输出**(进 `TrackAnalysis`,bump `currentVersion`):

```swift
struct Section: Codable, Sendable {
    var start: TimeInterval        // 已吸附 downbeat
    var end: TimeInterval
    var kind: Kind                 // intro / verse / chorus / bridge / drop / outro
    var repetition: Int            // 同簇段落数
    var energy: Float              // 段均 RMS / 全曲峰值
    var vocalDensity: Float        // 段均 vocalActivity / 全曲均值
}
var sections: [Section]
var structureConfidence: Double
```

**验证**(动 planner 之前):

- 语料 48 首全部跑分段,web 决策台把段落色块画在现有能量/人声时间轴上,叠加歌词行——**副歌边界应与重复歌词块对齐**,这是不需要标注数据的免费 ground truth;
- 人工抽查 12 首(每歌单 2 首),边界误差 >1 小节或标签错的比例超过 1/4 就回炉,不进 planner。

### 2.2 B 线:歌词桥接(独立落地,先行)

1. `PlayerService` 预取流水线在音频落盘后,把已拉到的 `ParsedLyrics` 序列化成标准 `.lrc` 写到音频旁(复用语料约定,`Lyrics.sidecarURL`);当前曲目的歌词同样回写,保证"出歌"侧可用;
2. `VocalExchange.compile` 与 `Audition.Lyrics` 零改动——app 与调参台从此走同一条歌词路径;
3. 缓存清理沿用音频缓存的生命周期(歌词与音频同目录同名,删音频顺手删);netease 歌词接口拿不到或纯音乐时不写文件,行为同今天。

**歌词衍生信号**(给 2.3 用,均从 `.lrc` 现算,不进 `TrackAnalysis`):

- **末句结束时刻**:最后一行时间戳 + 估算行长(下一行间隔或行均值)——"整首歌唱完了"的真锚点,比 `outroFadeStart` 更接近听者的"歌结束了"感受;
- **行间长空隙**(≥8 s):器乐桥段/间奏,天然的叠加窗口;
- **行边界格**:出点微调吸附目标——出点永远不落在一行中间。

### 2.3 C 线:planner 选点改造(唯一动决策的部分)

原则:**候选生成换血,判定门不动**。响度/音色/速度/调性/人声五信号门、tier 结构、bar 升级搜索全部保持;变的只是"候选出入点从哪来、按什么排序"。全部新行为挂 `Config` 开关 + `PlanTrace` 门记录,`sections` 为空时逐字段回退现状。

**出点**(替换 `phraseBoundaries` 排序,应用于 beat-matched / crossfade / stem 三处搜索):

1. 候选 = 尾窗内的段落边界,按优先级排:**末段副歌的 end** > 任意 chorus end > 任意段落边界 > phraseBoundaries(回退);
2. 吸附:候选点向前吸附到最近的歌词行结束(有 `.lrc` 时),避免切在行中;
3. 新守门(可配置):出点不得落在**末段副歌开始之前的 16 小节内**——不在高潮到来前把歌送走。这是"切点冒犯感"的最大来源之一,现有启发式完全无感知。

**入点**(替换 `introEnd` 的角色):

1. 默认:第一个核心段(verse/chorus/drop)的 start 所在 downbeat——清唱开场、慢 build 都被段落类型正确处理;
2. **drop 对齐**(电子乐手势,`sections` 里有 drop 段才启用):当入歌有 drop 且 overlap ≥ 8 小节时,把 overlap 的**终点**对齐到 drop start——出歌的尾巴叠在入歌的 build 上,交接落在 drop 落下的一拍。这是一条新的 plan 形态偏好而非新 plan 类型:仍是 beatMatched/crossfade,只是入点 = drop start − overlap;
3. 入点变更连带 `intakeCapacity` 的锚点同步(它现在从 `introEnd` 起算爬升)。

**Trace**:新增 `structure` stage 的门记录(候选来源、置信度、末副歌守门、drop 对齐是否启用),决策台的逐门淘汰直方图直接继承。

### 2.4 D 线:工具链

- web 决策台:段落色块 + 歌词行刻度叠加进现有时间轴;AI bundle 加入段落表和 chosen 出入点的段落语境("出点在末段副歌结束后 1 小节");
- 语料 sweep:planner 改造前后各跑一遍 48 首全配对,报告出入点位移分布 + 逐门淘汰变化,改造后人工盲听 8 对(沿用现有 A/B 流程)。

---

## 3. 里程碑

| # | 内容 | 可听验证 | 依赖 |
|---|---|---|---|
| P1 | 歌词桥接(2.2):预取写 `.lrc` | app 内 vocalExchange 交接点落在行尾 | 无 |
| P2 | 结构分段(2.1)+ 决策台可视化,**不动 planner** | 决策台肉眼核对段落 vs 歌词重复块 | 无 |
| P3 | planner 出入点改造(2.3,不含 drop 对齐)+ sweep + 盲听 | 8 对 A/B | P2 验收 |
| P4 | drop 对齐手势 | 电子乐歌单专项听感 | P3 验收 |

P1 与 P2 无依赖可并行;P1 极小,建议最先合。

---

## 4. 风险

1. **分段错误比没有分段更糟**(切在错标的"副歌结束"上)。对策:`structureConfidence` 门 + P2 先行人工验收 + 每个新行为独立 Config 开关,盲听不过就单项关回。
2. **analysis 版本 bump 的重算成本**。全库 sidecar 作废,预取路径每首 +1–2 s 后台分析。可接受;但要和其它待 bump 的分析改动(若有)攒同一次 bump。
3. **4/4 与 downbeat 相位仍是地基**。分段吸附 downbeat,相位错则边界整体偏一拍——但这与现状同罪,不新增风险;novelty 边界本身不依赖相位,错位可被 2.1 的验证抓到。
4. **NeteaseAPI 歌词质量参差**(逐行时间戳偏移、纯音乐误标)。行为守则:歌词只用于"吸附"与"守门",从不单独产生候选点;时间戳可疑(乱序、越界)整份丢弃。

---

## 5. 明确不做

- 不引入分段模型(MSAF/SpecTNT 类):novelty + 聚类在"选切点"这个用途上够用,且保持零依赖原则;
- 不做非 4/4 拍号检测;
- 不做入歌队列重排(那是另一个方向,单独立项);
- 不动 `PlaybackEngine` 与 stems 链路——本计划全部发生在分析与决策层。
