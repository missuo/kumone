#if os(macOS)
import Foundation

// 意图层 — the P3 layer of docs/automix-score-predev.md (§2.4).
//
// The tier gate answers "how aggressive a hand-over can this pair *survive*"
// (loudness, timbre, tempo, key, vocals). It never answers "what does this
// material *culturally want*". The consequences are symmetric and both bad: a
// hiphop×hiphop pair on two hard 128 BPM grids gets a polite 16 s blend, and a
// live-drummer rock track that happens to squeak past the gates gets dissolved
// — which is an offence against the song, not a rough edge on it.
//
// So this file computes one thing: an **intent**, a class plus a gesture budget
// plus the sentences that justify it. Restraint and aggression are one axis
// (predev §2.4), not two features, which is why "stand down" and "cut culture"
// come out of the same function.
//
// Three properties are load-bearing:
//
//   * **Pure.** Two analyses, a little queue metadata, a config. No files, no
//     clock, no network. The same pair always classifies the same way, which is
//     what makes it checkable over a corpus rather than a guess.
//   * **No new analysis.** Every input is a v7 field that is already on disk:
//     `downbeats`, `bpmConfidence`, `melProfile`, `rmsEnvelope`,
//     `vocalActivity`, `sections`. **No `TrackAnalysis.currentVersion` bump**,
//     so the whole cached library is classifiable today.
//   * **No genre tags.** No metadata lookup, no external label. "Rock-like" is
//     a statement about a drummer's grid drift and a wall of sound, and it is
//     wrong sometimes — the predev's risk #6 — so every threshold is biased
//     towards restraint, where being wrong costs a missed gesture instead of an
//     offence.
//
// **Explicitly out of v1: live-recording detection.** A live take differs from
// a studio one in applause, room tail and a grid that wanders over minutes, and
// none of those is a signal we have. The drummer-drift axis catches *some* live
// material for the right reason (a human keeping time) and misses the rest;
// pretending otherwise would be a rule nobody could calibrate. Live recordings
// therefore land wherever their grid and their spectrum put them, and the
// honest place for the gap is this paragraph.

/// **What this hand-over is for** — the class of gesture the material asks for,
/// how much gesture it may spend, and why.
///
/// Deliberately not a Bool and not a tier: `standDown` and `cutCulture` are the
/// two ends of one axis, so "be more careful with rock" and "be braver in the
/// club" are the same knob turned two ways rather than two features that can
/// disagree with each other.
struct TransitionIntent: Codable, Equatable, Sendable {

    /// The five classes, from most restrained to least.
    enum Class: String, Codable, Sendable, CaseIterable {
        /// **Hands off.** The pair is handed over the way a player with no
        /// AutoMix at all would hand it over. An album played in sequence is a
        /// *work*: the gap between two tracks was composed too.
        case standDown
        /// **Rock-like.** A staged crossfade, capped at the neutral overlap,
        /// and no score may be written. Dissolving a rock track into the next
        /// one is culturally wrong even when every gate says it is safe; a
        /// short, plain hand-over is the least wrong default.
        case restrained
        /// **Today, exactly.** The default, and the predev's first rule: when
        /// in doubt, blend. Nothing in the plan changes.
        case blend
        /// **EDM-like.** Still the blend family — but aimed, so the overlap
        /// *ends* on the incoming track's drop instead of somewhere in the
        /// middle of its build (predev §2.3).
        case dropAlign
        /// **Club-like.** Hard grids, instrumental edges: the culture that cuts
        /// rather than fades. The only class a cut score may be offered on.
        case cutCulture

        /// The gesture budget this class carries, 0 (gapless) … 1 (cut).
        ///
        /// A number rather than a rank because the predev asks for a *budget*:
        /// a later gesture can ask "can I afford this" without knowing which
        /// class authorized it.
        var budget: Double {
            switch self {
            case .standDown: return 0
            case .restrained: return 0.25
            case .blend: return 0.5
            case .dropAlign: return 0.75
            case .cutCulture: return 1
            }
        }
    }

