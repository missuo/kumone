import Foundation

// The AutoMix queue-reorder scorer (docs/automix-queue-predev.md §2.3).
//
// **The planner is the scorer.** There is no second compatibility model here:
// for a current track A and a candidate B this runs `TransitionPlanner.plan`
// — the very pure function that will decide the real hand-over — and scores
// the pair by the *tier of transition it came back with*. A high score
// therefore means "a good transition is actually reachable for this pair",
// not "some proxy metric likes it".
//
// Everything in this file is a pure function of its arguments. The stateful
// half (which candidates are downloaded, what has lost how many rounds) lives
// in `QueueOrderSelector`; the offline `audition order` command drives this
// file directly, so the numbers the console prints are the numbers the player
// picks on.

/// How good a hand-over the planner was able to build for a pair — the score's
/// **dominant** term (predev §2.3: "tier 是主项").
///
/// Ordered worst to best, and deliberately coarse: the continuous terms below
/// only ever sort *within* one of these, so a stylistically similar pair that
/// can only be crossfaded must never outrank a pair that can be beat-matched.
enum TransitionTier: Int, Comparable, Sendable, CaseIterable {
    /// One side has no analysis, or is too short — no hand-over at all.
    case gapless = 0
    /// A plain volume crossfade: the planner found nothing to exploit.
    case crossfade = 1
    /// A crossfade with the staged three-band EQ hand-over.
    case stagedCrossfade = 2
    /// Grids aligned by a rate *step*.
    case beatMatched = 3
    /// Grids aligned by a tempo *glide* — the best thing the planner can make.
    case rampedBeatMatched = 4

    static func < (a: TransitionTier, b: TransitionTier) -> Bool {
        a.rawValue < b.rawValue
    }

    /// Read the tier back off a plan the planner produced. Deliberately a
    /// *derivation*, never a re-implementation of the gates: whatever the
    /// planner decided is what this reports.
    init(_ planned: PlannedTransition) {
        switch planned.plan {
        case .beatMatched(let p):
            self = p.rampLeadSeconds > 0 ? .rampedBeatMatched : .beatMatched
        case .crossfade:
            self = planned.style.stagedEQ ? .stagedCrossfade : .crossfade
        case .gapless:
            self = .gapless
        }
    }

    var label: String {
        switch self {
        case .gapless: return "gapless"
        case .crossfade: return "crossfade"
        case .stagedCrossfade: return "stagedCrossfade"
        case .beatMatched: return "beatMatched"
        case .rampedBeatMatched: return "rampedBeatMatched"
        }
    }

    /// Whether the grids were actually locked — the share this whole feature
    /// exists to raise.
    var isBeatMatched: Bool { self >= .beatMatched }
}

/// Every tunable the queue-order decision turns on, in one value — the same
/// shape as `TransitionPlanner.Config`, and swept the same way (`fields`,
/// `standard(overriding:)`, `asDictionary`).
struct QueueOrderConfig: Sendable, Equatable {

    /// How far apart two adjacent tiers are on the score scale.
    ///
    /// This is what makes the tier the main term: the four continuous terms
    /// below are each bounded in `[0, 1]` and their weights sum to well under
    /// this, so no combination of them can promote a crossfade over a
    /// beat-match. **Aging is exempt on purpose** — it is unbounded, which is
    /// exactly what "no track starves" means.
    var tierSpacing: Double = 10

    /// BPM affinity: the folded tempo gap (the planner's own `[0.5, 1, 2]`
    /// folding) at which affinity has fallen to 0. Just past the ramped
    /// beat-match cap, so a pair that only *just* misses the gate still reads
    /// as tempo-adjacent when both candidates are stuck in the crossfade tier.
    var tempoFullScale: Double = 0.13
    var tempoWeight: Double = 1.0

    /// Harmony: circle-of-fifths distance, 0–6. Interpolated toward the
    /// neutral 0.5 by the weaker of the two key confidences, so a guess never
    /// speaks as loudly as a certainty.
    var keyWeight: Double = 1.0

    /// Style: `melProfile` cosine, the planner's own timbre signal.
    var styleWeight: Double = 1.0

