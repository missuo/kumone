import Testing
@testable import KumoneCore
import Foundation

// The AutoMix queue-reorder mode's arithmetic and bookkeeping
// (docs/automix-queue-predev.md). Three properties carry the whole design and
// each gets its own test:
//
//   - **the tier dominates**. A stylistically perfect pair that can only be
//     crossfaded must never outrank a pair that can be beat-matched, or the
//     mode is optimising a proxy instead of the thing it claims to optimise.
//   - **aging is unbounded**. "Every track gets played" has to be a property
//     of the arithmetic, not a hope: keep losing and you eventually outrank a
//     whole tier.
//   - **mode off changes nothing**. The three-state replaces a Bool that has
//     been persisted for as long as the app has existed, so a session written
//     before the mode came back exactly as it was.
//
// No engine is constructed anywhere in here: the scorer is a pure function and
// the selector's bookkeeping is reachable without a player.

@Suite struct QueueOrderTests {

    // MARK: - Fixtures

    private func makeAnalysis(
        bpm: Double = 120,
        bpmConfidence: Double = 0.9,
        duration: TimeInterval = 200,
        keyPitchClass: Int? = nil,
        keyIsMinor: Bool = false,
        keyConfidence: Double = 0,
        melProfile: [Float] = [],
        energy: Float? = nil
    ) -> TrackAnalysis {
        let barLength = 4 * 60 / bpm
        var a = TrackAnalysis(
            version: TrackAnalysis.currentVersion,
            bpm: bpm, bpmConfidence: bpmConfidence,
            beats: stride(from: 0.4, to: duration, by: 60 / bpm).map { $0 },
            downbeats: stride(from: 0.4, to: duration, by: barLength).map { $0 },
            phraseBoundaries: [150, 90, 30],
            rmsEnvelope: [Float](repeating: 0.5, count: Int(duration)),
            outroFadeStart: nil, introEnd: 2, duration: duration,
            melProfile: melProfile, keyPitchClass: keyPitchClass, keyIsMinor: keyIsMinor,
            keyConfidence: keyConfidence, vocalActivity: [],
            referenceLoudness: -12, peakDBFS: -6)
        if let energy {
            a.sections = [TrackAnalysis.Section(start: 0, end: duration, kind: .verse,
                                                repetition: 2, energy: energy, vocalDensity: 1)]
            a.structureConfidence = 0.8
        }
        return a
    }

    /// A `PlannedTransition` of a given shape, built by hand — the scorer takes
    /// the plan as a parameter precisely so the tier can be stated rather than
    /// coaxed out of the planner.
    private func planned(_ tier: TransitionTier) -> PlannedTransition {
        switch tier {
        case .gapless:
            return .plain(.gapless)
        case .crossfade:
            return .plain(.crossfade(duration: 6, outPoint: 180, inPoint: 0))
        case .stagedCrossfade:
            return PlannedTransition(
                plan: .crossfade(duration: 6, outPoint: 180, inPoint: 0),
                style: TransitionStyle(outroEffect: .fade, stagedEQ: true))
        case .beatMatched, .rampedBeatMatched:
            var plan = BeatMatchedPlan(
                outPoint: 160, inPoint: 2, overlapBars: 8,
                outgoingRate: 1.01, incomingRate: 0.99,
                bassSwapOffset: 4, overlapDuration: 16)
            if tier == .rampedBeatMatched {
                plan.rampLeadSeconds = 13
                plan.rampReleaseSeconds = 3
            }
            return .plain(.beatMatched(plan))
        }
    }

    private func track(_ id: Int, artist: Int = 0, name: String? = nil) -> Track {
        let artists = artist == 0 ? [] : [["id": artist, "name": "artist \(artist)"]]
        let json: [String: Any] = [
            "id": id, "name": name ?? "track \(id)", "ar": artists,
            "al": ["id": 1, "name": "album"], "dt": 200_000,
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(Track.self, from: data)
    }

    // MARK: - Tier ordering

    @Test func theTierDominatesEveryContinuityTerm() {
        // The crossfade candidate is perfect on every continuous term; the
        // beat-matched one is as bad as it can be on all four. The tier must
        // still win — this is predev §2.3's "tier 是主项" as an assertion.
        let a = makeAnalysis(bpm: 120, keyPitchClass: 0, keyConfidence: 0.9,
                             melProfile: [1, 0, 0, 0], energy: 0.6)
        let twin = makeAnalysis(bpm: 120, keyPitchClass: 0, keyConfidence: 0.9,
                                melProfile: [1, 0, 0, 0], energy: 0.6)
        let stranger = makeAnalysis(bpm: 172, keyPitchClass: 6, keyConfidence: 0.9,
                                    melProfile: [-1, 0, 0, 0], energy: 0.05)

        let crossfade = QueueOrderScorer.score(
            outgoing: a, incoming: twin, planned: planned(.crossfade))
        let beatMatched = QueueOrderScorer.score(
            outgoing: a, incoming: stranger, planned: planned(.beatMatched))

        #expect(crossfade.tier == .crossfade)
        #expect(beatMatched.tier == .beatMatched)
        #expect(beatMatched.total > crossfade.total)
    }

    @Test func everyTierStepBeatsAPerfectScoreInTheTierBelow() {
        // Stated as a property over the whole ladder rather than one pair: the
        // four weights sum to 4 and the spacing is 10, so no arrangement of
        // continuity terms can reach the next rung.
        let a = makeAnalysis()
        let b = makeAnalysis()
        let ordered = TransitionTier.allCases.sorted()
        for (lower, upper) in zip(ordered, ordered.dropFirst()) {
            let best = QueueOrderScorer.score(outgoing: a, incoming: b, planned: planned(lower))
            let worst = QueueOrderScorer.score(outgoing: nil, incoming: nil,
                                               planned: planned(upper))
            #expect(worst.total > best.total,
                    "\(upper.label) must outrank \(lower.label) regardless of continuity")
        }
    }

    @Test func aRampedBeatMatchOutranksASteppedOne() {
        let a = makeAnalysis()
        let stepped = QueueOrderScorer.score(outgoing: a, incoming: a,
                                             planned: planned(.beatMatched))
        let ramped = QueueOrderScorer.score(outgoing: a, incoming: a,
                                            planned: planned(.rampedBeatMatched))
        #expect(ramped.total > stepped.total)
    }

    // MARK: - Aging

    @Test func agingIsUnboundedSoNothingStarves() {
        // A track that can only ever be crossfaded, losing to a beat-matchable
        // one over and over. The whole no-starvation claim is that this
        // eventually stops being true — so find the round where it does.
        let a = makeAnalysis()
        let winnerScore = QueueOrderScorer.score(outgoing: a, incoming: a,
                                                 planned: planned(.rampedBeatMatched))
        var rounds = 0
        var loser = QueueOrderScorer.score(outgoing: a, incoming: a,
                                           planned: planned(.crossfade))
        while loser.total <= winnerScore.total {
            rounds += 1
            #expect(rounds < 1000, "aging never overtook the better tier")
            loser = QueueOrderScorer.score(outgoing: a, incoming: a,
                                           planned: planned(.crossfade),
                                           lostRounds: rounds)
        }
        // Three tiers apart at the shipped ε — a bounded number of songs, not
        // a bounded *fraction*, which is what "no starvation" has to mean.
        #expect(rounds > 0)
        #expect(rounds < 200)
    }