    /// Backticked to match the predev's own spelling. Swift allows a keyword as
    /// a member name, so call sites read `intent.class` without ceremony.
    let `class`: Class
    /// 0…1. Always `class.budget` today; carried as its own field because the
    /// predev's model is a budget that a class *sets*, and a later revision may
    /// want to trim one without inventing a class.
    let budget: Double
    /// Human sentences — "grids 0.7 %/1.1 % (hard)". Every rule that fired and
    /// the numbers it fired on, in the order they were evaluated, so the panel,
    /// the journal and the console all quote the reasoning the planner acted
    /// on rather than re-deriving it and drifting.
    let reasons: [String]

    init(_ class_: Class, reasons: [String], budget: Double? = nil) {
        self.class = class_
        self.budget = budget ?? class_.budget
        self.reasons = reasons
    }

    /// `intent=cutCulture (grids 0.7 %/1.1 % (hard); edges instrumental)` — the
    /// one line the panel row, the seam history and the journal all print.
    var label: String {
        "intent=\(self.class.rawValue) (\(reasons.joined(separator: "; ")))"
    }

    /// The line a report prints when the layer did not run at all. Spelled out
    /// rather than omitted, for the reason `TransitionAim.report` gives: a
    /// missing row reads as a missing feature.
    static func report(_ intent: TransitionIntent?) -> String {
        intent?.label ?? "intent=off"
    }
}

// MARK: - Material signals

/// The per-side numbers the intent rules read, computed over one **edge
/// window** rather than over the whole track.
///
/// The window matters more than it looks. P1's lesson was that beat-level
/// intervals are noisy even on rigidly quantized dance music — 5–13 % CV — while
/// the same tracks sit at 0.7–3.4 % on *bar* intervals, because a missed beat
/// costs a whole interval and a missed downbeat almost never happens. So every
/// grid number here is a downbeat statistic. And a track is not one material:
/// a ballad with a four-on-the-floor last chorus is a different animal at 3:10
/// than at 0:30, and the only part of it this hand-over touches is the exit. So
/// the statistics are taken where the seam will be.
struct MaterialProfile: Equatable, Sendable {

    /// Coefficient of variation of the **downbeat intervals** inside the edge
    /// window. Nil when the window holds too few downbeats to say anything.
    ///
    /// Quantized production sits under ~1 %; a human drummer drifts several
    /// percent. This is the single most load-bearing number in the file: a cut
    /// on a drifting grid lands half a beat out, and half a beat out is the one
    /// error the gesture cannot survive.
    var edgeGridCV: Double?
    /// The same statistic over the whole track, for the console's table and for
    /// the case where the edge window is too short to measure.
    var trackGridCV: Double?
    var bpmConfidence: Double
    /// **Spectral flatness of the timbre fingerprint**, 0 (one band carries the
    /// shape) … 1 (the shape is spread evenly over all 40).
    ///
    /// `melProfile` is zero-sum and unit-norm by construction, so its variance
    /// is fixed at 1/N and tells you nothing. What *is* informative is how
    /// concentrated it is, and the participation ratio measures exactly that:
    /// `(Σ|v|)² / (Σv²) = (Σ|v|)²`, normalized by the band count.
    ///
    /// The direction is the useful part. A spectrum with structure — a strong
    /// low end, a rolled-off top — leaves big systematic deviations from its own
    /// mean, so the normalized shape is *concentrated* and this number is low.
    /// A wall of sound is close to flat before normalization, so what is left
    /// after it is unstructured and spread, and this number is **high**. Hence
    /// "wall of sound ⇒ flat ⇒ high", which is the predev's `频谱墙` proxy.
    var flatness: Double?
    /// Fraction of the edge window's seconds sitting at or above half the
    /// window's peak RMS. High = the material is loud all the time (a wall, or
    /// a club track); low = it breathes.
    var occupancy: Double?
    /// Mean `vocalActivity` over the edge window relative to the track's own
    /// mean — `TransitionPlanner.vocalScore`'s number, so the intent layer and
    /// the vocal gate cannot disagree about what "singing" means. Nil for a
    /// track with no usable vocal contour.
    var vocalRatio: Double?
    /// Mean `vocalActivity` over the window in **absolute** terms, 0…1.
    ///
    /// `vocalRatio` is relative to the track's own mean, which makes it exactly
    /// 1 whenever the window *is* the whole track — degenerate for the console's
    /// per-track table, and the reason this second number exists. Nothing
    /// decides on it; it is there so a reader can tell an instrumental from a
    /// song at a glance.
    var vocalMean: Double?
    /// The track carries a `.drop` section the planner is allowed to act on.
    var hasDrop: Bool
    /// …and the segmenter's confidence in the sections that say so.
    var structureConfidence: Double
    /// Mean `sections.energy` of whatever section the edge window opens in,
    /// for the section-contrast reason line. Nil without usable sections.
    var edgeSectionEnergy: Double?