    /// Energy: the drop (or rise) between the outgoing tail and the incoming
    /// entry, in units of "fraction of the track's own peak RMS", at which
    /// continuity has fallen to 0.
    var energyFullScale: Double = 0.45
    /// A rise is not a fault the way a fall is — a set that lifts is a set
    /// that works — so a rise is charged this fraction of a fall of the same
    /// size.
    var energyRiseLeniency: Double = 0.4
    var energyWeight: Double = 1.0

    /// Added to a candidate's score per round it has lost (predev §2.3:
    /// "每落选一轮 +ε,保证不饿死"). Unbounded by design: keep losing and
    /// eventually you outrank a whole tier, which is what makes "every track
    /// gets played" a property of the arithmetic rather than a hope.
    var agingEpsilon: Double = 0.35

    /// Subtracted when the candidate shares an artist with the track now
    /// playing — `melProfile` likes an album rather too much (predev §4).
    /// 0 turns the rule off.
    var sameArtistPenalty: Double = 1.5

    // MARK: - Acquisition (predev §2.2)
    //
    // Read by `QueueOrderSelector`, not by the scoring below; they live here
    // so one value describes the whole mode.

    /// The tier at which a candidate is **good enough** and the escalation
    /// stops. The default is "the grids can be locked" — the share this whole
    /// feature exists to raise — which `beatMatched` and `rampedBeatMatched`
    /// both clear.
    ///
    /// Satisficing rather than optimising is sound here because the tier is the
    /// dominant term by construction (`tierSpacing`): once a candidate reaches
    /// the satisfying tier, everything a further round could buy is either a
    /// *higher* tier or a second-order reshuffle inside the same one. Paying
    /// several downloads for that is a bad trade against playing sooner.
    var satisfyingTier: TransitionTier = .beatMatched

    /// How many tracks the first escalation round downloads.
    var escalationFirstRound: Int = 1

    /// What each subsequent round multiplies the last one by: 1, 4, 16, 64 …
    /// Exponential so a cold queue that needs a lot of material gets it in a
    /// handful of rounds, while the common case — the very next track is
    /// already fine — costs exactly one download.
    var escalationFactor: Int = 4

    /// The most downloads **one pick** may spend before it settles for the best
    /// it has.
    ///
    /// Exponential growth against a long queue is unbounded in practice, not
    /// just in theory: on a 220-track queue a 10-minute opening song ran five
    /// rounds and bought 177 tracks before the deadline cut it off — nearly the
    /// whole playlist, paid for by one seam. The escalation was doing what it
    /// was told; what it was told had no ceiling.
    ///
    /// The cap is not a loss, because nothing bought is thrown away: the tail
    /// it does not reach this pick is still unresolved at the next one, which
    /// escalates into it from a pool that just got 24 tracks richer. The
    /// warming is *amortised across songs* instead of front-loaded onto the
    /// first one — same total, spread out, and the listener is not waiting on
    /// it.
    var maxDownloadsPerPick: Int = 24

    // MARK: - Future richness (predev §2.3 / §4's tail row)

    /// Which future-richness estimator the pick uses, as a raw value so it can
    /// ride the same `--order-set` sweep surface as every other knob.
    ///
    /// The term exists because greedy is measurably front-loaded: on a 101-pick
    /// schedule it eats the compatible pairs early and the last third collapses
    /// into aging-forced escapes. Preferring, *within a tier*, the candidate
    /// that leaves a richer future is the cheapest thing that could push back.
    enum FutureMode: Int, Sendable, CaseIterable {
        /// No future term at all — the shipping behaviour before this existed.
        case off = 0
        /// Degree: how much of the remaining pool this candidate could hand
        /// over to at the satisfying tier. One extra rank per evaluated
        /// candidate.
        case degree = 1
        /// Short rollout: greedily walk `futureRolloutDepth` seams on from this
        /// candidate and read the tiers back. `depth` extra ranks per candidate.
        case rollout = 2

        var label: String {
            switch self {
            case .off: return "off"
            case .degree: return "degree"
            case .rollout: return "rollout"
            }
        }
    }

