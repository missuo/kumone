import Foundation

// The offline face of the queue-reorder mode (docs/automix-queue-predev.md
// §2.5): run the greedy schedule over a set of locally cached, already
// analyzed tracks and report what it did to the tier distribution.
//
// This exists so "how much is reordering actually worth" is answered by a
// number before it is answered by an ear (predev §5.1). It drives
// `QueueOrderScorer` — the same pure functions `QueueOrderSelector` picks
// with — through `TransitionPlanner`, so nothing here is a model of the
// player: it *is* the player's decision, run offline.
//
// Public because `Sources/audition` lives outside the module and every
// internal type (`TrackAnalysis`, `TransitionPlanner`, `QueueOrderScore`) has
// to be flattened into strings and Doubles to cross that line anyway.

extension Audition {

    /// Tier names worst-to-best, so the console can table them in a fixed
    /// order without knowing the enum.
    public static let orderTierLabels: [String] = TransitionTier.allCases
        .sorted()
        .map(\.label)

    /// The queue-order weights as a tuning surface, alongside the planner's
    /// own `configFields` — same shape, so the console and the CLI can render
    /// both from one loop.
    public struct QueueOrderField: Sendable {
        public let name: String
        public let blurb: String
        public let min: Double
        public let max: Double
        public let step: Double
        public let digits: Int
        public let standard: Double
    }

    public static let queueOrderFields: [QueueOrderField] = QueueOrderConfig.fields.map {
        QueueOrderField(name: $0.name, blurb: $0.blurb, min: $0.min, max: $0.max,
                        step: $0.step, digits: $0.digits, standard: $0.read(.standard))
    }

    /// One candidate as it was scored at one pick.
    public struct OrderCandidate: Sendable {
        public let name: String
        public let tier: String
        public let tempoAffinity: Double
        public let keyAffinity: Double
        public let styleAffinity: Double
        public let energyContinuity: Double
        public let aging: Double
        public let sameArtistPenalty: Double
        /// 0 when the future term is off.
        public let futureRichness: Double
        public let total: Double
        public let lostRounds: Int
        /// This is the one the greedy took.
        public let chosen: Bool
    }

    /// One decision: what was playing, what the pool held, what won.
    public struct OrderStep: Sendable {
        /// 1-based position of the seam in the schedule.
        public let position: Int
        public let from: String
        public let to: String
        public let tier: String
        public let poolSize: Int
        /// Best first. Capped by the caller's `candidateLimit`.
        public let candidates: [OrderCandidate]
    }

    /// A complete play order plus the tiers of its adjacent pairs.
    public struct OrderSchedule: Sendable {
        public let label: String
        /// Track names in play order.
        public let names: [String]
        /// Tier of each adjacent pair; `names.count - 1` entries.
        public let tiers: [String]
        /// Empty for a schedule that was not produced by the greedy.
        public let steps: [OrderStep]

        public var pairs: Int { tiers.count }
        public var beatMatched: Int {
            tiers.filter { $0 == TransitionTier.beatMatched.label
                || $0 == TransitionTier.rampedBeatMatched.label }.count
        }
        /// How many pairs landed in each tier, keyed by `orderTierLabels`.
        public var tierCounts: [String: Int] {
            tiers.reduce(into: [:]) { $0[$1, default: 0] += 1 }
        }

        /// One third of a schedule: where it sits and how it did.
        public struct Third: Sendable {
            public let pairs: Int
            public let beatMatched: Int
            public var share: Double {
                pairs == 0 ? 0 : 100 * Double(beatMatched) / Double(pairs)
            }
        }

        /// The beat-matched share of the first, middle and last third of the
        /// schedule — **always exactly three entries**, and their `pairs` always
        /// sum back to `pairs`.
        ///
        /// This is the measurement the overall share hides. Greedy's quality is
        /// front-loaded: it spends the compatible pairs while it has the whole
        /// pool to choose from, and the tail is left escaping clusters on aging
        /// alone. A single percentage over the whole schedule averages that
        /// collapse away; three of them cannot.
        ///
        /// Contiguous, cut at `i × n / 3`, so the three parts differ in size by
        /// at most one pair and always tile the schedule exactly.
        public var thirds: [Third] {
            let n = tiers.count
            let bounds = (0...3).map { $0 * n / 3 }
            return (0..<3).map { i in
                let slice = tiers[bounds[i]..<bounds[i + 1]]
                return Third(
                    pairs: slice.count,
                    beatMatched: slice.filter {
                        $0 == TransitionTier.beatMatched.label
                            || $0 == TransitionTier.rampedBeatMatched.label
                    }.count)
            }
        }
    }

