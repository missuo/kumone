import Foundation

// From a score to audio: bars and beats → seconds → per-sample gain lanes.
//
// The division of labour is `vocalExchange`'s, one level up (predev §2.2). The
// planner names an intent — "cut on the one, throw the last line into a delay"
// — as a `TransitionScore` of typed events on a bar grid. It cannot turn that
// into audio: where bar 0 beat 0 *is* depends on the final geometry, on both
// beat grids, on how far each deck is bent, and on where the outgoing singer
// stopped singing. All of that is known here, once, just before the render.
//
// The refusal path matters as much as the compile. A score that cannot be
// placed on the grid is thrown away whole and the hand-over is today's blend —
// never a half-placed score, never a cut nudged onto the nearest thing that
// looked like a downbeat. Half a beat out is the one error a cut cannot
// survive (predev §4.2), so everything below fails closed.

enum ScoreCompiler {

    // MARK: - Tolerances

    /// How far the seam may be moved off `Geometry.swapOffset` to land on a
    /// downbeat, as a fraction of one bar. Half a bar means "the nearest
    /// downbeat, whichever side"; past that there is no downbeat near the
    /// hand-over at all and the grid is not to be trusted.
    static let seamSnapBars: Double = 0.5

    /// Grid self-check (predev §4.2): bar lengths around the seam must agree to
    /// within this fraction, or the grid is drifting and a cut on it would land
    /// off the beat.
    ///
    /// **Measured on bars, not beats, and that is not a softening.** The predev
    /// writes the check as "adjacent intervals jumping more than 3 %", and on
    /// the *beat* list that fires on everything: eight quantized dance tracks
    /// out of the user's own cache carry a 5–13 % worst beat interval and an
    /// 8 % typical one, because the tracker snaps each beat to an onset and the
    /// onsets are where the performance is, not where the clock is. That noise
    /// is the analyzer's, and a check that measures the analyzer refuses every
    /// score for no musical reason. The bar grid over the same eight tracks
    /// separates cleanly instead — 0.7–3.4 % around the seam for six of them,
    /// 12 % and 13 % for the two whose downbeats really do wander — and the bar
    /// grid is also what a score is addressed on, so it is the grid whose
    /// trustworthiness the gesture actually depends on.
    static let gridJitterTolerance: Double = 0.03
    /// How many bars either side of the seam the self-check looks at.
    static let gridCheckBars = 4

    /// One phrase, in bars — the unit the slam prefers to land on (see the seam
    /// placement below), and the length nearly all of this repertoire's
    /// sections are built out of.
    static let phraseBars = 4
    /// How far the seam may be walked to reach a phrase line, in bars. Two bars
    /// either way covers every offset inside a four-bar phrase.
    static let phraseSnapBars = 2

    /// Beat fraction the echo throw's delay is synced to — a dotted eighth,
    /// the same 0.75 `TransitionAutomation.echoDelayTime` uses, so a throw and
    /// an `.echoOut` on the same pair ring at the same tempo.
    static let echoDelayBeatFraction: Double = 0.75
    /// The throw needs this much room on both sides: a line end within a
    /// quarter second of the seam is not a throw, it is a cut with a click on
    /// it, and one that lands before the overlap has started cannot be played.
    static let echoThrowMarginSeconds: TimeInterval = 0.25

    // MARK: - Output

    /// One event, placed.
    struct Placed: Sendable, Equatable {
        var event: String
        var at: GridPosition
        /// Seconds into the overlap.
        var offset: TimeInterval
    }

    /// What compiling a score came to — enough for the console and the panel to
    /// say why it landed where it did, or why it did not land at all.
    struct Compilation: Sendable, Equatable {
        var label: String
        /// Seconds into the overlap where the seam ("the one") sits.
        var seamOffset: TimeInterval = 0
        /// The same instant on the two songs' own clocks.
        var seamOutgoing: TimeInterval = 0
        var seamIncoming: TimeInterval = 0
        /// How far the seam had to move off the plan's own swap point to land
        /// on a downbeat.
        var seamSnapSeconds: TimeInterval = 0
        var events: [Placed] = []
        var echoThrow: EchoThrowDirective?
        /// The outgoing line thrown into the delay.
        var echoLine: String?
        /// Gestures that were asked for and quietly came out smaller — an echo
        /// throw with no lyrics to aim at degrades to a plain cut. Never
        /// silent: a listener has to be able to tell which gesture they heard.
        var degradations: [String] = []
        /// The compiled lanes; nil exactly when `refusalReason` is set.
        var lanes: WholeMixLanes?
        /// Why the whole score was thrown away. Non-nil means the hand-over is
        /// the plain blend it would have been without a score at all.
        var refusalReason: String?

