# AutoMix 转场即乐谱 预研

> 状态:设计(2026-08-29) · 未写任何产品代码,待听感负责人审阅后动工
> 前置阅读:[`automix-spec.md`](automix-spec.md) · [`automix-structure-predev.md`](automix-structure-predev.md) · [`automix-queue-predev.md`](automix-queue-predev.md) · [`automix-stems-s1-report.md`](automix-stems-s1-report.md)

---

## 0. 一页摘要

这是**从"混得顺"到"混得有想法"的那一跳**。

过去几个月的工作把接缝磨平了:tempo ramp 让变速像呼吸,dominant-deck 填掉了 −6 dB 的中段深坑,vocal exchange 让两个人声不再打架,队列重排把 beatMatched 相邻对从 13% 抬到用户缓存上的 69%。但听感负责人放着 club hip-hop 得出的判词没有变:今天的 beat-switch 仍然是**渐变逻辑**——一条从 A 到 B 的连续函数,参数由门槛选出;而不是**有意识设计的逻辑**——一个被作曲出来的时刻。

差距不在参数值,在四层结构:

1. **时间单位**:我们的参数是秒和斜率(`overlapDuration`、`rampLeadSeconds`、dB/s);club 的单位是小节和拍——动作落在**格点上**,不是格点之间的包络。
2. **动作词汇表**:我们的词汇全是包络(fade / filterSweep / echoOut / stem 增益 lane);club 的词汇是离散手势——正拍直切(cut-on-the-one)、slam(全频带直入)、drums break(几小节纯鼓垫再进歌)、tension cut(落拍前一拍静默)、echo throw(末句甩进 delay 然后切)。**我们今天连"一拍静默"都表达不出来。**
3. **瞄准方向**:今天先选出点,入点是"安全的开唱处",blend 把两头缝起来——**blend 是主角**。设计出来的转场先瞄准:入曲的**哪个格点**(hook / drop)落在**哪里**,出曲的退场从那个点**倒推**出来。
4. **意图层**:手势应由**素材语义**选择——hiphop×hiphop 硬网格是切的文化,ballad 该长 blend,EDM 该对齐 drop,rock / live / 古典该**克制**(结构预研遗留的"语境克制"就是这根轴的零端)。今天的选型只有 tier 门,没有语义。

**方案**:**转场即乐谱(TransitionScore)**——一小段类型化的事件谱,以 seam 为原点、按小节/拍寻址,由意图层按素材语义选出,由编译器落成音频。执行主路径是**预渲染 segment**(那里可以放任意合成的音频、样本级精确);没有乐谱时,决策与声音**与今天 byte 级一致**。规划器命名意图、编译器实现它——这是 `vocalExchange` 已经验证过的分工,乐谱是它的一般化。

**不做的事**:不动引擎图(双 deck 图纹丝不动)、不动判定门(tier / 五信号 / climax guard 照旧)、不做 spinback 等新 DSP、不做 4-stem。乐谱只在 beatMatched 且格子可信时出现;segment 被拒绝时听到的是今天的曲线。

**代价**:样本级手势只能走 segment 路径(live 自动化是 20 ms tick,切不干净);带 stems 的乐谱要付 ~2×overlap+15 s 的预渲染跑道;一张写坏的乐谱比一个写好的 blend 更冒犯——所以**存疑时 blend**是整个意图层的第一条规则。

---

## 1. 现状与失效模式

### 1.1 时间单位:秒与斜率,不是小节与拍

引擎里"何时发生什么"的表达方式,今天全部是连续量:

| 表达 | 单位 | 消费点 |
|---|---|---|
| `overlapDuration` / `bassSwapOffset` | 秒 | `TransitionAutomation.frame` 逐 tick 求值 |
| `rampLeadSeconds` / `rampReleaseSeconds` | 秒(斜率 = %/s) | tempo ramp |
| `rideDB` + 释放斜率 | dB/s | gain ride |
| `StemEnvelope` breakpoint | 秒 + dB,**点间 dB 线性插值** | stem lane |

唯一按格子说话的地方是选点:出入点吸附 downbeat,`overlapBars` 记小节数。但那只是**端点**在格上;端点之间发生的一切都是插值。乐谱意义上的"第 3 小节第 1 拍发生一次切"——一个离散事件——在这套表达里没有名字。

### 1.2 词汇表:全是包络,没有手势