    /// How often the tier read off a **low-bitrate** analysis matches the one
    /// read off the playback-quality file (predev §2.2 / §4's risk row).
    ///
    /// The scoring terms are all shift-invariant, so this should be high; the
    /// pairs it is *not* high on are the pairs sitting on a gate line, and the
    /// point of measuring is to know how many of those there are.
    public struct OrderTierAgreement: Sendable {
        public let pairs: Int
        public let agreed: Int
        /// "A → B: beatMatched (playback) vs crossfade (low)".
        public let disagreements: [String]
    }

    // MARK: - Schedules

    /// The tiers of the adjacent pairs in the order the files were given —
    /// the baseline every reordering is judged against.
    public static func orderBaseline(
        files: [URL], config: [String: Double] = [:], label: String = "original order"
    ) throws -> OrderSchedule {
        let plannerConfig = TransitionPlanner.Config.standard(overriding: config)
        var analyses: [TrackAnalysis] = []
        for file in files { analyses.append(try analysis(of: file)) }
        var tiers: [String] = []
        for i in 0..<max(0, files.count - 1) {
            let planned = planned(analyses[i], analyses[i + 1],
                                  outgoingURL: files[i], config: plannerConfig)
            tiers.append(TransitionTier(planned).label)
        }
        return OrderSchedule(label: label, names: files.map(displayName),
                             tiers: tiers, steps: [])
    }

    /// The sliding-window greedy of predev §2.2, run to the end of the list.
    ///
    /// - Parameter window: how many of the remaining queue's *listed* entries
    ///   are in the pool. `nil` means every remaining track is — which is what
    ///   a fully cached playlist really gives the selector, since a track with
    ///   an analysis sidecar on disk joins the pool for free.
    /// - Parameter artists: `url.path → artist`, for the same-artist penalty.
    ///   Absent entries simply never trip it.
    public static func order(
        files: [URL],
        window: Int?,
        config: [String: Double] = [:],
        orderConfig: [String: Double] = [:],
        artists: [String: String] = [:],
        candidateLimit: Int = 6,
        label: String? = nil
    ) throws -> OrderSchedule {
        let plannerConfig = TransitionPlanner.Config.standard(overriding: config)
        let queueConfig = QueueOrderConfig.standard(overriding: orderConfig)
        guard files.count >= 2 else {
            return OrderSchedule(label: label ?? "greedy", names: files.map(displayName),
                                 tiers: [], steps: [])
        }
        var analyses: [String: TrackAnalysis] = [:]
        for file in files { analyses[file.path] = try analysis(of: file) }

        var current = files[0]
        var remaining = Array(files.dropFirst())
        /// How many picks each candidate has been passed over for.
        var lostRounds: [String: Int] = [:]
        var names = [displayName(current)]
        var tiers: [String] = []
        var steps: [OrderStep] = []

        while !remaining.isEmpty {
            // Pool: the next `window` listed entries, plus — offline, where
            // every file on disk is by definition cached and analyzed — the
            // whole remainder when no window was asked for.
            let pool = window.map { Array(remaining.prefix(max(1, $0))) } ?? remaining
            let outgoing = analyses[current.path]
            let outgoingArtist = artists[current.path]
            let lineEnds = Lyrics.lineEnds(for: current)

            var scored: [(key: URL, score: QueueOrderScore)] = []
            for candidate in pool {
                let incoming = analyses[candidate.path]
                let planned = TransitionPlanner.plan(
                    outgoing: outgoing, incoming: incoming, stems: .none,
                    config: plannerConfig,
                    context: .init(outgoingLyricLineEnds: lineEnds))
                let sharesArtist = outgoingArtist != nil
                    && outgoingArtist == artists[candidate.path]
                scored.append((candidate, QueueOrderScorer.score(
                    outgoing: outgoing, incoming: incoming, planned: planned,
                    lostRounds: lostRounds[candidate.path] ?? 0,
                    sharesArtist: sharesArtist,
                    config: queueConfig, plannerConfig: plannerConfig)))
            }
            // Ties break on list order, which is the pool's own order — so a
            // pool where nothing distinguishes the candidates reproduces the
            // listed sequence exactly.
            var ranked = sortByTotalThenListOrder(scored)
            QueueOrderScorer.applyFuture(
                to: &ranked, analysis: { analyses[$0.path] },
                config: queueConfig, plannerConfig: plannerConfig)
            guard let winner = ranked.first else { break }

            steps.append(OrderStep(
                position: steps.count + 1,
                from: displayName(current), to: displayName(winner.key),
                tier: winner.score.tier.label,
                poolSize: pool.count,
                candidates: ranked.prefix(candidateLimit).map { entry in
                    candidate(entry, lostRounds: lostRounds, winner: winner.key)
                }))

            // Everyone else in the pool ages; tracks that were never offered a
            // seat do not, or a long queue's tail would arrive pre-aged.
            for entry in ranked where entry.key.path != winner.key.path {
                lostRounds[entry.key.path, default: 0] += 1
            }
            lostRounds[winner.key.path] = nil

            names.append(displayName(winner.key))
            tiers.append(winner.score.tier.label)
            remaining.removeAll { $0.path == winner.key.path }
            current = winner.key
        }

        return OrderSchedule(
            label: label ?? (window.map { "greedy W=\($0)" } ?? "greedy (all cached)"),
            names: names, tiers: tiers, steps: steps)
    }