        var didCompile: Bool { lanes != nil }
    }

    // MARK: - Entry point

    /// Compile one score against the final geometry and both beat grids.
    ///
    /// Pure: two analyses, a plan, and (for the echo throw's anchor) the
    /// outgoing track's URL, which is read for its `.lrc` exactly as
    /// `VocalExchange` reads it. Never throws — a score that cannot be placed
    /// comes back as a `Compilation` carrying `refusalReason`, because the
    /// caller's answer to both outcomes is the same shape: play the blend.
    static func compile(_ score: TransitionScore, planned: PlannedTransition,
                        outgoing: TrackAnalysis, incoming: TrackAnalysis,
                        outgoingURL: URL?) -> Compilation {
        func refuse(_ reason: String) -> Compilation {
            Compilation(label: score.label, refusalReason: reason)
        }

        do { try score.validate() } catch {
            return refuse("乐谱本身不合法："
                          + ((error as? LocalizedError)?.errorDescription
                             ?? error.localizedDescription))
        }
        if let unsupported = score.events.first(where: { !$0.event.isSupportedInV1 }) {
            return refuse("\(unsupported.event.label) 还没有编译器实现（P1 只做 cut-on-one 与 "
                          + "echo throw），整谱作废。")
        }
        guard case .beatMatched(let p) = planned.plan else {
            return refuse("乐谱只在 beatMatched 的转场上有格子可以落。")
        }
        let geometry = TransitionAutomation.Geometry(plan: planned.plan)
        let overlap = geometry.overlapDuration
        guard overlap > 1 else {
            return refuse(String(format: "这次叠加只有 %.2f 秒，排不下一张乐谱。", overlap))
        }
        let glide = TransitionAutomation.incomingGlide(for: planned.plan, geometry: geometry)
        let outRate = Double(max(0.5, min(2, p.outgoingRate)))
        let inRate = Double(max(0.5, min(2, p.incomingRate)))

        // --- The two grids, each on its own song's clock.
        let outDownbeats = outgoing.downbeats
        let inDownbeats = incoming.downbeats
        guard outDownbeats.count > score.preBars, inDownbeats.count > score.postBars else {
            return refuse("两侧的小节网格不够长，落不下 \(score.preBars)/\(score.postBars) 小节的乐谱。")
        }

        /// Overlap-relative seconds → the outgoing track's own clock, on its
        /// (constant, already-bent) overlap rate.
        func outgoingSource(_ t: TimeInterval) -> TimeInterval { p.outPoint + t * outRate }
        func outgoingOverlapTime(_ source: TimeInterval) -> TimeInterval {
            (source - p.outPoint) / outRate
        }
        /// …and the incoming track's, which under a post-swap glide is the
        /// integral of a moving rate rather than a straight line. Exactly the
        /// map `StemTechniqueLayer.Side.sourceAdvance` uses, and its inverse.
        let incomingClock = StemTechniqueLayer.SourceClock(rate: inRate, glide: glide)
        func incomingSource(_ t: TimeInterval) -> TimeInterval {
            p.inPoint + incomingClock.sourceAdvance(to: t)
        }
        func incomingOverlapTime(_ source: TimeInterval) -> TimeInterval {
            incomingClock.overlapElapsed(atSource: source - p.inPoint, within: overlap)
        }

        // --- Where the seam goes.
        //
        // P1 does not move the plan — aiming is P2 — so the seam starts from
        // the plan's own hand-over instant, the floor swap, and is then snapped
        // onto the incoming track's grid. Two snaps, in order:
        //
        //   1. **a phrase line, if one is near.** The incoming deck has been
        //      running silently since the top of the overlap, so the slam lands
        //      wherever the seam is *in the incoming song*, not at its in point.
        //      Landing a whole number of four-bar phrases past the in point is
        //      what keeps that "cut into the next phrase" rather than "cut into
        //      the middle of a bar-group"; the in point is itself a downbeat the
        //      planner chose, so counting phrases from it is counting from the
        //      entry the planner meant.
        //   2. otherwise the nearest downbeat, which is the floor this can never
        //      go below: a cut is a cut on the one or it is nothing.
        //
        // Nothing constrains the seam's position beyond that, because a score
        // that owns the gain law replaces the crossfade rather than sitting on
        // it — there is no fader to compensate at any offset.
        let swapSource = incomingSource(geometry.swapOffset)
        guard var seamIndex = nearestIndex(inDownbeats, to: swapSource) else {
            return refuse("入曲没有小节线可以对齐。")
        }
        let inBar = barSeconds(inDownbeats, around: seamIndex, bpm: incoming.bpm)
        guard abs(inDownbeats[seamIndex] - swapSource) <= inBar * seamSnapBars else {
            return refuse(String(format: "交接点附近 %.2f 秒内没有入曲的小节线（最近的差 %.2f 秒）。",
                                 inBar * seamSnapBars, abs(inDownbeats[seamIndex] - swapSource)))
        }
        if let entry = nearestIndex(inDownbeats, to: p.inPoint) {
            let lo = Swift.max(0, seamIndex - phraseSnapBars)
            let hi = Swift.min(inDownbeats.count - 1, seamIndex + phraseSnapBars)
            let phrased = (lo...Swift.max(lo, hi))
                .filter { ($0 - entry) % phraseBars == 0 }
                .min { abs(inDownbeats[$0] - swapSource) < abs(inDownbeats[$1] - swapSource) }
            if let phrased { seamIndex = phrased }
        }
        let seamIncoming = inDownbeats[seamIndex]
        let seamOffset = incomingOverlapTime(seamIncoming)
        guard seamOffset > WholeMixLane.cutEdgeSeconds * 4,
              seamOffset < overlap - WholeMixLane.cutEdgeSeconds * 4 else {
            return refuse(String(format: "对齐后的 seam 落在 +%.2f 秒，贴着叠加的边缘，切不出来。",
                                 seamOffset))
        }
        let seamOutgoing = outgoingSource(seamOffset)

        // --- Grid self-check, both sides: a cut on a drifting grid is a cut on
        // the wrong beat, and the drift is measurable before anything is
        // rendered.
        for (label, grid, at) in [("出曲", outDownbeats, seamOutgoing),
                                  ("入曲", inDownbeats, seamIncoming)] {
            guard let jitter = worstJitter(grid, around: at, bars: gridCheckBars)
            else { continue }
            guard jitter <= gridJitterTolerance else {
                return refuse(String(format: "%@在交接点附近的小节长度抖动 %.1f%%，超过 %.0f%% 的上限，"
                                     + "格点不可信。", label, jitter * 100,
                                     gridJitterTolerance * 100))
            }
        }

        // --- Grid coverage: the score's whole span has to exist on the grids.
        guard let outSeamIndex = nearestIndex(outDownbeats, to: seamOutgoing) else {
            return refuse("出曲没有小节线可以对齐。")
        }
        guard outSeamIndex - score.preBars >= 0,
              seamIndex + score.postBars < inDownbeats.count else {
            return refuse("乐谱要用到的小节超出了拍网格的范围。")
        }
        let outBar = barSeconds(outDownbeats, around: outSeamIndex, bpm: outgoing.bpm)

        /// A grid position, in overlap-relative seconds. Nil when the grid does
        /// not reach it — which invalidates the score, not just the event.
        func place(_ position: GridPosition) -> TimeInterval? {
            if position.bar >= 0 {
                let index = seamIndex + position.bar
                guard index >= 0, index < inDownbeats.count else { return nil }
                let beat = (inBar / Double(TransitionScore.beatsPerBar)) * position.beat
                return incomingOverlapTime(inDownbeats[index] + beat)
            }
            let index = outSeamIndex + position.bar
            guard index >= 0, index < outDownbeats.count else { return nil }
            let beat = (outBar / Double(TransitionScore.beatsPerBar)) * position.beat
            return outgoingOverlapTime(outDownbeats[index] + beat)
        }

        var placed: [Placed] = []
        for scored in score.events {
            guard let offset = place(scored.at) else {
                return refuse("格点 bar \(scored.at.bar) 落在拍网格之外，整谱作废。")
            }
            guard offset >= 0, offset <= overlap else {
                return refuse(String(format: "格点 bar %d 落在叠加窗口之外（+%.2f 秒，窗口 0–%.2f 秒），"
                                     + "整谱作废。", scored.at.bar, offset, overlap))
            }
            placed.append(Placed(event: scored.event.label, at: scored.at, offset: offset))
        }

        // --- The echo throw's anchor: the last outgoing lyric line end before
        // the seam. `VocalExchange`'s precedent, asked a simpler question.
        var directive: EchoThrowDirective?
        var echoLine: String?
        var degradations: [String] = []
        if score.events.contains(where: { $0.event == .echoThrow }) {
            let beat = outBar / Double(TransitionScore.beatsPerBar) / outRate
            let delayTime = min(max(beat * echoDelayBeatFraction, 0.05), 2.0)
            if let anchor = lastLineEnd(before: seamOutgoing, outgoingURL: outgoingURL,
                                        notBefore: p.outPoint
                                            + echoThrowMarginSeconds * outRate,
                                        margin: echoThrowMarginSeconds * outRate) {
                directive = EchoThrowDirective(
                    throwAt: outgoingOverlapTime(anchor.end), delayTime: delayTime)
                echoLine = anchor.text
            } else {
                degradations.append("出曲在 seam 之前没有可用的歌词行尾，echo throw 降级为直切"
                                    + "（延时没有可甩的末句）。")
            }
        }

        // --- The lanes.
        let edge = WholeMixLane.cutEdgeSeconds
        var lanes = WholeMixLanes(ownsGainLaw: true)
        lanes.outgoing = WholeMixLane([
            .init(t: 0, gainDB: 0),
            .init(t: seamOffset - edge, gainDB: 0),
            .init(t: seamOffset, gainDB: WholeMixLane.minGainDB),
            .init(t: overlap, gainDB: WholeMixLane.minGainDB),
        ])
        lanes.incoming = WholeMixLane([
            .init(t: 0, gainDB: WholeMixLane.minGainDB),
            .init(t: seamOffset - edge, gainDB: WholeMixLane.minGainDB),
            .init(t: seamOffset, gainDB: 0),
            .init(t: overlap, gainDB: 0),
        ])
        lanes.echoThrow = directive

        return Compilation(
            label: score.label, seamOffset: seamOffset,
            seamOutgoing: seamOutgoing, seamIncoming: seamIncoming,
            seamSnapSeconds: seamOffset - geometry.swapOffset,
            events: placed, echoThrow: directive, echoLine: echoLine,
            degradations: degradations, lanes: lanes, refusalReason: nil)
    }

