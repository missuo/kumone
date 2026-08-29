import Foundation

// The stateful half of the AutoMix queue-reorder mode
// (docs/automix-queue-predev.md §2.2 / §2.4). The arithmetic lives in
// `QueueOrderScoring.swift`; what is here is bookkeeping — which candidates
// are in the pool, which have an analysis in hand, which one is being fetched,
// and how many rounds each has lost.
//
// **The acquisition policy is satisficing escalation.** A pick starts from
// every analysis already in hand and stops the instant one of them is good
// enough (`config.satisfyingTier`, "beat-matched or better"). Only when none
// is does it start paying, in exponentially growing rounds down the remaining
// queue — 1 track, then 4, then 16 — stopping mid-round the moment something
// satisfies. The fixed W=4 window this replaced was measured worthless on a
// real cache (13 % beat-matched at list order vs 16 % at W=4 vs 53 % with the
// whole analyzed pool): the value was never in the window, it was in the pool
// being rich, and the sidecars each round leaves behind make it richer for
// every later pick.
//
// **Nothing in this file exists while the mode is off.** `PlayerService` holds
// the selector as an optional and only builds one when the queue order is
// `.autoMix`, so a player in `.listed` or `.shuffled` runs the code it always
// ran, allocates nothing extra and issues no request.

/// Which order the player walks its queue in — the three-state upgrade of the
/// old `shuffleEnabled: Bool` (predev §2.1).
///
/// Mutually exclusive by construction: there is one value, so "turning AutoMix
/// order on turns shuffle off" is not a rule anybody has to remember to apply.
/// The raw `queue` is never reordered by any of them, so leaving a mode always
/// restores the list the user actually gave us.
enum QueueOrder: String, Codable, Sendable, CaseIterable {
    case listed, shuffled, autoMix

    /// The persisted-state migration: sessions written before the mode existed
    /// carry a bare `shuffle` bool and nothing else.
    init(migratingShuffle shuffle: Bool) {
        self = shuffle ? .shuffled : .listed
    }
}

@MainActor
final class QueueOrderSelector {

    /// The quality the *scoring* copy of a candidate is downloaded at
    /// (predev §2.2): the cheapest level NetEase serves, ~4 MB against 20–40
    /// for a lossless file. Every term the scorer reads is shift-invariant, so
    /// the lossy encoder's leading delay cannot reach it — but the beat grid a
    /// *plan* aligns to is not, which is why the winner is re-downloaded at
    /// playback quality and re-analyzed by the ordinary prefetch path before a
    /// single number of the real hand-over is computed.
    static let scoringLevel = AudioQuality.standard.rawValue

    /// One scored candidate, best-first in `lastPick`.
    struct Candidate: Equatable {
        let track: Track
        let score: QueueOrderScore
    }

    var config: QueueOrderConfig = .standard

    /// Fired on the main actor when a candidate analysis lands, so the player
    /// can reconsider a pick it has not committed to yet.
    var onCandidateReady: (() -> Void)?

    /// Scoring analyses in hand, by track ID. Filled from two places: the
    /// on-disk cache (free — a track heard before) and the low-bitrate fetch
    /// below (~4 MB and a couple of seconds).
    private var analyses: [Int: TrackAnalysis] = [:]
    /// Rounds each candidate has been passed over for. The aging term reads
    /// this; nothing else does.
    private var lostRounds: [Int: Int] = [:]
    /// Candidates that could not be fetched or analyzed. Never retried this
    /// session — a track NetEase will not serve at the scoring level will not
    /// start serving it three minutes later, and retrying would starve the
    /// budget-1 queue behind a track that can never join the pool.
    private var refused: Set<Int> = []
    /// Track IDs already looked up in the on-disk cache, so the directory walk
    /// happens once per track rather than once per tick.
    private var scanned: Set<Int> = []