    // MARK: - Cost of the scoring itself

    /// How long the queue-order arithmetic actually takes at a given pool size.
    ///
    /// The design called a scoring pass "microseconds — a pure function call".
    /// A `TransitionPlanner.plan` is a phrase search, a gate cascade and a
    /// couple of envelope walks, and a pool that started at 4 tracks is now
    /// 200+. This measures the claim instead of repeating it, because the
    /// selector runs on the main actor and a main actor that is busy is an app
    /// that has stopped.
    public struct OrderBench: Sendable {
        public let poolSize: Int
        /// Milliseconds for one `TransitionPlanner.plan`.
        public let planMS: Double
        /// Milliseconds to score a whole pool once — what `pick` costs.
        public let rankMS: Double
        /// Milliseconds for a full lookahead chain — `depth + 1` ranks over a
        /// shrinking pool.
        public let chainMS: Double
        public let depth: Int
        /// Milliseconds the future term adds to one rank — `futureTopK`
        /// evaluations against a pool bounded by `futurePoolCap`. 0 when the
        /// term is off.
        public let futureMS: Double
        public let futureMode: String
        public let futureTopK: Int
        public let futurePoolCap: Int

        /// What one `pick` really costs on the main actor now: the rank plus
        /// the future term. This is the number the 50 ms tripwire watches.
        public var pickMS: Double { rankMS + futureMS }
    }

