#if os(macOS)
import Foundation

// The tuning surface's description of `TransitionPlanner.Config`: one entry
// per knob, with the range a slider should span and the sentence that says
// what moving it does. Kept next to the audition facade rather than inside
// the planner because it exists purely for the tuning loop — the planner
// itself never reads it.
//
// Everything the web console shows is generated from this list, so adding a
// knob to `Config` and one row here is the whole change.

extension TransitionPlanner.Config {
    struct Field: Sendable {
        let name: String
        /// Which panel the console groups it under.
        let group: String
        /// One sentence: what does turning this up do?
        let blurb: String
        let min: Double
        let max: Double
        let step: Double
        /// Digits the console formats the value with.
        let digits: Int
        let read: @Sendable (TransitionPlanner.Config) -> Double
        let write: @Sendable (inout TransitionPlanner.Config, Double) -> Void
    }

    private static func field(
        _ name: String, _ group: String, _ blurb: String,
        _ min: Double, _ max: Double, _ step: Double, _ digits: Int = 2,
        _ path: WritableKeyPath<TransitionPlanner.Config, Double>
    ) -> Field {
        Field(name: name, group: group, blurb: blurb, min: min, max: max, step: step,
              digits: digits,
              read: { $0[keyPath: path] },
              write: { $0[keyPath: path] = $1 })
    }

    private static func intField(
        _ name: String, _ group: String, _ blurb: String,
        _ min: Double, _ max: Double,
        _ path: WritableKeyPath<TransitionPlanner.Config, Int>
    ) -> Field {
        Field(name: name, group: group, blurb: blurb, min: min, max: max, step: 1, digits: 0,
              read: { Double($0[keyPath: path]) },
              write: { $0[keyPath: path] = Int($1.rounded()) })
    }

    /// A flag, shown as a 0/1 slider. The console renders every knob from this
    /// list, so an on/off knob is a two-value one rather than a new widget.
    private static func boolField(
        _ name: String, _ group: String, _ blurb: String,
        _ path: WritableKeyPath<TransitionPlanner.Config, Bool>
    ) -> Field {
        Field(name: name, group: group, blurb: blurb, min: 0, max: 1, step: 1, digits: 0,
              read: { $0[keyPath: path] ? 1 : 0 },
              write: { $0[keyPath: path] = $1 >= 0.5 })
    }