    /// The tracks this pick's escalation has admitted for acquisition, by ID
    /// (predev §2.2).
    ///
    /// **A set, never indices.** The queue can be edited under us at any moment
    /// — a removal, an insertion, a manual jump — and every question the policy
    /// asks ("what is the frontier", "is it resolved", "what may I admit next")
    /// is answered by intersecting this set with the *current* remaining queue.
    /// A track that leaves the queue simply stops being in the frontier; one
    /// that joins is unadmitted until a round reaches it.
    private var admitted: Set<Int> = []
    /// How many tracks the last round admitted, so the next one can be `×
    /// escalationFactor` of it. 0 before the first round.
    private var lastRoundSize = 0
    /// Rounds this pick has escalated through — the cost figure the debug panel
    /// and `audition order` report.
    private(set) var rounds = 0
    /// Candidates downloaded for *this* pick. Reset with the pick, unlike
    /// `analyses`, which is cumulative across the session.
    private(set) var downloadsThisPick = 0

    /// **The whole download budget: one.** The same discipline the existing
    /// prefetch runs under, for the same reason — a second concurrent transfer
    /// competes with the audio that is playing.
    private var fetching = false
    private var scanning = false

    /// The last pick's full candidate table, best first — what the debug panel
    /// prints and the only reason the scores are kept after the choice.
    private(set) var lastPick: [Candidate] = []

    init() {}

    // MARK: - Pool bookkeeping

    /// The candidate pool for a remaining queue: **everything already analyzed**
    /// (predev §2.2).
    ///
    /// This is exactly the set the selector can score without spending
    /// anything — the window bookkeeping of earlier picks, everything the
    /// escalation downloaded in previous rounds and previous sessions, and
    /// every sidecar the disk scan found. It is free by construction, so every
    /// pick starts from all of it and the escalation below only ever has to pay
    /// for what this does not already cover.
    ///
    /// Kept in list order, which is what the pick's tie-break reads: a pool the
    /// scorer cannot tell apart reproduces the user's own list.
    func pool(remaining: [Track]) -> [Track] {
        remaining.filter { analyses[$0.id] != nil }
    }

    /// The tracks this pick's escalation has admitted, in list order —
    /// re-derived from `remaining` every time it is asked, so a queue edit
    /// needs no index fix-up.
    func frontier(remaining: [Track]) -> [Track] {
        remaining.filter { admitted.contains($0.id) }
    }

    /// Whether every candidate in the pool has been resolved one way or the
    /// other — analyzed, or refused. Once true there is nothing left to wait
    /// for and the pick can be made early instead of at the deadline.
    func isSettled(_ pool: [Track]) -> Bool {
        pool.allSatisfy { analyses[$0.id] != nil || refused.contains($0.id) }
    }

    func hasAnalysis(for track: Track) -> Bool { analyses[track.id] != nil }

    var analyzedCount: Int { analyses.count }

    /// Whether the last `pick` came back with a candidate that reaches
    /// `config.satisfyingTier` — the stop condition of the whole escalation.
    var lastPickSatisfies: Bool {
        guard let best = lastPick.first else { return false }
        return best.score.tier >= config.satisfyingTier
    }

    /// A new track is playing: the escalation starts over from nothing
    /// admitted. Analyses are emphatically **not** dropped — they are the
    /// richer pool this pick starts from, which is the entire point of paying
    /// for them once (predev §2.2).
    func beginPick() {
        admitted.removeAll()
        lastRoundSize = 0
        rounds = 0
        downloadsThisPick = 0
    }

    // MARK: - Satisficing escalation

    /// What one acquisition tick concluded.
    enum Acquisition: Equatable {
        /// A disk scan or a download is under way; call again when it lands.
        case acquiring
        /// The escalation is standing aside for the playback-quality prefetch.
        case deferred
        /// Nothing left to admit — the remaining queue is spent. The caller
        /// should pick the best it has rather than keep waiting.
        case exhausted
        /// This pick has spent its download budget. Same instruction to the
        /// caller as `exhausted` — settle for the best in hand — but a very
        /// different fact: the queue still has material, and the *next* pick
        /// will escalate into it from a pool this one made richer.
        case spent
    }