    var futureMode: FutureMode = .off

    /// The future term's weight. **Bounded on purpose**, like the four
    /// continuity terms and unlike aging: the richness itself is in `[0, 1]`
    /// and this knob's ceiling is 2, so the whole bounded budget is at most
    /// `1 + 1 + 1 + 1 + 2 = 6` against a `tierSpacing` of 10. No setting of it
    /// can promote a crossfade over a beat-match — the current seam is never
    /// sold for a better future.
    var futureWeight: Double = 0.5

    /// How many of the already-ranked candidates get the future term. The rest
    /// keep richness 0, which is safe rather than arbitrary: the bonus is
    /// non-negative and goes only to the *best* K, so it can lift them relative
    /// to each other but can never push one below a candidate it already beat.
    var futureTopK: Int = 5

    /// The most remaining tracks one future evaluation looks at. Above this the
    /// pool is sampled by a deterministic stride — an estimator of the same
    /// quantity at a bounded price, which is what keeps `K` extra ranks off the
    /// 50 ms tripwire at a 200-track pool.
    var futurePoolCap: Int = 64

    /// How many seams `FutureMode.rollout` walks.
    var futureRolloutDepth: Int = 3

    /// How many picks past the decided next the provisional chain looks
    /// (predev §2.1 / §2.2). Pure arithmetic over the analyzed pool — no
    /// download, no commitment — so it costs microseconds and can be redone
    /// whenever the pool grows. 0 turns the chain off.
    var lookaheadDepth: Int = 8

    static let standard = QueueOrderConfig()
}

/// One candidate's score, kept broken out so the debug panel and the console
/// can print *why* — a bare total is not reviewable.
struct QueueOrderScore: Sendable, Equatable {
    var tier: TransitionTier = .gapless
    /// Each in `[0, 1]`, before its weight.
    var tempoAffinity: Double = 0.5
    var keyAffinity: Double = 0.5
    var styleAffinity: Double = 0.5
    var energyContinuity: Double = 0.5
    /// Rounds this candidate has already lost, times `agingEpsilon`.
    var aging: Double = 0
    /// Already negative when it applies.
    var sameArtistPenalty: Double = 0

    /// How rich a future this candidate leaves, in `[0, 1]`, before its weight.
    /// 0 both when the term is off and when the candidate genuinely strands the
    /// pool — the two are told apart by `QueueOrderConfig.futureMode`, not here.
    var futureRichness: Double = 0

    /// The tier's own contribution — `tier.rawValue × tierSpacing`, kept
    /// rather than recomputed so a score made under a swept config can still
    /// be decomposed.
    var tierScore: Double = 0

    /// The number the pick is made on.
    var total: Double = 0

    /// Everything except the tier — what sorts candidates *inside* one tier.
    var continuity: Double { total - tierScore }

    /// Fold a future-richness reading into an already-computed score.
    ///
    /// Additive and idempotent-by-replacement: the previous contribution is
    /// backed out first, so re-applying a fresh reading to the same score does
    /// not compound.
    mutating func applyFuture(_ richness: Double, weight: Double) {
        let clamped = richness.isFinite ? Swift.min(1, Swift.max(0, richness)) : 0
        total -= weight * futureRichness
        futureRichness = clamped
        total += weight * clamped
    }
}

/// The pure half of the queue-order mode.
enum QueueOrderScorer {

    // MARK: - Scoring