    static let fields: [Field] = [
        // --- Tier gate: the five signals and the lines they cross.
        field("neutralLoudnessDB", "tier",
              "两首歌音量差多少就不算“很搭”了。调大 = 更容忍音量落差，愿意给更长的叠加。",
              0, 15, 0.1, 2, \.neutralLoudnessDB),
        field("clashLoudnessDB", "tier",
              "音量差大到这个地步就直接放弃，只给最短的礼貌淡出。",
              0, 20, 0.1, 2, \.clashLoudnessDB),
        field("neutralTimbreDistance", "tier",
              "两首歌的音色差多远就不算“很搭”。参考：同一首歌自己跟自己比大约 0.03，最差 0.11。",
              0, 1, 0.005, 3, \.neutralTimbreDistance),
        field("clashTimbreDistance", "tier",
              "音色差到这个地步就当成“差异很大”。目前只会命中语料里最不搭的一成。",
              0, 1, 0.005, 3, \.clashTimbreDistance),
        field("clashTempoRatio", "tier",
              "速度差到这个比例（已按倍速关系折算）就当成“差异很大”，前提是两边拍子都数得准。",
              0, 1, 0.005, 3, \.clashTempoRatio),
        intField("clashKeyDistance", "tier",
                 "两首歌的调在五度圈上隔几步就算不合，把“很搭”降一级。和声永远不会单独判定“差异很大”。",
                 0, 6, \.clashKeyDistance),
        field("keyConfidenceThreshold", "tier",
              "对调性的把握低于这个数，就当作没听出调，和声完全不参与判断。",
              0, 1, 0.01, 2, \.keyConfidenceThreshold),
        field("vocalClashRatio", "tier",
              "交接窗口里的人声密度是各自平常的几倍就算“太密”。两边都超过 = 两个主唱会打架，叠加缩短。",
              0.5, 2.5, 0.01, 2, \.vocalClashRatio),
        intField("loudnessWindow", "tier",
                 "比音量时，出曲结尾和入曲开头各取多少秒来算平均值。",
                 3, 45, \.loudnessWindow),
        field("loudnessTargetLUFS", "tier",
              "整首歌的播放响度补偿要把每首歌拉到哪个“统一音量”（LUFS）。"
                  + "这个数字越低，几乎每首歌被压得越狠——本机 157 首缓存里没有一首比 −14 更安静，"
                  + "所以 −14 不是“大家聚在一起的位置”，而是“所有人都被压下去的地板”（中位 −5.0 dB）。"
                  + "调高 = 歌本身响一些、听起来不闷；但高过某首歌自己的响度就只能靠提升，"
                  + "而提升受峰值余量限制、通常给不了，那首歌就会低于目标、跟别人对不齐。",
              -24, -6, 0.5, 1, \.loudnessTargetLUFS),
        field("rideMaxDB", "tier",
              "交接时最多把入曲的音量临时【抬高】多少 dB，过渡走完再用每秒 0.3 dB 悄悄推回原位——"
                  + "就是真人 DJ 手放在推子上的那一下。整首歌的响度补偿拉不平“安静的尾奏对上火热的开场”"
                  + "这种局部落差，这一项专治它。抬高还会再受入曲自己的峰值余量限制，不会把歌顶爆。"
                  + "设成 0 = 整个 ride 关掉（压低那一侧也一起关），音量差这条线退回只看整曲补偿之后的残差。",
              0, 8, 0.25, 2, \.rideMaxDB),
        field("rideMaxCutDB", "tier",
              "交接时最多把入曲的音量临时【压低】多少 dB。压低本身不占峰值余量也不会有杂音（推子这时还在 0），"
                  + "但它要花时间松手：这个上限同时也决定了新歌开头要在“比它自己该有的音量更小声”里待多久。"
                  + "压太深听感上就是新歌一进来发闷、然后慢慢“变好”。"
                  + "调大 = 敢压得更狠、音量差这条线看到的残差更小，但那个坑也更深更长。",
              0, 12, 0.25, 2, \.rideMaxCutDB),
        boolField("loudnessCompensation", "tier",
                  "开 = 先按每首歌的母带响度做一次播放增益补偿、交接时再做一次临时的音量微调（见 rideMaxDB），"
                  + "然后才看剩下的音量差；"
                  + "关 = 两级增益都不做，直接拿原始音量差去撞上面两条线（补偿功能上线前的老行为）。",
                  \.loudnessCompensation),

        // --- Beat-match gate.
        field("bpmConfidenceThreshold", "beatmatch",
              "两首歌的拍子都要数到这个把握以上，才谈得上让它们踩同一个拍子。",
              0, 1, 0.01, 2, \.bpmConfidenceThreshold),
        field("maxBPMDeltaRatio", "beatmatch",
              "速度差在这个比例以内才允许对拍。调大 = 更多曲子够得着对拍，但也更容易听出变速。",
              0, 0.5, 0.005, 3, \.maxBPMDeltaRatio),
        field("maxRateDeviation", "beatmatch",
              "为了对上拍子，每首歌最多允许被拉快/放慢多少。调大 = 更多曲子对得上，但音色开始走味。",
              0, 0.2, 0.002, 3, \.maxRateDeviation),
        boolField("tempoRampEnabled", "beatmatch",
                  "开 = 变速不再是“一脚踩上去”，而是提前一段慢慢滑上去、交接完再慢慢滑回来"
                      + "（真人 DJ 的手法）；此时上面两条线让位给 rampMaxBPMDeltaRatio / "
                      + "rampMaxRateDeviation 这两条更宽的线。关 = 回到上线前的老行为，"
                      + "老的两条线重新生效。",
                  \.tempoRampEnabled),
        field("rampLeadSeconds", "beatmatch",
              "提前多少秒开始把出曲的速度滑到对拍速度（滑行在出点前 0.5 秒结束）。"
                  + "调大 = 变速更慢更听不出来，但出曲更早就已经不是原速了。"
                  + "默认 12 秒 = 6% 的变速按每秒 0.5% 的可听阈算出来的。",
              2, 30, 0.5, 1, \.rampLeadSeconds),
        field("rampReleaseSeconds", "beatmatch",
              "叠加结束、只剩入曲在响之后，用多少秒把它的速度放回原速。注意方向跟 rampLeadSeconds 相反："
                  + "变速期间一直在过变调器，会有“水声”，所以这里是越短越干净，只要别短到变成一个台阶。"
                  + "调大 = 速度回落更平缓，但水声拖得更久。",
              1, 20, 0.5, 1, \.rampReleaseSeconds),
        boolField("rampGlideBackFromSwap", "beatmatch",
                  "开 = 入曲的速度从【低频交接那一刻】就开始往原速滑回去，把整段出曲退场的时间都花在这上面，"
                  + "叠加结束时它已经回到原速；关 = 老行为，整段叠加都把入曲摁在变速上，"
                  + "交接完之后再用 rampReleaseSeconds 放回来。变速总量一样，差别是那点“水声”落在哪里："
                  + "老行为把它全放在入曲接过场子、然后独自在响的那段——最藏不住的位置，"
                  + "听感就是新歌一进来像在水里、过一会儿才“好了”。"
                  + "代价：交接点之后两首歌的拍子会慢慢错开（几百毫秒），但那时出曲低频已经交出去且正在淡出，"
                  + "听不出来。",
                  \.rampGlideBackFromSwap),
        field("rampMaxBPMDeltaRatio", "beatmatch",
              "开了 tempoRampEnabled 时生效的速度差上限（替代 maxBPMDeltaRatio）。"
                  + "滑行让更大的变速听不出来，所以这条线可以放宽。",
              0, 0.5, 0.005, 3, \.rampMaxBPMDeltaRatio),
        field("rampMaxRateDeviation", "beatmatch",
              "开了 tempoRampEnabled 时生效的单曲变速上限（替代 maxRateDeviation）。",
              0, 0.2, 0.002, 3, \.rampMaxRateDeviation),
        field("rampBendShareOutgoing", "beatmatch",
              "对拍要凑的速度差里，【出曲】承担多少比例（剩下的给入曲）。只在 tempoRampEnabled 开着时生效。"
                  + "变调器的“水声”只跟“变速持续了多久”有关，而出曲的变速是在它退场的路上、被入曲和分频"
                  + "交接盖住的；入曲的变速却是它接过场子、独自在响的时候——同样的变速，一边听不见，"
                  + "一边听得一清二楚。0.5 = 老的对半分；调大 = 把脏活推给出曲。"
                  + "注意任何一边都不会超过 rampMaxRateDeviation：超了就卡在上限、余下的自动落到另一边，"
                  + "所以速度差本来就贴着上限的那些曲子会自己退回接近对半分。",
              0.5, 1, 0.05, 2, \.rampBendShareOutgoing),
        boolField("dominantDeckBlend", "beatmatch",
                  "开 = 长的对拍叠加里始终只有一首歌“坐镇”：出曲先稳住不动，入曲在它下面（被切掉低频）"
                      + "先升上来待命，到低频交接那一刻才接过场子，然后出曲才退场。"
                      + "关 = 两条推子对称交叉（老行为）——那样在 30 秒叠加的正中间两边都只有 −3 dB、"
                      + "而且各自只占半个频谱，中段会明显变虚，就是“强—弱—强”那个坑。",
                  \.dominantDeckBlend),
        field("preSwapPlateau", "beatmatch",
              "交接之前，入曲先升到多高待命（推子 0–1）。太低 = 新歌还没“立住”就被交了场子，"
                  + "像剪切；太高 = 顶到出曲头上，两边抢。同时也是余量旋钮：真要削峰就削它。",
              0.5, 1, 0.01, 2, \.preSwapPlateau),
        field("stableCV", "beatmatch",
              "要叠满 8 或 16 小节，两首歌这段的音量起伏得多平稳。调大 = 更宽松，更容易拿到长叠加。",
              0.05, 1, 0.01, 2, \.stableCV),
        field("sectionSteadyCV", "beatmatch",
              "如果这段叠加完整地落在同一个段落里（结构层认出来的），平稳度就按这条更宽松的线算。"
                  + "理由：CV 本来就是在猜“这段中间会不会换编曲”，而“整段都在一个段落里”是直接的证据，"
                  + "比猜准。只放宽、不否决：还是得过这条线。没有结构信息的歌完全走老线。",
              0.05, 1, 0.01, 2, \.sectionSteadyCV),

        // --- Overlap length.
        field("maxOverlap", "overlap",
              "不管怎么算，两首歌最多叠这么久（秒）。",
              2, 60, 0.5, 1, \.maxOverlap),
        field("minOverlap", "overlap",
              "不管怎么算，至少也要叠这么久（秒），免得过渡短到像切歌。",
              0.2, 10, 0.1, 1, \.minOverlap),
        field("maxOverlapShare", "overlap",
              "叠加最多能占掉较短那首歌的多大比例，避免短曲子被过渡吞掉一半。",
              0.02, 0.6, 0.01, 2, \.maxOverlapShare),
        field("neutralOverlapCap", "overlap",
              "“一般般”这一档最多叠多久（秒）。",
              0.5, 20, 0.25, 2, \.neutralOverlapCap),
        field("clashOverlapCap", "overlap",
              "“差异很大”这一档最多叠多久（秒）。",
              0.2, 12, 0.25, 2, \.clashOverlapCap),
        field("vocalClashFadeCap", "overlap",
              "两个主唱会打架时，叠加被砍到多少秒以内。",
              0.5, 15, 0.25, 2, \.vocalClashFadeCap),
        field("tailStableCV", "overlap",
              "判断出曲尾巴“够平稳”的宽松度；越宽松，就认为尾巴能扛住越长的淡出。",
              0.05, 1, 0.01, 2, \.tailStableCV),
        field("tailCapacityFallback", "overlap",
              "出曲尾巴一直忽大忽小、算不出承载力时，退而求其次用多长的淡出（秒）。",
              0.5, 15, 0.25, 2, \.tailCapacityFallback),
        field("intakePeakShare", "overlap",
              "入曲从开头爬到全曲多大音量之前，都还能藏在出曲的淡出底下不被察觉。",
              0.2, 1, 0.01, 2, \.intakePeakShare),
        field("intakeBodySeconds", "overlap",
              "在入曲“爬起来”所需的时间之外，再多给几秒正身，让交接不那么局促。",
              0, 20, 0.5, 1, \.intakeBodySeconds),
        field("minTrackDuration", "overlap",
              "任何一首短于这个秒数，就不做过渡了，直接一首接一首播完。",
              5, 180, 1, 0, \.minTrackDuration),

        // --- Where and how it lands.
        field("tailWindowShare", "shape",
              "出曲最早可以从整首歌的百分之多少处开始交接，防止过渡点提前到副歌以前。",
              0.1, 0.95, 0.01, 2, \.tailWindowShare),
        field("tailWindowSeconds", "shape",
              "对拍时，从曲尾往前找交接点的搜索范围有多长（秒）。",
              5, 180, 1, 0, \.tailWindowSeconds),
        field("crossfadeOutPointShare", "shape",
              "普通淡入淡出的交接点必须落在整首歌百分之多少之后。",
              0.1, 0.95, 0.01, 2, \.crossfadeOutPointShare),
        field("stagedEQMinOverlap", "shape",
              "叠加至少这么长（秒），才值得把高、中、低三段分批交接；更短就只做普通淡出。",
              0, 30, 0.5, 1, \.stagedEQMinOverlap),
        field("echoBeatFraction", "shape",
              "戛然而止的回声，间隔是出曲一拍的多少倍（0.75 就是附点八分，最常见的 DJ 手感）。",
              0.1, 2, 0.01, 2, \.echoBeatFraction),
        field("echoDelayMin", "shape",
              "回声间隔的下限（秒），太短会糊成一团。",
              0.02, 1, 0.01, 2, \.echoDelayMin),
        field("echoDelayMax", "shape",
              "回声间隔的上限（秒），太长会拖沓。",
              0.1, 3, 0.01, 2, \.echoDelayMax),

        // --- Stem layer. Only read when人声分离可用；关掉时这四项完全不参与判断。
        field("stemVocalActiveRatio", "stem",
              "出曲的交接窗口里人声要有平常的几倍密，才值得动用人声分离。"
                  + "调小 = 更容易升级到 stem 手法，但也更容易选到其实没什么人声的段落。"
                  + "参考：语料里每首歌自己的 8 秒窗口，中位数 1.00，第 95 百分位 1.16–1.58。",
              0.8, 2, 0.01, 2, \.stemVocalActiveRatio),
        field("stemAcapellaIncomingVocalMax", "stem",
              "要让出曲的清唱飘在入曲上，入曲开头的人声必须低于自己平常的这个倍数（即“基本是伴奏”）。"
                  + "调大 = 更多曲子够得着 acapella，但入曲一开口就会变成两个主唱抢戏。",
              0.2, 1.5, 0.01, 2, \.stemAcapellaIncomingVocalMax),
        field("stemMinOverlap", "stem",
              "叠加短于这个秒数就不用 stem 手法：手法本身展不开，也不值得为它跑一次人声分离。",
              2, 20, 0.5, 1, \.stemMinOverlap),
        field("stemDuckDepthDB", "stem",
              "两边都在唱时，出曲的人声被压低多少 dB（S1 盲听选的是 9）。"
                  + "调大 = 出曲人声让得更彻底，但也更容易听出“被人按住了”。",
              0, 24, 0.5, 1, \.stemDuckDepthDB),
        field("stemExchangeHandoverMin", "stem",
              "vocal exchange 的“交接句”最早可以落在叠加的百分之多少处。"
                  + "太早入曲的伴奏还没铺开，换人声就像切了一刀。",
              0.05, 0.7, 0.01, 2, \.stemExchangeHandoverMin),
        field("stemExchangeHandoverMax", "stem",
              "vocal exchange 的“交接句”最晚可以落在叠加的百分之多少处。"
                  + "太晚入曲的人声还没站稳，出曲这边已经没声音了。",
              0.4, 0.98, 0.01, 2, \.stemExchangeHandoverMax),
        boolField("twoClockExchange", "stem",
                  "开 = 人声和伴奏走两个时钟：伴奏在低频交接点 S 换台，人声按歌词另选一个"
                      + "交接点 L —— L 落在 S 之后就是“唱完才走”（vocalCarryover，出曲人声"
                      + "骑在入曲伴奏上把这句唱完），落在 S 之前就是“人声先行”"
                      + "（vocalYield，交接点砸在一个没人唱的小节上）。"
                      + "关 = 回到只有一个交接点、离叠加正中最近的老编排，逐字段一致。",
                  \.twoClockExchange),
        boolField("scoreEnabled", "stem",
                  "开 = 允许规划器给够格的一对开一张“转场乐谱”（格点上的离散手势：正拍直切 + "
                      + "末句甩延时），由预渲染 segment 演出；segment 没备好就还是今天的 blend，"
                      + "live 路径永远不近似乐谱。关（默认）= 一张谱都不出，逐字段回到今天。",
                  \.scoreEnabled),
        field("scoreMinBPMConfidence", "stem",
              "两首歌的拍子都要数到这个把握以上，才谈得上在格点上“切”。"
                  + "比对拍那条线高得多：blend 扛得住半拍的网格误差，切扛不住。",
              0, 1, 0.01, 2, \.scoreMinBPMConfidence),
        boolField("scoreAimEnabled", "stem",
                  "开（默认）= 先定入曲的目标格点——drop 起点 > 副歌起点 > 首个核心段起点——"
                      + "再把入曲的进点从那里倒推出来，让那一刀正好落在这个点上；"
                      + "入曲没有结构信息时自动退化成今天的进点。"
                      + "关 = P1 的落法：seam 从低频交接点吸附到最近的乐句线，"
                      + "切得干净但落在哪儿全看几何。只在出谱时起作用。",
                  \.scoreAimEnabled),
        field("scoreAimMaxLeadSeconds", "stem",
              "瞄准点最多可以落在入曲 introEnd 之后多少秒。瞄准会跳过目标之前的一切，"
                  + "所以这是“为了落在那个 drop 上，愿意丢掉入曲多少”的上限。",
              0, 240, 5, 0, \.scoreAimMaxLeadSeconds),
        boolField("scoreTensionCutEnabled", "stem",
                  "开（默认，只在出谱时有意义）= 允许“张力切”：落拍前 N 拍全场静默，然后直切 + slam。"
                      + "只在这一刀确实落在 drop / 副歌上时才给——切进主歌前的静默不是张力，是故障。"
                      + "关 = 这一档从模板梯子上摘掉，退回 echo throw / 直切。",
                  \.scoreTensionCutEnabled),
        field("scoreTensionCutBeats", "stem",
              "张力切静默几拍。1 拍是一口屏住的气；2 拍听众已经来得及觉得不对；"
                  + "一小节以上模型直接拒收。",
              0.25, 4, 0.25, 2, \.scoreTensionCutBeats),
        boolField("scoreBedIntroEnabled", "stem",
                  "开（默认，只在意图层判为 dropAlign 时有意义）= 允许“伴奏垫”："
                      + "入曲先只出伴奏（人声 lane 压到 −60 dB）垫在出曲的退场底下，"
                      + "人声到 drop 那一拍才进来。底下的 blend 一个字段都不改。"
                      + "这是手势库里唯一要跑人声分离的一个，所以它要付单边分离的跑道。",
                  \.scoreBedIntroEnabled),
        intField("scoreBedIntroBars", "stem",
                 "伴奏垫最长铺几小节——这其实是对【叠加长度】的上限，不是把垫子补到这个长度："
                     + "瞄准之后入曲的进点本来就是从落点倒推出来的，"
                     + "垫子就是“进点到人声进入点”这一整段。"
                     + "叠加比这个长出半小节以上，整谱作废（从头压住人声就不是这个手势了）。"
                     + "默认 8 = 规划器自己最常给的叠加长度；预研写的 4 在真实计划上一次都够不着。",
                 1, 16, \.scoreBedIntroBars),
        field("scoreBedIntroMinIncomingVocal", "stem",
              "入曲进点窗口里的人声密度要到自己平常的这个倍数，才值得给它做伴奏垫。"
                  + "低于这条线的入曲开头本来就没人唱——垫子就等于原混音，"
                  + "手势听不出来，分离却照付。",
              0.3, 1.5, 0.05, 2, \.scoreBedIntroMinIncomingVocal),
        field("vocalCarryWindowSeconds", "stem",
              "出曲人声最多可以越过低频交接点 S 多少秒去把一句唱完；这个窗口里找得到歌词行末"
                  + "就是 vocalCarryover，找不到就退成 vocalYield（在 S 之前唱完）。"
                  + "调大 = 更容易“唱完才走”，但唱得越久出曲推子已经落得越低，"
                  + "补偿到顶（+6 dB）之后人声还是会跟着推子一起走。",
              0, 20, 0.5, 1, \.vocalCarryWindowSeconds),

        // --- Intent layer (P3). 默认整层关闭；关着的时候一个信号都不算，逐字段回到今天。
        boolField("intentEnabled", "intent",
                  "开 = 先问“这一对在文化上该怎么接”，再决定允许哪一类手法："
                      + "专辑连播站下（gapless）、摇滚类克制（只给短的分段交叉淡入）、"
                      + "无拍子的古典站下、EDM 把叠加终点对到 drop、"
                      + "硬网格且两头都没人唱才允许切。存疑一律 blend（今天的行为）。"
                      + "关（默认）= 整层不运行。",
                  \.intentEnabled),
        boolField("intentStandDownEnabled", "intent",
                  "开 = 允许“站下”这一类：同专辑且在原队列里相邻的一对、"
                      + "以及两边都数不准拍子的一对，直接按没有 AutoMix 的方式交接。"
                      + "关 = 这条规则跳过，落到下一条。",
                  \.intentStandDownEnabled),
        boolField("intentRestrainedEnabled", "intent",
                  "开 = 允许“克制”这一类：网格像真人鼓手一样漂、或者一堵墙声配上"
                      + "不够硬的网格时，不对拍、叠加压到 neutral 档、且绝不出谱。",
                  \.intentRestrainedEnabled),
        boolField("intentDropAlignEnabled", "intent",
                  "开 = 允许“对 drop”这一类：入曲有 drop 且两边网格都硬时，"
                      + "仍然是 blend，但把叠加的终点对到 drop 上（出曲的尾巴叠在 build 上）。",
                  \.intentDropAlignEnabled),
        boolField("intentCutCultureEnabled", "intent",
                  "开 = 允许“切的文化”这一类：两边网格都硬、且交接窗口里两边都基本没人唱时，"
                      + "才允许给这一对写转场乐谱（正拍直切）。这是唯一能拿到谱的一类。",
                  \.intentCutCultureEnabled),
        field("intentEdgeWindowSeconds", "intent",
              "意图层的各项统计取多长的“边缘窗口”：出曲取退场点之前这么多秒，"
                  + "入曲取进点之后这么多秒。整首歌的平均值回答的是另一个问题。",
              5, 90, 1, 0, \.intentEdgeWindowSeconds),
        field("intentDrummerDriftCV", "intent",
              "小节间隔的变异系数到这个数就算“真人在打拍子”，判为克制。"
                  + "注意是【小节】不是【拍】：量化制作的小节网格在 0.7–3.4 %，"
                  + "同一批歌的拍网格却有 5–13 %（掉一拍就少一整个间隔）。"
                  + "调小 = 更容易判成摇滚、更克制。",
              0.005, 0.2, 0.005, 3, \.intentDrummerDriftCV),
        field("intentHardGridCV", "intent",
              "小节间隔的变异系数低到这个数才算“网格够硬，可以在格点上动手”。"
                  + "和上面那条之间故意留了一条模糊带，落在带子里的素材一律给今天的 blend。",
              0.002, 0.1, 0.002, 3, \.intentHardGridCV),
        field("intentWallFlatness", "intent",
              "音色指纹的“平坦度”（0 = 形状集中在少数几个频带，1 = 均匀铺满 40 个带）"
                  + "到这个数就算一堵墙声。墙声 + 网格不够硬 = 摇滚代理信号。"
                  + "调小 = 更多曲子被判成墙、更克制。",
              0.3, 1, 0.01, 2, \.intentWallFlatness),
        field("intentWallOccupancy", "intent",
              "还要求边缘窗口里有这么大比例的秒数是“响的”（≥ 窗口峰值的一半），"
                  + "免得把安静的噪声段落当成吉他墙。",
              0.3, 1, 0.01, 2, \.intentWallOccupancy),
        field("intentInstrumentalEdgeRatio", "intent",
              "交接窗口里的人声密度低于自己平常的这个倍数，才算“这头没人在唱”——"
                  + "切的前提。比 vocalClashRatio 严得多：“没人唱”比“不会打架”强得多。",
              0.1, 1.2, 0.05, 2, \.intentInstrumentalEdgeRatio),

        // --- 高潮延长 + 人声悬崖。**不属于意图层**：这是选点上的修正，
        // 意图层开不开都生效（语料证据见 `climaxExtendPostChorus` 的注释）。
        boolField("climaxExtendPostChorus", "structure",
                  "开 = 末段副歌之后如果紧跟着一个“只出现过一次、而且人声很密”的段落，"
                      + "把禁切区一路延到那个段落结束——歌还没唱完。"
                      + "末段副歌自己的结尾仍然是合法出点（区间在低端是开的）。",
                  \.climaxExtendPostChorus),
        field("climaxExtendVocalDensity", "structure",
              "上面那个段落的人声密度要到这个数（1 = 这首歌的平均水平）才算“还在唱”。"
                  + "纯器乐的尾巴不算，走都可以走。",
              0.3, 2, 0.05, 2, \.climaxExtendVocalDensity),
        boolField("preferVocalCliffOutPoints", "structure",
                  "开 = 出点候选里，坐在“人声悬崖”上的（往后看人声密度掉下去）整体提到前面，"
                      + "组内顺序不变。只重排、绝不删除，所以兜底列表原封不动。",
                  \.preferVocalCliffOutPoints),
        field("vocalCliffWindowSeconds", "structure",
              "判断人声悬崖时，候选点前后各取多少秒来比。",
              1, 20, 0.5, 1, \.vocalCliffWindowSeconds),
        field("vocalCliffDrop", "structure",
              "人声密度要跌掉这么多（以这首歌自己的平均值为单位）才算一道悬崖。"
                  + "调小 = 更多候选被认成悬崖，重排更激进。",
              0.05, 1.5, 0.05, 2, \.vocalCliffDrop),

        // --- Structure layer. 只在这首歌的分析里带着段落（v7 sidecar、分段器够有把握）
        // 时才被读到；没有段落的歌整块都不参与判断。
        boolField("useStructureOutPoints", "structure",
                  "开 = 出点优先从段落边界里选（末段副歌唱完 > 任意副歌结束 > 任意段落边界），"
                      + "能量跳变打分的老候选退到最后当兜底；关 = 完全回到今天的行为。",
                  \.useStructureOutPoints),
        boolField("useStructureInPoint", "structure",
                  "开 = 入点取第一个核心段（第一个既不是 intro 也不是 outro 的段落）的开始，"
                      + "而不是“第一处不安静的地方”；"
                      + "清唱开场和慢 build 的电子乐就是靠这一项修好的。关 = 回到 introEnd。",
                  \.useStructureInPoint),
        field("structureConfidenceGate", "structure",
              "对段落划分的把握低于这个数就当作没有段落，出入点全部走老路。"
                  + "默认与分段器自己的门槛相同（所以默认下这道复查永远不会触发）；"
                  + "调高 = 只在“非常确定”的歌上按结构选点。",
              0, 1, 0.01, 2, \.structureConfidenceGate),
        field("lyricSnapMaxSeconds", "structure",
              "出点最多可以往前挪多少秒，去落在一句歌词唱完的地方（只往前，绝不往后）。"
                  + "超过这个距离就原地不动，免得被拖到上一段去。设成 0 = 不吸附歌词。",
              0, 12, 0.5, 1, \.lyricSnapMaxSeconds),
        intField("climaxGuardBarsBefore", "structure",
                 "末段副歌开始前的多少小节之内禁止出点——不在高潮到来前把歌送走。"
                     + "16 小节约等于常见的“预副歌抬升”整段。设成 0 = 关掉这道守门。"
                     + "（若守门把候选清空，仍会退回不守门的列表：过渡总得发生。）",
                 0, 64, \.climaxGuardBarsBefore),
        intField("climaxGuardBarsAfter", "structure",
                 "末段副歌开始之后再禁止多少小节。默认 0：正好切在副歌第一拍是合法手势，"
                     + "要防的是它前面那段蓄力。",
                 0, 32, \.climaxGuardBarsAfter),
        field("structureInPointMaxLeadSeconds", "structure",
              "结构入点最多可以比 introEnd 晚多少秒；再晚就当成段落标错了，退回 introEnd。",
              5, 180, 1, 0, \.structureInPointMaxLeadSeconds),
        field("structureInPointSlackSeconds", "structure",
              "结构入点允许比 introEnd 早多少秒（段落边界吸附到小节线，早一点点是正常的）。",
              0, 15, 0.5, 1, \.structureInPointSlackSeconds),
    ]

    /// This config as `name: value`, in field order.
    var asDictionary: [String: Double] {
        var out: [String: Double] = [:]
        for f in Self.fields { out[f.name] = f.read(self) }
        return out
    }

    /// `.standard` with the named fields replaced. Unknown names are ignored
    /// (a stale saved preset must never take the console down); every value
    /// is clamped into the field's own range.
    static func standard(overriding overrides: [String: Double]) -> TransitionPlanner.Config {
        var config = TransitionPlanner.Config.standard
        for f in fields {
            guard let raw = overrides[f.name] else { continue }
            f.write(&config, Swift.min(Swift.max(raw, f.min), f.max))
        }
        return config
    }

    /// Fields that differ from `.standard`, as (name, standard, current).
    var diffFromStandard: [(name: String, standard: Double, current: Double)] {
        Self.fields.compactMap { f in
            let std = f.read(.standard), cur = f.read(self)
            return abs(std - cur) < 1e-12 ? nil : (f.name, std, cur)
        }
    }
}
#endif