    /// Move the escalation one step (predev §2.2).
    ///
    /// Called from the playback tick, only while the pick is still unsatisfied.
    /// It costs a directory walk once per track and at most one download at a
    /// time, and it is idempotent — a tick that arrives while a job is in
    /// flight does nothing.
    ///
    /// - Parameter mayDownload: false while the playback-quality prefetch is
    ///   pulling bytes. The escalation is background work and yields to the
    ///   audio that is about to play; the disk scan, which costs no network,
    ///   goes ahead either way.
    @discardableResult
    func acquire(remaining: [Track], mayDownload: Bool = true) -> Acquisition {
        guard !scanning else { return .acquiring }
        // Free first, always: a sidecar already on disk is a candidate that
        // costs nothing, and finding it may end the escalation outright.
        let unscanned = remaining.filter { !scanned.contains($0.id) }
        if !unscanned.isEmpty {
            scanning = true
            let ids = Set(unscanned.map(\.id))
            Task { [weak self] in
                let found = await AudioCache.shared.analyses(forTrackIDs: ids)
                guard let self else { return }
                self.scanned.formUnion(ids)
                self.scanning = false
                var landed = false
                for (id, analysis) in found where self.analyses[id] == nil {
                    self.analyses[id] = analysis
                    landed = true
                }
                if landed { self.onCandidateReady?() }
            }
            return .acquiring
        }
        guard !fetching else { return .acquiring }
        // The budget is checked before the ladder, not inside it, so a spent
        // pick opens no further round either: admitting tracks it cannot buy
        // would only make the frontier lie.
        guard downloadsThisPick < max(1, config.maxDownloadsPerPick) else {
            PlaybackJournal.note(
                "order budget spent downloads=\(downloadsThisPick) "
                + "cap=\(config.maxDownloadsPerPick) rounds=\(rounds) "
                + "analyzed=\(analyses.count)")
            return .spent
        }

        // Walk down the ladder: serve the admitted frontier first, and only
        // once every admitted track has resolved does the next — four times
        // larger — round open.
        while true {
            if let next = frontier(remaining: remaining).first(where: isUnresolved) {
                guard mayDownload else { return .deferred }
                startFetch(next)
                return .acquiring
            }
            guard escalate(remaining: remaining) else { return .exhausted }
        }
    }

    /// Admit the next round's worth of unresolved tracks, in list order.
    /// False when there were none left to admit.
    ///
    /// Only *unresolved* tracks count against a round's size: a track already
    /// analyzed is in the pool for free and admitting it would spend a round on
    /// nothing.
    private func escalate(remaining: [Track]) -> Bool {
        let size = lastRoundSize == 0
            ? max(1, config.escalationFirstRound)
            : lastRoundSize * max(1, config.escalationFactor)
        let opened = remaining
            .filter { isUnresolved($0) && !admitted.contains($0.id) }
            .prefix(size)
        guard !opened.isEmpty else { return false }
        admitted.formUnion(opened.map(\.id))
        lastRoundSize = size
        rounds += 1
        PlaybackJournal.note(
            "order round \(rounds) opened size=\(size) admitted=\(opened.count) "
            + "analyzed=\(analyses.count) refused=\(refused.count)")
        return true
    }

    private func isUnresolved(_ track: Track) -> Bool {
        analyses[track.id] == nil && !refused.contains(track.id)
    }

    private func startFetch(_ track: Track) {
        fetching = true
        downloadsThisPick += 1
        Task { [weak self] in
            let fetched = await Self.scoringAnalysis(for: track)
            guard let self else { return }
            self.fetching = false
            switch fetched {
            case .analyzed(let analysis):
                self.analyses[track.id] = analysis
                PlaybackJournal.note("order fetch ok id=\(track.id)")
            case .refused(let why):
                self.refused.insert(track.id)
                PlaybackJournal.note("order fetch refused id=\(track.id) why=\(why)")
            }
            self.onCandidateReady?()
        }
    }