现有全部词汇逐一对照 club 手势:

- `fade` / `filterSweep` / `echoOut`:三种**退场曲线**;
- staged EQ / dominant-deck / preSwapPlateau:**blend 的形状**;
- `StemTechnique` 各案 + `StemEnvelope`:四条**增益 lane**,点间线性——它*可以*写出阶跃(两点相隔几毫秒),但没有任何生产者这样写过,而且 lane 叠在 fader 之上、只在 stem 路径存在。

**"一拍静默"的不可表达是可以证明的**:live 路径的自动化是 1/50 s tick(`PlaybackEngine.tickInterval`),fader 阶跃最坏差 20 ms——128 BPM 下一个十六分音符是 117 ms,20 ms 的抖动落在切音上就是 flam;而 `StemEnvelope` 想写全频带静默需要四条 lane 同时 −60 dB,这要求两侧都做 stem 分离——为了一拍安静付 ~30 s 的分离,荒谬。今天没有一条路径能干净地给出一拍静默。

### 1.3 瞄准方向:blend 是主角

今天的选点顺序(`TransitionPlanner`):

1. 出点:结构候选(末段副歌 end 优先)+ climax guard + 歌词行尾吸附;
2. 入点:第一个核心段落的 start(`inPointChoice`);
3. overlap:由 tail/intake capacity 算出,blend 把两头缝起来。

出点问的是"出曲在哪结束最不冒犯",入点问的是"入曲从哪开始最安全"——**没有人问"入曲最好的那个小节应该落在哪里"**。结构预研已经看见了这一层(§2.3 的 drop 对齐),但排到 P4 一直没做:它在"渐变逻辑"的框架里是个特例补丁,在"乐谱"的框架里是常态——瞄准就是写谱的第一步。

### 1.4 意图层:门槛不是语义

tier 门回答"这一对**能承受**多激进的转场"(响度 / 音色 / 速度 / 调性 / 人声五信号),从不回答"这一对**文化上该用**什么手势"。后果对称地坏在两头:

- hiphop×hiphop、双方 128 BPM 硬网格、能量顶格——五信号全绿,得到的是一条 16 s 的礼貌 blend。切的文化里,这叫不敢切;
- rock / live 录音——真人鼓手的网格漂移让 `bpmConfidence` 时好时坏,全频段墙声让 EQ 交接两头都浑;一旦碰巧过了门,得到的 blend 是**文化上错误**的:把一首摇滚溶解掉本身就是冒犯。听感负责人已单独确认 rock 与今天的 blend 不合。结构预研 roadmap #4"语境克制"说的就是这个,但克制与激进是同一根轴,应该由同一个意图层给出,而不是再立一个独立的门。

### 1.5 已就位的地基(本方案全部踩在上面)

- **segment 路径**:`TransitionSegmentRenderer` → 一段任意合成的 `AVAudioPCMBuffer`,样本级精确,两端各 0.5 s 同料交叉隐藏拼接;stem lane 在 offline 路径逐样本施加增益(`StemTechniqueLayer.apply`)。**segment 里可以放任何声音——这就是乐谱的舞台。**
- **marker → compile 分工**:planner 发 `.vocalExchange` 标记,`Audition.VocalExchange.compile` 拿着 `.lrc` 落成 `StemEnvelope`,落不成就可见地降级。乐谱沿用同一分工。
- **结构信号**:`sections` 有 `.drop` kind、能量、人声密度、重复次数;`beats`/`downbeats` 可现算网格稳定度;`melProfile` 是风格指纹。瞄准与意图层的原料都在 sidecar 里,**不需要 bump 分析版本**。
- **听感回路**:audition A/B 渲染 + 盲听流程 + debug panel + feedback.jsonl 的 seam 标记——每个阶段都有现成的验收器。

---

## 2. 方案

### 2.1 事件谱数据模型

一张乐谱是**以 seam 为原点、按小节/拍寻址的一小串离散事件**,横跨 `[−preBars, +postBars]`:

```swift
/// 共享小节格上的一个位置。bar 0 beat 0 = seam(“the one”:入曲瞄准点落地的那一拍)。
/// 负 bar 在出曲侧,按出曲(已弯速)的格子解析;非负 bar 按入曲的格子解析。
struct GridPosition: Codable, Equatable {
    var bar: Int
    var beat: Double   // 0..<拍数,允许 0.5(反拍)
}

enum ScoreEvent: Codable, Equatable {
    /// 出曲在此格点满切(≤10 ms 边沿)。cut-on-the-one 的“cut”半边。
    case cutOut
    /// 入曲在此格点全频带直入,无淡入无 EQ 分频。slam / cut 的“in”半边。
    case slamIn
    /// 全场静默这么多拍(两侧全部 lane 拉到 −60 dB)。tension cut。
    case silence(beats: Double)
    /// 出曲从上一个歌词行尾起甩进 beat-synced delay,湿声延续到此格点后切干。
    case echoThrow
    /// 入曲以“伴奏垫”入场(人声 lane −60 dB),持续 bars 小节后人声进入。
    /// drums-break 的 2-stem 近似——诚实地说:这不是 drums-only(见下)。
    case bedIntro(bars: Int)
}

struct ScoredEvent: Codable, Equatable {
    var at: GridPosition
    var event: ScoreEvent
}

struct TransitionScore: Codable, Equatable {
    var preBars: Int      // seam 前动用出曲多少小节(v1 ≤ 4)
    var postBars: Int     // seam 后动用入曲多少小节(v1 ≤ 8)
    var events: [ScoredEvent]
}
```

挂载点仿照 `stemTechnique`:`TransitionStyle.score: TransitionScore? = nil`。**nil 是默认、是今天的一切**——planner 不写它时,决策、曲线、渲染逐字段与现状一致,这是"回退路径与今天 byte 级一致"的结构保证,不是测试保证。

**v1 手势库的可表达性**,逐条对账:

| 手势 | 今天能否表达 | 途径 | 缺口 / 诚实条款 |
|---|---|---|---|
| cut-on-one(cutOut+slamIn 同格点) | segment 内**可** | 编译成整混 lane 的阶跃(见 2.2),逐样本施加,边沿 5–10 ms 半余弦(DJ 推子的物理速度;0 ms 是爆音不是切) | live 路径**不可**:20 ms tick 切不齐,不做近似 |
| slam(单独) | segment 内可 | 同上,只动入侧 | 入曲若带弯速,直入瞬间 vocoder 水声裸露(见 §4.3) |
| tension cut | segment 内可 | 两侧整混 lane −60 dB 一拍;或更干净:渲染后直接写零样本 | −60 dB 即为静默(`StemEnvelope.minGainDB` 的既有判断);live 路径不可 |
| echo throw | **今天就近乎可** | 每 deck 的 delay 单元已在图里(`DeckChain`,echoOut 先例),offline 同图;“末句”定位复用 `.lrc` 行尾(`VocalExchange` 先例) | 与 echoOut 的差别在收尾:湿声之后是**切**不是淡;无歌词时降级为 echoOut |
| bedIntro(伴奏垫) | 今天就可 | 入侧 `incomingVocal` lane −60 dB N 小节——现有 `StemEnvelope` 一字不改就能写 | **不是 drums break**:2-stem 的“伴奏”含旋律与和声,是“垫”不是“鼓垫”。真 drums-only 需要 4-stem 模型,与 `stagedStemSwap` 同一条已声明的缺口,推迟 |
| spinback / brake | **推迟** | 需要变速尾 DSP(倒放/减速渲染),全新能力 | 不进 v1;乐谱模型给它留了事件位,仅此而已 |

**16 breakpoint 上限不约束乐谱。** 上限是每 lane 16 点(`StemEnvelope.validate` 按 lane 计),一个 tension cut 每 lane 花 4 点,单手势够用;但一张多手势的谱可能顶到上限。所以编译器**不经过** `StemEnvelope` 表达全频带手势——它把乐谱直接降成渲染期的逐样本增益掩码(下节),上限只对"stem lane 表达的手势"存在,而那类手势(bedIntro)单张谱只有一个。

### 2.2 编译与执行路径

分工照抄 `vocalExchange` 的先例,只是升了一级:

```
意图层(planner/decide) ──选──▶ TransitionScore(标记:格点 + 事件)
ScoreCompiler(渲染前) ──编译──▶ 逐样本增益掩码 ×2(出/入整混)
                                + StemEnvelope(仅 bedIntro 需要)
                                + delay 参数(仅 echoThrow 需要)
OfflineTransitionRenderer ──渲染──▶ TransitionSegment(样本级,任意合成)
PlaybackEngine ──splice──▶ 听众
```