    @Test func agingOnlyMovesWithTheRoundsLost() {
        let a = makeAnalysis()
        let fresh = QueueOrderScorer.score(outgoing: a, incoming: a,
                                           planned: planned(.crossfade))
        let aged = QueueOrderScorer.score(outgoing: a, incoming: a,
                                          planned: planned(.crossfade), lostRounds: 4)
        #expect(fresh.aging == 0)
        #expect(abs(aged.aging - 4 * QueueOrderConfig.standard.agingEpsilon) < 1e-9)
        #expect(abs((aged.total - fresh.total) - aged.aging) < 1e-9)
    }

    // MARK: - Same-artist penalty

    @Test func theSameArtistPenaltyIsSubtractedAndCanBeTurnedOff() {
        let a = makeAnalysis()
        let plain = QueueOrderScorer.score(outgoing: a, incoming: a,
                                           planned: planned(.crossfade))
        let penalised = QueueOrderScorer.score(outgoing: a, incoming: a,
                                               planned: planned(.crossfade),
                                               sharesArtist: true)
        #expect(penalised.sameArtistPenalty == -QueueOrderConfig.standard.sameArtistPenalty)
        #expect(abs((plain.total - penalised.total)
                    - QueueOrderConfig.standard.sameArtistPenalty) < 1e-9)

        var off = QueueOrderConfig.standard
        off.sameArtistPenalty = 0
        let unpenalised = QueueOrderScorer.score(outgoing: a, incoming: a,
                                                 planned: planned(.crossfade),
                                                 sharesArtist: true, config: off)
        #expect(unpenalised.sameArtistPenalty == 0)
    }

    @Test func sharingAnArtistIsWhatTripsThePenaltyAndIdZeroIsNotAnArtist() {
        #expect(QueueOrderSelector.sharesArtist(track(1, artist: 7), track(2, artist: 7)))
        #expect(!QueueOrderSelector.sharesArtist(track(1, artist: 7), track(2, artist: 8)))
        // 0 is the decoder's "unknown", not an artist two tracks have in common.
        #expect(!QueueOrderSelector.sharesArtist(track(1, artist: 0), track(2, artist: 0)))
        #expect(!QueueOrderSelector.sharesArtist(nil, track(2, artist: 7)))
    }

    // MARK: - Continuity terms

    @Test func continuityTermsAbstainAtTheNeutralHalfRatherThanGuessing() {
        // Every term has an "I cannot tell" answer, and it has to be 0.5 —
        // neither a bonus nor a penalty — or an unanalyzable track would be
        // systematically preferred or systematically buried.
        let noTempo = makeAnalysis(bpmConfidence: 0.1)
        #expect(QueueOrderScorer.tempoAffinity(noTempo, noTempo) == 0.5)
        let noKey = makeAnalysis(keyConfidence: 0)
        #expect(QueueOrderScorer.keyAffinity(noKey, noKey) == 0.5)
        let noStyle = makeAnalysis(melProfile: [])
        #expect(QueueOrderScorer.styleAffinity(noStyle, noStyle) == 0.5)
    }

    @Test func tempoAffinityFoldsDoubleTimeTheWayThePlannerDoes() {
        let slow = makeAnalysis(bpm: 85)
        let double = makeAnalysis(bpm: 170)
        let awkward = makeAnalysis(bpm: 97)
        #expect(QueueOrderScorer.tempoAffinity(slow, double) == 1)
        #expect(QueueOrderScorer.tempoAffinity(slow, awkward) < 0.5)
    }

    @Test func keyAffinityIsWeightedByTheWeakerConfidence() {
        let c = makeAnalysis(keyPitchClass: 0, keyConfidence: 0.9)
        let sameKey = makeAnalysis(keyPitchClass: 0, keyConfidence: 0.9)
        let tritone = makeAnalysis(keyPitchClass: 6, keyConfidence: 0.9)
        #expect(QueueOrderScorer.keyAffinity(c, sameKey) > 0.9)
        #expect(QueueOrderScorer.keyAffinity(c, tritone) < 0.1)
        // A guess pulls its own verdict back toward the neutral half.
        let unsure = makeAnalysis(keyPitchClass: 6, keyConfidence: 0.65)
        let confident = QueueOrderScorer.keyAffinity(c, tritone)
        let hedged = QueueOrderScorer.keyAffinity(c, unsure)
        #expect(hedged > confident)
        #expect(hedged < 0.5)
    }

    @Test func aHardEnergyDropCostsMoreThanTheSameSizedRise() {
        let mid = makeAnalysis(energy: 0.5)
        let quiet = makeAnalysis(energy: 0.2)
        let loud = makeAnalysis(energy: 0.8)
        let drop = QueueOrderScorer.energyContinuity(mid, quiet)
        let rise = QueueOrderScorer.energyContinuity(mid, loud)
        let flat = QueueOrderScorer.energyContinuity(mid, makeAnalysis(energy: 0.5))
        #expect(flat == 1)
        #expect(rise > drop)
        #expect(drop < 1)
    }

    // MARK: - Tier derivation

    @Test func theTierIsReadOffThePlanNeverReDecided() {
        #expect(TransitionTier(planned(.gapless)) == .gapless)
        #expect(TransitionTier(planned(.crossfade)) == .crossfade)
        #expect(TransitionTier(planned(.stagedCrossfade)) == .stagedCrossfade)
        #expect(TransitionTier(planned(.beatMatched)) == .beatMatched)
        #expect(TransitionTier(planned(.rampedBeatMatched)) == .rampedBeatMatched)
        #expect(TransitionTier(planned(.beatMatched)).isBeatMatched)
        #expect(!TransitionTier(planned(.stagedCrossfade)).isBeatMatched)
    }

    // MARK: - Pool bookkeeping

    @MainActor
    @Test func thePoolIsEverythingAlreadyAnalyzedInListOrder() {
        let selector = QueueOrderSelector()
        let remaining = (1...6).map { track($0) }
        // Cold: nothing is free, so the pool is empty and the escalation below
        // is the only way to fill it.
        #expect(selector.pool(remaining: remaining).isEmpty)

        // Anything with an analysis in hand joins for free, wherever it sits —
        // and the pool stays in list order, which is what the pick's tie-break
        // reads.
        selector.injectAnalysisForTesting(makeAnalysis(), forTrackID: 5)
        selector.injectAnalysisForTesting(makeAnalysis(), forTrackID: 2)
        #expect(selector.pool(remaining: remaining).map(\.id) == [2, 5])

        // An analysis for a track that is no longer in the queue is simply not
        // in the pool — no bookkeeping needed.
        #expect(selector.pool(remaining: [track(1), track(5)]).map(\.id) == [5])
    }

    // MARK: - Satisficing escalation (predev §2.2)

    /// A selector whose pool already satisfies, seen through `pick`: an
    /// outgoing and an incoming analysis that the *planner* will beat-match.
    /// The escalation's stop condition reads the tier off a real plan, so the
    /// fixtures have to be plannable rather than stated.
    @MainActor
    private func beatMatchableSelector() -> (QueueOrderSelector, TrackAnalysis) {
        let selector = QueueOrderSelector()
        return (selector, makeAnalysis(bpm: 120, keyPitchClass: 0, keyConfidence: 0.9,
                                       melProfile: [1, 0, 0, 0], energy: 0.6))
    }

    @MainActor
    @Test func aPoolThatAlreadySatisfiesCostsNothing() {
        let (selector, outgoing) = beatMatchableSelector()
        let remaining = (1...20).map { track($0) }
        // Track 7 is a twin of what is playing: same tempo, same key, same
        // energy — the planner beat-matches it.
        selector.injectAnalysisForTesting(outgoing, forTrackID: 7)

        let pool = selector.pool(remaining: remaining)
        let winner = selector.pick(outgoing: nil, outgoingAnalysis: outgoing, pool: pool)
        #expect(winner?.id == 7)
        #expect(selector.lastPickSatisfies)
        // Zero rounds, zero downloads: the whole point of satisficing.
        #expect(selector.rounds == 0)
        #expect(selector.downloadsThisPick == 0)
        #expect(selector.frontier(remaining: remaining).isEmpty)
    }

    @MainActor
    @Test func aPoolThatDoesNotSatisfyIsNotMistakenForOne() {
        let (selector, outgoing) = beatMatchableSelector()
        // Far enough apart in tempo that the planner cannot lock the grids.
        selector.injectAnalysisForTesting(
            makeAnalysis(bpm: 155, keyPitchClass: 6, keyConfidence: 0.9,
                         melProfile: [-1, 0, 0, 0], energy: 0.1),
            forTrackID: 3)
        let remaining = (1...20).map { track($0) }
        _ = selector.pick(outgoing: nil, outgoingAnalysis: outgoing,
                          pool: selector.pool(remaining: remaining))
        #expect(!selector.lastPickSatisfies)
        // A pick with nothing scored at all cannot satisfy either.
        let empty = QueueOrderSelector()
        _ = empty.pick(outgoing: nil, outgoingAnalysis: outgoing, pool: [])
        #expect(!empty.lastPickSatisfies)
    }

    @MainActor
    @Test func theRoundsAreOneThenFourThenSixteenInListOrder() {
        let selector = QueueOrderSelector()
        let remaining = (1...40).map { track($0) }
        // No network in a test: `acquire` is driven with downloads forbidden,
        // which is exactly the politeness path — it opens rounds and reports
        // `.deferred` rather than fetching, so the ladder is observable
        // without a single byte.
        #expect(selector.escalateForTesting(remaining: remaining))
        #expect(selector.frontier(remaining: remaining).map(\.id) == [1])
        #expect(selector.rounds == 1)

        #expect(selector.escalateForTesting(remaining: remaining))
        #expect(selector.frontier(remaining: remaining).map(\.id) == Array(1...5))
        #expect(selector.rounds == 2)

        #expect(selector.escalateForTesting(remaining: remaining))
        #expect(selector.frontier(remaining: remaining).map(\.id) == Array(1...21))
        #expect(selector.rounds == 3)

        // Bounded by the remaining queue: the fourth round takes what is left
        // and the fifth has nothing to admit.
        #expect(selector.escalateForTesting(remaining: remaining))
        #expect(selector.frontier(remaining: remaining).count == 40)
        #expect(!selector.escalateForTesting(remaining: remaining))
    }

    @MainActor
    @Test func aRoundOnlySpendsItselfOnTracksItActuallyHasToBuy() {
        let selector = QueueOrderSelector()
        let remaining = (1...20).map { track($0) }
        // Tracks 1–3 are already analyzed (a previous session paid for them)
        // and track 4 was refused. A round of one must reach past all four
        // rather than spend itself on a track that costs nothing.
        for id in 1...3 { selector.injectAnalysisForTesting(makeAnalysis(), forTrackID: id) }
        selector.injectRefusalForTesting(trackID: 4)

        #expect(selector.escalateForTesting(remaining: remaining))
        #expect(selector.frontier(remaining: remaining).map(\.id) == [5])
        #expect(selector.escalateForTesting(remaining: remaining))
        #expect(selector.frontier(remaining: remaining).map(\.id) == [5, 6, 7, 8, 9])
    }

    @MainActor
    @Test func satisfactionStopsTheRoundHalfWayThrough() {
        let (selector, outgoing) = beatMatchableSelector()
        let remaining = (1...20).map { track($0) }
        // Open the 1 and the 4: five tracks admitted, none resolved.
        #expect(selector.escalateForTesting(remaining: remaining))
        #expect(selector.escalateForTesting(remaining: remaining))
        #expect(selector.frontier(remaining: remaining).count == 5)

        // The second track of the round of four comes back beat-matchable.
        selector.injectAnalysisForTesting(makeAnalysis(bpm: 155), forTrackID: 1)
        selector.injectAnalysisForTesting(outgoing, forTrackID: 3)
        _ = selector.pick(outgoing: nil, outgoingAnalysis: outgoing,
                          pool: selector.pool(remaining: remaining))
        #expect(selector.lastPickSatisfies)

        // Three of the five admitted tracks are still unresolved. The caller
        // stops here — it never asks `acquire` again — so they are never
        // bought. The round does not have to finish for the pick to be made.
        #expect(selector.frontier(remaining: remaining)
                    .filter { !selector.hasAnalysis(for: $0) }.map(\.id) == [2, 4, 5])
        #expect(selector.rounds == 2)
    }

    @MainActor
    @Test func theEscalationIsBoundedByTheQueueAndThenReportsExhausted() {
        let selector = QueueOrderSelector()
        let remaining = [track(1), track(2)]
        // Both already resolved, so there is nothing left to admit at all and
        // the very first tick says so — which is the caller's cue to pick the
        // best it has rather than wait for the deadline.
        selector.injectAnalysisForTesting(makeAnalysis(), forTrackID: 1)
        selector.injectRefusalForTesting(trackID: 2)
        #expect(selector.acquire(remaining: remaining, mayDownload: true) == .exhausted)
    }

    @MainActor
    @Test func theDeadlineStillTakesTheBestAnalyzedCandidateOrNothing() {
        // The deadline path is the one thing the escalation does not touch: it
        // never consults the satisfying tier, it takes `pick`'s answer — the
        // best analyzed candidate, or nil, which leaves the user's list order
        // alone rather than holding up a hand-over for a download.
        let (selector, outgoing) = beatMatchableSelector()
        let remaining = (1...6).map { track($0) }
        #expect(selector.pick(outgoing: nil, outgoingAnalysis: outgoing,
                              pool: selector.pool(remaining: remaining)) == nil)

        // Two candidates that cannot be beat-matched: nothing satisfies, and
        // the deadline takes the better of them anyway.
        selector.injectAnalysisForTesting(
            makeAnalysis(bpm: 155, keyPitchClass: 6, keyConfidence: 0.9,
                         melProfile: [-1, 0, 0, 0], energy: 0.05),
            forTrackID: 4)
        selector.injectAnalysisForTesting(
            makeAnalysis(bpm: 151, keyPitchClass: 0, keyConfidence: 0.9,
                         melProfile: [1, 0, 0, 0], energy: 0.6),
            forTrackID: 2)
        let winner = selector.pick(outgoing: nil, outgoingAnalysis: outgoing,
                                   pool: selector.pool(remaining: remaining))
        #expect(!selector.lastPickSatisfies)
        #expect(winner?.id == 2)
    }

    @MainActor
    @Test func theEscalationStandsAsideWhileThePlaybackDownloadRuns() {
        let selector = QueueOrderSelector()
        let remaining = (1...8).map { track($0) }
        selector.markScannedForTesting(remaining)
        // Impolite moment: a round opens (the bookkeeping is free) but no
        // transfer starts, and the tick says why.
        #expect(selector.acquire(remaining: remaining, mayDownload: false) == .deferred)
        #expect(selector.rounds == 1)
        #expect(selector.downloadsThisPick == 0)
        // Asking again while still impolite does not open a second round: the
        // frontier is unresolved, so there is nothing to escalate past.
        #expect(selector.acquire(remaining: remaining, mayDownload: false) == .deferred)
        #expect(selector.rounds == 1)
    }

    // MARK: - Per-pick download budget

    @MainActor
    @Test func aPickThatHasSpentItsBudgetStopsBuyingAndSaysSo() {
        let selector = QueueOrderSelector()
        selector.config.maxDownloadsPerPick = 3
        let remaining = (1...40).map { track($0) }
        selector.markScannedForTesting(remaining)

        // Under budget: the ladder runs as usual.
        #expect(selector.acquire(remaining: remaining, mayDownload: false) == .deferred)
        selector.markDownloadsForTesting(2)
        #expect(selector.acquire(remaining: remaining, mayDownload: false) == .deferred)

        // At the cap: `.spent`, which is the caller's cue to commit the best it
        // has. Distinct from `.exhausted` on purpose — the queue still has 39
        // unresolved tracks, they are simply not this pick's to buy.
        selector.markDownloadsForTesting(3)
        #expect(selector.acquire(remaining: remaining, mayDownload: true) == .spent)
        // And no further round is opened: admitting tracks it cannot buy would
        // only make the frontier lie.
        let roundsAtCap = selector.rounds
        #expect(selector.acquire(remaining: remaining, mayDownload: true) == .spent)
        #expect(selector.rounds == roundsAtCap)
    }

    @MainActor
    @Test func theBudgetBitesMidRoundNotAtARoundBoundary() {
        let selector = QueueOrderSelector()
        selector.config.maxDownloadsPerPick = 3
        let remaining = (1...40).map { track($0) }
        selector.markScannedForTesting(remaining)
        // Round 1 (one track) and round 2 (four) are open: five admitted, so
        // the cap of three falls in the middle of the second round.
        selector.escalateForTesting(remaining: remaining)
        selector.escalateForTesting(remaining: remaining)
        #expect(selector.frontier(remaining: remaining).count == 5)

        selector.markDownloadsForTesting(3)
        #expect(selector.acquire(remaining: remaining, mayDownload: true) == .spent)
        // Two of the round's tracks stay unbought — and they stay *unresolved*,
        // which is what lets the next pick escalate into them from a pool this
        // one made richer. The warming is spread, not lost.
        #expect(selector.frontier(remaining: remaining)
                    .filter { !selector.hasAnalysis(for: $0) }.count == 5)
        selector.beginPick()
        #expect(selector.downloadsThisPick == 0)
        #expect(selector.acquire(remaining: remaining, mayDownload: false) == .deferred)
        #expect(selector.rounds == 1)
    }

    @Test func theBudgetIsSweepableAndCannotBeSetToZero() {
        #expect(QueueOrderConfig.standard.maxDownloadsPerPick == 24)
        let moved = QueueOrderConfig.standard(overriding: ["maxDownloadsPerPick": 60])
        #expect(moved.maxDownloadsPerPick == 60)
        // A budget of zero would be a mode that can never buy anything; the
        // field's own floor rules it out.
        #expect(QueueOrderConfig.standard(
            overriding: ["maxDownloadsPerPick": 0]).maxDownloadsPerPick == 1)
    }

    // MARK: - Lookahead chain

    @MainActor
    @Test func theChainIsPureAndNeverAgesAnything() {
        let selector = QueueOrderSelector()
        let head = track(1)
        let remaining = (2...6).map { track($0) }
        for t in [head] + remaining {
            selector.injectAnalysisForTesting(makeAnalysis(), forTrackID: t.id)
        }
        // Give the real counters a shape worth protecting.
        selector.noteRound(chosen: track(2), pool: remaining)
        let before = remaining.map { selector.lostRoundsForTesting($0.id) }
        let pickBefore = selector.lastPick

        selector.recomputeLookahead(head: head, remaining: remaining)
        #expect(!selector.lookahead.isEmpty)

        // The chain ages its own private copy of the counters, so a preview
        // cannot change the future it is previewing.
        #expect(remaining.map { selector.lostRoundsForTesting($0.id) } == before)
        #expect(selector.lastPick == pickBefore)
        // Idempotent: running it twice gives the same answer, which it would
        // not if it were leaving a mark.
        let first = selector.lookahead
        selector.recomputeLookahead(head: head, remaining: remaining)
        #expect(selector.lookahead == first)
    }

    @MainActor
    @Test func theChainVisitsEachTrackOnceAndStopsAtTheConfiguredDepth() {
        let selector = QueueOrderSelector()
        selector.config.lookaheadDepth = 3
        let head = track(1)
        let remaining = (2...9).map { track($0) }
        for t in [head] + remaining {
            selector.injectAnalysisForTesting(makeAnalysis(), forTrackID: t.id)
        }
        selector.recomputeLookahead(head: head, remaining: remaining)
        #expect(selector.lookahead.count == 3)
        // The chain's own aging is what keeps it from proposing one track over
        // and over: each step drops its winner from the pool.
        let ids = selector.lookahead.map(\.track.id)
        #expect(Set(ids).count == ids.count)
        #expect(!ids.contains(head.id))

        // Depth 0 turns it off outright.
        selector.config.lookaheadDepth = 0
        selector.recomputeLookahead(head: head, remaining: remaining)
        #expect(selector.lookahead.isEmpty)
    }

    @MainActor
    @Test func theChainOnlyEverPlansWithAnalysesItAlreadyHas() {
        let selector = QueueOrderSelector()
        let head = track(1)
        let remaining = (2...9).map { track($0) }
        // Nothing analyzed: no chain at all, rather than a chain of guesses.
        selector.recomputeLookahead(head: head, remaining: remaining)
        #expect(selector.lookahead.isEmpty)

        // The pool grows by two, and the chain grows with it — this is the
        // "recompute when the pool grows" contract, stated as an assertion
        // about the answer rather than about the plumbing.
        selector.injectAnalysisForTesting(makeAnalysis(), forTrackID: 1)
        selector.injectAnalysisForTesting(makeAnalysis(), forTrackID: 4)
        selector.recomputeLookahead(head: head, remaining: remaining)
        #expect(selector.lookahead.map(\.track.id) == [4])

        selector.injectAnalysisForTesting(makeAnalysis(), forTrackID: 7)
        selector.recomputeLookahead(head: head, remaining: remaining)
        #expect(selector.lookahead.map(\.track.id) == [4, 7])

        // A queue edit is the same story: re-derived from what it is handed.
        selector.recomputeLookahead(head: head, remaining: remaining.filter { $0.id != 4 })
        #expect(selector.lookahead.map(\.track.id) == [7])
    }

    @MainActor
    @Test func aQueueEditIsHandledByReDerivingNotByFixingUpIndices() {
        let selector = QueueOrderSelector()
        var remaining = (1...20).map { track($0) }
        selector.escalateForTesting(remaining: remaining)
        selector.escalateForTesting(remaining: remaining)
        #expect(selector.frontier(remaining: remaining).map(\.id) == Array(1...5))

        // The user removes two admitted tracks and inserts a new one at the
        // head. The frontier is the admitted set intersected with the queue as
        // it is *now*: the departed tracks are gone, and the newcomer is not
        // admitted until a round reaches it.
        remaining = [track(99)] + remaining.filter { $0.id != 2 && $0.id != 4 }
        #expect(selector.frontier(remaining: remaining).map(\.id) == [1, 3, 5])

        // The next round admits the newcomer along with the rest of the list,
        // in the order the list has now — no index anywhere survived the edit.
        selector.escalateForTesting(remaining: remaining)
        #expect(selector.frontier(remaining: remaining).map(\.id)
                == [99, 1, 3, 5] + Array(6...20))

        // A pick that lands on a departed track is impossible: the pool is
        // derived from `remaining` too.
        selector.injectAnalysisForTesting(makeAnalysis(), forTrackID: 2)
        #expect(!selector.pool(remaining: remaining).contains { $0.id == 2 })
    }

    @MainActor
    @Test func aNewTrackRestartsTheEscalationButKeepsWhatItPaidFor() {
        let selector = QueueOrderSelector()
        let remaining = (1...20).map { track($0) }
        selector.escalateForTesting(remaining: remaining)
        selector.injectAnalysisForTesting(makeAnalysis(), forTrackID: 1)
        #expect(selector.rounds == 1)

        selector.beginPick()
        #expect(selector.rounds == 0)
        #expect(selector.downloadsThisPick == 0)
        #expect(selector.frontier(remaining: remaining).isEmpty)
        // The sidecar it bought is the whole reason the next pick is cheaper.
        #expect(selector.pool(remaining: remaining).map(\.id) == [1])
    }

    @MainActor
    @Test func aPoolIsSettledOnlyOnceEveryCandidateHasBeenResolved() {
        let selector = QueueOrderSelector()
        let pool = [track(1), track(2)]
        #expect(!selector.isSettled(pool))
        selector.injectAnalysisForTesting(makeAnalysis(), forTrackID: 1)
        #expect(!selector.isSettled(pool))
        selector.injectRefusalForTesting(trackID: 2)
        #expect(selector.isSettled(pool))
    }

    @MainActor
    @Test func onlyThePoolAgesAndTheWinnerIsForgiven() {
        let selector = QueueOrderSelector()
        let one = track(1), two = track(2), three = track(3)
        for t in [one, two, three] {
            selector.injectAnalysisForTesting(makeAnalysis(), forTrackID: t.id)
        }
        selector.noteRound(chosen: one, pool: [one, two, three])
        selector.noteRound(chosen: two, pool: [two, three])

        // Track 3 lost twice; track 1 was never in the second pool, so it did
        // not age for a round it was not offered.
        #expect(selector.lostRoundsForTesting(three.id) == 2)
        #expect(selector.lostRoundsForTesting(one.id) == 0)
        // A winner starts clean again.
        #expect(selector.lostRoundsForTesting(two.id) == 0)
    }

    @MainActor
    @Test func aPickOnlyEverConsidersAnalyzedCandidatesAndTiesBreakOnListOrder() {
        let selector = QueueOrderSelector()
        let outgoing = makeAnalysis()
        let pool = [track(1), track(2), track(3)]
        // Nothing analyzed: nil, which is the caller's cue to leave the list
        // order alone rather than wait for a download.
        #expect(selector.pick(outgoing: nil, outgoingAnalysis: outgoing, pool: pool) == nil)

        // Two identical candidates: the earlier one in the pool wins, so a
        // pool the scorer cannot tell apart reproduces the user's list.
        selector.injectAnalysisForTesting(makeAnalysis(), forTrackID: 2)
        selector.injectAnalysisForTesting(makeAnalysis(), forTrackID: 3)
        let winner = selector.pick(outgoing: nil, outgoingAnalysis: outgoing, pool: pool)
        #expect(winner?.id == 2)
        #expect(selector.lastPick.map(\.track.id) == [2, 3])
    }

    @MainActor
    @Test func resettingKeepsAnalysesAndDropsEverythingAboutTheOldQueue() {
        let selector = QueueOrderSelector()
        let one = track(1), two = track(2)
        selector.injectAnalysisForTesting(makeAnalysis(), forTrackID: 1)
        selector.injectRefusalForTesting(trackID: 2)
        selector.noteRound(chosen: one, pool: [one, two])
        #expect(selector.lostRoundsForTesting(two.id) == 1)

        selector.reset()
        // The analysis is on disk anyway; forgetting it would buy nothing and
        // cost a re-download.
        #expect(selector.hasAnalysis(for: one))
        #expect(selector.lostRoundsForTesting(two.id) == 0)
        // A refusal described a queue that no longer exists.
        #expect(!selector.isSettled([two]))
        #expect(selector.lastPick.isEmpty)
    }

    // MARK: - Chain cost and concurrency

    @MainActor
    @Test func theChainComputesTheSameAnswerOffTheMainActorAsOn() async {
        // The production path splits the chain into snapshot → pure compute →
        // apply so the middle can run on a detached task. That split is only
        // safe if it is an identity, so: build the input, run the pure function
        // *off* the main actor, and check it against the synchronous wrapper.
        let selector = QueueOrderSelector()
        selector.config.lookaheadDepth = 5
        let head = track(1, artist: 7)
        let remaining = (2...12).map { track($0, artist: $0 % 3 == 0 ? 7 : $0) }
        for t in [head] + remaining {
            selector.injectAnalysisForTesting(
                makeAnalysis(bpm: 110 + Double(t.id), keyPitchClass: t.id % 12,
                             keyConfidence: 0.8, melProfile: [Float(t.id), 1, 0, 0],
                             energy: Float(t.id % 5) / 5),
                forTrackID: t.id)
        }
        let input = selector.chainInput(head: head, remaining: remaining,
                                        plannerConfig: .standard)
        let offMain = await Task.detached(priority: .utility) {
            QueueOrderSelector.chain(input, depth: 5)
        }.value

        selector.recomputeLookahead(head: head, remaining: remaining)
        #expect(selector.lookahead.map(\.track.id) == offMain.map(\.id))
        #expect(selector.lookahead.map(\.score) == offMain.map(\.score))
        #expect(!offMain.isEmpty)
        // The same-artist penalty survives the crossing: the snapshot carries
        // artist IDs rather than tracks, and this is what proves it.
        #expect(input.artistIDs[head.id] == [7])
        #expect(input.artistIDs[6] == [7])
    }

    @MainActor
    @Test func applyingAChainDropsStepsThatHaveLeftTheQueue() {
        // The compute runs while the user can still edit the queue, so the
        // answer may name tracks that are gone by the time it lands. They are
        // dropped, not repaired — the chain is provisional and showing a track
        // that is no longer queued would be a lie.
        let selector = QueueOrderSelector()
        let head = track(1)
        let remaining = (2...6).map { track($0) }
        for t in [head] + remaining {
            selector.injectAnalysisForTesting(makeAnalysis(), forTrackID: t.id)
        }
        let results = [3, 4, 5].map {
            QueueOrderSelector.ChainResult(id: $0, score: QueueOrderScore())
        }
        selector.applyLookahead(results, remaining: remaining.filter { $0.id != 4 })
        #expect(selector.lookahead.map(\.track.id) == [3, 5])

        // Nothing left at all is an empty chain, not a stale one.
        selector.applyLookahead(results, remaining: [])
        #expect(selector.lookahead.isEmpty)
    }

    @MainActor
    @Test func aChainInputCarriesOnlyWhatTheChainCanUse() {
        let selector = QueueOrderSelector()
        let head = track(1)
        let remaining = (2...9).map { track($0) }
        selector.injectAnalysisForTesting(makeAnalysis(), forTrackID: 1)
        selector.injectAnalysisForTesting(makeAnalysis(), forTrackID: 4)
        selector.injectAnalysisForTesting(makeAnalysis(), forTrackID: 7)
        // An analysis for a track outside this queue entirely — the pool is
        // cumulative across sessions, so this is the normal case.
        selector.injectAnalysisForTesting(makeAnalysis(), forTrackID: 999)

        let input = selector.chainInput(head: head, remaining: remaining,
                                        plannerConfig: .standard)
        // Only analyzed candidates, in list order; the head is not a candidate
        // for its own chain.
        #expect(input.poolIDs == [4, 7])
        #expect(input.headID == 1)
        // The analyses dictionary is the snapshot that crosses to another
        // thread, so it carries the head and the pool and nothing else.
        #expect(Set(input.analyses.keys) == [1, 4, 7])
    }

    @Test func theChainRefreshIsThrottledExceptWhenItsHeadChanges() {
        let allowed = PlayerService.lookaheadRefreshAllowed
        let interval = PlayerService.lookaheadRefreshInterval

        // A landing analysis just after another one: skipped. During an
        // escalation these arrive every few seconds, and a pool one track
        // richer does not meaningfully change an eight-step preview.
        #expect(!allowed(false, false, 0))
        #expect(!allowed(false, false, interval - 0.01))
        #expect(allowed(false, false, interval))

        // A commit is the moment the chain's head changes, so it never waits.
        #expect(allowed(true, false, 0))

        // Never two at once — a second computation would only race the first.
        #expect(!allowed(false, true, interval * 10))
        // Except a forced one, which supersedes rather than races: the running
        // task's generation is stale by then and it drops its own answer.
        #expect(allowed(true, true, 0))
    }

    // MARK: - Splicing the plan into the working list

    @Test func splicingBuildsTheWholeQueueOnceAndSaysWhenItWouldChangeNothing() {
        let queue = (0...9).map { track($0) }
        // Current track is index 0, so the plan lands at 1.
        let moved = PlayerService.queueSplicingPlan(queue, at: 1, plan: [track(5), track(3)])
        #expect(moved?.map(\.id) == [0, 5, 3, 1, 2, 4, 6, 7, 8, 9])
        // A permutation: nothing gained, nothing lost, and the current track
        // never moves.
        #expect(Set(moved!.map(\.id)) == Set(queue.map(\.id)))
        #expect(moved?.count == queue.count)
        #expect(moved?.first?.id == 0)

        // **Nil is the point.** Re-splicing the same plan onto the result must
        // not publish: `autoMixQueue` is `@Published` and the queue view is
        // hundreds of rows, so a no-op assignment costs a full SwiftUI diff.
        #expect(PlayerService.queueSplicingPlan(moved!, at: 1,
                                                plan: [track(5), track(3)]) == nil)
        // Same for a plan that is already in place at the head of the tail.
        #expect(PlayerService.queueSplicingPlan(queue, at: 1,
                                                plan: [track(1), track(2)]) == nil)
    }

    @Test func splicingIgnoresTracksThatAreNotAheadOfThePlayhead() {
        let queue = (0...5).map { track($0) }
        // Track 0 is behind the playhead at target 3, and 99 is not in the
        // queue at all: both are simply not part of the plan. A chain step
        // whose track has left the queue can therefore never reorder anything.
        #expect(PlayerService.queueSplicingPlan(
            queue, at: 3, plan: [track(0), track(99), track(5)])?.map(\.id)
            == [0, 1, 2, 5, 3, 4])
        // A plan with nothing usable in it does not publish.
        #expect(PlayerService.queueSplicingPlan(
            queue, at: 3, plan: [track(0), track(99)]) == nil)
        #expect(PlayerService.queueSplicingPlan(queue, at: 3, plan: []) == nil)
        // Out-of-range targets are refused rather than trapping.
        #expect(PlayerService.queueSplicingPlan(queue, at: 99, plan: [track(5)]) == nil)
        #expect(PlayerService.queueSplicingPlan(queue, at: -1, plan: [track(5)]) == nil)
        // A duplicate in the plan is placed once.
        #expect(PlayerService.queueSplicingPlan(
            queue, at: 1, plan: [track(4), track(4)])?.map(\.id) == [0, 4, 1, 2, 3, 5])
    }

    // MARK: - Stem pre-render runway

    @Test func theRunwayEstimateScalesWithTheSeamRatherThanBeingOneFlatNumber() {
        // Separation is ~1× realtime per side and a segment wants both, plus a
        // margin: a 16 s overlap needs 47 s. The point of the estimate is that
        // 49 s of runway is *enough* for it — under the old flat 60 s lead that
        // seam was refused, and the stem gesture silently became a whole-mix
        // crossfade.
        #expect(PlayerService.stemPrerenderRunway(overlapDuration: 16) == 47)
        #expect(PlayerService.stemPrerenderRunway(overlapDuration: 16) < 49)
        // The nominal seam the flat lead was sized for still fits inside it, so
        // the ordinary path is unchanged.
        #expect(PlayerService.stemPrerenderRunway(overlapDuration: 15) == 45)
        #expect(PlayerService.stemPrerenderRunway(overlapDuration: 15) <= 60)
        // A long overlap costs more than the lead can offer, and is refused up
        // front rather than started and abandoned at the guard.
        #expect(PlayerService.stemPrerenderRunway(overlapDuration: 30) == 75)
        #expect(PlayerService.stemPrerenderRunway(overlapDuration: 30) > 60)
        // Monotone, and never negative for a degenerate plan.
        #expect(PlayerService.stemPrerenderRunway(overlapDuration: 8)
                < PlayerService.stemPrerenderRunway(overlapDuration: 9))
        #expect(PlayerService.stemPrerenderRunway(overlapDuration: 0) == 15)
        #expect(PlayerService.stemPrerenderRunway(overlapDuration: -5) == 15)
    }

    // MARK: - Migration

    @Test func aSessionWrittenBeforeTheModeExistedMigratesFromItsShuffleBool() {
        // No `queueOrder` key at all — the shape every state file on disk has
        // today.
        let legacyShuffling = PlayerService.PersistedState(
            queue: [], currentID: nil, repeatMode: "off", shuffle: true,
            recentContexts: nil, queueOrder: nil)
        let legacyListed = PlayerService.PersistedState(
            queue: [], currentID: nil, repeatMode: "off", shuffle: false,
            recentContexts: nil, queueOrder: nil)
        #expect(PlayerService.restoredQueueOrder(legacyShuffling) == .shuffled)
        #expect(PlayerService.restoredQueueOrder(legacyListed) == .listed)
        #expect(QueueOrder(migratingShuffle: true) == .shuffled)
        #expect(QueueOrder(migratingShuffle: false) == .listed)
    }

    @Test func anExplicitQueueOrderWinsOverTheLegacyBool() {
        // Both keys present and disagreeing: a build that wrote `autoMix` also
        // wrote `shuffle: false`, and a build that has since been downgraded
        // and re-upgraded must not lose the mode.
        let state = PlayerService.PersistedState(
            queue: [], currentID: nil, repeatMode: "off", shuffle: false,
            recentContexts: nil, queueOrder: "autoMix")
        #expect(PlayerService.restoredQueueOrder(state) == .autoMix)
    }

    @Test func anUnknownQueueOrderFallsBackToTheBoolRatherThanFailing() {
        let state = PlayerService.PersistedState(
            queue: [], currentID: nil, repeatMode: "off", shuffle: true,
            recentContexts: nil, queueOrder: "someFutureMode")
        #expect(PlayerService.restoredQueueOrder(state) == .shuffled)
    }

    // MARK: - The future term (predev §2.3 / §4's tail row)
    //
    // The term exists to be *measured*, and it ships off; what these assert is
    // that it cannot do damage while it is available — the current seam is
    // never sold for a better future, and the price is bounded.

    /// A pool of tracks whose planner outcome against `outgoing` is stated by
    /// construction: `matches` twins of the 120 BPM outgoing (beat-matchable)
    /// followed by `strangers` that nothing can lock to.
    private func futurePool(matches: Int, strangers: Int)
        -> (keys: [Int], analyses: [Int: TrackAnalysis], outgoing: TrackAnalysis) {
        let outgoing = makeAnalysis(bpm: 120, keyPitchClass: 0, keyConfidence: 0.9,
                                    melProfile: [1, 0, 0, 0], energy: 0.6)
        var analyses: [Int: TrackAnalysis] = [:]
        var keys: [Int] = []
        for i in 0..<matches {
            keys.append(i)
            analyses[i] = outgoing
        }
        for i in 0..<strangers {
            let id = matches + i
            keys.append(id)
            analyses[id] = makeAnalysis(bpm: 155 + Double(i), keyPitchClass: 6,
                                        keyConfidence: 0.9, melProfile: [-1, 0, 0, 0],
                                        energy: 0.1)
        }
        return (keys, analyses, outgoing)
    }

    @Test func theFutureTermIsOffUntilItIsAskedFor() {
        // The shipping default. The offline evaluation (predev §5.2) found no
        // tail improvement from either estimator, so the mode stays off and the
        // live pick is arithmetically identical to the one before it existed.
        #expect(QueueOrderConfig.standard.futureMode == .off)
        let pool = futurePool(matches: 2, strangers: 2)
        var ranked = pool.keys.map { key -> (key: Int, score: QueueOrderScore) in
            (key, QueueOrderScorer.score(outgoing: pool.outgoing,
                                         incoming: pool.analyses[key],
                                         planned: planned(.crossfade)))
        }
        let before = ranked.map(\.score)
        let evaluated = QueueOrderScorer.applyFuture(
            to: &ranked, analysis: { pool.analyses[$0] }, config: .standard)
        #expect(evaluated == 0)
        #expect(ranked.map(\.score) == before)
        #expect(ranked.allSatisfy { $0.score.futureRichness == 0 })
    }

    @Test func theFutureTermNeverSellsTheCurrentSeam() {
        // The dominance guarantee, stated at the weight's ceiling: a candidate
        // that satisfies with the emptiest possible future must still outrank
        // one that does not satisfy with the richest possible future.
        let ceiling = QueueOrderConfig.fields.first { $0.name == "futureWeight" }!.max
        var satisfying = QueueOrderScorer.score(outgoing: nil, incoming: nil,
                                                planned: planned(.beatMatched))
        var stranded = QueueOrderScorer.score(
            outgoing: makeAnalysis(), incoming: makeAnalysis(),
            planned: planned(.stagedCrossfade))
        satisfying.applyFuture(0, weight: ceiling)
        stranded.applyFuture(1, weight: ceiling)
        #expect(satisfying.total > stranded.total)
        // And the reason it holds: the bounded budget still sits under one
        // tier step. Four continuity weights of 1 each, plus the future's own.
        let c = QueueOrderConfig.standard
        #expect(c.tempoWeight + c.keyWeight + c.styleWeight + c.energyWeight + ceiling
                < c.tierSpacing)
    }

    @Test func theFutureTermCannotFlipASatisfyingWinnerBelowANonSatisfyingOne() {
        // The same guarantee end to end, through `applyFuture` on a real
        // ranked list: one beat-matchable candidate that leads nowhere, three
        // crossfade-only candidates that lead everywhere.
        let pool = futurePool(matches: 1, strangers: 3)
        var config = QueueOrderConfig.standard
        config.futureMode = .degree
        config.futureWeight = QueueOrderConfig.fields.first { $0.name == "futureWeight" }!.max
        var ranked = pool.keys.map { key -> (key: Int, score: QueueOrderScore) in
            let planned = TransitionPlanner.plan(
                outgoing: pool.outgoing, incoming: pool.analyses[key], stems: .none,
                config: .standard, context: .init(outgoingLyricLineEnds: []))
            return (key, QueueOrderScorer.score(outgoing: pool.outgoing,
                                                incoming: pool.analyses[key],
                                                planned: planned, config: config))
        }
        #expect(ranked[0].score.tier.isBeatMatched)
        #expect(ranked.dropFirst().allSatisfy { !$0.score.tier.isBeatMatched })
        QueueOrderScorer.applyFuture(to: &ranked, analysis: { pool.analyses[$0] },
                                     config: config)
        #expect(ranked.first?.key == 0)
        #expect(ranked.first?.score.tier.isBeatMatched == true)
    }

    @Test func onlyTheTopKCandidatesArePaidFor() {
        // The price of the term is `futureTopK` extra ranks and not one more —
        // this is what keeps a 200-track pool under the 50 ms tripwire.
        let pool = futurePool(matches: 6, strangers: 6)
        var config = QueueOrderConfig.standard
        config.futureMode = .degree
        config.futureWeight = 1
        config.futureTopK = 3
        var ranked = pool.keys.map { key -> (key: Int, score: QueueOrderScore) in
            (key, QueueOrderScorer.score(outgoing: pool.outgoing,
                                         incoming: pool.analyses[key],
                                         planned: planned(.beatMatched), config: config))
        }
        let evaluated = QueueOrderScorer.applyFuture(
            to: &ranked, analysis: { pool.analyses[$0] }, config: config)
        #expect(evaluated == 3)
        #expect(ranked.filter { $0.score.futureRichness > 0 }.count <= 3)
        // A K larger than the pool asks for the pool, not for an out-of-bounds
        // read — a swept preset must not be able to trap the pick.
        config.futureTopK = 999
        var short = Array(ranked.prefix(2))
        #expect(QueueOrderScorer.applyFuture(
            to: &short, analysis: { pool.analyses[$0] }, config: config) == 2)
    }

    @Test func theDegreeIsTheShareOfThePoolThisCandidateCouldHandOverTo() {
        // Two of the four others are twins of the candidate, so the candidate
        // reaches the satisfying tier with exactly half of them.
        let pool = futurePool(matches: 3, strangers: 2)
        let degree = QueueOrderScorer.futureDegree(
            candidate: 0, rest: pool.keys, analysis: { pool.analyses[$0] },
            config: .standard)
        #expect(abs(degree - 0.5) < 1e-9)
        // The candidate never counts itself, and a dead end reads 0.
        let deadEnd = futurePool(matches: 1, strangers: 3)
        #expect(QueueOrderScorer.futureDegree(
            candidate: 0, rest: deadEnd.keys, analysis: { deadEnd.analyses[$0] },
            config: .standard) == 0)
    }

    @Test func aFutureEvaluationNeverLooksAtMoreThanItsCap() {
        // The cap is the price gate. Above it the pool is sampled by a stride
        // — every entry distinct, spread across the whole list, deterministic.
        var config = QueueOrderConfig.standard
        config.futurePoolCap = 7
        let rest = Array(0..<100)
        let sample = QueueOrderScorer.futureSample(rest, config: config)
        #expect(sample.count == 7)
        #expect(Set(sample).count == 7)
        #expect(sample == QueueOrderScorer.futureSample(rest, config: config))
        #expect(sample.first == 0)
        #expect(sample.max()! < 100)
        // Below the cap nothing is dropped at all.
        #expect(QueueOrderScorer.futureSample(Array(0..<5), config: config) == Array(0..<5))
    }

    @Test func foldingAFutureReadingInIsIdempotentByReplacement() {
        // `applyFuture` is called on scores that may already carry a reading —
        // a re-rank of the same pool — so the contribution must be replaced,
        // never compounded.
        var score = QueueOrderScorer.score(outgoing: nil, incoming: nil,
                                           planned: planned(.crossfade))
        let base = score.total
        score.applyFuture(0.5, weight: 2)
        #expect(abs(score.total - (base + 1)) < 1e-9)
        score.applyFuture(0.5, weight: 2)
        #expect(abs(score.total - (base + 1)) < 1e-9)
        score.applyFuture(0, weight: 2)
        #expect(abs(score.total - base) < 1e-9)
        // Out-of-range and non-finite readings are clamped rather than trusted.
        score.applyFuture(5, weight: 1)
        #expect(score.futureRichness == 1)
        score.applyFuture(.nan, weight: 1)
        #expect(score.futureRichness == 0)
    }

    @Test func theFutureKnobsRideTheSameSweepSurfaceAsEverythingElse() {
        let moved = QueueOrderConfig.standard(
            overriding: ["futureMode": 2, "futureWeight": 0.75, "futureTopK": 9,
                         "futurePoolCap": 32, "futureRolloutDepth": 4])
        #expect(moved.futureMode == .rollout)
        #expect(moved.futureWeight == 0.75)
        #expect(moved.futureTopK == 9)
        #expect(moved.futurePoolCap == 32)
        #expect(moved.futureRolloutDepth == 4)
        // A mode out of range is clamped to a real one rather than crashing.
        #expect(QueueOrderConfig.standard(overriding: ["futureMode": 99]).futureMode
                == .rollout)
        #expect(QueueOrderConfig.standard(overriding: ["futureMode": -5]).futureMode == .off)
    }

    // MARK: - Thirds of a schedule (predev §2.5)

    @Test func aScheduleSplitsIntoThreeThirdsThatTileItExactly() {
        // The arithmetic the acceptance gate is read off. Whatever the length,
        // there are always three parts, they always sum back to the whole, and
        // no two differ by more than one seam.
        for n in 0...40 {
            let tiers = (0..<n).map { _ in TransitionTier.crossfade.label }
            let schedule = Audition.OrderSchedule(
                label: "t", names: [], tiers: tiers, steps: [])
            let thirds = schedule.thirds
            #expect(thirds.count == 3)
            #expect(thirds.reduce(0) { $0 + $1.pairs } == n)
            #expect(thirds.map(\.pairs).max()! - thirds.map(\.pairs).min()! <= 1)
        }
    }

    @Test func theThirdsCountBeatMatchedSeamsWhereTheyActuallyFell() {
        // Nine seams, three per third: all of the first third beat-matched,
        // none of the last. This is the front-loading the report exists to
        // make visible — an overall 44 % that is really 100 / 33 / 0.
        let bm = TransitionTier.beatMatched.label
        let ramped = TransitionTier.rampedBeatMatched.label
        let cf = TransitionTier.crossfade.label
        let schedule = Audition.OrderSchedule(
            label: "t", names: [],
            tiers: [bm, ramped, bm, cf, bm, cf, cf, cf, cf], steps: [])
        let thirds = schedule.thirds
        #expect(thirds.map(\.pairs) == [3, 3, 3])
        #expect(thirds.map(\.beatMatched) == [3, 1, 0])
        #expect(thirds[0].share == 100)
        #expect(abs(thirds[1].share - 100.0 / 3) < 1e-9)
        #expect(thirds[2].share == 0)
        // The thirds and the overall count are the same measurement, cut two
        // ways: they cannot disagree.
        #expect(thirds.reduce(0) { $0 + $1.beatMatched } == schedule.beatMatched)
        #expect(thirds.reduce(0) { $0 + $1.pairs } == schedule.pairs)
    }

    // MARK: - Config surface

    @Test func theWeightsAreSweepableTheSameWayThePlannersAre() {
        let moved = QueueOrderConfig.standard(
            overriding: ["agingEpsilon": 1.25, "escalationFirstRound": 7,
                         "escalationFactor": 2, "satisfyingTier": 2])
        #expect(moved.agingEpsilon == 1.25)
        #expect(moved.escalationFirstRound == 7)
        #expect(moved.escalationFactor == 2)
        #expect(moved.satisfyingTier == .stagedCrossfade)
        // The default is "the grids can be locked", which both beat-matched
        // tiers clear.
        #expect(QueueOrderConfig.standard.satisfyingTier == .beatMatched)
        #expect(TransitionTier.rampedBeatMatched >= QueueOrderConfig.standard.satisfyingTier)
        // A tier out of range is clamped rather than crashing a swept preset.
        #expect(QueueOrderConfig.standard(overriding: ["satisfyingTier": 99]).satisfyingTier
                == .rampedBeatMatched)
        // Unknown names are ignored and values are clamped, so a stale preset
        // can never take the mode down.
        let clamped = QueueOrderConfig.standard(
            overriding: ["agingEpsilon": 9_999, "nonsense": 3])
        #expect(clamped.agingEpsilon == 5)
        #expect(QueueOrderConfig.standard.asDictionary["tierSpacing"] == 10)
    }
}