    /// Score one candidate against the track now playing.
    ///
    /// - Parameter planned: the transition `TransitionPlanner.plan(A, B)` came
    ///   back with. Taken as a parameter rather than planned here so the caller
    ///   controls the planner config, the stem availability and the lyric
    ///   context — and so this stays testable without two real analyses.
    /// - Parameter lostRounds: how many picks this candidate has already been
    ///   passed over for.
    static func score(
        outgoing: TrackAnalysis?, incoming: TrackAnalysis?,
        planned: PlannedTransition,
        lostRounds: Int = 0,
        sharesArtist: Bool = false,
        config: QueueOrderConfig = .standard,
        plannerConfig: TransitionPlanner.Config = .standard
    ) -> QueueOrderScore {
        var s = QueueOrderScore()
        s.tier = TransitionTier(planned)
        if let outgoing, let incoming {
            s.tempoAffinity = tempoAffinity(outgoing, incoming,
                                            config: config, plannerConfig: plannerConfig)
            s.keyAffinity = keyAffinity(outgoing, incoming, plannerConfig: plannerConfig)
            s.styleAffinity = styleAffinity(outgoing, incoming)
            s.energyContinuity = energyContinuity(outgoing, incoming, config: config)
        }
        s.aging = Double(max(0, lostRounds)) * config.agingEpsilon
        s.sameArtistPenalty = sharesArtist ? -config.sameArtistPenalty : 0
        s.tierScore = Double(s.tier.rawValue) * config.tierSpacing
        s.total = s.tierScore
            + config.tempoWeight * s.tempoAffinity
            + config.keyWeight * s.keyAffinity
            + config.styleWeight * s.styleAffinity
            + config.energyWeight * s.energyContinuity
            + s.aging
            + s.sameArtistPenalty
        return s
    }

    // MARK: - Future richness
    //
    // Greedy is myopic by construction: it buys the best seam in front of it
    // and never asks what that leaves behind. Measured on a real cache, that
    // shows up as a schedule whose quality is front-loaded — the compatible
    // pairs are spent early and the last third is aging-forced escapes from
    // clusters nothing can leave.
    //
    // These two functions estimate "how much future does this candidate leave"
    // and nothing else. They never decide anything: the caller folds the
    // reading in as a *bounded, weighted, in-tier* term, so the current seam is
    // never sold for a better future.
    //
    // Generic over the pool's key type because there are two callers with two
    // key spaces — the selector keys by track ID, the offline `audition order`
    // by file path — and the arithmetic is the same for both.

    /// The pool a future evaluation actually looks at: `rest` itself when it is
    /// small enough, otherwise a deterministic stride sample of
    /// `config.futurePoolCap` entries spread across the whole of it.
    ///
    /// A stride rather than a prefix on purpose: a prefix of a list-ordered
    /// pool is a sample of one corner of the playlist, and the whole question
    /// being asked is about the pool's *spread*.
    static func futureSample<Key>(_ rest: [Key], config: QueueOrderConfig) -> [Key] {
        let cap = max(1, config.futurePoolCap)
        guard rest.count > cap else { return rest }
        // Evenly spaced indices, endpoints included, no duplicates by
        // construction because `cap < rest.count`.
        return (0..<cap).map { rest[$0 * rest.count / cap] }
    }

    /// **Design (a): degree.** The share of the remaining pool that this
    /// candidate could hand over to at `config.satisfyingTier`, with the
    /// candidate as the *outgoing* track.
    ///
    /// One rank per candidate, and the cheapest honest answer to "is this a
    /// hub or a dead end". A candidate that only one other track can follow is
    /// a cluster escape waiting to happen; one that half the pool can follow
    /// costs the schedule nothing to spend now.
    static func futureDegree<Key: Hashable>(
        candidate: Key, rest: [Key],
        analysis: (Key) -> TrackAnalysis?,
        config: QueueOrderConfig,
        plannerConfig: TransitionPlanner.Config = .standard
    ) -> Double {
        guard let outgoing = analysis(candidate) else { return 0 }
        let sample = futureSample(rest.filter { $0 != candidate }, config: config)
        guard !sample.isEmpty else { return 0 }
        var reached = 0
        for key in sample {
            guard let incoming = analysis(key) else { continue }
            let planned = TransitionPlanner.plan(
                outgoing: outgoing, incoming: incoming, stems: .none,
                config: plannerConfig, context: .init(outgoingLyricLineEnds: []))
            if TransitionTier(planned) >= config.satisfyingTier { reached += 1 }
        }
        return Double(reached) / Double(sample.count)
    }