- **编译发生在渲染前、格子已知处**:编译器拿最终 `BeatMatchedPlan` 的 beats/downbeats(出侧按 `outgoingRate` 弯过的格子——segment 的 pre-roll 本来就渲染在恒定弯速上,`TransitionSegmentRenderer.handoff` 的既有构造),把 `GridPosition` 解析成样本号。格点解析失败(拍网格覆盖不到 postBars)⇒ 整谱作废、可见降级到无谱计划,同 `vocalExchange` 降 duck 的礼仪。
- **新渲染能力只有一件**:`OfflineTransitionRenderer.Options` 增加两条**整混 lane**(出/入各一),语义与 stem lane 相同(叠在 fader/EQ 之上、逐样本),但作用于整混、**不触发分离**。这就是"一拍静默为什么今天要付 30 s 分离"的解法:全频带手势本来就不需要 stems。工程量小:`StemTechniqueLayer.apply` 的增益循环已经存在,少的只是一个不分离的输入路径。
- **segment 准入条件放宽一格**:今天 `TransitionSegmentRenderer.render` 要求 `stemTechnique != nil`(`SegmentError.noStemTechnique`);改为"有 stem 技法**或**有乐谱"。无 stems 的纯乐谱 segment(cut-on-one、tension cut)**不付分离成本**:渲染 ~1 s,跑道需求从 `2×overlap+15 s` 塌缩到 margin 一档——15 s 足够,60 s 的 lead 绰绰有余。带 bedIntro 的谱付入侧单边分离(~1× 实时),跑道公式照 `stemPrerenderRunway` 的算法补一项即可。
- **与 120 s 决策提前量的合账**:队列模式最坏情况下,选定→重下播放音质+重分析吃 ~40 s,剩 ~80 s;16 s overlap 的双侧 stems segment 需要 47 s——今天已经是紧的。纯乐谱 segment 反而**放松**了这笔账;唯一变紧的是"乐谱+bedIntro"(单侧分离 ~overlap+15 s),仍在 80 s 内。跑道不够时按现有礼仪拒绝。
- **segment 被拒绝 / 用户 seek 拆除时**:live 路径播**今天的曲线**——乐谱是 style 上的装饰,`plan` 本身(出入点、overlap、rate)不因谱而变,所以 live 回退不是"劣化的谱",是完整的、被调了几个月的 blend。journal 与 debug panel 记录"谱未上演",A/B 时能分清听到的是哪个版本。
- **live 路径永不近似乐谱**。20 ms tick 上的"差不多的切"比 blend 更糟(§4.1 的第一原则)。这条是刻意的不作为,写进契约。

### 2.3 瞄准优先的选点(吸收结构预研 P4)

顺序反过来:**先定入曲的目标格点 T,出曲的退场倒推**。

1. **目标格点 T**(入曲,按优先级):`.drop` 段 start > 首个 chorus start > 首个核心段 start(= 今天的 `inPointChoice`,即无结构信息时瞄准层自动退化为现状)。结构预研 P4 的"drop 对齐"由此吸收:它不再是一个特例开关,而是"瞄准"在 EDM 素材上的自然取值。
2. **seam 放置**:乐谱转场(cut/slam)把 **seam = T**——"the one"就是 drop / hook 落下的那拍;blend 转场沿用 P4 原设计,把 **overlap 终点 = T**(出曲尾巴叠在 build 上,交接落在 drop 上)。两者是同一次瞄准的两种落法,由手势决定。
3. **出曲退场倒推**:入点定了(`T − postBars` 或 `T − overlap`),出点在现有候选机制里选**离目标时刻最近的合格候选**——候选生成、climax guard、歌词行尾吸附**一概不动**。守门优先于瞄准:倒推出的理想出点撞上 climax guard 窗口时,让位给下一个合格候选;让无可让时放弃瞄准、回到今天的排序。**门不为谱开。**
4. **与结构置信度的耦合**:T 只从 `sections` 取,`structureConfidenceGate` 照旧;无结构的曲目整个瞄准层不运行,选点逐字段回到现状。

### 2.4 意图选型层(吸收"语境克制")

意图层输出的不是布尔,是一个**手势预算**:从 0(克制:gapless / 短 fade,连 blend 都收着)到满格(切文化)。克制与激进从此是同一根轴,roadmap #4 不再单独立项。全部输入都是既有信号,**没有 genre 标签**:

| 信号 | 来源 | 计算 | 语义 |
|---|---|---|---|
| 网格稳定度 | `beats`/`downbeats` 现算(不 bump 版本) | downbeat 间隔的 CV;真人鼓手 >~1%,量化制作 <0.3%(阈值待语料标定) | 低稳定 ⇒ 格点动作全部禁用——切在漂移的格上必错半拍 |
| 能量与人声密度 | `sections.energy` / `vocalDensity` | seam 两侧段落值 | 双高能硬网格 ⇒ 切文化;低能高人声 ⇒ 长 blend |
| drop 存在 | `sections` 的 `.drop` | 有无 | 瞄准 drop + slam(2.3) |
| 频谱墙 | `melProfile` | 带间形状的平坦度(全频段满 ⇒ 平) | 墙声 ⇒ 克制(EQ 交接与 blend 都不适合)——rock/live 的信号代理 |
| 结构置信度 | `structureConfidence` | 既有门 | 低 ⇒ 无谱无瞄准 |
| 专辑连播 | 队列元数据 | 原队列相邻 + 同专辑 | 站下(stand down):专辑序是作品的一部分,gapless 是正确答案 |

选型规则(v1,全部可单独关):

- **切文化**(cut/slam/tension cut):双方网格稳定 + `bpmConfidence` 双高 + seam 两侧段能量都 ≥ 全曲 0.8 + tier compatible。四个条件缺一给 blend。
- **drop 瞄准 + slam**:入曲有 `.drop` 且置信度过门。
- **echo throw**:clash tier 的升级款——今天 clash 已经给 echoOut,有 `.lrc` 时升级为 throw(末句甩尾),无歌词维持 echoOut。这是唯一一个非 compatible tier 也能拿到的手势。
- **bedIntro**:入曲开局人声密度高(没有自然器乐入口)且 stems 就绪时,给它造一个入口。
- **克制端**:网格稳定度低 / 频谱墙 / 专辑连播 / 结构置信度低 ⇒ 预算归零:不出谱,且(新行为,独立开关)blend 收短到 neutral 档——rock 用户已确认今天的 blend 文化上不合身,收短是比"照混"更少错的默认。
- **存疑时 blend**:任何信号缺失或骑线,回到今天的路径。一张错的谱的冒犯度远高于一条平庸的 blend——这条规则的优先级高于以上全部。

规则以 `Config` 旋钮 + `PlanTrace` 新 stage(`intent`)落地:每个手势为什么给/为什么没给,决策台逐门直方图直接继承。

### 2.5 渐进交付