    /// A one-word bucket for the console's per-track table. Pairwise intent is
    /// the real output; this is what a listening owner eyeballs to check that
    /// his rock, his EDM and his ballads landed in the right places at all.
    enum Bucket: String, Sendable, CaseIterable {
        /// No trustworthy tempo — classical, ambient, rubato.
        case noBeat
        /// A grid that drifts like a person: the drummer axis.
        case drummerDrift
        /// Flat-spectrum, high-occupancy: the wall.
        case wall
        /// Hard grid and a drop: the material a slam was invented for.
        case dropCarrying
        /// Hard grid, nothing else remarkable.
        case hardGrid
        /// Everything the rules have nothing to say about — most of a library,
        /// and the correct answer for most of a library.
        case ordinary
    }

    /// Which bucket this side falls in, under `config`'s thresholds. The order
    /// mirrors the rule precedence in `TransitionIntent.classify` so the table
    /// and the pair decisions cannot tell different stories.
    func bucket(config: TransitionPlanner.Config) -> Bucket {
        if bpmConfidence < config.bpmConfidenceThreshold { return .noBeat }
        if let cv = edgeGridCV ?? trackGridCV, cv >= config.intentDrummerDriftCV {
            return .drummerDrift
        }
        if let flatness, flatness >= config.intentWallFlatness,
           (occupancy ?? 0) >= config.intentWallOccupancy {
            return .wall
        }
        guard bpmConfidence >= config.scoreMinBPMConfidence,
              let cv = edgeGridCV ?? trackGridCV, cv <= config.intentHardGridCV
        else { return .ordinary }
        return hasDrop ? .dropCarrying : .hardGrid
    }

    /// `grid 0.9 %` / `grid —` — the way every reason line quotes a CV.
    static func percent(_ v: Double?) -> String {
        v.map { String(format: "%.1f %%", $0 * 100) } ?? "—"
    }

    static func number(_ v: Double?, _ digits: Int = 2) -> String {
        v.map { String(format: "%.\(digits)f", $0) } ?? "—"
    }
}

extension MaterialProfile {

    /// The exit window of the outgoing track: `window` seconds ending at the
    /// point it is most likely to leave from.
    static func outgoing(
        _ a: TrackAnalysis, exitAt anchor: TimeInterval,
        config: TransitionPlanner.Config
    ) -> MaterialProfile {
        profile(a, from: max(0, anchor - config.intentEdgeWindowSeconds), to: anchor,
                config: config)
    }

    /// The entry window of the incoming track: `window` seconds from where it
    /// will be entered.
    static func incoming(
        _ a: TrackAnalysis, entryAt anchor: TimeInterval,
        config: TransitionPlanner.Config
    ) -> MaterialProfile {
        profile(a, from: anchor,
                to: min(a.duration, anchor + config.intentEdgeWindowSeconds), config: config)
    }