    /// **Design (b): short rollout.** Walk `config.futureRolloutDepth` seams on
    /// from the candidate, greedily, and report the mean tier of the seams
    /// walked, normalized onto `[0, 1]`.
    ///
    /// Strictly more informative than the degree — it knows that a hub which
    /// leads only into a second dead end is not really a hub — and strictly
    /// more expensive, at `depth` ranks per candidate rather than one. Which of
    /// the two earns its price is a question for `audition order`, not for a
    /// comment.
    ///
    /// The greedy inside is the same greedy the chain runs (best `total`, ties
    /// on list order); aging is deliberately *not* advanced, because a rollout
    /// that aged its own copy of the counters would be measuring the aging
    /// term's escape hatch rather than the pool's compatibility.
    static func futureRollout<Key: Hashable>(
        candidate: Key, rest: [Key],
        analysis: (Key) -> TrackAnalysis?,
        config: QueueOrderConfig,
        plannerConfig: TransitionPlanner.Config = .standard
    ) -> Double {
        let depth = max(1, config.futureRolloutDepth)
        var pool = futureSample(rest.filter { $0 != candidate }, config: config)
        var head = candidate
        var tierSum = 0
        var seams = 0
        while seams < depth, !pool.isEmpty {
            let outgoing = analysis(head)
            var best: (index: Int, score: QueueOrderScore)?
            for (index, key) in pool.enumerated() {
                guard let incoming = analysis(key) else { continue }
                let planned = TransitionPlanner.plan(
                    outgoing: outgoing, incoming: incoming, stems: .none,
                    config: plannerConfig, context: .init(outgoingLyricLineEnds: []))
                let s = score(outgoing: outgoing, incoming: incoming, planned: planned,
                              config: config, plannerConfig: plannerConfig)
                if best == nil || s.total > best!.score.total { best = (index, s) }
            }
            guard let winner = best else { break }
            tierSum += winner.score.tier.rawValue
            seams += 1
            head = pool[winner.index]
            pool.remove(at: winner.index)
        }
        guard seams > 0 else { return 0 }
        let top = TransitionTier.rampedBeatMatched.rawValue
        return clamp01(Double(tierSum) / Double(seams * top))
    }

    /// Fold the future term into an already-ranked candidate list, in place.
    ///
    /// Only the first `config.futureTopK` entries are evaluated, and the bonus
    /// is non-negative — so this can reorder the head of the list but can never
    /// demote a candidate below one it already outscored. That, plus the
    /// bounded weight, is the whole of the tier-dominance guarantee: the future
    /// term acts within and near ties and nowhere else.
    ///
    /// Returns how many candidates were actually evaluated — the bound the
    /// bench and the tests assert on.
    @discardableResult
    static func applyFuture<Key: Hashable>(
        to ranked: inout [(key: Key, score: QueueOrderScore)],
        analysis: (Key) -> TrackAnalysis?,
        config: QueueOrderConfig,
        plannerConfig: TransitionPlanner.Config = .standard
    ) -> Int {
        guard config.futureMode != .off, config.futureWeight != 0 else { return 0 }
        let k = min(max(0, config.futureTopK), ranked.count)
        guard k > 0 else { return 0 }
        let keys = ranked.map(\.key)
        for i in 0..<k {
            let richness: Double
            switch config.futureMode {
            case .off: continue
            case .degree:
                richness = futureDegree(candidate: keys[i], rest: keys,
                                        analysis: analysis, config: config,
                                        plannerConfig: plannerConfig)
            case .rollout:
                richness = futureRollout(candidate: keys[i], rest: keys,
                                         analysis: analysis, config: config,
                                         plannerConfig: plannerConfig)
            }
            ranked[i].score.applyFuture(richness, weight: config.futureWeight)
        }
        // Only the evaluated head can have moved, and it can only have moved
        // up; re-sorting the whole list keeps the tie-break (original position)
        // that the callers already rely on.
        ranked = ranked.enumerated()
            .sorted {
                $0.element.score.total == $1.element.score.total
                    ? $0.offset < $1.offset
                    : $0.element.score.total > $1.element.score.total
            }
            .map(\.element)
        return k
    }

    // MARK: - Continuity terms
    //
    // Every one of these is a shift-invariant statistic of the analysis —
    // which is why scoring may run on a low-bitrate copy of the file while
    // the *plan* may not (predev §2.2): a lossy encoder's leading delay moves
    // the beat grid, and none of the four terms below can see it.