| # | 内容 | 可听验证(全部走现有 A/B 渲染 + 盲听 + feedback.jsonl seam 标记回路) | 依赖 |
|---|---|---|---|
| P1 | 乐谱模型 + 编译器 + 整混 lane + segment 准入放宽;**一张谱端到端**:cut-on-one(出侧 echo throw 收尾) | club 对(hiphop×hiphop)8 对 A/B:谱版 vs 现 blend 版盲听;回退 byte 级一致性测试;拒绝路径演练(拆 segment 听 live 回退) | 无 |
| P2 | 瞄准层(T 选取 + seam 放置 + 倒推),含吸收 P4 的 drop 对齐 | EDM 歌单专项;出入点位移分布报告;climax guard 回归测试 | P1 验收 |
| P3 | 意图层:手势预算 + 克制端(吸收 #4) | rock/live 语料 stand-down 命中率人工核对;误切率(格点错半拍)统计;全库 sweep 谱触发率 | P2 验收 |
| P4 | 手势库扩张:tension cut、bedIntro,逐手势 S1 式盲听 | 每手势独立 A/B(仿 stems S1 的三技法盲测) | P3 验收 |

P1 刻意选 cut-on-one + echo throw:前者是"离散事件"最纯的检验(表达不出一拍边沿,整个模型就是空谈),后者复用最多现有件(delay 单元、`.lrc`、echoOut)。两者都**不需要 stems**——P1 全程零分离成本,跑道无压力,失败了也只赔一个渲染选项。

---

## 3. 不做的事

- **不动 `PlaybackEngine` 的图**:双 deck 图固定不重连,delay 单元用现有的;乐谱全部发生在 offline 渲染与决策层。
- **不动判定门**:tier、五信号、climax guard、结构置信度门一个不改。乐谱改变的是"格点上放什么",不是"这一对能不能混"。
- **live 路径不近似乐谱**:20 ms tick 上没有切,不装有。
- **不做 spinback / brake / scratch**:需要新 DSP,推迟;模型给事件位留了名字。
- **不做 4-stem**:drums break 以"伴奏垫"近似并如实命名;真鼓垫与 `stagedStemSwap` 同批等 4-stem 模型。
- **不做 genre 标签 / 外部元数据推断**:意图层只吃已有音频信号 + 队列元数据。
- **不做 crossfade tier 上的格点手势**:无共享网格,"格点"无从谈起;echo throw 是唯一例外(它锚在出曲自己的格上)。

---

## 4. 风险与对策

1. **一张坏谱比一条好 blend 更糟(最大风险)**。切错半拍、slam 在错误的段落上,冒犯度远超任何渐变的平庸。对策是分层的:意图层"存疑时 blend"优先级最高;每个手势独立 `Config` 开关,盲听不过单项关回;P1 只在人工挑选的 club 对上开,全库 sweep 只统计触发率不放行;feedback.jsonl 的 seam 标记做上线后的哨兵——谱版 seam 的标记率高于 blend 版即回退。
2. **格点错位是切的死穴**。downbeat 相位错一拍,fade 听不出来,cut 全暴露。对策:网格稳定度门 + `bpmConfidence` 双高门是硬前置;编译器对 seam 附近的 beat 间隔做一次自检(相邻间隔突变 >3% 即弃谱);错了有 journal 可追。
3. **phase-vocoder × 切的相互作用**。slam 直入的那一瞬,入 deck 若还带着弯速,vocoder 水声没有任何东西遮掩——正是这次"入曲全程弯速导致 vocoder wash"诊断的裸奔版。对策:切文化手势只在弯速 ≤2% 的对上给(切文化对本来 BPM 就近);或编译期把入侧弯速在 seam 后第一小节内 glide 归零,复用 `rampGlideBackFromSwap` 的既有思路。两案 P1 期间 A/B 定夺。
4. **跑道压力**。乐谱把更多 seam 推向 segment 路径;segment 被拒 ⇒ 谱不上演。对策:纯乐谱 segment 渲染 ~1 s、几乎不占跑道(唯一贵的是 bedIntro 的单边分离);拒绝路径就是今天的 blend,不是残谱;`prerender refused` 的既有 journal 行照常报账,验收时统计"谱计划 vs 谱实演"的落差率,落差 >20% 则手势预算要向跑道低头(bedIntro 降级为无谱)。
5. **live 回退的听感断层**。用户 seek 后同一 seam 从"设计过的切"变回 blend,前后两次听感不一致。对策:接受它——一致性让位于"回退必须是完整的 blend"这条更硬的规则;debug panel 与 journal 标明实演版本,盲听样本只取实演一致的 seam。
6. **意图层误判克制端**。网格稳定度与频谱墙都是代理信号,可能把量化的摇滚放进切文化、把 lo-fi hiphop 判成墙。对策:阈值在 audition 语料上先标定后启用(P3 的验收就是命中率核对);克制端错杀的代价只是"少一张谱",错放的代价才是冒犯——阈值一律往克制方向偏。

---

## 5. 验收

- **回退不变性(先于一切听感)**:意图层不出谱时,`plan` 输出、live 曲线、渲染结果与主干 byte 级一致;`score == nil` 的 `TransitionStyle` 走遍全部既有测试零改动。
- **P1**:club 对 8 对盲听,谱版被判"更有意图/更像 DJ"的 ≥5 对,且**没有一对**被判"比 blend 更冒犯";切边沿实测 ≤10 ms;拒绝路径演练一次通过(拆 segment 后 live 播完整 blend,journal 有账)。
- **P2**:EDM 专项听感确认"叠在 build、落在 drop"成立;climax guard 回归测试全绿;出入点位移报告经听感负责人过目。
- **P3**:rock/live 抽样 12 首,克制端命中 ≥10;切文化误触发(格点错拍被听出)为 0;全库 sweep 报告谱触发率与各手势分布。
- **P4**:每个新手势独立 S1 式盲测,胜过或持平无谱版才默认开启;输了的留在 console 手动可选(`instrumentalOut` 的先例)。
- **上线后哨兵**:feedback.jsonl 中谱实演 seam 的标记率 ≤ blend seam 的标记率;高出即单手势回退。