    // MARK: - Picking

    /// The highest-scoring **analyzed** candidate, or nil when none of the
    /// pool has an analysis yet.
    ///
    /// Nil is the deadline fallback the caller needs: the mode never waits for
    /// a download at the cost of a gap, it just plays what the list said next
    /// (predev §2.2).
    ///
    /// Pure with respect to the selector's state — call it as often as you
    /// like. `noteRound` is what actually moves the aging counters.
    func pick(
        outgoing: Track?, outgoingAnalysis: TrackAnalysis?,
        pool: [Track],
        plannerConfig: TransitionPlanner.Config = .standard,
        outgoingLyricLineEnds: [TimeInterval] = []
    ) -> Track? {
        lastPick = rank(
            outgoing: outgoing, outgoingAnalysis: outgoingAnalysis, pool: pool,
            lostRounds: lostRounds, plannerConfig: plannerConfig,
            outgoingLyricLineEnds: outgoingLyricLineEnds)
        return lastPick.first?.track
    }

    /// Score a pool against one outgoing track, best first.
    ///
    /// **The aging counters are a parameter, not a field read.** That is what
    /// lets the lookahead chain below replay this function against a private
    /// copy of them: a preview that aged the real counters would be a preview
    /// that changed the future it was previewing.
    private func rank(
        outgoing: Track?, outgoingAnalysis: TrackAnalysis?,
        pool: [Track], lostRounds: [Int: Int],
        plannerConfig: TransitionPlanner.Config,
        outgoingLyricLineEnds: [TimeInterval]
    ) -> [Candidate] {
        var scored: [(key: Int, score: QueueOrderScore)] = []
        var byID: [Int: Track] = [:]
        for track in pool {
            guard let incoming = analyses[track.id] else { continue }
            // The planner *is* the scorer: whatever hand-over it can build for
            // this pair is what the pair is worth (predev §2.3).
            let planned = TransitionPlanner.plan(
                outgoing: outgoingAnalysis, incoming: incoming, stems: .none,
                config: plannerConfig,
                context: .init(outgoingLyricLineEnds: outgoingLyricLineEnds))
            byID[track.id] = track
            scored.append((track.id, QueueOrderScorer.score(
                outgoing: outgoingAnalysis, incoming: incoming, planned: planned,
                lostRounds: lostRounds[track.id] ?? 0,
                sharesArtist: Self.sharesArtist(outgoing, track),
                config: config, plannerConfig: plannerConfig)))
        }
        // Ties break on pool order — which is list order — so a pool the scorer
        // cannot tell apart reproduces the user's list rather than an arbitrary
        // permutation. `sorted` is not stable, hence the explicit index
        // tiebreak.
        var ranked = scored.enumerated()
            .sorted {
                $0.element.score.total == $1.element.score.total
                    ? $0.offset < $1.offset
                    : $0.element.score.total > $1.element.score.total
            }
            .map(\.element)
        // The future term, if it is on: a bounded in-tier bonus for the top few
        // candidates that leave the most of the pool still reachable.
        QueueOrderScorer.applyFuture(
            to: &ranked, analysis: { self.analyses[$0] },
            config: config, plannerConfig: plannerConfig)
        return ranked.compactMap { entry in
            byID[entry.key].map { Candidate(track: $0, score: entry.score) }
        }
    }

    // MARK: - Lookahead chain (predev §2.1 / §2.2)

    /// One provisional step of the chain.
    struct ChainStep: Equatable {
        let track: Track
        let score: QueueOrderScore
    }

