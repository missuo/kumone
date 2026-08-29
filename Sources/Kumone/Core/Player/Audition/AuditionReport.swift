import Foundation

// The JSON the tuning console draws from: everything the decision turned on,
// plus the derivation that got there. `audition plan --json` prints it and
// `audition serve` answers it over HTTP; nothing here re-derives a decision,
// it only re-narrates the one `Audition.decide` already made.

extension Audition {

    // MARK: - Tunables, for the slider panel

    public struct ConfigField: Encodable, Sendable {
        public let name: String
        public let group: String
        public let blurb: String
        public let min: Double
        public let max: Double
        public let step: Double
        public let digits: Int
        /// The shipped value — what the console's "reset" and diff compare to.
        public let standard: Double
    }

    /// Every planner knob, in panel order.
    public static var configFields: [ConfigField] {
        TransitionPlanner.Config.fields.map {
            ConfigField(name: $0.name, group: $0.group, blurb: $0.blurb,
                        min: $0.min, max: $0.max, step: $0.step, digits: $0.digits,
                        standard: $0.read(.standard))
        }
    }

    public static var standardConfig: [String: Double] {
        TransitionPlanner.Config.standard.asDictionary
    }

    // MARK: - Report DTOs

    public struct TrackReport: Encodable, Sendable {
        public let name: String
        public let path: String
        public let duration: TimeInterval
        public let bpm: Double
        public let bpmConfidence: Double
        public let key: String?
        public let keyConfidence: Double
        public let introEnd: TimeInterval
        public let outroFadeStart: TimeInterval?
        /// Whole-track mastered loudness (BS.1770 gated integrated, LUFS).
        public let referenceLoudness: Double?
        /// 1 s RMS, scaled so the track's own peak is 1.
        public let rms: [Double]
        /// 1 s vocal-presence likelihood, 0–1 as analyzed.
        public let vocal: [Double]
        public let downbeats: [TimeInterval]
        /// Candidate mix points, best first (the console draws the top ones).
        public let phraseBoundaries: [TimeInterval]
        /// Structural sections, in time order; empty when the segmenter was not
        /// confident (the console then says so rather than drawing nothing).
        public let sections: [SectionReport]
        public let structureConfidence: Double
    }

    /// One `TrackAnalysis.Section`, flattened for the console. Nothing decides
    /// anything on this yet (predev P2 is the eyeball pass) — it is drawn on the
    /// timeline and written into the AI bundle so a human, and an AI, can check
    /// the labels against the lyrics before the planner is allowed to use them.
    public struct SectionReport: Encodable, Sendable {
        public let start: TimeInterval
        public let end: TimeInterval
        /// "intro" | "verse" | "chorus" | "bridge" | "drop" | "outro"
        public let kind: String
        public let repetition: Int
        public let energy: Double
        public let vocalDensity: Double
    }

    public struct SignalMark: Encodable, Sendable {
        public let label: String
        public let value: Double
        /// Which knob this line is, so the console can link mark → slider.
        public let field: String
    }

    public struct SignalReport: Encodable, Sendable {
        public let id: String
        public let label: String
        public let value: Double?
        public let display: String
        public let axisMax: Double
        public let marks: [SignalMark]
        /// What this one signal, on its own, argues for.
        public let state: String
        public let verdict: String
    }

    public struct ChainStep: Encodable, Sendable {
        /// "gate" | "tier" | "key" | "beatmatch" | "overlap" | "vocals" | "style"
        public let stage: String
        public let title: String
        /// The rule, quoted the way the source states it.
        public let rule: String
        /// What the numbers made of it here.
        public let detail: String
        public let outcome: String
        /// Whether this rule actually changed the outcome.
        public let fired: Bool
    }

    /// One gate off the planner's ledger. Same numbers the chain narrates,
    /// in machine form — so a sweep can histogram eliminations without
    /// parsing prose.
    public struct GateReport: Encodable, Sendable {
        public let id: String
        public let label: String
        /// "duration" | "tier" | "key" | "beatMatch" | "barUpgrade"
        public let stage: String
        public let passed: Bool
        public let value: Double?
        public let threshold: Double?
        public let detail: String
        /// The one gate that cost this pair its beat-matched hand-over.
        public let blocking: Bool
    }

    public struct PlanReport: Encodable, Sendable {
        public let kind: String
        public let outPoint: TimeInterval?
        public let inPoint: TimeInterval?
        public let overlapDuration: TimeInterval
        public let overlapBars: Int?
        public let outgoingRate: Float?
        public let incomingRate: Float?
        /// The three numbers a crossfade length is the minimum of.
        public let tailCapacity: TimeInterval?
        public let intakeCapacity: TimeInterval?
        public let ceiling: TimeInterval?
        public let tierCap: TimeInterval
        /// A hand-written plan override for this pair: which of the three
        /// fields it named, and where the planner itself had landed — so the
        /// console can draw "199.50 → 186.00" rather than just the result.
        public let overrideFields: [String]
        public let plannerOutPoint: TimeInterval?
        public let plannerInPoint: TimeInterval?
        public let plannerOverlap: TimeInterval?
        /// The ceiling a hand-written overlap is held to.
        public let maxManualOverlap: TimeInterval
    }

    public struct StyleReport: Encodable, Sendable {
        public let description: String
        public let outroEffect: String
        public let stagedEQ: Bool
        public let echoDelayTime: TimeInterval?
        public let reason: String
    }

    public struct ConfigDiffEntry: Encodable, Sendable {
        public let name: String
        public let standard: Double
        public let current: Double
    }

    public struct DecisionReport: Encodable, Sendable {
        public let outgoing: TrackReport
        public let incoming: TrackReport
        public let signals: [SignalReport]
        public let rawTier: String
        public let tier: String
        public let demotedByKey: Bool
        /// The transition gain ride, and how long it takes to unwind. Broken
        /// out of the prose so the console can chip it next to the deck trims.
        public let rideDB: Double
        public let rideReleaseSeconds: TimeInterval
        public let chain: [ChainStep]
        /// The gates the planner walked, and — when the pair had already lost
        /// its beat-match at the tier — the ones it walked into the shadow
        /// ledger to answer the counterfactual.
        public let gates: [GateReport]
        public let shadowGates: [GateReport]
        /// `id` of the gate that eliminated this pair from `beatMatched`,
        /// nil when the pair is beat-matched.
        public let beatMatchBlocker: String?
        public let plan: PlanReport
        public let style: StyleReport
        public let nearMisses: [String]
        public let overridden: Bool
        /// Whether the planner was offered a vocal separator, and what it did
        /// with the offer.
        public let stemsReady: Bool
        public let plannedStemTechnique: String?
        /// How a `vocalExchange` compiled — where the vocal changes hands, on
        /// which line, or why it degraded. Nil when no exchange was asked for.
        public let stemExchange: ExchangeReport?
        /// The four lanes the render will play, for the console's mini plot.
        /// Nil for the one-shot gestures and for no stem at all.
        public let stemEnvelope: EnvelopeReport?
        public let config: [String: Double]
        public let configDiff: [ConfigDiffEntry]
    }