    // MARK: - Grid helpers

    /// Index of the entry nearest `t`; nil for an empty grid.
    static func nearestIndex(_ grid: [TimeInterval], to t: TimeInterval) -> Int? {
        guard !grid.isEmpty else { return nil }
        var best = 0
        var bestDistance = abs(grid[0] - t)
        for i in 1..<grid.count {
            let d = abs(grid[i] - t)
            if d < bestDistance { best = i; bestDistance = d }
            // The grid is ascending, so once it starts walking away it is done.
            else if grid[i] > t { break }
        }
        return best
    }

    /// One bar in seconds, measured on the grid itself around `index` and
    /// falling back to the analysis tempo where the grid cannot say.
    static func barSeconds(_ downbeats: [TimeInterval], around index: Int,
                           bpm: Double) -> TimeInterval {
        let fallback = bpm > 1 ? 60 / bpm * Double(TransitionScore.beatsPerBar) : 2
        guard downbeats.count > 1 else { return fallback }
        let i = max(0, min(downbeats.count - 2, index))
        let measured = downbeats[i + 1] - downbeats[i]
        return measured > 0.2 && measured < 12 ? measured : fallback
    }

    /// The worst relative deviation between bar lengths in a window of `bars`
    /// either side of `t`, or nil when there are too few bars there to judge.
    static func worstJitter(_ downbeats: [TimeInterval], around t: TimeInterval,
                            bars: Int) -> Double? {
        guard let index = nearestIndex(downbeats, to: t) else { return nil }
        let lo = Swift.max(0, index - bars)
        let hi = Swift.min(downbeats.count - 1, index + bars)
        guard hi - lo >= 3 else { return nil }
        var intervals: [TimeInterval] = []
        for i in lo..<hi where downbeats[i + 1] > downbeats[i] {
            intervals.append(downbeats[i + 1] - downbeats[i])
        }
        guard intervals.count > 2 else { return nil }
        let median = intervals.sorted()[intervals.count / 2]
        guard median > 1e-6 else { return nil }
        return intervals.map { abs($0 - median) / median }.max()
    }

    /// The last outgoing lyric line end before `seam`, with room on both sides.
    static func lastLineEnd(before seam: TimeInterval, outgoingURL: URL?,
                            notBefore: TimeInterval,
                            margin: TimeInterval) -> (end: TimeInterval, text: String)? {
        guard let outgoingURL, let lines = Audition.Lyrics.load(for: outgoingURL),
              !lines.isEmpty else { return nil }
        let ends = Audition.Lyrics.lineEnds(lines)
        var best: (end: TimeInterval, text: String)?
        for (line, end) in zip(lines, ends)
        where end >= notBefore && end <= seam - margin {
            if best == nil || end > best!.end { best = (end, line.text) }
        }
        return best
    }
}