    /// The plan past the decided next: what the *analyzed pool alone* would
    /// choose at each of the following `config.lookaheadDepth` seams.
    ///
    /// **Provisional, and labelled so everywhere it is shown.** Nothing here is
    /// committed: each real pick is made fresh at its own decision point, from
    /// a pool that will have grown and against a deadline this chain knows
    /// nothing about. The chain exists so the upcoming list and the debug panel
    /// can show a plausible run rather than a decided next followed by raw list
    /// order — and so a listener can see the shape of what the mode is heading
    /// towards.
    private(set) var lookahead: [ChainStep] = []

    /// Everything the chain needs, in value types only — no `Track`, no
    /// selector, nothing main-actor-bound. This is what crosses to the
    /// background, and the reason it can.
    struct ChainInput: Sendable {
        var headID: Int
        /// Analyzed candidates in list order.
        var poolIDs: [Int]
        var analyses: [Int: TrackAnalysis]
        var lostRounds: [Int: Int]
        /// Credited artist IDs per track, for the same-artist penalty. Id 0 is
        /// the decoder's "unknown" and is filtered out before it gets here.
        var artistIDs: [Int: Set<Int>]
        var config: QueueOrderConfig
        var plannerConfig: TransitionPlanner.Config
    }

    /// One computed step, still in value types.
    struct ChainResult: Sendable, Equatable {
        let id: Int
        let score: QueueOrderScore
    }

    /// The chain, as a pure function.
    ///
    /// Chained greedy over the analyzed pool: each step scores the pool against
    /// the previous step's winner, takes the best, and ages its own private
    /// copy of the counters exactly as a real round would — so a chain of eight
    /// does not hand the same track to all eight seams.
    ///
    /// `nonisolated` and free of reference types on purpose: at a 156-track
    /// pool this is 5.6 ms in release and **110 ms in debug**, and the selector
    /// lives on the main actor. A hundred milliseconds of main actor, every
    /// time a candidate lands, is a stutter; at a thousand-track playlist it is
    /// a freeze. So it runs on a detached task and only the answer comes back.
    ///
    /// Lyric line ends are deliberately absent: a chain step's candidate has no
    /// local file yet, and a vocal-exchange hand-over is a detail of a seam
    /// this chain is not promising to make.
    nonisolated static func chain(_ input: ChainInput, depth: Int) -> [ChainResult] {
        var out: [ChainResult] = []
        var aging = input.lostRounds
        var outgoingID = input.headID
        var pool = input.poolIDs.filter { $0 != input.headID }
        while out.count < depth, !pool.isEmpty {
            let outgoing = input.analyses[outgoingID]
            let outgoingArtists = input.artistIDs[outgoingID] ?? []
            var scored: [(key: Int, score: QueueOrderScore)] = []
            for id in pool {
                guard let incoming = input.analyses[id] else { continue }
                let planned = TransitionPlanner.plan(
                    outgoing: outgoing, incoming: incoming, stems: .none,
                    config: input.plannerConfig,
                    context: .init(outgoingLyricLineEnds: []))
                scored.append((id, QueueOrderScorer.score(
                    outgoing: outgoing, incoming: incoming, planned: planned,
                    lostRounds: aging[id] ?? 0,
                    sharesArtist: !outgoingArtists.isEmpty
                        && !(input.artistIDs[id] ?? []).isDisjoint(with: outgoingArtists),
                    config: input.config, plannerConfig: input.plannerConfig)))
            }
            // Ties break on list order, which `pool` is in.
            var ranked = scored.enumerated()
                .sorted {
                    $0.element.score.total == $1.element.score.total
                        ? $0.offset < $1.offset
                        : $0.element.score.total > $1.element.score.total
                }
                .map(\.element)
            // The chain runs the same pick the real seam will, future term
            // included — a preview that scored differently would be previewing
            // a different player. It can afford to: this is a detached task.
            QueueOrderScorer.applyFuture(
                to: &ranked, analysis: { input.analyses[$0] },
                config: input.config, plannerConfig: input.plannerConfig)
            guard let winner = ranked.first else { break }
            out.append(ChainResult(id: winner.key, score: winner.score))
            for id in pool where id != winner.key { aging[id, default: 0] += 1 }
            aging[winner.key] = nil
            pool.removeAll { $0 == winner.key }
            outgoingID = winner.key
        }
        return out
    }

