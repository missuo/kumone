import AVFoundation
import Foundation

/// The offline AutoMix tuning surface, and the only part of KumoneCore the
/// `audition` CLI touches.
///
/// It exists so a transition-parameter change can be judged in seconds:
/// analyze (cached), plan, explain *why* that plan was chosen, and render the
/// hand-over to a WAV you can `afplay`. Everything below the surface is the
/// production code — `TrackAnalyzer`, `TransitionPlanner`,
/// `TransitionAutomation`, `DeckChain` — so what you hear is what the player
/// would do.
public enum Audition {

    // MARK: - Analysis (sidecar-cached)

    /// Analyze `url`, reusing (and writing) a `<file>.analysis.json` sidecar so
    /// a re-run over the same corpus is instant. Same format and version gate
    /// as the app's own `AudioCache` sidecars.
    static func analysis(of url: URL, useCache: Bool = true) throws -> TrackAnalysis {
        let sidecar = URL(fileURLWithPath: url.path + ".analysis.json")
        if useCache, let data = try? Data(contentsOf: sidecar),
           let cached = try? JSONDecoder().decode(TrackAnalysis.self, from: data),
           cached.version == TrackAnalysis.currentVersion {
            return cached
        }
        let fresh = try TrackAnalyzer.analyze(fileAt: url)
        if useCache, let data = try? JSONEncoder().encode(fresh) {
            try? data.write(to: sidecar, options: .atomic)
        }
        return fresh
    }