    /// The whole-track profile the console's per-track table prints. The edge
    /// window is the whole track, which is the honest reading when there is no
    /// particular seam in question.
    static func wholeTrack(
        _ a: TrackAnalysis, config: TransitionPlanner.Config
    ) -> MaterialProfile {
        profile(a, from: 0, to: a.duration, config: config)
    }

    static func profile(
        _ a: TrackAnalysis, from: TimeInterval, to: TimeInterval,
        config: TransitionPlanner.Config
    ) -> MaterialProfile {
        let sections = a.structureConfidence >= config.structureConfidenceGate ? a.sections : []
        return MaterialProfile(
            edgeGridCV: downbeatCV(a.downbeats, from: from, to: to),
            trackGridCV: downbeatCV(a.downbeats, from: 0, to: .greatestFiniteMagnitude),
            bpmConfidence: a.bpmConfidence,
            flatness: flatness(a.melProfile),
            occupancy: occupancy(a.rmsEnvelope, from: from, to: to),
            vocalRatio: TransitionPlanner.vocalScore(a, from: from, length: max(0, to - from)),
            vocalMean: vocalMean(a.vocalActivity, from: from, to: to),
            hasDrop: sections.contains { $0.kind == .drop },
            structureConfidence: a.structureConfidence,
            edgeSectionEnergy: sections.last(where: { $0.start <= from + 0.01 })
                .map { Double($0.energy) })
    }

    /// CV of the intervals between consecutive downbeats inside `[from, to]`.
    ///
    /// Two deliberate details. **Bars, not beats**: see the type's own note.
    /// And **a median filter before the statistic**: a downbeat the tracker
    /// dropped shows up as one interval of twice the length, and one such
    /// interval in twelve moves the CV by more than the entire drummer-drift
    /// threshold. A dropped downbeat is a detector failure, not a drummer, so
    /// intervals outside [0.67×, 1.5×] of the median are discarded rather than
    /// allowed to speak for the material. If more than a third of them are, the
    /// grid is not a grid and this returns nil.
    static func downbeatCV(
        _ downbeats: [TimeInterval], from: TimeInterval, to: TimeInterval
    ) -> Double? {
        var intervals: [Double] = []
        for i in 1..<max(1, downbeats.count) {
            let a = downbeats[i - 1], b = downbeats[i]
            guard b > a, b.isFinite, a.isFinite else { continue }
            let mid = (a + b) / 2
            guard mid >= from, mid <= to else { continue }
            intervals.append(b - a)
        }
        guard intervals.count >= 4 else { return nil }
        let sorted = intervals.sorted()
        let median = sorted[sorted.count / 2]
        guard median > 0 else { return nil }
        let kept = intervals.filter { $0 >= median * 0.67 && $0 <= median * 1.5 }
        guard kept.count >= 4, Double(kept.count) >= Double(intervals.count) * 2.0 / 3
        else { return nil }
        let mean = kept.reduce(0, +) / Double(kept.count)
        guard mean > 0 else { return nil }
        let variance = kept.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(kept.count)
        return variance.squareRoot() / mean
    }

    /// Normalized participation ratio of the timbre fingerprint — see
    /// `flatness`'s own documentation for why this and not a variance.
    static func flatness(_ melProfile: [Float]) -> Double? {
        guard melProfile.count >= 8 else { return nil }
        var absSum = 0.0, sqSum = 0.0
        for v in melProfile {
            let d = Double(v)
            guard d.isFinite else { return nil }
            absSum += abs(d)
            sqSum += d * d
        }
        guard sqSum > 1e-12 else { return nil }
        let participation = absSum * absSum / sqSum
        return min(1, participation / Double(melProfile.count))
    }