    public static func orderBench(
        files: [URL], config: [String: Double] = [:], orderConfig: [String: Double] = [:]
    ) throws -> OrderBench {
        let plannerConfig = TransitionPlanner.Config.standard(overriding: config)
        let queueConfig = QueueOrderConfig.standard(overriding: orderConfig)
        var analyses: [TrackAnalysis] = []
        for file in files { analyses.append(try analysis(of: file)) }
        guard analyses.count >= 2 else {
            return OrderBench(
                poolSize: analyses.count, planMS: 0, rankMS: 0, chainMS: 0,
                depth: queueConfig.lookaheadDepth, futureMS: 0,
                futureMode: queueConfig.futureMode.label,
                futureTopK: queueConfig.futureTopK,
                futurePoolCap: queueConfig.futurePoolCap)
        }
        let outgoing = analyses[0]
        let pool = Array(analyses.dropFirst())
        let poolFiles = Array(files.dropFirst().prefix(pool.count))
        let byPath = Dictionary(uniqueKeysWithValues: zip(poolFiles.map(\.path), pool))

        func score(_ a: TrackAnalysis, _ b: TrackAnalysis) {
            let planned = TransitionPlanner.plan(
                outgoing: a, incoming: b, stems: .none, config: plannerConfig,
                context: .init(outgoingLyricLineEnds: []))
            _ = QueueOrderScorer.score(outgoing: a, incoming: b, planned: planned,
                                       config: queueConfig, plannerConfig: plannerConfig)
        }
        func milliseconds(_ body: () -> Void) -> Double {
            let start = ContinuousClock.now
            body()
            return (ContinuousClock.now - start).milliseconds
        }

        // One rank: the whole pool scored against one outgoing track.
        let rankMS = milliseconds { for b in pool { score(outgoing, b) } }
        // A full chain: `depth + 1` ranks over a pool that shrinks by one each
        // step — the shape `recomputeLookahead` runs.
        let depth = max(0, queueConfig.lookaheadDepth)
        let chainMS = milliseconds {
            var remaining = pool
            var from = outgoing
            for _ in 0...depth {
                guard let next = remaining.first else { break }
                for b in remaining { score(from, b) }
                from = next
                remaining.removeFirst()
            }
        }
        // What the future term adds to one pick: `futureTopK` evaluations over
        // a pool the cap has already bounded. Measured as the caller runs it —
        // through `applyFuture`, on a ranked list — so the number includes the
        // re-sort and cannot drift from the shipping path.
        var futureRanked = poolFiles.map { (key: $0, score: QueueOrderScore()) }
        let futureMS = milliseconds {
            QueueOrderScorer.applyFuture(
                to: &futureRanked, analysis: { byPath[$0.path] },
                config: queueConfig, plannerConfig: plannerConfig)
        }
        return OrderBench(poolSize: pool.count,
                          planMS: rankMS / Double(max(1, pool.count)),
                          rankMS: rankMS, chainMS: chainMS, depth: depth,
                          futureMS: futureMS,
                          futureMode: queueConfig.futureMode.label,
                          futureTopK: queueConfig.futureTopK,
                          futurePoolCap: queueConfig.futurePoolCap)
    }

    // MARK: - Satisficing escalation

    /// What the escalation cost, alongside what it bought.
    public struct OrderEscalation: Sendable {
        public let schedule: OrderSchedule
        /// Downloads the escalation started at each pick, in schedule order.
        public let downloadsPerPick: [Int]
        /// Rounds it opened at each pick.
        public let roundsPerPick: [Int]
        /// Picks that ended because a candidate reached the satisfying tier,
        /// rather than because the queue ran out or the budget did.
        public let satisfied: Int
        /// Picks that stopped on the per-pick download budget.
        public let budgeted: Int
        public let satisfyingTier: String
        public let budget: Int

        public var picks: Int { downloadsPerPick.count }
        public var totalDownloads: Int { downloadsPerPick.reduce(0, +) }
        public var maxDownloads: Int { downloadsPerPick.max() ?? 0 }
        public var maxRounds: Int { roundsPerPick.max() ?? 0 }
        public var averageDownloads: Double {
            picks == 0 ? 0 : Double(totalDownloads) / Double(picks)
        }
    }