    /// Build the chain's input from the selector's state.
    func chainInput(head: Track, remaining: [Track],
                    plannerConfig: TransitionPlanner.Config) -> ChainInput {
        let candidates = remaining.filter { analyses[$0.id] != nil }
        var artistIDs: [Int: Set<Int>] = [:]
        for track in [head] + candidates {
            artistIDs[track.id] = Set(track.artists.map(\.id).filter { $0 != 0 })
        }
        var wanted = Set(candidates.map(\.id))
        wanted.insert(head.id)
        let needed = analyses.filter { wanted.contains($0.key) }
        return ChainInput(
            headID: head.id, poolIDs: candidates.map(\.id), analyses: needed,
            lostRounds: lostRounds, artistIDs: artistIDs,
            config: config, plannerConfig: plannerConfig)
    }

    /// Turn a computed chain back into steps, dropping anything that has left
    /// the queue while the background task was running.
    ///
    /// That drop is the whole staleness story: the chain is provisional, the
    /// answer is only ever *shown*, and a track that is no longer in the queue
    /// simply is not in the chain. No repair, no invalidation bookkeeping.
    func applyLookahead(_ results: [ChainResult], remaining: [Track]) {
        let byID = Dictionary(remaining.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        lookahead = results.compactMap { result in
            byID[result.id].map { ChainStep(track: $0, score: result.score) }
        }
        // One line per applied chain — the observable proof of "recomputed at
        // every commit, rarely in between". Throttled upstream, so this is
        // lifecycle-frequency, not per-tick.
        let steps = lookahead
            .map { "\($0.track.id):\($0.score.tier.label)" }
            .joined(separator: " ")
        PlaybackJournal.note("order lookahead applied steps=\(lookahead.count) [\(steps)]")
    }

    func clearLookahead() { lookahead = [] }

    /// Input → chain → apply, in one synchronous call.
    ///
    /// The production path does the middle step on a detached task, which is
    /// the whole point of the split; this composes the same three functions so
    /// the two cannot drift, and so the chain's behaviour is assertable without
    /// a scheduler in the test.
    func recomputeLookahead(
        head: Track, remaining: [Track],
        plannerConfig: TransitionPlanner.Config = .standard
    ) {
        let input = chainInput(head: head, remaining: remaining,
                               plannerConfig: plannerConfig)
        applyLookahead(Self.chain(input, depth: max(0, config.lookaheadDepth)),
                       remaining: remaining)
    }

    /// Commit a pick: everyone else in the pool ages by one round.
    ///
    /// Only the pool ages, never the whole remaining queue — a track that was
    /// never offered a seat has not lost anything, and pre-aging the tail of a
    /// long list would let it outrank the head before it was ever considered.
    func noteRound(chosen: Track, pool: [Track]) {
        for track in pool where track.id != chosen.id {
            lostRounds[track.id, default: 0] += 1
        }
        lostRounds[chosen.id] = nil
    }

    /// The queue changed underneath us (new playlist, mode switch). Analyses
    /// are kept — they are on disk anyway and cost nothing to remember — but
    /// every aging counter and the refusal list go, because they described a
    /// queue that no longer exists.
    func reset() {
        lostRounds.removeAll()
        refused.removeAll()
        lastPick = []
        lookahead = []
        beginPick()
    }

    // MARK: - Test hooks
    //
    // The pool arithmetic is worth asserting on and the fetch is not: it is a
    // network call, and every property the bookkeeping has is a property of
    // what the fetch *produced*, not of the fetching. So the two states a
    // fetch can end in are settable directly.

    func injectAnalysisForTesting(_ analysis: TrackAnalysis, forTrackID id: Int) {
        analyses[id] = analysis
        scanned.insert(id)
    }

    func injectRefusalForTesting(trackID id: Int) {
        refused.insert(id)
        scanned.insert(id)
    }

    func lostRoundsForTesting(_ id: Int) -> Int { lostRounds[id] ?? 0 }

    /// Open one escalation round without going near the network — the ladder
    /// (1, 4, 16 …) is arithmetic over the remaining queue and is worth
    /// asserting on directly.
    @discardableResult
    func escalateForTesting(remaining: [Track]) -> Bool { escalate(remaining: remaining) }

    /// Pretend the disk has already been walked for these tracks, so `acquire`
    /// gets past its free half without a file system.
    func markScannedForTesting(_ tracks: [Track]) {
        scanned.formUnion(tracks.map(\.id))
    }

    /// Pretend this pick has already spent `n` downloads. The budget is a
    /// count, and what it does at its limit is worth asserting on without
    /// opening `n` real transfers.
    func markDownloadsForTesting(_ n: Int) { downloadsThisPick = n }

    // MARK: - Fetching

    /// Whether the two tracks share a credited artist — the same-artist
    /// penalty's whole input. Artist id 0 is the decoder's "unknown" and never
    /// matches anything.
    nonisolated static func sharesArtist(_ a: Track?, _ b: Track) -> Bool {
        guard let a else { return false }
        let left = Set(a.artists.map(\.id).filter { $0 != 0 })
        guard !left.isEmpty else { return false }
        return b.artists.contains { $0.id != 0 && left.contains($0.id) }
    }

    /// Resolve, download and analyze one candidate at the scoring level.
    ///
    /// Goes through `AudioCache` like everything else, so the file and its
    /// sidecar land under the ordinary key (`<id>-standard-netease.<ext>`),
    /// take part in LRU eviction, and are found again for free by
    /// `analyses(forTrackIDs:)` on a later queue.
    ///
    /// Trial fragments are refused: a 30-second excerpt has neither the
    /// structure nor the duration the planner needs, and scoring one would be
    /// scoring a different piece of music.
    /// One fetch's outcome, with the refusal reason kept for the journal —
    /// the mass-refusal failure mode is invisible without it.
    private enum ScoringFetch {
        case analyzed(TrackAnalysis)
        case refused(String)
    }

    private static func scoringAnalysis(for track: Track) async -> ScoringFetch {
        guard let data = try? await NeteaseAPI.songURL(
                ids: [track.id], level: scoringLevel).first
        else { return .refused("songURL failed") }
        guard data.freeTrialInfo == nil else { return .refused("trial fragment") }
        guard let urlString = data.url,
              let remote = URL(string: urlString.replacingOccurrences(
                  of: "http://", with: "https://"))
        else { return .refused("no url served") }
        let ext = remote.pathExtension.isEmpty ? "mp3" : remote.pathExtension.lowercased()
        let key = AudioCache.Key(trackID: track.id, level: data.level ?? scoringLevel,
                                 source: "netease", fileExtension: ext)
        if let cached = await AudioCache.shared.loadAnalysis(for: key) {
            return .analyzed(cached)
        }
        guard let local = try? await AudioCache.shared.download(from: remote, key: key)
        else { return .refused("download failed") }
        guard let analyzed = await Task.detached(priority: .utility, operation: {
            try? TrackAnalyzer.analyze(fileAt: local)
        }).value else { return .refused("analysis failed") }
        await AudioCache.shared.storeAnalysis(analyzed, for: key)
        return .analyzed(analyzed)
    }
}

extension Duration {
    /// Wall-clock milliseconds, for the timing the queue-order code reports.
    ///
    /// `ContinuousClock` is the right clock for "did this block the main
    /// actor": it does not stop when the machine sleeps and it is not
    /// adjustable, so a number measured here is the number the user waited.
    var milliseconds: Double {
        let parts = components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }
}