    /// One `StemEnvelope`, flattened for the console: each lane is a list of
    /// `[t, dB]` pairs in overlap-relative seconds.
    public struct EnvelopeReport: Encodable, Sendable {
        public struct LaneReport: Encodable, Sendable {
            public let key: String
            public let label: String
            public let points: [[Double]]
        }
        public let overlap: TimeInterval
        public let minGainDB: Double
        public let maxGainDB: Double
        public let lanes: [LaneReport]
    }

    public struct ExchangeReport: Encodable, Sendable {
        public let handover: TimeInterval
        public let handoverAbsolute: TimeInterval
        public let source: String
        public let lyricLine: String?
        public let clampedFrom: TimeInterval?
        public let fallbackReason: String?
        /// The floor clock: where the low end changes decks. `handover` is the
        /// vocal clock, and the gesture is which side of this it landed on.
        public let swapOffset: TimeInterval
        /// `"vocalCarryover"` / `"vocalYield"`, or nil when the two-clock rule
        /// did not run (knob off, or a contour/duck outcome).
        public let gesture: String?
        /// `[S, L]` — the stretch the incoming vocal is held down for while the
        /// outgoing singer carries a line over its bed. Carryover only.
        public let incomingDuckWindow: [TimeInterval]?
        /// dB the carried voice loses at L once fader compensation saturates;
        /// 0 when it held the line flat the whole way.
        public let carryShortfallDB: Double
    }

    // MARK: - Building the report

    public static func report(_ d: Decision) -> DecisionReport {
        let c = d.resolvedConfig
        let out = d.outgoingAnalysis, inc = d.incomingAnalysis

        return DecisionReport(
            outgoing: track(out, url: d.outgoingURL),
            incoming: track(inc, url: d.incomingURL),
            signals: signalReports(d, config: c),
            rawTier: d.rawTier,
            tier: d.tier,
            demotedByKey: d.demotedByKey,
            rideDB: d.rideDB,
            rideReleaseSeconds: d.rideReleaseSeconds,
            chain: chain(d, config: c),
            gates: d.planTrace.gates.map { gateReport($0, blocker: d.planTrace.blocker?.id) },
            shadowGates: d.planTrace.shadowGates.map { gateReport($0, blocker: nil) },
            beatMatchBlocker: d.planTrace.blocker?.id,
            plan: planReport(d, config: c),
            style: styleReport(d, config: c),
            nearMisses: d.nearMisses,
            overridden: d.overridden,
            stemsReady: d.stemsReady,
            plannedStemTechnique: d.plannedStemTechnique,
            stemExchange: d.stemExchange.map {
                ExchangeReport(handover: $0.handover,
                               handoverAbsolute: $0.handoverAbsolute,
                               source: $0.source, lyricLine: $0.lyricLine,
                               clampedFrom: $0.clampedFrom,
                               fallbackReason: $0.fallbackReason,
                               swapOffset: $0.swapOffset,
                               gesture: $0.gesture?.rawValue,
                               incomingDuckWindow: $0.incomingDuckWindow.map {
                                   [$0.lowerBound, $0.upperBound]
                               },
                               carryShortfallDB: Double($0.carryShortfallDB))
            },
            stemEnvelope: d.stemEnvelope.map { envelope in
                EnvelopeReport(
                    overlap: d.overlapDuration,
                    minGainDB: Double(StemEnvelope.minGainDB),
                    maxGainDB: Double(StemEnvelope.maxGainDB),
                    lanes: StemEnvelope.Lane.allCases.map { lane in
                        EnvelopeReport.LaneReport(
                            key: lane.jsonKey, label: lane.chineseLabel,
                            points: envelope[lane].map { [$0.t, Double($0.gainDB)] })
                    })
            },
            config: d.config,
            configDiff: c.diffFromStandard.map {
                ConfigDiffEntry(name: $0.name, standard: $0.standard, current: $0.current)
            })
    }

    private static func gateReport(_ g: PlanGate, blocker: String?) -> GateReport {
        GateReport(id: g.id, label: g.label, stage: g.stage.rawValue, passed: g.passed,
                   value: g.value, threshold: g.threshold, detail: g.detail,
                   blocking: blocker == g.id)
    }