    /// The satisficing escalation of predev §2.2, run offline over a corpus
    /// that is fully analyzed on disk.
    ///
    /// The corpus being fully analyzed is exactly what would make an offline
    /// run meaningless — every candidate free, every pick trivial — so this
    /// simulates **visibility** instead: a track's analysis is hidden until the
    /// escalation has paid for it, in the order the escalation would have
    /// reached it. That is what makes the download counts here the counts the
    /// player would really incur on a cold playlist.
    ///
    /// Visibility persists across picks, because sidecars do: the warming is a
    /// by-product, and it is why the per-pick cost falls as the schedule runs.
    ///
    /// The per-pick download budget **is** modelled: it is a count, not a
    /// clock, and it is the bound that actually matters in the field. The
    /// decision deadline is not, for the opposite reason — so these numbers are
    /// the worst case the deadline would truncate, never an understatement.
    public static func orderEscalating(
        files: [URL],
        config: [String: Double] = [:],
        orderConfig: [String: Double] = [:],
        artists: [String: String] = [:],
        candidateLimit: Int = 6,
        label: String = "escalation"
    ) throws -> OrderEscalation {
        let plannerConfig = TransitionPlanner.Config.standard(overriding: config)
        let queueConfig = QueueOrderConfig.standard(overriding: orderConfig)
        let budget = max(1, queueConfig.maxDownloadsPerPick)
        guard files.count >= 2 else {
            return OrderEscalation(
                schedule: OrderSchedule(label: label, names: files.map(displayName),
                                        tiers: [], steps: []),
                downloadsPerPick: [], roundsPerPick: [], satisfied: 0, budgeted: 0,
                satisfyingTier: queueConfig.satisfyingTier.label, budget: budget)
        }
        var analyses: [String: TrackAnalysis] = [:]
        for file in files { analyses[file.path] = try analysis(of: file) }

        var current = files[0]
        var remaining = Array(files.dropFirst())
        var lostRounds: [String: Int] = [:]
        var names = [displayName(current)]
        var tiers: [String] = []
        var steps: [OrderStep] = []
        var downloadsPerPick: [Int] = []
        var roundsPerPick: [Int] = []
        var satisfied = 0
        var budgeted = 0
        /// The pool that costs nothing: everything paid for so far. The track
        /// now playing is visible because it is playing.
        var visible: Set<String> = [current.path]

        while !remaining.isEmpty {
            let outgoing = analyses[current.path]
            let outgoingArtist = artists[current.path]
            let lineEnds = Lyrics.lineEnds(for: current)

            /// Score the free pool as it stands. Best first.
            ///
            /// The future term is folded in here, on the *visible* pool — which
            /// is exactly what the player sees, and the reason this row's
            /// numbers are the shipping numbers rather than an idealisation.
            func rank() -> [(key: URL, score: QueueOrderScore)] {
                let scored = remaining.filter { visible.contains($0.path) }
                    .map { candidate -> (key: URL, score: QueueOrderScore) in
                        let incoming = analyses[candidate.path]
                        let planned = TransitionPlanner.plan(
                            outgoing: outgoing, incoming: incoming, stems: .none,
                            config: plannerConfig,
                            context: .init(outgoingLyricLineEnds: lineEnds))
                        let sharesArtist = outgoingArtist != nil
                            && outgoingArtist == artists[candidate.path]
                        return (candidate, QueueOrderScorer.score(
                            outgoing: outgoing, incoming: incoming, planned: planned,
                            lostRounds: lostRounds[candidate.path] ?? 0,
                            sharesArtist: sharesArtist,
                            config: queueConfig, plannerConfig: plannerConfig))
                    }
                // Ties break on list order, which the filter above preserves.
                var ranked = sortByTotalThenListOrder(scored)
                QueueOrderScorer.applyFuture(
                    to: &ranked, analysis: { analyses[$0.path] },
                    config: queueConfig, plannerConfig: plannerConfig)
                return ranked
            }
            func isSatisfied(_ ranked: [(key: URL, score: QueueOrderScore)]) -> Bool {
                (ranked.first?.score.tier).map { $0 >= queueConfig.satisfyingTier } ?? false
            }

            var ranked = rank()
            var downloads = 0
            var rounds = 0
            var roundSize = 0
            // Escalate only while nothing satisfies. Each round admits its own
            // size worth of not-yet-visible tracks in list order, and the loop
            // re-scores after *every* one — so it stops mid-round, which is
            // where most of the saving is.
            while !isSatisfied(ranked), downloads < budget {
                roundSize = roundSize == 0
                    ? max(1, queueConfig.escalationFirstRound)
                    : roundSize * max(1, queueConfig.escalationFactor)
                let opened = remaining.filter { !visible.contains($0.path) }.prefix(roundSize)
                guard !opened.isEmpty else { break }
                rounds += 1
                for candidate in opened {
                    visible.insert(candidate.path)
                    downloads += 1
                    ranked = rank()
                    if isSatisfied(ranked) || downloads >= budget { break }
                }
            }
            if isSatisfied(ranked) {
                satisfied += 1
            } else if downloads >= budget {
                // Not a failure: the tracks this pick could not reach are still
                // unbought at the next one, which starts from a pool this pick
                // made `budget` tracks richer.
                budgeted += 1
            }
            guard let winner = ranked.first else { break }

            steps.append(OrderStep(
                position: steps.count + 1,
                from: displayName(current), to: displayName(winner.key),
                tier: winner.score.tier.label,
                poolSize: ranked.count,
                candidates: ranked.prefix(candidateLimit).map { entry in
                    candidate(entry, lostRounds: lostRounds, winner: winner.key)
                }))
            downloadsPerPick.append(downloads)
            roundsPerPick.append(rounds)

            for entry in ranked where entry.key.path != winner.key.path {
                lostRounds[entry.key.path, default: 0] += 1
            }
            lostRounds[winner.key.path] = nil

            names.append(displayName(winner.key))
            tiers.append(winner.score.tier.label)
            remaining.removeAll { $0.path == winner.key.path }
            current = winner.key
        }

        return OrderEscalation(
            schedule: OrderSchedule(label: "\(label) ≤\(budget)/pick",
                                    names: names, tiers: tiers, steps: steps),
            downloadsPerPick: downloadsPerPick, roundsPerPick: roundsPerPick,
            satisfied: satisfied, budgeted: budgeted,
            satisfyingTier: queueConfig.satisfyingTier.label, budget: budget)
    }