    /// Whether a usable sidecar already exists (so the CLI can say "analyzing"
    /// only when it really is).
    public static func hasCachedAnalysis(for url: URL) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: url.path + ".analysis.json")),
              let cached = try? JSONDecoder().decode(TrackAnalysis.self, from: data)
        else { return false }
        return cached.version == TrackAnalysis.currentVersion
    }

    // MARK: - Style / fade overrides

    /// `--style` values, for auditioning one technique in isolation.
    public enum StyleOverride: String, CaseIterable, Sendable {
        case plain, sweep, echo, staged
    }

    /// `--stem` values: a technique picked by hand, layered onto whatever
    /// style the planner (or `--style`) chose rather than replacing it.
    ///
    /// The planner can now choose `vocalDuck` / `acapellaOver` itself when it
    /// is told `stems: .ready`; this stays the way to hear a technique the
    /// rules would not have picked — `instrumentalOut` above all, which is
    /// never chosen automatically.
    public enum StemOverride: Sendable, Equatable {
        case acapella
        case instrumental
        case duck(depthDB: Float)
        /// The orchestrated vocal hand-off template; `decide` compiles it
        /// against the outgoing track's lyrics like the planner's own.
        case exchange
        /// A finished four-lane orchestration — what an AI's `stemEnvelope`
        /// arrives as. There is no name for it: it *is* its curves.
        case custom(StemEnvelope)

        /// S1's blind-test depth.
        public static let defaultDuckDepthDB: Float = -9
        /// The names the CLI and the console offer, without the `duck:N` tail.
        public static let names = ["acapella", "instrumental", "duck", "exchange"]

        /// `acapella` / `instrumental` / `duck` / `duck:9` / `duck:-9` /
        /// `exchange`. The duck depth is read as an attenuation either way —
        /// `duck:9` and `duck:-9` both mean 9 dB down, because nobody means +9.
        public static func parse(_ raw: String) -> StemOverride? {
            let parts = raw.split(separator: ":", maxSplits: 1)
            guard let head = parts.first else { return nil }
            switch head {
            case "acapella", "acapellaOver": return .acapella
            case "instrumental", "instrumentalOut": return .instrumental
            case "exchange", "vocalExchange": return .exchange
            case "duck", "vocalDuck":
                guard parts.count == 2 else { return .duck(depthDB: defaultDuckDepthDB) }
                guard let value = Float(parts[1]) else { return nil }
                return .duck(depthDB: -abs(value))
            default: return nil
            }
        }

        var technique: StemTechnique {
            switch self {
            case .acapella: return .acapellaOver
            case .instrumental: return .instrumentalOut
            case .duck(let depth): return .vocalDuck(depthDB: depth)
            case .exchange: return .vocalExchange
            case .custom(let envelope): return .custom(envelope)
            }
        }
    }

    // MARK: - Plan-level override

    /// A hand-written (or AI-written) hand-over geometry for *this one pair*,
    /// layered on top of whatever the planner decided.
    ///
    /// The 35 planner knobs are global: they move every pair in the corpus at
    /// once, which is the wrong instrument when the thing you want is "on this
    /// pair, leave the outgoing vocal running four bars longer and bring the
    /// incoming in from its instrumental intro". That is a *plan*, not a
    /// threshold, so it lives here — outside `TransitionPlanner`, which stays a
    /// pure function of the two analyses.
    ///
    /// Every field is optional; an omitted one keeps the planner's own value.
    public struct PlanOverride: Sendable, Equatable {
        /// Seconds into the outgoing track where the hand-over starts.
        public var outPoint: TimeInterval?
        /// Seconds into the incoming track that lands on `outPoint`.
        public var inPoint: TimeInterval?
        /// How long the two run together.
        public var overlap: TimeInterval?

        public init(outPoint: TimeInterval? = nil, inPoint: TimeInterval? = nil,
                    overlap: TimeInterval? = nil) {
            self.outPoint = outPoint
            self.inPoint = inPoint
            self.overlap = overlap
        }

        /// Longer than this and it stops being a transition and starts being a
        /// mashup; also the point past which the renderer's pre/post roll makes
        /// the audition file unwieldy.
        public static let maxOverlap: TimeInterval = 40
        /// `TransitionAutomation.Geometry` floors the overlap at 0.1 s; asking
        /// for less than half a second is always a mistake, not a taste.
        public static let minOverlap: TimeInterval = 0.5

        public var isEmpty: Bool { outPoint == nil && inPoint == nil && overlap == nil }

        /// Which fields were actually specified, in panel order.
        public var specifiedFields: [String] {
            var out: [String] = []
            if outPoint != nil { out.append("outPoint") }
            if inPoint != nil { out.append("inPoint") }
            if overlap != nil { out.append("overlap") }
            return out
        }

        /// Seconds from `199.5`, `"199.5"`, `"3:19.5"`, `"03:19"` or
        /// `"1:03:19.5"`. Returns nil for anything else — including negatives
        /// and out-of-range minute/second fields, so a typo is a rejection
        /// rather than a surprising number.
        public static func seconds(from raw: String) -> TimeInterval? {
            let text = raw.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            if !text.contains(":") {
                guard let v = Double(text), v.isFinite, v >= 0 else { return nil }
                return v
            }
            let parts = text.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2 || parts.count == 3 else { return nil }
            var total: TimeInterval = 0
            for (i, part) in parts.enumerated() {
                guard let v = Double(part), v.isFinite, v >= 0 else { return nil }
                // Only the leading field may exceed its wheel: "90:00" is a
                // legitimate 90 minutes, but "3:75" is a typo.
                if i > 0 && v >= 60 { return nil }
                total = total * 60 + v
            }
            return total
        }

        /// Accepts a JSON value that is either a number or one of the strings
        /// `seconds(from:)` understands.
        public static func seconds(fromJSON value: Any) -> TimeInterval? {
            if let n = value as? NSNumber {
                let v = n.doubleValue
                return v.isFinite && v >= 0 ? v : nil
            }
            if let s = value as? String { return seconds(from: s) }
            return nil
        }

        /// Why an override could not be honoured, phrased for the console.
        public enum Failure: LocalizedError, Equatable {
            case notANumber(field: String, given: String)
            case pastEnd(field: String, value: TimeInterval, duration: TimeInterval, track: String)
            case overlapTooLong(TimeInterval)
            case overlapTooShort(TimeInterval)
            case tailTooShort(outPoint: TimeInterval, available: TimeInterval,
                              wanted: TimeInterval)
            case intakeTooShort(inPoint: TimeInterval, available: TimeInterval,
                                wanted: TimeInterval)

            public var errorDescription: String? {
                func t(_ s: TimeInterval) -> String {
                    String(format: "%d:%05.2f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
                }
                switch self {
                case .notANumber(let field, let given):
                    return "planOverride.\(field) 看不懂：\(given)。"
                        + "用秒（如 199.5）或 mm:ss(.xx)（如 3:19.5）。"
                case .pastEnd(let field, let value, let duration, let track):
                    return "planOverride.\(field) = \(t(value))，超出了\(track)的时长 \(t(duration))。"
                case .overlapTooLong(let v):
                    return String(format: "planOverride.overlap = %.2f 秒，超过 %.0f 秒的上限。",
                                  v, maxOverlap)
                case .overlapTooShort(let v):
                    return String(format: "planOverride.overlap = %.2f 秒，短于 %.2f 秒的下限。",
                                  v, minOverlap)
                case .tailTooShort(let outPoint, let available, let wanted):
                    return String(format: "出点 %@ 之后只剩 %.2f 秒，放不下 %.2f 秒的叠加。",
                                  t(outPoint), available, wanted)
                case .intakeTooShort(let inPoint, let available, let wanted):
                    return String(format: "入点 %@ 之后只剩 %.2f 秒，放不下 %.2f 秒的叠加。",
                                  t(inPoint), available, wanted)
                }
            }
        }

        /// The geometry this override resolves to against a planner baseline,
        /// or the first rule it breaks.
        ///
        /// `baseOverlap` is floored at `minOverlap` so a `.gapless` baseline
        /// (no overlap at all) still has something to move.
        public func resolve(
            baseOutPoint: TimeInterval, baseInPoint: TimeInterval, baseOverlap: TimeInterval,
            outgoingDuration: TimeInterval, incomingDuration: TimeInterval
        ) throws -> (outPoint: TimeInterval, inPoint: TimeInterval, overlap: TimeInterval) {
            let o = outPoint ?? baseOutPoint
            let i = inPoint ?? baseInPoint
            let d = overlap ?? Swift.max(baseOverlap, Self.minOverlap)

            guard o < outgoingDuration else {
                throw Failure.pastEnd(field: "outPoint", value: o,
                                      duration: outgoingDuration, track: "出曲")
            }
            guard i < incomingDuration else {
                throw Failure.pastEnd(field: "inPoint", value: i,
                                      duration: incomingDuration, track: "入曲")
            }
            guard d <= Self.maxOverlap else { throw Failure.overlapTooLong(d) }
            guard d >= Self.minOverlap else { throw Failure.overlapTooShort(d) }
            let tail = outgoingDuration - o
            guard tail + 1e-6 >= d else {
                throw Failure.tailTooShort(outPoint: o, available: tail, wanted: d)
            }
            let intake = incomingDuration - i
            guard intake + 1e-6 >= d else {
                throw Failure.intakeTooShort(inPoint: i, available: intake, wanted: d)
            }
            return (o, i, d)
        }
    }

    // MARK: - Hand-written envelopes

    /// Reading a four-lane orchestration out of a JSON reply.
    ///
    /// `{"outVocal": [[0, 0], [9, 0], [9.8, -40]], "inBed": [[0, -6], [8, 0]]}`
    /// — seconds and dB, lanes optional, an omitted lane meaning 0 dB
    /// pass-through. This is the same contract `StemEnvelope` documents; the
    /// only thing living here is the *spelling*, because the spelling is a
    /// console/AI concern and `StemEnvelope` is a playback one.
    public enum StemEnvelopeInput {

        public enum Failure: LocalizedError, Equatable {
            case notAnObject(given: String)
            case laneNotAnArray(lane: String)
            case pointNotAPair(lane: String, given: String)
            case notANumber(lane: String, given: String)
            case unknownLane(String)
            case conflictsWithStem

            public var errorDescription: String? {
                switch self {
                case .notAnObject(let given):
                    return "stemEnvelope 要是一个对象，比如 "
                        + #"{"outVocal": [[0, 0], [9, 0]]}，收到的是：\#(given)"#
                case .laneNotAnArray(let lane):
                    return "stemEnvelope.\(lane) 要是一个数组，每项是 [秒, dB]。"
                case .pointNotAPair(let lane, let given):
                    return "stemEnvelope.\(lane) 里的每一项都要写成 [秒, dB] 两个数字，"
                        + "收到的是：\(given)"
                case .notANumber(let lane, let given):
                    return "stemEnvelope.\(lane) 里有不是数字的取值：\(given)"
                case .unknownLane(let name):
                    return "stemEnvelope 里没有 \(name) 这条轨。只有 outVocal / outBed /"
                        + " inVocal / inBed 四条。"
                case .conflictsWithStem:
                    return "\"stem\" 和 \"stemEnvelope\" 只能给一个："
                        + "前者是选一个现成手法，后者是自己写四条增益曲线。"
                        + "想要标准的人声交接就写 \"stem\": \"exchange\"。"
                }
            }
        }

        /// Structure, lane names, gain range and monotonicity. The *time*
        /// bound needs the overlap, which is only final after any
        /// `planOverride` has been applied, so `decide` checks that separately
        /// against the geometry it ends up with.
        /// `String(describing:)` pretty-prints a JSON array across five lines,
        /// which is not what a one-line error message wants to quote back.
        static func describe(_ value: Any) -> String {
            if let data = try? JSONSerialization.data(withJSONObject: value,
                                                      options: [.fragmentsAllowed]),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
            return String(describing: value)
                .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }

        public static func parse(_ raw: Any) throws -> StemEnvelope {
            guard let object = raw as? [String: Any] else {
                throw Failure.notAnObject(given: describe(raw))
            }
            var envelope = StemEnvelope()
            for (key, value) in object {
                if value is NSNull { continue }
                guard let lane = StemEnvelope.Lane.named(key) else {
                    throw Failure.unknownLane(key)
                }
                guard let rows = value as? [Any] else {
                    throw Failure.laneNotAnArray(lane: key)
                }
                var points: [StemEnvelope.Breakpoint] = []
                for row in rows {
                    guard let pair = row as? [Any], pair.count == 2 else {
                        throw Failure.pointNotAPair(lane: key, given: describe(row))
                    }
                    var numbers: [Double] = []
                    for item in pair {
                        guard let n = (item as? NSNumber)?.doubleValue, n.isFinite else {
                            throw Failure.notANumber(lane: key, given: describe(item))
                        }
                        numbers.append(n)
                    }
                    points.append(StemEnvelope.Breakpoint(t: numbers[0],
                                                          gainDB: Float(numbers[1])))
                }
                // `.infinity` here means "do not judge the times yet"; every
                // other rule (count, order, dB range) is judged now, where the
                // message can still name the field the author typed.
                try StemEnvelope.validate(points, lane: key, overlap: .infinity)
                envelope[lane] = points
            }
            return envelope
        }
    }

    // MARK: - Decision

    /// A planned transition plus the numbers that produced it.
    public struct Decision: Sendable {
        public let outgoingName: String
        public let incomingName: String
        public let outgoingDuration: TimeInterval
        public let incomingDuration: TimeInterval

        /// "compatible" / "neutral" / "clash", after any key demotion.
        public let tier: String
        /// The key gate turned a compatible pair into a neutral one.
        public let demotedByKey: Bool

        /// Level gap at the hand-over after **both** gain stages — the
        /// per-track loudness trims and the transition gain ride. This is what
        /// the tier gate judges, and what the listener hears at the seam.
        public let loudnessGapDB: Double
        /// The same gap after the trims but before the ride (stage two).
        public let trimmedLoudnessGapDB: Double
        /// The same gap before any compensation (stage one), and the two trims
        /// that closed the first part of it.
        public let rawLoudnessGapDB: Double
        public let outgoingTrimDB: Double
        public let incomingTrimDB: Double
        /// Signed gain ride the incoming deck is held at across the overlap,
        /// in dB (negative = held down). See `TransitionPlanner.rideDB`.
        public let rideDB: Double
        /// How long that ride takes to unwind back to unity after the overlap.
        public let rideReleaseSeconds: TimeInterval
        /// Whole-track mastered loudness (LUFS) of each side, nil when unknown.
        public let outgoingLoudnessLUFS: Double?
        public let incomingLoudnessLUFS: Double?
        public let timbreDistance: Double
        public let tempoRatio: Double?
        public let keyDistance: Int?
        public let outgoingBPM: Double
        public let incomingBPM: Double
        public let outgoingBPMConfidence: Double
        public let incomingBPMConfidence: Double
        /// Vocal activity over the chosen overlap window, relative to each
        /// track's own mean. Above `vocalClashRatio` on both sides is the one
        /// blend a DJ never allows.
        public let outgoingVocalScore: Double?
        public let incomingVocalScore: Double?

        /// "beatMatched" / "crossfade" / "gapless".
        public let planKind: String
        /// e.g. "fade+stagedEQ", "echoOut (delay 0.37s)", "filterSweep".
        public let styleDescription: String
        public let outPoint: TimeInterval?
        public let inPoint: TimeInterval?
        public let overlapDuration: TimeInterval
        public let overlapBars: Int?
        public let outgoingRate: Float?
        public let incomingRate: Float?
        /// Whether `--style` / `--fade` rewrote the planner's own choice.
        public let overridden: Bool

        /// A hand-written hand-over geometry for this pair, if one was given,
        /// alongside what the planner had chosen before it — so the console
        /// can show the move rather than just the destination.
        public let planOverride: PlanOverride?
        public let plannerOutPoint: TimeInterval?
        public let plannerInPoint: TimeInterval?
        public let plannerOverlap: TimeInterval

        /// Whether the planner was told a vocal separator is available.
        public let stemsReady: Bool
        /// The stem technique the *planner* chose, before any `--stem`
        /// override — nil when it chose none (or was never offered stems).
        public let plannedStemTechnique: String?
        /// What the same pair would have got with `stems: .none`, so the
        /// console can say how far the stem rules moved the hand-over.
        /// Nil when stems were not offered.
        public let stemBaselineOutPoint: TimeInterval?
        public let stemBaselineOverlap: TimeInterval?
        /// How a `.vocalExchange` (planner's or `--stem exchange`'s) compiled:
        /// where the vocal changes hands, on which lyric line, and — when it
        /// could not — why it degraded to a duck. Nil when no exchange was
        /// asked for.
        public let stemExchange: ExchangeCompilation?
        /// The four-lane curves this render will actually play, whether they
        /// came from the exchange template or straight from a hand-written
        /// `stemEnvelope`. Nil for the three one-shot gestures and for no stem.
        public let stemEnvelope: StemEnvelope?

        // --- Transition score (docs/automix-score-predev.md). Empty on every
        // decision made without `scoreEnabled`, which is every shipped one.

        /// The score the planner offered, named as the predev names it
        /// ("cutOnOne+echoThrow"). Nil when none was.
        public let scoreLabel: String?
        /// Whether it compiled against the two beat grids. False with a
        /// `scoreLabel` present means the render is the plain blend — a score
        /// that cannot be placed is thrown away whole, never approximated.
        public let scoreCompiled: Bool
        /// The compile, in sentences: where the seam landed, what was thrown
        /// where, and what degraded or refused. Empty when no score was offered.
        public let scoreLines: [String]
        /// The compiled lanes the render will actually perform.
        let scoreLanes: WholeMixLanes?

        /// "timbre 0.31 vs clash line 0.30" — signals sitting close enough to a
        /// threshold that nudging the constant would flip this pair.
        public let nearMisses: [String]

        /// Every gate the planner walked for this pair, and the first one it
        /// failed. This is the ledger behind "why is this pair not
        /// beat-matched": see `PlanTrace`.
        public let planTrace: PlanTrace

        /// Where the chosen out/in point sits in that side's structure —
        /// "chorus 130–170, +40.0 s in (its end)". Nil when the side has no
        /// usable sections, which is the normal state for most of a library.
        public let outPointSection: String?
        public let inPointSection: String?
        /// Segmenter confidence per side; 0 means "no structure to act on".
        public let outgoingStructureConfidence: Double
        public let incomingStructureConfidence: Double

        /// The tier the signals alone produced, before the key gate.
        public let rawTier: String
        /// `name: value` for every knob this decision was made under.
        public let config: [String: Double]

        let planned: PlannedTransition
        let outgoingURL: URL
        let incomingURL: URL
        let outgoingAnalysis: TrackAnalysis
        let incomingAnalysis: TrackAnalysis
        let resolvedConfig: TransitionPlanner.Config
        let signals: TransitionPlanner.Signals
    }

    /// Which section a cue landed in, and where inside it — the sentence the
    /// console and the corpus sweep quote next to a moved out point ("it used to
    /// cut in the second verse, now it cuts where the last chorus ends").
    private static func sectionContext(
        _ sections: [TrackAnalysis.Section], at t: TimeInterval?
    ) -> String? {
        guard let t, !sections.isEmpty else { return nil }
        guard let s = sections.last(where: { $0.start <= t + 0.01 }) ?? sections.first
        else { return nil }
        // "at its end" is the case the whole structure layer exists to produce,
        // so it gets said rather than left to arithmetic.
        let where_: String
        if abs(t - s.end) < 1 { where_ = "at its end" }
        else if abs(t - s.start) < 1 { where_ = "at its start" }
        else { where_ = String(format: "+%.1f s in", t - s.start) }
        return String(format: "%@ %.0f–%.0f %@", s.kind.rawValue, s.start, s.end, where_)
    }

    /// Analyze both tracks, plan the hand-over, and explain the decision.
    ///
    /// `config` names planner knobs to override (see
    /// `TransitionPlanner.Config.fields`); an empty dictionary — the default,
    /// and what every product path uses — resolves to `Config.standard`.
    public static func decide(
        outgoing outgoingURL: URL, incoming incomingURL: URL,
        style styleOverride: StyleOverride? = nil,
        fade fadeOverride: TimeInterval? = nil,
        stem stemOverride: StemOverride? = nil,
        plan planOverride: PlanOverride? = nil,
        score scoreOverride: TransitionScore? = nil,
        stems: StemAvailability = .none,
        config configOverrides: [String: Double] = [:],
        useCache: Bool = true
    ) throws -> Decision {
        let out = try analysis(of: outgoingURL, useCache: useCache)
        let inc = try analysis(of: incomingURL, useCache: useCache)
        let config = TransitionPlanner.Config.standard(overriding: configOverrides)

        let signals = TransitionPlanner.signals(outgoing: out, incoming: inc, config: config)
        let rawTier = TransitionPlanner.tier(of: signals, config: config)
        let keyDistance = TransitionPlanner.keyDistance(out, inc, config: config)
        let demoted = rawTier == .compatible
            && (keyDistance ?? 0) >= config.clashKeyDistance
        let effectiveTier = demoted ? TransitionPlanner.CompatibilityTier.neutral : rawTier

        // The corpus keeps a `.lrc` next to every track, and the app now writes
        // one next to its cache; both sides therefore hand the planner the same
        // out-point snap grid, and the console decides what the product decides.
        let context = TransitionPlanner.PlanContext(
            outgoingLyricLineEnds: Lyrics.lineEnds(for: outgoingURL))

        var trace: PlanTrace? = PlanTrace()
        var planned = TransitionPlanner.plan(outgoing: out, incoming: inc,
                                             stems: stems, config: config,
                                             context: context, trace: &trace)
        let planTrace = trace ?? PlanTrace()
        let plannedStem = planned.style.stemTechnique
        // The same decision without stems, purely so the console can quote the
        // difference. Planning is a pure function over two cached analyses, so
        // this costs microseconds.
        var baselineOutPoint: TimeInterval?
        var baselineOverlap: TimeInterval?
        if stems == .ready {
            let base = TransitionPlanner.plan(outgoing: out, incoming: inc,
                                              stems: .none, config: config, context: context)
            baselineOutPoint = base.plan.outPoint
            baselineOverlap = TransitionAutomation.Geometry(plan: base.plan).overlapDuration
        }
        var overridden = false
        if let fadeOverride {
            planned = applyFade(fadeOverride, to: planned, outgoingDuration: out.duration)
            overridden = true
        }
        // Every override below carries `rideDB` through untouched. The ride is
        // a level match between two *tracks*, derived from their local RMS
        // windows and the trims they will play at — none of which a hand-picked
        // style, stem technique or seam changes. Recomputing it from a moved
        // window would also make the console's three-stage loudness narrative
        // disagree with the tier gate, which is decided long before any of
        // these run. Move the seam, keep the level match.
        if let styleOverride {
            planned = PlannedTransition(plan: planned.plan,
                                        style: style(styleOverride, basedOn: planned.style),
                                        rideDB: planned.rideDB)
            overridden = true
        }
        if let stemOverride {
            var style = planned.style
            style.stemTechnique = stemOverride.technique
            planned = PlannedTransition(plan: planned.plan, style: style,
                                        rideDB: planned.rideDB)
            overridden = true
        }

        // Where the planner had landed, captured before any plan-level
        // override rewrites it, so the report can quote the diff.
        let plannerGeometry = TransitionAutomation.Geometry(plan: planned.plan)
        let plannerOutPoint = planned.plan.outPoint
        let plannerInPoint = planInPoint(of: planned.plan)
        let plannerOverlap = plannerGeometry.overlapDuration
        var appliedPlanOverride: PlanOverride?
        if let planOverride, !planOverride.isEmpty {
            planned = try apply(planOverride, to: planned,
                                outgoingDuration: out.duration, incomingDuration: inc.duration)
            // Deliberately not `overridden`: that flag is about the *style*
            // having been rewritten by hand, and the report has its own step
            // and chip for a moved seam.
            appliedPlanOverride = planOverride
        }

        // --- Compile `.vocalExchange` last, once the geometry is final: the
        // template is written in overlap-relative seconds and reads the fade
        // law it will sit on top of, so a plan override that moved the seam or
        // stretched the window has to be visible to it.
        var exchange: ExchangeCompilation?
        if planned.style.stemTechnique == .vocalExchange {
            let compiled = VocalExchange.compile(outgoingURL: outgoingURL, outgoing: out,
                                                 planned: planned, config: config)
            var style = planned.style
            style.stemTechnique = compiled.technique
            planned = PlannedTransition(plan: planned.plan, style: style,
                                        rideDB: planned.rideDB)
            exchange = compiled.compilation
        }
        // --- And the score, last of all, for the same reason: it is addressed
        // in bars around the seam, so it cannot be placed until the seam is
        // final. A hand-passed score wins over whatever the planner offered.
        if let scoreOverride {
            var style = planned.style
            style.score = scoreOverride
            planned = PlannedTransition(plan: planned.plan, style: style,
                                        rideDB: planned.rideDB)
        }
        var scoreCompilation: ScoreCompiler.Compilation?
        if let score = planned.style.score {
            scoreCompilation = ScoreCompiler.compile(score, planned: planned,
                                                     outgoing: out, incoming: inc,
                                                     outgoingURL: outgoingURL)
        }

        var envelope: StemEnvelope?
        if case .custom(let compiled) = planned.style.stemTechnique {
            // A hand-written envelope is only checked against the overlap here,
            // because *here* is the first point at which the overlap is final:
            // `--fade`, a style override and a `planOverride` can all move it.
            try compiled.validate(
                overlap: TransitionAutomation.Geometry(plan: planned.plan).overlapDuration)
            envelope = compiled
        }

        let geometry = TransitionAutomation.Geometry(plan: planned.plan)
        let outPoint = planned.plan.outPoint
        let inPoint: TimeInterval?
        var bars: Int?
        var outRate: Float?
        var inRate: Float?
        switch planned.plan {
        case .beatMatched(let p):
            inPoint = p.inPoint
            bars = p.overlapBars
            outRate = p.outgoingRate
            inRate = p.incomingRate
        case .crossfade(_, _, let point):
            inPoint = point
        case .gapless:
            inPoint = nil
        }

        let window = geometry.overlapDuration
        let outVocal = outPoint.flatMap {
            TransitionPlanner.vocalScore(out, from: $0, length: window)
        }
        let inVocal = inPoint.flatMap {
            TransitionPlanner.vocalScore(inc, from: $0, length: window)
        }

        return Decision(
            outgoingName: outgoingURL.lastPathComponent,
            incomingName: incomingURL.lastPathComponent,
            outgoingDuration: out.duration,
            incomingDuration: inc.duration,
            tier: name(of: effectiveTier),
            demotedByKey: demoted,
            loudnessGapDB: signals.loudnessGapDB,
            trimmedLoudnessGapDB: signals.trimmedLoudnessGapDB,
            rawLoudnessGapDB: signals.rawLoudnessGapDB,
            outgoingTrimDB: signals.outgoingTrimDB,
            incomingTrimDB: signals.incomingTrimDB,
            rideDB: planned.rideDB,
            rideReleaseSeconds: TransitionAutomation.rideReleaseDuration(planned.rideDB),
            outgoingLoudnessLUFS: out.referenceLoudness,
            incomingLoudnessLUFS: inc.referenceLoudness,
            timbreDistance: signals.timbreDistance,
            tempoRatio: signals.tempoRatio,
            keyDistance: keyDistance,
            outgoingBPM: out.bpm, incomingBPM: inc.bpm,
            outgoingBPMConfidence: out.bpmConfidence,
            incomingBPMConfidence: inc.bpmConfidence,
            outgoingVocalScore: outVocal, incomingVocalScore: inVocal,
            planKind: kind(of: planned.plan),
            styleDescription: describe(planned.style, geometry: geometry),
            outPoint: outPoint, inPoint: inPoint,
            overlapDuration: window, overlapBars: bars,
            outgoingRate: outRate, incomingRate: inRate,
            overridden: overridden,
            planOverride: appliedPlanOverride,
            plannerOutPoint: plannerOutPoint,
            plannerInPoint: plannerInPoint,
            plannerOverlap: plannerOverlap,
            stemsReady: stems == .ready,
            plannedStemTechnique: plannedStem?.label,
            stemBaselineOutPoint: baselineOutPoint,
            stemBaselineOverlap: baselineOverlap,
            stemExchange: exchange,
            stemEnvelope: envelope,
            scoreLabel: planned.style.score?.label,
            scoreCompiled: scoreCompilation?.didCompile ?? false,
            scoreLines: scoreCompilation.map(describe) ?? [],
            scoreLanes: scoreCompilation?.lanes,
            nearMisses: nearMisses(signals: signals, keyDistance: keyDistance,
                                   outVocal: outVocal, inVocal: inVocal, config: config),
            planTrace: planTrace,
            outPointSection: sectionContext(out.sections, at: outPoint),
            inPointSection: sectionContext(inc.sections, at: inPoint),
            outgoingStructureConfidence: out.structureConfidence,
            incomingStructureConfidence: inc.structureConfidence,
            rawTier: name(of: rawTier),
            config: config.asDictionary,
            planned: planned, outgoingURL: outgoingURL, incomingURL: incomingURL,
            outgoingAnalysis: out, incomingAnalysis: inc,
            resolvedConfig: config, signals: signals)
    }

    /// A compiled score, in sentences — the console and the CLI print these
    /// verbatim. Kept here rather than in `ScoreCompiler` so the compiler stays
    /// a pure placement problem with no opinions about phrasing.
    static func describe(_ c: ScoreCompiler.Compilation) -> [String] {
        if let refusal = c.refusalReason {
            return ["乐谱 \(c.label) 没有上演：\(refusal)", "这次转场听到的是今天的 blend。"]
        }
        var lines = [String(format: "乐谱 %@：seam 落在叠加的 +%.3f 秒"
                            + "（出曲 %.3f 秒 / 入曲 %.3f 秒），"
                            + "相对低频交接点移了 %+.3f 秒以落到小节线上。",
                            c.label, c.seamOffset, c.seamOutgoing, c.seamIncoming,
                            c.seamSnapSeconds)]
        for placed in c.events {
            lines.append(String(format: "  %@ @ bar %d beat %.2f → +%.3f 秒",
                                placed.event, placed.at.bar, placed.at.beat, placed.offset))
        }
        if let throwDirective = c.echoThrow {
            lines.append(String(format: "  echo throw 从 +%.3f 秒起甩进 %.0f ms 的 delay%@",
                                throwDirective.throwAt, throwDirective.delayTime * 1000,
                                c.echoLine.map { "（末句：“\($0)”）" } ?? ""))
        }
        lines.append(contentsOf: c.degradations.map { "  ⚠︎ \($0)" })
        lines.append(String(format: "  切边沿 %.0f ms（半余弦），逐样本施加，不做任何分离。",
                            WholeMixLane.cutEdgeSeconds * 1000))
        return lines
    }

    // MARK: - Rendering

    public struct RenderSummary: Sendable {
        public let outputURL: URL
        public let duration: TimeInterval
        public let overlapStart: TimeInterval
        public let overlapDuration: TimeInterval
        public let renderSeconds: Double
        public let realtimeFactor: Double
        /// The stem technique that shaped this render, the wall-clock cost of
        /// getting the stem, and — when a requested technique could not run —
        /// why the render fell back to the whole mix.
        public let stemTechnique: String?
        public let stemSeconds: Double?
        public let stemSeparatedSeconds: TimeInterval?
        /// Non-nil only when the render also split the *incoming* deck — a
        /// four-lane envelope with a live incoming lane. That is a second
        /// separation pass, and it costs a second ~15 s on a cold window.
        public let stemIncomingSeparatedSeconds: TimeInterval?
        /// Which decks were split, in the order they were.
        public let stemSeparatedSides: [String]
        /// Vocal energy in the separated window over the mixture's. Near zero
        /// means the outgoing window is instrumental, so the technique had
        /// nothing to act on however correctly it ran.
        public let stemVocalEnergyRatio: Double?
        public let stemCacheHit: Bool
        public let stemFallbackReason: String?
        /// The trims the render played the two decks at — the product's own
        /// compensation, so the render is what the player would do.
        public let outgoingTrimDB: Double
        public let incomingTrimDB: Double
        /// The hand-over's gain ride the incoming deck was held at across the
        /// overlap (dB), and how long its release took to unwind. Both are
        /// audible in the file: the render carries the ride's whole envelope.
        public let rideDB: Double
        public let rideReleaseSeconds: TimeInterval
        /// Blind-test level matching: what the finished mix measured and the
        /// constant gain applied to bring it to `normalizationTargetLUFS`.
        /// Purely a fairness device for A/B listening; no product counterpart.
        public let measuredLUFS: Double?
        public let normalizationGainDB: Double
        public let normalizationTargetLUFS: Double?
        /// The render performed a score's whole-mix lanes, and — when it was
        /// asked to and did not — why not.
        public let scoreLanesApplied: Bool
        public let scoreFallbackReason: String?
    }

    /// Render the decision's transition to a 44.1 kHz / 16-bit WAV.
    ///
    /// `stemProvider` is only consulted when the decision's style carries a
    /// stem technique; without one, a stem render degrades to a whole-mix
    /// render and says so in `RenderSummary.stemFallbackReason`.
    ///
    /// `rideReleaseDBPerSecond` overrides how fast the gain ride is let go of,
    /// for A/B-ing that slope against the shipped one; nil renders what the
    /// player does. It is the one render parameter with no counterpart in a
    /// planner knob, because the slope is a constant the engine reaches without
    /// a `Config` in hand — see `OfflineTransitionRenderer.Options`.
    public static func render(_ decision: Decision, to outputURL: URL,
                              preRoll: TimeInterval = 12,
                              postRoll: TimeInterval = 12,
                              rideReleaseDBPerSecond: Double? = nil,
                              stemProvider: VocalStemProvider? = nil) throws -> RenderSummary {
        var options = OfflineTransitionRenderer.Options()
        options.preRoll = preRoll
        options.postRoll = postRoll
        options.vocalStemProvider = stemProvider
        // The render plays the decks at exactly the trims the product would.
        options.outgoingTrimDB = decision.signals.outgoingTrimDB
        options.incomingTrimDB = decision.signals.incomingTrimDB
        // …and with the same bent-rate headroom pad, which needs each track's
        // own peak. Without these the render would clip where the player does
        // not, which is exactly the kind of divergence the audition exists to
        // rule out.
        options.outgoingPeakDBFS = decision.outgoingAnalysis.peakDBFS
        options.incomingPeakDBFS = decision.incomingAnalysis.peakDBFS
        // …and at exactly the gain ride it would ride, release included.
        options.rideDB = decision.planned.rideDB
        options.rideReleaseDBPerSecond = rideReleaseDBPerSecond
        // The compiled score, if this decision has one that placed. Nothing
        // here consults `stemProvider`: whole-mix lanes separate nothing.
        options.mixLanes = decision.scoreLanes
        let result = try OfflineTransitionRenderer.render(
            decision.planned,
            outgoing: decision.outgoingURL, incoming: decision.incomingURL,
            to: outputURL, options: options)
        return RenderSummary(outputURL: result.outputURL, duration: result.duration,
                             overlapStart: result.overlapStart,
                             overlapDuration: result.overlapDuration,
                             renderSeconds: result.renderSeconds,
                             realtimeFactor: result.realtimeFactor,
                             stemTechnique: result.stemTechnique,
                             stemSeconds: result.stemSeconds,
                             stemSeparatedSeconds: result.stemSeparatedSeconds,
                             stemIncomingSeparatedSeconds: result.stemIncomingSeparatedSeconds,
                             stemSeparatedSides: result.stemSeparatedSides,
                             stemVocalEnergyRatio: result.stemVocalEnergyRatio,
                             stemCacheHit: result.stemCacheHit,
                             stemFallbackReason: result.stemFallbackReason,
                             outgoingTrimDB: result.outgoingTrimDB,
                             incomingTrimDB: result.incomingTrimDB,
                             rideDB: result.rideDB,
                             rideReleaseSeconds: result.rideReleaseSeconds,
                             measuredLUFS: result.measuredLUFS,
                             normalizationGainDB: result.normalizationGainDB,
                             normalizationTargetLUFS: result.normalizationTargetLUFS,
                             scoreLanesApplied: result.scoreLanesApplied,
                             scoreFallbackReason: result.scoreFallbackReason)
    }

    // Thresholds are no longer republished here: `Decision.config` carries
    // the whole resolved config, so an explanation always quotes the lines
    // that decision was actually made under — including a `--set` run's.

    // MARK: - Internals

    private static func name(of tier: TransitionPlanner.CompatibilityTier) -> String {
        switch tier {
        case .compatible: return "compatible"
        case .neutral: return "neutral"
        case .clash: return "clash"
        }
    }

    private static func kind(of plan: TransitionPlan) -> String {
        switch plan {
        case .beatMatched: return "beatMatched"
        case .crossfade: return "crossfade"
        case .gapless: return "gapless"
        }
    }

    private static func describe(_ style: TransitionStyle,
                                 geometry: TransitionAutomation.Geometry) -> String {
        var parts: [String] = []
        switch style.outroEffect {
        case .fade: parts.append("fade")
        case .filterSweep: parts.append("filterSweep")
        case .echoOut:
            let delay = TransitionAutomation.echoDelayTime(style: style, geometry: geometry)
            parts.append(String(format: "echoOut(delay %.0fms)", delay * 1000))
        }
        if style.stagedEQ { parts.append("stagedEQ") }
        if let stem = style.stemTechnique { parts.append(stem.label) }
        return parts.joined(separator: "+")
    }

    private static func style(_ override: StyleOverride,
                              basedOn original: TransitionStyle) -> TransitionStyle {
        switch override {
        case .plain:
            return .plain
        case .sweep:
            return TransitionStyle(outroEffect: .filterSweep, stagedEQ: false)
        case .echo:
            // Keep the planner's beat-synced delay hint when it had one.
            return TransitionStyle(outroEffect: .echoOut, stagedEQ: false,
                                   echoDelayTime: original.echoDelayTime)
        case .staged:
            return TransitionStyle(outroEffect: .fade, stagedEQ: true)
        }
    }

    /// `--fade N`: keep the mix points, change only how long the overlap runs.
    /// A `.gapless` plan has no mix point, so it becomes a crossfade landing on
    /// the end of the outgoing track — which is what you want when you are
    /// auditioning a fade length rather than the planner's choice.
    private static func applyFade(_ fade: TimeInterval, to planned: PlannedTransition,
                                  outgoingDuration: TimeInterval) -> PlannedTransition {
        let fade = max(0.1, fade)
        switch planned.plan {
        case .crossfade(_, let outPoint, let inPoint):
            return PlannedTransition(
                plan: .crossfade(duration: fade,
                                 outPoint: min(outPoint, max(0, outgoingDuration - fade)),
                                 inPoint: inPoint),
                style: planned.style, rideDB: planned.rideDB)
        case .beatMatched(let p):
            return PlannedTransition(
                plan: .beatMatched(BeatMatchedPlan(
                    outPoint: min(p.outPoint, max(0, outgoingDuration - fade)),
                    inPoint: p.inPoint, overlapBars: p.overlapBars,
                    outgoingRate: p.outgoingRate, incomingRate: p.incomingRate,
                    bassSwapOffset: fade / 2, overlapDuration: fade,
                    // The ramp fields ride along. Rebuilding the plan without
                    // them used to hand the renderer a *stepped* hand-over and
                    // call it a length override: `--fade` says "keep the mix
                    // points, change how long the overlap runs", and both
                    // glides are part of the hand-over, not of its length.
                    rampLeadSeconds: p.rampLeadSeconds,
                    rampReleaseSeconds: p.rampReleaseSeconds,
                    rampGlideBackFromSwap: p.rampGlideBackFromSwap)),
                style: planned.style, rideDB: planned.rideDB)
        case .gapless:
            return PlannedTransition(
                plan: .crossfade(duration: fade,
                                 outPoint: max(0, outgoingDuration - fade), inPoint: 0),
                style: planned.style, rideDB: planned.rideDB)
        }
    }

    static func planInPoint(of plan: TransitionPlan) -> TimeInterval? {
        switch plan {
        case .beatMatched(let p): return p.inPoint
        case .crossfade(_, _, let point): return point
        case .gapless: return nil
        }
    }

    /// Rewrite a planned transition's geometry with the caller's own out /
    /// in / overlap, keeping everything else the planner decided.
    ///
    /// The plan *kind* survives: a beat-matched hand-over that gets its
    /// overlap stretched stays beat-matched (bars are re-derived so the beat
    /// period is preserved), because the kind is what the style and the bass
    /// swap are written against. A `.gapless` plan has no geometry to move, so
    /// an override on it produces the crossfade it implicitly asked for.
    static func apply(_ override: PlanOverride, to planned: PlannedTransition,
                      outgoingDuration: TimeInterval,
                      incomingDuration: TimeInterval) throws -> PlannedTransition {
        let geometry = TransitionAutomation.Geometry(plan: planned.plan)
        // `.gapless` has no seam of its own. Its implied one is "the overlap
        // you asked for, landing on the end of the outgoing track" — anchoring
        // it anywhere else would reject every gapless override that named only
        // a length.
        let baseOut = planned.plan.outPoint
            ?? Swift.max(0, outgoingDuration
                         - Swift.max(override.overlap ?? geometry.overlapDuration,
                                     PlanOverride.minOverlap))
        let baseIn = planInPoint(of: planned.plan) ?? 0
        let g = try override.resolve(
            baseOutPoint: baseOut, baseInPoint: baseIn, baseOverlap: geometry.overlapDuration,
            outgoingDuration: outgoingDuration, incomingDuration: incomingDuration)

        switch planned.plan {
        case .beatMatched(let p):
            // Keep the beat period the planner matched to; the bar count is
            // just how many of those fit in the new window.
            let beat = p.overlapBars > 0 ? p.overlapDuration / Double(p.overlapBars * 4) : 0
            let bars = beat > 0.05
                ? Swift.max(1, Int((g.overlap / (beat * 4)).rounded())) : p.overlapBars
            return PlannedTransition(
                plan: .beatMatched(BeatMatchedPlan(
                    outPoint: g.outPoint, inPoint: g.inPoint, overlapBars: bars,
                    outgoingRate: p.outgoingRate, incomingRate: p.incomingRate,
                    bassSwapOffset: g.overlap / 2, overlapDuration: g.overlap)),
                style: planned.style, rideDB: planned.rideDB)
        case .crossfade, .gapless:
            return PlannedTransition(
                plan: .crossfade(duration: g.overlap, outPoint: g.outPoint, inPoint: g.inPoint),
                style: planned.style, rideDB: planned.rideDB)
        }
    }

    /// A signal is a "near miss" when it sits within 15 % of a threshold —
    /// i.e. nudging that planner constant would move this pair to another tier.
    private static func nearMisses(signals: TransitionPlanner.Signals,
                                   keyDistance: Int?,
                                   outVocal: Double?, inVocal: Double?,
                                   config: TransitionPlanner.Config) -> [String] {
        var out: [String] = []
        func check(_ label: String, _ value: Double, _ threshold: Double,
                   _ thresholdName: String, format: String = "%.3f") {
            guard threshold > 0, abs(value - threshold) / threshold <= 0.15 else { return }
            let side = value > threshold ? "just over" : "just under"
            out.append(String(format: "\(label) \(format) \(side) \(thresholdName) \(format)",
                              value, threshold))
        }
        check("loudness", signals.loudnessGapDB, config.neutralLoudnessDB,
              "the neutral line", format: "%.2f dB")
        check("loudness", signals.loudnessGapDB, config.clashLoudnessDB,
              "the clash line", format: "%.2f dB")
        check("timbre", signals.timbreDistance, config.neutralTimbreDistance,
              "the neutral line")
        check("timbre", signals.timbreDistance, config.clashTimbreDistance,
              "the clash line")
        if let ratio = signals.tempoRatio {
            check("tempo", ratio, config.clashTempoRatio, "the clash line")
            check("tempo", ratio, config.maxBPMDeltaRatio,
                  "the beat-match line")
        }
        if let keyDistance, keyDistance == config.clashKeyDistance - 1 {
            out.append("key distance \(keyDistance), one fifth short of the "
                       + "\(config.clashKeyDistance) that demotes to neutral")
        }
        for (label, score) in [("outgoing", outVocal), ("incoming", inVocal)] {
            guard let score else { continue }
            check("\(label) vocals", score, config.vocalClashRatio,
                  "the vocal-clash line", format: "%.2f")
        }
        return out
    }
}