    /// 1 at an identical (or exactly double/half) tempo, falling to 0 at
    /// `tempoFullScale`. Neutral 0.5 when either side's beat tracking is not
    /// confident enough for the planner to use it either.
    static func tempoAffinity(
        _ a: TrackAnalysis, _ b: TrackAnalysis,
        config: QueueOrderConfig = .standard,
        plannerConfig: TransitionPlanner.Config = .standard
    ) -> Double {
        guard a.bpmConfidence >= plannerConfig.bpmConfidenceThreshold,
              b.bpmConfidence >= plannerConfig.bpmConfidenceThreshold,
              a.bpm > 0, b.bpm > 0 else { return 0.5 }
        let ratio = [0.5, 1.0, 2.0].map { abs(b.bpm * $0 - a.bpm) / a.bpm }.min()!
        guard config.tempoFullScale > 0 else { return ratio == 0 ? 1 : 0 }
        return clamp01(1 - ratio / config.tempoFullScale)
    }

    /// 1 for the same key, 0 for the tritone, interpolated toward 0.5 by the
    /// weaker of the two key confidences. 0.5 when the planner's own key gate
    /// abstains, so harmony neither helps nor hurts an untonal pair.
    static func keyAffinity(
        _ a: TrackAnalysis, _ b: TrackAnalysis,
        plannerConfig: TransitionPlanner.Config = .standard
    ) -> Double {
        guard let distance = TransitionPlanner.keyDistance(a, b, config: plannerConfig)
        else { return 0.5 }
        // The circle of fifths' farthest point is 6 steps away.
        let affinity = clamp01(1 - Double(distance) / 6)
        let confidence = clamp01(Swift.min(a.keyConfidence, b.keyConfidence))
        return 0.5 + (affinity - 0.5) * confidence
    }

    /// `melProfile` cosine mapped from `[-1, 1]` onto `[0, 1]`. The profiles
    /// are L2-normalized and mean-removed by the analyzer, so the dot product
    /// *is* the cosine. Neutral 0.5 when either side has no profile.
    static func styleAffinity(_ a: TrackAnalysis, _ b: TrackAnalysis) -> Double {
        let x = a.melProfile, y = b.melProfile
        guard !x.isEmpty, x.count == y.count else { return 0.5 }
        var dot: Double = 0, nx: Double = 0, ny: Double = 0
        for i in 0..<x.count {
            dot += Double(x[i]) * Double(y[i])
            nx += Double(x[i]) * Double(x[i])
            ny += Double(y[i]) * Double(y[i])
        }
        guard nx > 1e-12, ny > 1e-12 else { return 0.5 }
        let cosine = dot / (nx.squareRoot() * ny.squareRoot())
        return clamp01((cosine + 1) / 2)
    }

    /// How level the seam is: the outgoing track's energy where it leaves
    /// against the incoming track's energy where it enters, both as a fraction
    /// of their own peak. 1 for a matched hand-over, falling to 0 at
    /// `energyFullScale`; a rise is charged `energyRiseLeniency` of a fall.
    static func energyContinuity(
        _ a: TrackAnalysis, _ b: TrackAnalysis, config: QueueOrderConfig = .standard
    ) -> Double {
        guard let out = exitEnergy(a), let into = entryEnergy(b) else { return 0.5 }
        let delta = into - out
        let charged = delta < 0 ? -delta : delta * config.energyRiseLeniency
        guard config.energyFullScale > 0 else { return charged == 0 ? 1 : 0 }
        return clamp01(1 - charged / config.energyFullScale)
    }

    /// Energy in the last stretch the outgoing track is still playing at
    /// level — before any natural outro fade, which is a fade, not a drop in
    /// the arrangement.
    static func exitEnergy(_ a: TrackAnalysis) -> Double? {
        let end = a.outroFadeStart ?? a.duration
        return energy(of: a, around: max(0, end - energyWindow / 2))
    }

    /// Energy where the incoming track actually starts playing — after its
    /// intro, which is where the planner aims its in point.
    static func entryEnergy(_ b: TrackAnalysis) -> Double? {
        energy(of: b, around: b.introEnd)
    }