    /// Mean vocal likelihood over the window, in absolute 0…1 terms.
    static func vocalMean(
        _ envelope: [Float], from: TimeInterval, to: TimeInterval
    ) -> Double? {
        let start = max(0, Int(from))
        let end = min(envelope.count, Int(to.rounded(.up)))
        guard end - start >= 1 else { return nil }
        let slice = envelope[start..<end]
        return Double(slice.reduce(Float(0), +)) / Double(slice.count)
    }

    /// Fraction of the window's seconds at or above half its peak RMS.
    static func occupancy(
        _ envelope: [Float], from: TimeInterval, to: TimeInterval
    ) -> Double? {
        let start = max(0, Int(from))
        let end = min(envelope.count, Int(to.rounded(.up)))
        guard end - start >= 4 else { return nil }
        let slice = envelope[start..<end]
        let peak = slice.max() ?? 0
        guard peak > 1e-4 else { return nil }
        let loud = slice.filter { $0 >= peak * 0.5 }.count
        return Double(loud) / Double(slice.count)
    }
}

// MARK: - The rules

extension TransitionIntent {

    /// **The intent function.** Ordered precedence rules, restraint first.
    ///
    /// Every rule is a named guard with its own `Config` switch, and every one
    /// of them can only ever hand the decision *down* the list — there is no
    /// rule that promotes. The last line is the predev's first rule: when in
    /// doubt, blend.
    ///
    /// The order is the argument:
    ///
    ///   1. **Album-sequential ⇒ `standDown`.** Same album *and* adjacent in
    ///      the listed queue. The gap between two album tracks was composed;
    ///      AutoMix's job there is to get out of the way.
    ///   2. **Rock-like ⇒ `restrained`.** A drifting grid, or a wall of sound
    ///      over a grid we do not trust. Requires at least one side to have a
    ///      believable tempo — with neither, this is not rock, it is rule 3,
    ///      and an orchestra must not be filed under "drummer".
    ///   3. **No beat on either side ⇒ `standDown`.** Classical, ambient,
    ///      rubato: there is no grid to be clever on, and a crossfade between
    ///      two pieces of chamber music is not a hand-over, it is a smear.
    ///   4. **Confident drop + hard grids ⇒ `dropAlign`.** Still the blend
    ///      family; what changes is where the overlap *ends*.
    ///   5. **Hard grids + instrumental edges ⇒ `cutCulture`.** The one class a
    ///      score may be written on. Instrumental edges are not decoration: a
    ///      cut across two singing voices is a cut through a word.
    ///   6. **Otherwise ⇒ `blend`,** field-for-field today.
    ///
    /// A manual `playNext` never reaches here at all: the player treats a
    /// hand-picked next track as sovereign long before the planner runs, so
    /// there is deliberately no rule for it.
    static func classify(
        outgoing: TrackAnalysis, incoming: TrackAnalysis,
        outgoingEdge: MaterialProfile, incomingEdge: MaterialProfile,
        context: TransitionPlanner.PlanContext,
        stems: StemAvailability = .none,
        config: TransitionPlanner.Config
    ) -> TransitionIntent {
        let grids = String(format: "grids %@/%@ (conf %.2f/%.2f)",
                           MaterialProfile.percent(outgoingEdge.edgeGridCV
                                                   ?? outgoingEdge.trackGridCV),
                           MaterialProfile.percent(incomingEdge.edgeGridCV
                                                   ?? incomingEdge.trackGridCV),
                           outgoingEdge.bpmConfidence, incomingEdge.bpmConfidence)

        // --- 1. An album, in sequence.
        if config.intentStandDownEnabled, context.albumSequential {
            return TransitionIntent(.standDown, reasons: [
                "same album, adjacent in the listed queue — an album in sequence is a work",
                "handed over exactly as a player with AutoMix off would (gapless)",
            ])
        }

        // --- 2. Rock-like. Drummer drift, or a wall over a grid we mistrust.
        let outCV = outgoingEdge.edgeGridCV ?? outgoingEdge.trackGridCV
        let inCV = incomingEdge.edgeGridCV ?? incomingEdge.trackGridCV
        let anyBeat = outgoingEdge.bpmConfidence >= config.bpmConfidenceThreshold
            || incomingEdge.bpmConfidence >= config.bpmConfidenceThreshold
        let drift = [outCV, inCV].compactMap { $0 }.filter { $0 >= config.intentDrummerDriftCV }
        let wall = wallOfSound(outgoingEdge, config: config)
            || wallOfSound(incomingEdge, config: config)
        let weakGrid = outgoingEdge.bpmConfidence < config.scoreMinBPMConfidence
            || incomingEdge.bpmConfidence < config.scoreMinBPMConfidence
        if config.intentRestrainedEnabled, anyBeat, !drift.isEmpty || (wall && weakGrid) {
            var reasons = [grids]
            if !drift.isEmpty {
                reasons.append(String(format: "downbeat drift over the %.1f %% line on %d side(s)"
                                      + " — a human keeping time",
                                      config.intentDrummerDriftCV * 100, drift.count))
            }
            if wall && weakGrid {
                reasons.append(String(format: "wall of sound (flatness %@/%@ over %.2f) on a grid"
                                      + " below the %.2f cut line",
                                      MaterialProfile.number(outgoingEdge.flatness),
                                      MaterialProfile.number(incomingEdge.flatness),
                                      config.intentWallFlatness, config.scoreMinBPMConfidence))
            }
            reasons.append("staged crossfade only, capped at the neutral overlap; no score")
            return TransitionIntent(.restrained, reasons: reasons)
        }

        // --- 3. No beat on either side.
        if config.intentStandDownEnabled, !anyBeat {
            return TransitionIntent(.standDown, reasons: [
                grids,
                String(format: "neither side reaches the %.2f tempo-confidence floor — "
                       + "there is no grid to be clever on", config.bpmConfidenceThreshold),
            ])
        }

        let hardGrids = config.intentCutCultureEnabled || config.intentDropAlignEnabled
            ? bothGridsHard(outgoingEdge, incomingEdge, config: config)
            : false

        // --- 4. EDM-like: a confident drop to aim at, on grids that can hold
        // an aimed overlap end.
        if config.intentDropAlignEnabled, hardGrids, incomingEdge.hasDrop,
           incomingEdge.structureConfidence >= config.structureConfidenceGate {
            return TransitionIntent(.dropAlign, reasons: [
                grids,
                String(format: "the incoming track carries a drop (structure confidence %.2f "
                       + "against a %.2f gate)", incomingEdge.structureConfidence,
                       config.structureConfidenceGate),
                "blend family, with the overlap ending on the drop",
            ])
        }

        // --- 5. Club-like: hard grids, and nobody is singing at the seam.
        if config.intentCutCultureEnabled, hardGrids,
           let outVocal = outgoingEdge.vocalRatio, let inVocal = incomingEdge.vocalRatio,
           outVocal <= config.intentInstrumentalEdgeRatio,
           inVocal <= config.intentInstrumentalEdgeRatio {
            return TransitionIntent(.cutCulture, reasons: [
                grids,
                String(format: "both edges instrumental (vocal %.2f/%.2f of each track's own "
                       + "mean, against a %.2f line)", outVocal, inVocal,
                       config.intentInstrumentalEdgeRatio),
                "cut scores allowed on this pair",
            ])
        }

        // --- 6. When in doubt, blend. The predev's first rule, and the only
        // branch here that changes nothing at all.
        var reasons = [grids]
        var requested = false
        if let sung = bothEdgesSung(outgoingEdge, incomingEdge, config: config) {
            requested = stems == .ready
            // The sentence has to name what actually happens downstream. Before
            // this branch existed the layer promised "a vocal-managed blend" and
            // then, at `stems == .none` or behind the 1.15 hot-spot gate,
            // managed nothing — the reader was told about a technique that was
            // never asked for. So the promise now ends in whichever of the two
            // things is true.
            reasons.append(String(format: "both edges are sung (vocal %.2f/%.2f) — "
                                  + "a vocal-managed blend, %@", sung.outgoing, sung.incoming,
                                  stems == .ready
                                      ? "vocalExchange requested"
                                      : "no separator, unmanaged"))
        } else if !hardGrids {
            reasons.append("grids are not hard enough on both sides to cut on")
        } else {
            reasons.append("nothing here asks for a gesture")
        }
        // The closing line is the class's own claim about itself, and it stops
        // being true the moment the layer asks for something. A requested
        // exchange is the one branch of `blend` that is *not* field-for-field
        // yesterday's plan, so it does not get to say it is.
        reasons.append(requested
                       ? "blend, with the vocal hand-over managed by the stem layer rather "
                       + "than left to the fader"
                       : "blend, field-for-field what this pair got before the intent layer")
        return TransitionIntent(.blend, reasons: reasons)
    }