    /// The report as pretty JSON — what `--json` prints and `/api/plan` returns.
    public static func reportJSON(_ d: Decision) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report(d))
    }

    // MARK: - Track curves

    private static let pitchNames =
        ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]

    private static func track(_ a: TrackAnalysis, url: URL) -> TrackReport {
        let peak = Double(a.rmsEnvelope.max() ?? 1)
        let scale = peak > 1e-9 ? peak : 1
        return TrackReport(
            name: url.lastPathComponent,
            path: url.path,
            duration: a.duration,
            bpm: a.bpm,
            bpmConfidence: a.bpmConfidence,
            key: a.keyPitchClass.map { "\(pitchNames[$0 % 12]) \(a.keyIsMinor ? "minor" : "major")" },
            keyConfidence: a.keyConfidence,
            introEnd: a.introEnd,
            outroFadeStart: a.outroFadeStart,
            referenceLoudness: a.referenceLoudness,
            rms: a.rmsEnvelope.map { Double($0) / scale },
            vocal: a.vocalActivity.map { Double($0) },
            // Whole-track grids get big; one downbeat every other bar is
            // plenty for a 900-px timeline.
            downbeats: thin(a.downbeats, to: 400),
            phraseBoundaries: Array(a.phraseBoundaries.prefix(60)),
            sections: a.sections.map {
                SectionReport(start: $0.start, end: $0.end, kind: $0.kind.rawValue,
                              repetition: $0.repetition, energy: Double($0.energy),
                              vocalDensity: Double($0.vocalDensity))
            },
            structureConfidence: a.structureConfidence)
    }

    private static func thin(_ xs: [TimeInterval], to limit: Int) -> [TimeInterval] {
        guard xs.count > limit, limit > 0 else { return xs }
        let stride = Int((Double(xs.count) / Double(limit)).rounded(.up))
        return xs.enumerated().compactMap { $0.offset % stride == 0 ? $0.element : nil }
    }

    // MARK: - Signals

    private static func signalReports(
        _ d: Decision, config c: TransitionPlanner.Config
    ) -> [SignalReport] {
        func state(_ v: Double, neutral: Double, clash: Double) -> String {
            v > clash ? "clash" : (v > neutral ? "neutral" : "compatible")
        }

        var out: [SignalReport] = []

        // 1. Loudness — measured after *both* gain stages (the per-track
        // playback trims, then the transition gain ride), so the gate only ever
        // punishes the part neither of them could absorb.
        let loud = d.loudnessGapDB
        func lufs(_ v: Double?) -> String {
            v.map { String(format: "%.1f LUFS", $0) } ?? "未测出"
        }
        var compensation: String
        if !c.loudnessCompensation {
            compensation = "（响度补偿已关闭，这里是两首歌的原始音量差。"
                + "出曲 \(lufs(d.outgoingLoudnessLUFS))、入曲 \(lufs(d.incomingLoudnessLUFS))。）"
        } else if abs(d.outgoingTrimDB) < 0.05 && abs(d.incomingTrimDB) < 0.05 {
            compensation = String(
                format: "（母带响度 出曲 %@ / 入曲 %@，两边都不需要调整，播放增益均为 0.00 dB。）",
                lufs(d.outgoingLoudnessLUFS), lufs(d.incomingLoudnessLUFS))
        } else {
            compensation = String(
                format: "（母带响度 出曲 %@ / 入曲 %@，播放时分别加 %+.2f dB 和 %+.2f dB 的增益。）",
                lufs(d.outgoingLoudnessLUFS), lufs(d.incomingLoudnessLUFS),
                d.outgoingTrimDB, d.incomingTrimDB)
        }
        // The three-stage story, in the order the two gain stages happen:
        // raw local gap → what the whole-track trims left → what the ride left.
        // The gate reads the last number and nothing else.
        var stages: String
        if !c.loudnessCompensation {
            stages = ""
        } else if abs(d.rideDB) < 0.005 {
            stages = String(
                format: "局部落差原本 %.2f dB，整曲响度补偿之后剩 %.2f dB；"
                    + "已经在容忍范围内（或没有可用的响度读数），交接时不需要再动推子。",
                d.rawLoudnessGapDB, d.trimmedLoudnessGapDB)
        } else {
            let absorbed = d.trimmedLoudnessGapDB - loud
            let direction = d.rideDB < 0 ? "压低" : "抬高"
            stages = String(
                format: "局部落差原本 %.2f dB，整曲响度补偿之后剩 %.2f dB；"
                    + "交接时再把入曲%@ %.2f dB（吸收掉 %.2f dB，过渡走完用 %.1f 秒悄悄推回原位），"
                    + "最后落到 %.2f dB —— %@。",
                d.rawLoudnessGapDB, d.trimmedLoudnessGapDB,
                direction, abs(d.rideDB), absorbed, d.rideReleaseSeconds, loud,
                loud > c.neutralLoudnessDB ? "仍在容忍线之外" : "已在容忍线之内")
        }
        let loudnessVerdict: String
        if loud > c.clashLoudnessDB {
            loudnessVerdict = String(
                format: "出曲结尾和入曲开头的平均音量差 %.2f dB，已经越过 %.2f dB 的红线。"
                    + "这么大的落差叠在一起，总有一边会被压垮，所以这一对只给最短的礼貌淡出。",
                loud, c.clashLoudnessDB)
        } else if loud > c.neutralLoudnessDB {
            loudnessVerdict = String(
                format: "出曲结尾和入曲开头的平均音量差 %.2f dB，超过了 %.2f dB 的容忍线。"
                    + "还不到灾难的地步，但不适合让两首歌长时间叠在一起，叠加会被缩短。",
                loud, c.neutralLoudnessDB)
        } else {
            loudnessVerdict = String(
                format: "出曲结尾和入曲开头的平均音量差 %.2f dB，在 %.2f dB 的容忍线以内，不构成问题。",
                loud, c.neutralLoudnessDB)
        }
        out.append(SignalReport(
            id: "loudness", label: "音量差",
            value: loud, display: String(format: "%.2f dB", loud),
            axisMax: Swift.max(c.clashLoudnessDB * 1.6, loud * 1.15, 1),
            marks: [SignalMark(label: "容忍线", value: c.neutralLoudnessDB,
                               field: "neutralLoudnessDB"),
                    SignalMark(label: "红线", value: c.clashLoudnessDB,
                               field: "clashLoudnessDB")],
            state: state(loud, neutral: c.neutralLoudnessDB, clash: c.clashLoudnessDB),
            verdict: loudnessVerdict + stages + compensation))

        // 2. Timbre
        let timbre = d.timbreDistance
        out.append(SignalReport(
            id: "timbre", label: "音色像不像",
            value: timbre, display: String(format: "%.3f", timbre),
            axisMax: Swift.max(c.clashTimbreDistance * 1.6, timbre * 1.15, 0.2),
            marks: [SignalMark(label: "容忍线", value: c.neutralTimbreDistance,
                               field: "neutralTimbreDistance"),
                    SignalMark(label: "红线", value: c.clashTimbreDistance,
                               field: "clashTimbreDistance")],
            state: state(timbre, neutral: c.neutralTimbreDistance, clash: c.clashTimbreDistance),
            verdict: timbre > c.clashTimbreDistance
                ? String(format: "两首歌的音色差距 %.3f，越过了 %.3f 的红线。"
                         + "声音质地差得太远，硬叠在一起会很浑，只能快速交接。",
                         timbre, c.clashTimbreDistance)
                : (timbre > c.neutralTimbreDistance
                   ? String(format: "两首歌的音色差距 %.3f，超过了 %.3f 的容忍线。"
                            + "差别听得出来，所以只给一段短交接，不长时间共存。",
                            timbre, c.neutralTimbreDistance)
                   : String(format: "两首歌的音色差距 %.3f，在 %.3f 的容忍线以内 —— "
                            + "听感上属于同一类声音，可以放心长叠。",
                            timbre, c.neutralTimbreDistance))))

        // 3. Tempo
        let tempoAxis = Swift.max(c.clashTempoRatio * 1.6, (d.tempoRatio ?? 0) * 1.15, 0.1)
        let tempoVerdict: String
        let tempoState: String
        if let r = d.tempoRatio {
            if r > c.clashTempoRatio {
                tempoState = "clash"
                tempoVerdict = String(format: "把倍速关系折算之后，两首歌的速度还差 %.1f%%，"
                                      + "越过了 %.1f%% 的红线 —— 快慢差太多，按“差异很大”处理。",
                                      r * 100, c.clashTempoRatio * 100)
            } else if r > c.maxBPMDeltaRatio {
                tempoState = "compatible"
                tempoVerdict = String(format: "速度差 %.1f%%，没到 %.1f%% 的红线，"
                                      + "但超过了对拍所需的 %.1f%% —— 拍子对不上，改用普通的交叉淡入淡出。",
                                      r * 100, c.clashTempoRatio * 100, c.maxBPMDeltaRatio * 100)
            } else {
                tempoState = "compatible"
                tempoVerdict = String(format: "速度差只有 %.1f%%，在对拍所需的 %.1f%% 以内 —— "
                                      + "两首歌各自微调一点速度就能踩在同一个拍子上。",
                                      r * 100, c.maxBPMDeltaRatio * 100)
            }
        } else {
            tempoState = "na"
            tempoVerdict = String(format: "至少有一首歌的节拍没测准（出 %.2f / 入 %.2f，需要 %.2f 以上），"
                                  + "所以速度这一项这次不参与判断。",
                                  d.outgoingBPMConfidence, d.incomingBPMConfidence,
                                  c.bpmConfidenceThreshold)
        }
        out.append(SignalReport(
            id: "tempo", label: "速度差",
            value: d.tempoRatio,
            display: d.tempoRatio.map { String(format: "%.1f%%", $0 * 100) } ?? "—",
            axisMax: tempoAxis,
            marks: [SignalMark(label: "能对拍", value: c.maxBPMDeltaRatio,
                               field: "maxBPMDeltaRatio"),
                    SignalMark(label: "红线", value: c.clashTempoRatio,
                               field: "clashTempoRatio")],
            state: tempoState, verdict: tempoVerdict))

        // 4. Key
        let keyState = (d.keyDistance ?? 0) >= c.clashKeyDistance ? "neutral" : "compatible"
        out.append(SignalReport(
            id: "key", label: "调性远近",
            value: d.keyDistance.map(Double.init),
            display: d.keyDistance.map { "\($0) 步" } ?? "—",
            axisMax: 6,
            marks: [SignalMark(label: "降档线", value: Double(c.clashKeyDistance),
                               field: "clashKeyDistance")],
            state: d.keyDistance == nil ? "na" : keyState,
            verdict: d.keyDistance == nil
                ? String(format: "至少有一首歌听不出稳定的调（需要 %.2f 以上的把握），"
                         + "所以和声这一项这次不参与判断。", c.keyConfidenceThreshold)
                : (d.keyDistance! >= c.clashKeyDistance
                   ? "两首歌的调在五度圈上隔了 \(d.keyDistance!) 步，达到了 \(c.clashKeyDistance) 步的门槛 —— "
                     + "和声上不太合得来，档位往下降一级；不过和声从不单独把一对判成“差异很大”。"
                   : "两首歌的调在五度圈上只隔 \(d.keyDistance!) 步，没到 \(c.clashKeyDistance) 步的门槛 —— "
                     + "和声上不冲突。")))

        // 5. Vocals
        let ov = d.outgoingVocalScore, iv = d.incomingVocalScore
        let bothHot = (ov ?? 0) > c.vocalClashRatio && (iv ?? 0) > c.vocalClashRatio
        out.append(SignalReport(
            id: "vocals", label: "人声挤不挤（出 / 入）",
            value: ov.flatMap { o in iv.map { Swift.min(o, $0) } },
            display: "\(ov.map { String(format: "%.2f", $0) } ?? "—") / "
                + "\(iv.map { String(format: "%.2f", $0) } ?? "—")",
            axisMax: Swift.max(c.vocalClashRatio * 1.8, (ov ?? 0) * 1.15, (iv ?? 0) * 1.15),
            marks: [SignalMark(label: "打架线", value: c.vocalClashRatio,
                               field: "vocalClashRatio")],
            state: bothHot ? "clash" : "compatible",
            verdict: (ov == nil || iv == nil)
                ? "至少有一边在这段里没有可用的人声轮廓（纯器乐，或者人声太弱），"
                  + "所以“别让两个主唱打架”这条规则这次不生效。"
                : String(format: "这两个数字是交接窗口里的人声密度，相对各自整首歌的平均值："
                         + "出曲 %.2f 倍、入曲 %.2f 倍。", ov!, iv!)
                  + (bothHot
                     ? String(format: "两边都超过了 %.2f 倍的打架线 —— 会听到两个主唱同时在唱，"
                              + "所以叠加被砍到 %.2f 秒以内。", c.vocalClashRatio, c.vocalClashFadeCap)
                     : String(format: "至少有一边低于 %.2f 倍的打架线 —— 不会出现两个主唱抢戏。",
                              c.vocalClashRatio))))

        return out
    }

    // MARK: - Derivation chain

    private static func chain(
        _ d: Decision, config c: TransitionPlanner.Config
    ) -> [ChainStep] {
        var steps: [ChainStep] = []
        let out = d.outgoingAnalysis, inc = d.incomingAnalysis

        // 0. Duration gate.
        let tooShort = out.duration < c.minTrackDuration || inc.duration < c.minTrackDuration
        steps.append(ChainStep(
            stage: "gate", title: "先看两首歌够不够长",
            rule: "太短的曲子（间奏、语音、彩蛋）不值得做过渡，直接一首接一首播完。",
            detail: String(format: "出曲 %.0f 秒、入曲 %.0f 秒，门槛是 %.0f 秒。"
                           + "（参数 minTrackDuration）",
                           out.duration, inc.duration, c.minTrackDuration),
            outcome: tooShort
                ? "有一首太短，放弃过渡，改成无缝接续（gapless），下面的规则都不用看了。"
                : "两首都够长，继续往下判断。",
            fired: tooShort))
        if tooShort { return steps }

        // 1. Tier from the three signals.
        let s = d.signals
        var reasons: [String] = []
        if s.loudnessGapDB > c.clashLoudnessDB {
            reasons.append(String(format: "音量差 %.2f dB 越过了 %.2f dB 的红线",
                                  s.loudnessGapDB, c.clashLoudnessDB))
        }
        if s.timbreDistance > c.clashTimbreDistance {
            reasons.append(String(format: "音色差距 %.3f 越过了 %.3f 的红线",
                                  s.timbreDistance, c.clashTimbreDistance))
        }
        if (s.tempoRatio ?? 0) > c.clashTempoRatio {
            reasons.append(String(format: "速度差 %.1f%% 越过了 %.1f%% 的红线",
                                  (s.tempoRatio ?? 0) * 100, c.clashTempoRatio * 100))
        }
        var neutralReasons: [String] = []
        if s.loudnessGapDB > c.neutralLoudnessDB {
            neutralReasons.append(String(format: "音量差 %.2f dB 超过了 %.2f dB 的容忍线",
                                         s.loudnessGapDB, c.neutralLoudnessDB))
        }
        if s.timbreDistance > c.neutralTimbreDistance {
            neutralReasons.append(String(format: "音色差距 %.3f 超过了 %.3f 的容忍线",
                                         s.timbreDistance, c.neutralTimbreDistance))
        }
        let tierDetail: String
        if !reasons.isEmpty {
            tierDetail = reasons.joined(separator: "；") + "。"
        } else if !neutralReasons.isEmpty {
            tierDetail = neutralReasons.joined(separator: "；") + "，其余都在线内。"
        } else {
            tierDetail = String(format: "音量差 %.2f dB、音色差距 %.3f、速度差 %@，三项都在容忍线以内。",
                                s.loudnessGapDB, s.timbreDistance,
                                s.tempoRatio.map { String(format: "%.1f%%", $0 * 100) } ?? "（不参与）")
        }
        steps.append(ChainStep(
            stage: "tier", title: "三项信号先定一个档",
            rule: "只要有一项越过红线，就当成“差异很大”；只要音量或音色越过容忍线，就是“一般般”；"
                + "都没越过才是“很搭”。",
            detail: tierDetail,
            outcome: "→ 这一步给出：\(tierName(d.rawTier))",
            fired: d.rawTier != "compatible"))

        // 2. Key gate.
        if d.rawTier == "compatible" {
            steps.append(ChainStep(
                stage: "key", title: "再问一句和声合不合",
                rule: "两首歌的调都听得准、而且在五度圈上离得够远时，把“很搭”降一级；"
                    + "和声从来不单独把一对判成“差异很大”。",
                detail: d.keyDistance.map { "五度圈距离 \($0) 步，降档门槛是 \(c.clashKeyDistance) 步。" }
                    ?? String(format: "至少有一首的调没听准（出 %.2f / 入 %.2f，需要 %.2f 以上），"
                              + "这一关不生效。",
                              out.keyConfidence, inc.keyConfidence, c.keyConfidenceThreshold),
                outcome: d.demotedByKey
                    ? "→ 和声不合，从“很搭”降到“一般般”。"
                    : "→ 和声没有意见，维持“很搭”。",
                fired: d.demotedByKey))
        }

        // 3. Beat-match attempt (only tried at compatible). Narrated straight
        // off the planner's own ledger, so every number quoted here is the
        // number the gate compared — see `PlanTrace`.
        steps.append(beatMatchStep(d, config: c))
        if let bars = barUpgradeStep(d, config: c) { steps.append(bars) }

        // 4. Overlap length.
        if d.planKind == "crossfade" {
            let tierCap = cap(for: d.tier, config: c)
            let tail = TransitionPlanner.tailCapacity(out, config: c)
            let intake = TransitionPlanner.intakeCapacity(inc, inPoint: inc.introEnd, config: c)
            let ceiling = Swift.min(c.maxOverlap, tierCap,
                                    c.maxOverlapShare * Swift.min(out.duration, inc.duration))
            let raw = Swift.max(c.minOverlap, Swift.min(tail, intake, ceiling))
            let binding: String
            if raw <= c.minOverlap + 1e-9 { binding = "最短叠加的下限兜住了它" }
            else if abs(raw - tail) < 1e-9 { binding = "出曲的尾巴撑不了更久" }
            else if abs(raw - intake) < 1e-9 { binding = "入曲的开头藏不住更长的淡出" }
            else { binding = "档位上限（和曲长比例）封顶了" }
            steps.append(ChainStep(
                stage: "overlap", title: "两首歌该叠多久",
                rule: "取三者中最小的一个：出曲尾巴还能撑多久、入曲开头能藏住多长的淡出、"
                    + "这个档位允许的上限；再兜一个最短值。",
                detail: String(format: "出曲尾巴 %.2f 秒 · 入曲开头 %.2f 秒 · 档位上限 %.2f 秒"
                               + "（「%@」这一档封顶 %.2f 秒）。",
                               tail, intake, ceiling, tierName(d.tier), tierCap),
                outcome: String(format: "→ %.2f 秒，%@。", raw, binding),
                fired: true))

            // 5. Vocal cap.
            let capped = raw > d.overlapDuration + 1e-6
            steps.append(ChainStep(
                stage: "vocals", title: "别让两个主唱同时开口",
                rule: "如果交接窗口里两首歌的人声都比各自平时更密，就把叠加砍短，"
                    + "让两段人声尽量不重合。",
                detail: "出曲人声密度 \(d.outgoingVocalScore.map { String(format: "%.2f", $0) } ?? "—")"
                    + " 倍、入曲 \(d.incomingVocalScore.map { String(format: "%.2f", $0) } ?? "—") 倍，"
                    + String(format: "打架线 %.2f 倍，砍到 %.2f 秒以内。",
                             c.vocalClashRatio, c.vocalClashFadeCap),
                outcome: capped
                    ? String(format: "→ 两边人声都太密，叠加从 %.2f 秒砍到 %.2f 秒。",
                             raw, d.overlapDuration)
                    : (d.plannedStemTechnique != nil
                       ? String(format: "→ 这一步让位给了下面的人声分离：叠加不砍，保持 %.2f 秒。",
                                d.overlapDuration)
                       : String(format: "→ 不会打架，叠加保持 %.2f 秒。", d.overlapDuration)),
                fired: capped))
        }

        // 6. Stem layer.
        steps.append(stemStep(d, config: c))

        // 7. Style.
        steps.append(ChainStep(
            stage: "style", title: "出曲用什么姿势离场",
            rule: styleRule(d.tier),
            detail: styleReport(d, config: c).reason,
            outcome: "→ \(d.styleDescription)",
            fired: true))
        // 8. A hand-written hand-over geometry, if one was given. This is the
        // one step that is not a rule at all — it is a person (or an AI) saying
        // "on this pair, put the seam here" — so it is quoted as a diff.
        if let po = d.planOverride {
            func t(_ s: TimeInterval?) -> String {
                guard let s else { return "—" }
                return String(format: "%d:%05.2f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
            }
            var moves: [String] = []
            if po.outPoint != nil {
                moves.append("出点 \(t(d.plannerOutPoint)) → \(t(d.outPoint))")
            }
            if po.inPoint != nil {
                moves.append("入点 \(t(d.plannerInPoint)) → \(t(d.inPoint))")
            }
            if po.overlap != nil {
                moves.append(String(format: "叠加 %.2f → %.2f 秒",
                                    d.plannerOverlap, d.overlapDuration))
            }
            let kept = ["outPoint": "出点", "inPoint": "入点", "overlap": "叠加长度"]
                .filter { !po.specifiedFields.contains($0.key) }
                .map(\.value).sorted()
            steps.append(ChainStep(
                stage: "plan", title: "这一对的交接点是人工/AI 指定的",
                rule: "planOverride 只作用于这一对：给出点、入点、叠加长度中的任意几项，"
                    + "没给的沿用规划器算出来的值。"
                    + String(format: "唯一的硬约束是两边都装得下，且叠加不超过 %.0f 秒。",
                             PlanOverride.maxOverlap),
                detail: moves.joined(separator: " · ")
                    + (kept.isEmpty ? "" : "；\(kept.joined(separator: "、"))沿用规划器的值。"),
                outcome: String(format: "→ 出点 %@ · 入点 %@ · 叠加 %.2f 秒（接法仍是 %@）。",
                                t(d.outPoint), t(d.inPoint), d.overlapDuration, d.planKind),
                fired: true))
        }

        if d.overridden {
            steps.append(ChainStep(
                stage: "style", title: "这一版是手动改过的",
                rule: "面板上的「手法」「叠加长度」「stem 手法」一旦选了，就直接盖掉上面算出来的结果。",
                detail: "所以你现在听到的不是纯粹由规则推出来的方案。",
                outcome: String(format: "→ %@，叠加 %.2f 秒。", d.styleDescription, d.overlapDuration),
                fired: true))
        }
        return steps
    }

    // MARK: - The beat-match chain, read off the planner's ledger

    /// One gate the planner walked, said the way a person would say it. Every
    /// number quoted is the number that gate compared — nothing is re-derived,
    /// so the narration cannot drift from the decision (`PlanTrace`).
    private static func gateSentence(_ g: PlanGate) -> String {
        func v(_ digits: Int = 2) -> String {
            g.value.map { String(format: "%.\(digits)f", $0) } ?? "—"
        }
        func t(_ digits: Int = 2) -> String {
            g.threshold.map { String(format: "%.\(digits)f", $0) } ?? "—"
        }
        func pct(_ x: Double?) -> String {
            x.map { String(format: "%.1f%%", $0 * 100) } ?? "—"
        }
        switch g.id {
        case "minDuration": return "最短的一首 \(v(0)) 秒，门槛 \(t(0)) 秒"
        case "loudnessGap": return "音量差 \(v()) dB，容忍线 \(t(1)) dB"
        case "timbreDistance": return "音色距离 \(v(3))，容忍线 \(t(2))"
        case "tempoClash":
            return g.value == nil
                ? "至少一边节拍没测准，速度红线这一关不参与"
                : "折算速度差 \(pct(g.value))，红线 \(pct(g.threshold))"
        case "keyDistance":
            return g.value == nil
                ? "至少一边听不出稳定的调，和声这一关不参与"
                : "五度圈距离 \(v(0)) 步，降档线 \(t(0)) 步"
        case "bpmConfidence": return "节拍把握度（取低的一边）\(v())，门槛 \(t())"
        case "bpmDelta": return "折算后的 BPM 差 \(pct(g.value))，对拍窗口 \(pct(g.threshold))"
        case "rateDeviation": return "单边变速幅度 \(pct(g.value))，上限 \(pct(g.threshold))"
        case "inPoint":
            return g.passed
                ? "入点（intro 之后第一个 downbeat）落在 \(v()) 秒"
                : "入曲整首都没有可用的 downbeat，入点无从谈起"
        case "overlapCeiling": return "这段叠加要 \(v()) 秒，上限 \(t()) 秒"
        case "outPoint":
            return g.passed
                ? "出点（尾窗里装得下这段叠加的乐句起点）落在 \(v()) 秒"
                : "出曲尾窗里没有任何一个乐句起点装得下这段叠加"
        case "incomingRoom": return "入点 + 叠加 = \(v()) 秒，入曲全长 \(t(0)) 秒"
        default: break
        }
        switch g.id.split(separator: ".").last.map(String.init) ?? "" {
        case "ceiling": return "叠加 \(v()) 秒 / 上限 \(t()) 秒"
        case "outPoint":
            return g.passed ? "出点 \(v()) 秒" : "尾窗里没有装得下的乐句起点"
        case "incomingRoom": return "入点 + 叠加 = \(v()) 秒 / 入曲 \(t(0)) 秒"
        case "stableOut": return "出曲这段的能量起伏 \(v(3))，稳定门槛 \(t(2))"
        case "stableIn": return "入曲这段的能量起伏 \(v(3))，稳定门槛 \(t(2))"
        case "vocals":
            return g.passed
                ? "人声不撞车（打架线 \(t()) 倍）"
                : "两边人声都比各自平时更密，越过了 \(t()) 倍的打架线"
        default: return g.detail
        }
    }

    /// "差多少" — how far a failed gate sat from its line, as a share of the
    /// line, so a 0.9 dB miss and a 4-point BPM miss are comparable.
    private static func gateGap(_ g: PlanGate) -> String {
        guard !g.passed, let m = g.margin, m.isFinite, abs(m) >= 0.005 else { return "" }
        return m > 0 ? String(format: "，超出 %.0f%%", m * 100)
                     : String(format: "，还差 %.0f%%", -m * 100)
    }

    /// Short Chinese name of a gate, for "卡在「X」这道门上".
    private static func gateName(_ id: String) -> String {
        switch id {
        case "minDuration": return "曲长"
        case "loudnessGap": return "音量差"
        case "timbreDistance": return "音色距离"
        case "tempoClash": return "速度红线"
        case "keyDistance": return "调性"
        case "bpmConfidence": return "节拍把握度"
        case "bpmDelta": return "折算 BPM 差"
        case "rateDeviation": return "变速幅度"
        case "inPoint": return "入点"
        case "overlapCeiling": return "叠加上限"
        case "outPoint": return "出点"
        case "incomingRoom": return "入曲余量"
        default: break
        }
        switch id.split(separator: ".").last.map(String.init) ?? "" {
        case "ceiling": return "叠加上限"
        case "outPoint": return "出点"
        case "incomingRoom": return "入曲余量"
        case "stableOut": return "出曲能量稳定"
        case "stableIn": return "入曲能量稳定"
        case "vocals": return "人声撞车"
        default: return id
        }
    }

    private static func gateLine(_ g: PlanGate) -> String {
        "\(g.passed ? "✓" : "✗") \(gateSentence(g))\(gateGap(g))"
    }

    /// The beat-match step: every gate on the road to a beat-matched
    /// hand-over, in order, with the number each one compared — and, when the
    /// pair lost it, exactly which gate did the killing and by how much.
    ///
    /// At a demoted tier the pair never reaches this rule for real, so the
    /// planner's shadow ledger is narrated instead: it answers the question the
    /// tier alone cannot ("and would it have cleared the rest?").
    private static func beatMatchStep(
        _ d: Decision, config c: TransitionPlanner.Config
    ) -> ChainStep {
        let rule = "两边节拍都数得准、折算后的速度差在对拍线以内、各自变速幅度不过分、"
            + "入曲找得到入点、出曲尾部有一个乐句起点能装下整段叠加 —— 全部满足才做对拍过渡。"
        let trace = d.planTrace
        let real = trace.gates.filter { $0.stage == .beatMatch }
        let shadow = trace.shadowGates.filter { $0.stage == .beatMatch }
        let shown = real.isEmpty ? shadow : real
        let lines = shown.map(gateLine)

        guard d.tier == "compatible" else {
            var detail = "这一对是「\(tierName(d.tier))」，对拍这条路在档位那一步就断了。"
            detail += shown.isEmpty
                ? "（后面的门一道都没走到。）"
                : "　假设档位放行，后面几道门会是：" + lines.joined(separator: "；") + "。"
            let outcome: String
            if let s = trace.shadowBlocker {
                outcome = "→ 跳过对拍。而且就算档位放行，它也会卡在「\(gateName(s.id))」"
                    + "这道门上（\(gateSentence(s))\(gateGap(s))）。"
            } else if shown.isEmpty {
                outcome = "→ 跳过对拍，走普通交叉淡入淡出。"
            } else {
                outcome = "→ 跳过对拍。不过值得记一笔：对拍自己的每一道门它都过得去 —— "
                    + "拦住这一对的只有档位本身。"
            }
            return ChainStep(stage: "beatmatch", title: "试试能不能踩到同一个拍子上",
                             rule: rule, detail: detail, outcome: outcome, fired: false)
        }

        let outcome: String
        if d.planKind == "beatMatched" {
            outcome = "→ 每一道门都过了，两首歌踩着同一个拍子叠 \(d.overlapBars ?? 0) 个小节。"
        } else if let b = trace.blocker {
            outcome = "→ 卡在「\(gateName(b.id))」这道门上"
                + "（\(gateSentence(b))\(gateGap(b))），退回普通交叉淡入淡出。"
        } else {
            outcome = "→ 没做成对拍，走普通交叉淡入淡出。"
        }
        return ChainStep(
            stage: "beatmatch", title: "试试能不能踩到同一个拍子上",
            rule: rule,
            detail: lines.isEmpty ? "（这一对没有走到对拍这一步。）"
                : lines.joined(separator: "；") + "。",
            outcome: outcome, fired: d.planKind == "beatMatched")
    }

    /// The 16 / 8-bar upgrade search. Failing it never costs a pair its
    /// beat-matched plan — it only shortens the overlap to the 4-bar floor —
    /// so it gets its own step rather than muddying the elimination story.
    private static func barUpgradeStep(
        _ d: Decision, config c: TransitionPlanner.Config
    ) -> ChainStep? {
        let gates = d.planTrace.gates.filter { $0.stage == .barUpgrade }
        guard !gates.isEmpty, d.tier == "compatible" else { return nil }
        var parts: [String] = []
        for candidate in [16, 8] {
            let own = gates.filter { $0.id.hasPrefix("bars\(candidate).") }
            guard !own.isEmpty else { continue }
            if let failed = own.first(where: { !$0.passed }) {
                parts.append("\(candidate) 小节：✗ \(gateSentence(failed))\(gateGap(failed))")
            } else {
                parts.append("\(candidate) 小节：全部通过")
            }
        }
        let chosen = d.planTrace.chosenBars
        let outcome: String
        if let chosen, chosen > 4 {
            outcome = "→ 拿到 \(chosen) 小节的长叠加。"
        } else if d.planKind == "beatMatched" {
            outcome = "→ 两次升级都没成，退到 4 小节的兜底叠加。"
        } else {
            outcome = "→ 两次升级都没成，4 小节兜底也没成（见上一步）。"
        }
        return ChainStep(
            stage: "bars", title: "这段叠加能有多长",
            rule: "先试 16 小节、再试 8 小节：叠加不超上限、出曲尾窗里有装得下的乐句起点、"
                + "入曲还有余量、两边这一段的能量都够稳、而且人声不撞车 —— 全中才升级；"
                + "否则退到 4 小节的兜底。",
            detail: parts.joined(separator: "；") + "。",
            outcome: outcome, fired: (chosen ?? 4) > 4)
    }

    /// The stem-layer step: which of the two upgrade rules fired, on what
    /// numbers, and where it moved the hand-over to. Always emitted — saying
    /// *why* a stem technique was not chosen is the more common and the more
    /// useful case.
    private static func stemStep(
        _ d: Decision, config c: TransitionPlanner.Config
    ) -> ChainStep {
        let rule = "人声分离可用时，再问两句：出曲的交接窗口里人声够不够密（"
            + String(format: "≥ %.2f 倍", c.stemVocalActiveRatio)
            + "）？如果够，而且入曲开头也在唱，就不再砍短叠加，改成编排一次人声交接"
            + "（vocal exchange：入曲伴奏先铺底 → 出曲伴奏早退 → 出曲人声把这一句唱完 →"
            + "入曲人声接手；交接句由歌词时间戳定位，落点被夹在叠加的 "
            + String(format: "%.0f%%–%.0f%% 之间）；出曲没有歌词也没有人声曲线时，"
                     + "退回把出曲人声整段压低 %.0f dB（vocal duck）",
                     c.stemExchangeHandoverMin * 100, c.stemExchangeHandoverMax * 100,
                     c.stemDuckDepthDB)
            + "；如果够，而入曲开头基本是伴奏（"
            + String(format: "≤ %.2f 倍", c.stemAcapellaIncomingVocalMax)
            + "）且这一对很搭，就让出曲的清唱飘在入曲上（acapella over）。"
            + "两条都不成立就完全不用 stem。instrumental out 从不自动选（S1 盲听里一次没赢过），"
            + "只保留手动挑选。"

        guard d.stemsReady else {
            return ChainStep(
                stage: "stem", title: "要不要动用人声分离",
                rule: rule,
                detail: "这次没有告诉规划器人声分离可用（stems = none），"
                    + "所以下面四个 stem 参数一个都没被读到。",
                outcome: "→ 不用 stem，结论与不带人声分离时逐字段一致。",
                fired: false)
        }

        let ov = d.outgoingVocalScore, iv = d.incomingVocalScore
        var detail = String(format: "交接窗口的人声密度：出曲 %@ 倍（门槛 %.2f）、入曲 %@ 倍"
                            + "（打架线 %.2f，伴奏线 %.2f）；叠加 %.2f 秒（stem 至少要 %.2f 秒）。",
                            ov.map { String(format: "%.2f", $0) } ?? "—",
                            c.stemVocalActiveRatio,
                            iv.map { String(format: "%.2f", $0) } ?? "—",
                            c.vocalClashRatio, c.stemAcapellaIncomingVocalMax,
                            d.overlapDuration, c.stemMinOverlap)
        if let base = d.stemBaselineOutPoint, let baseOverlap = d.stemBaselineOverlap {
            detail += String(format: "　不用 stem 的话，这一对会在 %@ 交接、叠 %.2f 秒。",
                             mmssText(base), baseOverlap)
        }

        var outcome: String
        if let technique = d.plannedStemTechnique {
            let moved = d.stemBaselineOutPoint.map { abs($0 - (d.outPoint ?? $0)) > 0.05 } ?? false
            outcome = "→ 升级到 \(technique)"
                + (moved
                   ? "，并把交接点从尾奏挪到 \(mmssText(d.outPoint ?? 0)) 这个还在唱的乐句起点上。"
                   : "，交接点不变。")
        } else if (ov ?? 0) < c.stemVocalActiveRatio {
            outcome = "→ 出曲尾部找不到一个人声够密的乐句起点，"
                + "stem 手法在这里等于空转，所以不用。"
        } else if d.overlapDuration < c.stemMinOverlap {
            outcome = String(format: "→ 叠加只有 %.2f 秒，撑不起 stem 手法，不用。",
                             d.overlapDuration)
        } else {
            outcome = "→ 出曲这边够唱，但入曲开头既没热到要压低、也没静到能飘清唱"
                + "（而且 acapella 只在“很搭”这一档才给），所以不用。"
        }
        // The exchange compile is a second decision on top of the planner's,
        // made where the lyrics are; it gets its own sentence rather than
        // hiding inside the technique's name.
        if let x = d.stemExchange {
            if let reason = x.fallbackReason {
                outcome += "　编排交接失败：\(reason)"
            } else {
                outcome += String(format: "　交接句落在叠加的第 %.2f 秒（出曲 %@）",
                                  x.handover, mmssText(x.handoverAbsolute))
                outcome += x.source == "lyric"
                    ? "，依据是出曲歌词「\(x.lyricLine ?? "")」唱完的位置。"
                    : "，出曲这段没有可用的歌词行末，改用人声活跃度的低谷。"
                if let from = x.clampedFrom {
                    outcome += String(format: "（原本算到 %.2f 秒，被夹回窗口内。）", from)
                }
                // The two clocks, and which side of the floor swap the voice
                // ended up on — the one sentence that tells a listener whether
                // they are about to hear a DJ move or a mix.
                if let gesture = x.gesture {
                    outcome += String(format: "　伴奏的低频交接点在第 %.2f 秒；",
                                      x.swapOffset)
                    switch gesture {
                    case .carryover:
                        outcome += String(
                            format: "人声比它晚 %.2f 秒才走（\(gesture.rawValue)，"
                                + "\(gesture.chineseLabel)）：出曲这句是骑在入曲的伴奏上唱完的，"
                                + "这段时间里入曲的人声被压住不出声。",
                            x.handover - x.swapOffset)
                        if x.carryShortfallDB < -0.05 {
                            outcome += String(
                                format: "（骑到最后补偿到顶，出曲人声比开头低了 %.1f dB。）",
                                -x.carryShortfallDB)
                        }
                    case .yield:
                        outcome += String(
                            format: "人声比它早 %.2f 秒就退了（\(gesture.rawValue)，"
                                + "\(gesture.chineseLabel)）：低频交接砸在一个没人唱的小节上，"
                                + "入曲的人声不受影响。",
                            x.swapOffset - x.handover)
                    }
                }
            }
        }
        return ChainStep(stage: "stem", title: "要不要动用人声分离",
                         rule: rule, detail: detail, outcome: outcome,
                         fired: d.plannedStemTechnique != nil || d.stemEnvelope != nil)
    }

    private static func mmssText(_ t: TimeInterval) -> String {
        String(format: "%d:%05.2f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
    }

    /// The tier, said the way a person would say it. The English term stays
    /// available in `DecisionReport.tier` for anything that needs to match on it.
    static func tierName(_ tier: String) -> String {
        switch tier {
        case "compatible": return "这两首歌很搭"
        case "neutral": return "一般般，能接但别贪"
        case "clash": return "差异很大，快进快出"
        default: return tier
        }
    }

    private static func cap(for tier: String,
                            config c: TransitionPlanner.Config) -> TimeInterval {
        switch tier {
        case "neutral": return c.neutralOverlapCap
        case "clash": return c.clashOverlapCap
        default: return c.maxOverlap
        }
    }

    private static func styleRule(_ tier: String) -> String {
        switch tier {
        case "clash":
            return "差异很大的一对：能数清出曲的拍子，就让它在拍点上戛然而止、留一串回声散掉"
                + "（echo out）；数不清就老老实实淡出。"
        case "neutral":
            return "一般般的一对：出曲自己没有淡出结尾，就用一道从低到高的滤波把它掏空着送走"
                + "（filter sweep）；本来就在自己淡出的，不再多此一举。"
        default:
            return "很搭的一对：叠加够长，就把高、中、低三段分批交接（staged EQ），"
                + "低频最后才换手；叠加太短就只做普通淡出。"
        }
    }

    private static func planReport(
        _ d: Decision, config c: TransitionPlanner.Config
    ) -> PlanReport {
        var tail: TimeInterval?, intake: TimeInterval?, ceiling: TimeInterval?
        let tierCap = cap(for: d.tier, config: c)
        if d.planKind == "crossfade" {
            tail = TransitionPlanner.tailCapacity(d.outgoingAnalysis, config: c)
            intake = TransitionPlanner.intakeCapacity(
                d.incomingAnalysis, inPoint: d.incomingAnalysis.introEnd, config: c)
            ceiling = Swift.min(c.maxOverlap, tierCap,
                                c.maxOverlapShare * Swift.min(d.outgoingDuration,
                                                              d.incomingDuration))
        }
        return PlanReport(
            kind: d.planKind, outPoint: d.outPoint, inPoint: d.inPoint,
            overlapDuration: d.overlapDuration, overlapBars: d.overlapBars,
            outgoingRate: d.outgoingRate, incomingRate: d.incomingRate,
            tailCapacity: tail, intakeCapacity: intake, ceiling: ceiling, tierCap: tierCap,
            overrideFields: d.planOverride?.specifiedFields ?? [],
            plannerOutPoint: d.plannerOutPoint,
            plannerInPoint: d.plannerInPoint,
            plannerOverlap: d.plannerOverlap,
            maxManualOverlap: PlanOverride.maxOverlap)
    }

    private static func styleReport(
        _ d: Decision, config c: TransitionPlanner.Config
    ) -> StyleReport {
        let style = d.planned.style
        let effect: String
        switch style.outroEffect {
        case .fade: effect = "fade"
        case .filterSweep: effect = "filterSweep"
        case .echoOut: effect = "echoOut"
        }
        var reason: String
        if d.planKind == "beatMatched" {
            reason = "既然两首歌能踩在同一个拍子上，出曲就规规矩矩地淡出，"
                + "并把高、中、低三段分批交给入曲。"
        } else if d.overridden {
            reason = "这一版的手法是面板上手动选的，不是规则算出来的。"
        } else {
            switch d.tier {
            case "clash":
                reason = d.outgoingBPMConfidence >= c.bpmConfidenceThreshold
                    && d.outgoingBPM > 0
                    ? String(format: "差异很大，而出曲 %.1f BPM 的拍子数得准，"
                             + "所以让它在拍点上停住，留一串 %.0f 毫秒的回声散场。",
                             d.outgoingBPM, (style.echoDelayTime ?? 0) * 1000)
                    : String(format: "差异很大，但出曲的拍子只有 %.2f 的把握（要 %.2f 以上），"
                             + "回声接不到点上，改成普通淡出。",
                             d.outgoingBPMConfidence, c.bpmConfidenceThreshold)
            case "neutral":
                reason = d.outgoingAnalysis.outroFadeStart == nil
                    ? "一般般的一对，出曲自己没有淡出结尾，"
                      + "所以用一道从低到高的滤波把它慢慢掏空着送走。"
                    : String(format: "一般般的一对，不过出曲从 %.1f 秒起就在自己淡出了，"
                             + "再扫一道反而多余，普通淡出即可。",
                             d.outgoingAnalysis.outroFadeStart ?? 0)
            default:
                reason = d.overlapDuration >= c.stagedEQMinOverlap
                    ? String(format: "很搭的一对，叠加有 %.2f 秒（够到 %.2f 秒的门槛），"
                             + "值得把高、中、低三段分批交接，低频最后才换手。",
                             d.overlapDuration, c.stagedEQMinOverlap)
                    : String(format: "很搭的一对，但叠加只有 %.2f 秒，不到 %.2f 秒，"
                             + "分段交接来不及展开，只做普通淡出。",
                             d.overlapDuration, c.stagedEQMinOverlap)
            }
        }
        return StyleReport(description: d.styleDescription, outroEffect: effect,
                           stagedEQ: style.stagedEQ, echoDelayTime: style.echoDelayTime,
                           reason: reason)
    }
}