    /// The window both edge measurements average over.
    private static let energyWindow: TimeInterval = 15

    /// Normalized energy (fraction of the track's own peak) around `t`,
    /// preferring the structural section that contains it — the analyzer has
    /// already normalized those the same way — and falling back to the RMS
    /// envelope.
    private static func energy(of a: TrackAnalysis, around t: TimeInterval) -> Double? {
        if let section = a.sections.last(where: { $0.start <= t + 0.01 }) ?? a.sections.first {
            return Double(section.energy)
        }
        let env = a.rmsEnvelope
        guard !env.isEmpty, let peak = env.max(), peak > 1e-9 else { return nil }
        let start = Swift.max(0, Swift.min(env.count - 1, Int(t)))
        let end = Swift.max(start + 1, Swift.min(env.count, Int((t + energyWindow).rounded(.up))))
        let slice = env[start..<end]
        let mean = slice.reduce(0.0) { $0 + Double($1) } / Double(slice.count)
        return mean / Double(peak)
    }

    private static func clamp01(_ v: Double) -> Double {
        guard v.isFinite else { return 0.5 }
        return Swift.min(1, Swift.max(0, v))
    }
}

// MARK: - Tuning surface

extension QueueOrderConfig {
    /// One entry per knob, the same description `TransitionPlanner.Config`
    /// carries — so a sweep can drive both from one `--set` list.
    struct Field: Sendable {
        let name: String
        let blurb: String
        let min: Double
        let max: Double
        let step: Double
        let digits: Int
        let read: @Sendable (QueueOrderConfig) -> Double
        let write: @Sendable (inout QueueOrderConfig, Double) -> Void
    }

    private static func field(
        _ name: String, _ blurb: String,
        _ min: Double, _ max: Double, _ step: Double, _ digits: Int = 2,
        _ path: WritableKeyPath<QueueOrderConfig, Double>
    ) -> Field {
        Field(name: name, blurb: blurb, min: min, max: max, step: step, digits: digits,
              read: { $0[keyPath: path] }, write: { $0[keyPath: path] = $1 })
    }