    // MARK: - Low-bitrate agreement

    /// Plan each adjacent pair of `files` twice — once from the playback-quality
    /// analyses, once from the low-bitrate ones — and count how often the tier
    /// came out the same.
    ///
    /// - Parameter lowQuality: `playbackURL.path → low-bitrate URL`. A pair
    ///   with no low-bitrate counterpart on either side is skipped, so a corpus
    ///   with none at all reports zero pairs rather than failing.
    public static func orderTierAgreement(
        files: [URL], lowQuality: [String: URL], config: [String: Double] = [:]
    ) throws -> OrderTierAgreement {
        let plannerConfig = TransitionPlanner.Config.standard(overriding: config)
        var pairs = 0, agreed = 0
        var disagreements: [String] = []
        for i in 0..<max(0, files.count - 1) {
            let a = files[i], b = files[i + 1]
            guard let lowA = lowQuality[a.path], let lowB = lowQuality[b.path] else { continue }
            let high = TransitionTier(planned(try analysis(of: a), try analysis(of: b),
                                              outgoingURL: a, config: plannerConfig))
            // The low-bitrate side is scored on its own file's lyric sidecar,
            // exactly as the selector would see it.
            let low = TransitionTier(planned(try analysis(of: lowA), try analysis(of: lowB),
                                             outgoingURL: lowA, config: plannerConfig))
            pairs += 1
            if high == low {
                agreed += 1
            } else {
                disagreements.append("\(displayName(a)) → \(displayName(b)): "
                                     + "\(high.label) (playback) vs \(low.label) (low)")
            }
        }
        return OrderTierAgreement(pairs: pairs, agreed: agreed, disagreements: disagreements)
    }

    // MARK: - Helpers

    /// Best first, ties on the candidate's position in the pool — the one
    /// ordering both offline schedules and the live selector agree on.
    private static func sortByTotalThenListOrder(
        _ scored: [(key: URL, score: QueueOrderScore)]
    ) -> [(key: URL, score: QueueOrderScore)] {
        scored.enumerated()
            .sorted {
                $0.element.score.total == $1.element.score.total
                    ? $0.offset < $1.offset
                    : $0.element.score.total > $1.element.score.total
            }
            .map(\.element)
    }

    private static func candidate(
        _ entry: (key: URL, score: QueueOrderScore),
        lostRounds: [String: Int], winner: URL
    ) -> OrderCandidate {
        OrderCandidate(
            name: displayName(entry.key),
            tier: entry.score.tier.label,
            tempoAffinity: entry.score.tempoAffinity,
            keyAffinity: entry.score.keyAffinity,
            styleAffinity: entry.score.styleAffinity,
            energyContinuity: entry.score.energyContinuity,
            aging: entry.score.aging,
            sameArtistPenalty: entry.score.sameArtistPenalty,
            futureRichness: entry.score.futureRichness,
            total: entry.score.total,
            lostRounds: lostRounds[entry.key.path] ?? 0,
            chosen: entry.key.path == winner.path)
    }

    private static func planned(
        _ a: TrackAnalysis, _ b: TrackAnalysis,
        outgoingURL: URL, config: TransitionPlanner.Config
    ) -> PlannedTransition {
        TransitionPlanner.plan(
            outgoing: a, incoming: b, stems: .none, config: config,
            context: .init(outgoingLyricLineEnds: Lyrics.lineEnds(for: outgoingURL)))
    }

    private static func displayName(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }
}