    /// **The "both edges are sung" finding**, as one function so that the
    /// sentence the layer prints and the stem technique the planner requests
    /// cannot come from two different readings of the same two profiles.
    ///
    /// The threshold is `intentInstrumentalEdgeRatio` (0.5) and it is *not* a
    /// new one: rule 5 refuses to cut unless both edges sit at or below it, so
    /// "sung" here is exactly the negation of the "instrumental" the cut rule
    /// already uses. Nil when either side has no usable vocal contour — an
    /// abstention, never an assertion that nobody is singing.
    ///
    /// Note that this is a much weaker claim than the stem layer's own
    /// `stemVocalActiveRatio` (1.15), and deliberately so. 1.15 asks "is this
    /// window a vocal *hot spot* for this song" — an S1-era question, asked
    /// when a stem technique had to justify a separation pass on a hunch. The
    /// question a hand-over between two singing tracks actually poses is "is
    /// anyone singing on either side of this seam", and an ordinary sung edge
    /// answers yes at 1.0–1.1 while never clearing 1.15. That gap is what left
    /// the field's three `intent=blend … both edges are sung` seams at
    /// `stem=none`, with two lead vocals over a 20 s overlap and nothing but
    /// the fader law between them.
    static func bothEdgesSung(
        _ outgoingEdge: MaterialProfile, _ incomingEdge: MaterialProfile,
        config: TransitionPlanner.Config
    ) -> (outgoing: Double, incoming: Double)? {
        guard let out = outgoingEdge.vocalRatio, let incoming = incomingEdge.vocalRatio,
              out > config.intentInstrumentalEdgeRatio,
              incoming > config.intentInstrumentalEdgeRatio
        else { return nil }
        return (out, incoming)
    }

    /// Both sides quantized *and* confidently tracked — the precondition every
    /// grid-point gesture shares.
    static func bothGridsHard(
        _ a: MaterialProfile, _ b: MaterialProfile, config: TransitionPlanner.Config
    ) -> Bool {
        guard a.bpmConfidence >= config.scoreMinBPMConfidence,
              b.bpmConfidence >= config.scoreMinBPMConfidence,
              let aCV = a.edgeGridCV ?? a.trackGridCV,
              let bCV = b.edgeGridCV ?? b.trackGridCV
        else { return false }
        return aCV <= config.intentHardGridCV && bCV <= config.intentHardGridCV
    }

    /// A flat spectrum that is also loud most of the time. Flatness alone is
    /// not enough — a quiet, noisy field recording is flat too — so occupancy
    /// carries the "wall" half of "wall of sound".
    static func wallOfSound(
        _ p: MaterialProfile, config: TransitionPlanner.Config
    ) -> Bool {
        guard let flatness = p.flatness, let occupancy = p.occupancy else { return false }
        return flatness >= config.intentWallFlatness && occupancy >= config.intentWallOccupancy
    }
}
#endif