    static let fields: [Field] = [
        field("tierSpacing",
              "档位之间的分差。调大 = 更不容易让连续项跨档翻盘。",
              1, 50, 0.5, 1, \.tierSpacing),
        field("tempoFullScale",
              "BPM 比值差到多少时速度亲和力归零。调大 = 对速度差更宽容。",
              0.01, 0.5, 0.005, 3, \.tempoFullScale),
        field("tempoWeight", "速度亲和力在档位内的权重。", 0, 5, 0.05, 2, \.tempoWeight),
        field("keyWeight", "调性亲和力在档位内的权重。", 0, 5, 0.05, 2, \.keyWeight),
        field("styleWeight", "风格（melProfile 余弦）在档位内的权重。", 0, 5, 0.05, 2, \.styleWeight),
        field("energyFullScale",
              "能量落差到多少（占各自峰值的比例）时连续性归零。",
              0.05, 1, 0.01, 2, \.energyFullScale),
        field("energyRiseLeniency",
              "能量上扬按下跌的几折计费。0 = 上扬完全免费。",
              0, 1, 0.05, 2, \.energyRiseLeniency),
        field("energyWeight", "能量连续性在档位内的权重。", 0, 5, 0.05, 2, \.energyWeight),
        field("agingEpsilon",
              "每落选一轮加多少分。调大 = 更快轮到冷门曲目，也更容易跨档翻盘。",
              0, 5, 0.05, 2, \.agingEpsilon),
        field("sameArtistPenalty",
              "候选与当前曲同歌手时扣多少分。0 = 关掉这条规则。",
              0, 10, 0.1, 2, \.sameArtistPenalty),
        Field(name: "satisfyingTier",
              blurb: "满意档位：候选达到这一档就立即选定、停止下载。"
                  + "0=gapless 1=crossfade 2=stagedCrossfade 3=beatMatched 4=rampedBeatMatched。",
              min: 0, max: 4, step: 1, digits: 0,
              read: { Double($0.satisfyingTier.rawValue) },
              write: { config, raw in
                  let clamped = Swift.min(Swift.max(Int(raw.rounded()), 0),
                                          TransitionTier.rampedBeatMatched.rawValue)
                  config.satisfyingTier = TransitionTier(rawValue: clamped) ?? .beatMatched
              }),
        Field(name: "escalationFirstRound",
              blurb: "第一轮补下载几首。调大 = 更急躁,冷队列更快出结果也更费流量。",
              min: 1, max: 32, step: 1, digits: 0,
              read: { Double($0.escalationFirstRound) },
              write: { $0.escalationFirstRound = Swift.max(1, Int($1.rounded())) }),
        Field(name: "escalationFactor",
              blurb: "每轮相对上一轮的倍数(1→4→16…)。1 = 每次只加一首。",
              min: 1, max: 8, step: 1, digits: 0,
              read: { Double($0.escalationFactor) },
              write: { $0.escalationFactor = Swift.max(1, Int($1.rounded())) }),
        Field(name: "maxDownloadsPerPick",
              blurb: "单次选曲最多买几首。买满就用手上最好的定下,余下的留给后面几首慢慢暖。",
              min: 1, max: 256, step: 1, digits: 0,
              read: { Double($0.maxDownloadsPerPick) },
              write: { $0.maxDownloadsPerPick = Swift.max(1, Int($1.rounded())) }),
        Field(name: "futureMode",
              blurb: "未来富余项的估法:0=关 1=degree(候选还能接上多少首) "
                  + "2=rollout(往前贪心走几步看档位)。",
              min: 0, max: 2, step: 1, digits: 0,
              read: { Double($0.futureMode.rawValue) },
              write: { config, raw in
                  let clamped = Swift.min(Swift.max(Int(raw.rounded()), 0), 2)
                  config.futureMode = QueueOrderConfig.FutureMode(rawValue: clamped) ?? .off
              }),
        field("futureWeight",
              "未来富余项在档位内的权重。上限 2,连同其余连续项仍远小于 tierSpacing——"
                  + "当前 seam 永远不会为了未来被卖掉。",
              0, 2, 0.05, 2, \.futureWeight),
        Field(name: "futureTopK",
              blurb: "对排名前几位的候选算未来项。调大 = 更准也更贵(每位一次 rank)。",
              min: 1, max: 16, step: 1, digits: 0,
              read: { Double($0.futureTopK) },
              write: { $0.futureTopK = Swift.max(1, Int($1.rounded())) }),
        Field(name: "futurePoolCap",
              blurb: "一次未来评估最多看剩余池里的几首(超出按等距抽样)。这是主 actor 上的价格闸。",
              min: 4, max: 512, step: 4, digits: 0,
              read: { Double($0.futurePoolCap) },
              write: { $0.futurePoolCap = Swift.max(1, Int($1.rounded())) }),
        Field(name: "futureRolloutDepth",
              blurb: "rollout 模式往前走几个 seam。",
              min: 1, max: 8, step: 1, digits: 0,
              read: { Double($0.futureRolloutDepth) },
              write: { $0.futureRolloutDepth = Swift.max(1, Int($1.rounded())) }),
        Field(name: "lookaheadDepth",
              blurb: "定下下一首后,再往前预演几步(纯计算,不下载、不承诺)。0 = 关掉。",
              min: 0, max: 32, step: 1, digits: 0,
              read: { Double($0.lookaheadDepth) },
              write: { $0.lookaheadDepth = Swift.max(0, Int($1.rounded())) }),
    ]

    var asDictionary: [String: Double] {
        var out: [String: Double] = [:]
        for f in Self.fields { out[f.name] = f.read(self) }
        return out
    }

    /// `.standard` with the named fields replaced; unknown names ignored,
    /// values clamped into their own range.
    static func standard(overriding overrides: [String: Double]) -> QueueOrderConfig {
        var config = QueueOrderConfig.standard
        for f in fields {
            guard let raw = overrides[f.name] else { continue }
            f.write(&config, Swift.min(Swift.max(raw, f.min), f.max))
        }
        return config
    }
}
