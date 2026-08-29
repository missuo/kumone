import Testing
@testable import KumoneCore
import AVFoundation
import Foundation

// 转场即乐谱 P1: the model, the compiler's grid→seconds map, the whole-mix
// lanes, and — the load-bearing one — that a score-shaped `TransitionStyle`
// with no compiled lanes renders byte-for-byte what it rendered before scores
// existed.
//
// Nothing here needs a separation model, and one test asserts exactly that: a
// score-only render must never reach for the vocal stem provider, because the
// whole cost argument for P1 ("~1 s of rendering, no separation runway") is
// that claim.

// MARK: - Fixtures

private enum ScoreFixtures {

    static let dir: URL = {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransitionScore-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static let outgoing: URL = try! sine(hz: 440, seconds: 30, name: "score-out")
    static let incoming: URL = try! sine(hz: 660, seconds: 30, name: "score-in")

    static func sine(hz: Double, seconds: Double, name: String) throws -> URL {
        let url = dir.appendingPathComponent("\(name).caf")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let sampleRate = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk: AVAudioFrameCount = 4096
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)!
        var frame = 0
        let total = Int(seconds * sampleRate)
        while frame < total {
            let n = min(Int(chunk), total - frame)
            for channel in 0..<2 {
                let data = buffer.floatChannelData![channel]
                for i in 0..<n {
                    data[i] = 0.25 * sinf(2 * .pi * Float(hz) * Float(frame + i) / Float(sampleRate))
                }
            }
            buffer.frameLength = AVAudioFrameCount(n)
            try file.write(from: buffer)
            frame += n
        }
        return url
    }

    /// An analysis with a mathematically exact grid: a beat every `60/bpm`, a
    /// downbeat every four of them, from 0 to `duration`.
    static func analysis(bpm: Double, duration: TimeInterval = 30,
                         confidence: Double = 0.95,
                         jitterAt: Int? = nil, jitter: Double = 0) -> TrackAnalysis {
        let beat = 60 / bpm
        var beats: [TimeInterval] = []
        var t: TimeInterval = 0
        var index = 0
        while t < duration {
            beats.append(t)
            t += beat + (index == jitterAt ? jitter : 0)
            index += 1
        }
        let downbeats = stride(from: 0, to: beats.count, by: 4).map { beats[$0] }
        return TrackAnalysis(
            version: TrackAnalysis.currentVersion, bpm: bpm, bpmConfidence: confidence,
            beats: beats, downbeats: downbeats, phraseBoundaries: downbeats,
            rmsEnvelope: [Float](repeating: 0.5, count: Int(duration)),
            outroFadeStart: nil, introEnd: 0, duration: duration,
            melProfile: [], keyPitchClass: nil, keyIsMinor: false, keyConfidence: 0,
            vocalActivity: [Float](repeating: 0.5, count: Int(duration)))
    }
}

/// A beat-matched plan whose grids line up: 120 BPM both sides, 2 s bars, the
/// out point and the in point both on a downbeat.
private func matchedPlan(overlap: TimeInterval = 16,
                         outPoint: TimeInterval = 8, inPoint: TimeInterval = 0,
                         incomingRate: Float = 1, glideBack: Bool = false,
                         bassSwapOffset: TimeInterval = 8) -> BeatMatchedPlan {
    var plan = BeatMatchedPlan(
        outPoint: outPoint, inPoint: inPoint, overlapBars: Int(overlap / 2),
        outgoingRate: 1, incomingRate: incomingRate,
        bassSwapOffset: bassSwapOffset, overlapDuration: overlap)
    plan.rampGlideBackFromSwap = glideBack
    return plan
}

private func scoredStyle(_ score: TransitionScore?) -> TransitionStyle {
    var style = TransitionStyle(outroEffect: .fade, stagedEQ: true)
    style.dominantDeck = true
    style.score = score
    return style
}

// MARK: - The model

@Suite struct TransitionScoreModelTests {

    @Test func theP1ScoreIsValidAndNamesItself() throws {
        let plain = TransitionScore.cutOnOne()
        try plain.validate()
        #expect(plain.label == "cutOnOne")

        let thrown = TransitionScore.cutOnOne(throwingEcho: true)
        try thrown.validate()
        #expect(thrown.label == "cutOnOne+echoThrow")
        #expect(thrown.seamOwner?.event == .echoThrow)
    }

    @Test func aScoreNeedsExactlyOneEventThatEndsTheOutgoingSide() {
        // None: nothing stops the outgoing deck, so this is not a hand-over.
        let noOwner = TransitionScore(preBars: 1, postBars: 1,
                                      events: [ScoredEvent(at: .seam, .slamIn)])
        #expect(throws: TransitionScore.ValidationFailure.noSeamOwner) { try noOwner.validate() }

        // Two: two ways of stopping the same deck at the same instant.
        let twoOwners = TransitionScore(preBars: 1, postBars: 1, events: [
            ScoredEvent(at: .seam, .cutOut), ScoredEvent(at: .seam, .echoThrow),
        ])
        #expect(throws: TransitionScore.ValidationFailure.self) { try twoOwners.validate() }
    }

    @Test func theSeamOwnerHasToSitOnTheOne() {
        let offBeat = TransitionScore(preBars: 1, postBars: 2, events: [
            ScoredEvent(at: GridPosition(bar: 1, beat: 0), .cutOut),
        ])
        #expect(throws: TransitionScore.ValidationFailure.self) { try offBeat.validate() }
    }

    @Test func positionsStayInsideTheScoresOwnSpanAndTheBar() {
        let past = TransitionScore(preBars: 1, postBars: 1, events: [
            ScoredEvent(at: .seam, .cutOut),
            ScoredEvent(at: GridPosition(bar: 5, beat: 0), .slamIn),
        ])
        #expect(throws: TransitionScore.ValidationFailure.self) { try past.validate() }

        let beyondTheBar = TransitionScore(preBars: 1, postBars: 1, events: [
            ScoredEvent(at: GridPosition(bar: 0, beat: 4), .cutOut),
        ])
        #expect(throws: TransitionScore.ValidationFailure.self) { try beyondTheBar.validate() }

        let tooWide = TransitionScore(preBars: 9, postBars: 9,
                                      events: [ScoredEvent(at: .seam, .cutOut)])
        #expect(throws: TransitionScore.ValidationFailure.self) { try tooWide.validate() }

        #expect(throws: TransitionScore.ValidationFailure.emptyScore) {
            try TransitionScore(preBars: 1, postBars: 1, events: []).validate()
        }
    }

    @Test func eventsAreMonotonicAndNeverDuplicated() {
        let backwards = TransitionScore(preBars: 2, postBars: 1, events: [
            ScoredEvent(at: .seam, .cutOut),
            ScoredEvent(at: GridPosition(bar: -1, beat: 0), .slamIn),
        ])
        #expect(throws: TransitionScore.ValidationFailure.self) { try backwards.validate() }

        let doubled = TransitionScore(preBars: 1, postBars: 1, events: [
            ScoredEvent(at: .seam, .cutOut),
            ScoredEvent(at: .seam, .slamIn),
            ScoredEvent(at: .seam, .slamIn),
        ])
        #expect(throws: TransitionScore.ValidationFailure.self) { try doubled.validate() }
    }

    @Test func theModelExpressesGesturesTheCompilerCannotYetPlay() {
        // The point of naming them now is that adding them later must not
        // rewrite the type — but a score carrying one has to be refused, out
        // loud, rather than half-played.
        #expect(!ScoreEvent.silence(beats: 1).isSupportedInV1)
        #expect(!ScoreEvent.bedIntro(bars: 2).isSupportedInV1)
        #expect(ScoreEvent.cutOut.isSupportedInV1 && ScoreEvent.echoThrow.isSupportedInV1)

        let tension = TransitionScore(preBars: 1, postBars: 1, events: [
            ScoredEvent(at: GridPosition(bar: -1, beat: 3), .silence(beats: 1)),
            ScoredEvent(at: .seam, .cutOut),
        ])
        #expect(throws: Never.self) { try tension.validate() }
        let compiled = ScoreCompiler.compile(
            tension, planned: PlannedTransition(plan: .beatMatched(matchedPlan()),
                                                style: scoredStyle(tension)),
            outgoing: ScoreFixtures.analysis(bpm: 120),
            incoming: ScoreFixtures.analysis(bpm: 120), outgoingURL: nil)
        #expect(!compiled.didCompile)
        #expect(compiled.refusalReason?.contains("silence") == true)
    }
}

// MARK: - The compiler

@Suite struct ScoreCompilerTests {

    @Test func theSeamLandsOnADownbeatAndTheOffsetsAgreeWithBothClocks() throws {
        let plan = matchedPlan()
        let planned = PlannedTransition(plan: .beatMatched(plan),
                                        style: scoredStyle(.cutOnOne()))
        let c = ScoreCompiler.compile(
            .cutOnOne(), planned: planned,
            outgoing: ScoreFixtures.analysis(bpm: 120),
            incoming: ScoreFixtures.analysis(bpm: 120), outgoingURL: nil)
        #expect(c.didCompile, "\(c.refusalReason ?? "")")

        // The seam is a downbeat of the incoming track, in its own timeline…
        #expect(abs(c.seamIncoming.truncatingRemainder(dividingBy: 2)) < 1e-6)
        // …and the plan's swap point is where it was snapped from.
        let geometry = TransitionAutomation.Geometry(plan: planned.plan)
        #expect(abs(c.seamOffset - geometry.swapOffset) <= 1.0)
        #expect(abs(c.seamSnapSeconds - (c.seamOffset - geometry.swapOffset)) < 1e-9)
        // The outgoing clock is the plan's constant bent rate.
        #expect(abs(c.seamOutgoing - (plan.outPoint + c.seamOffset * Double(plan.outgoingRate)))
                < 1e-9)
        // Both halves of the gesture placed on the same instant.
        #expect(c.events.count == 2)
        #expect(c.events.allSatisfy { abs($0.offset - c.seamOffset) < 1e-9 })
    }

    @Test func theIncomingGridIsReadThroughTheGlidesIntegralNotItsRate() throws {
        // A bent incoming deck that walks back to unity at the swap: overlap
        // time and source time stop being proportional, and a downbeat is a
        // fact about *source* time. Getting this wrong is what put a compiled
        // vocal hand-over hundreds of milliseconds out before `Side.glide`.
        let plan = matchedPlan(incomingRate: 1.04, glideBack: true)
        let planned = PlannedTransition(plan: .beatMatched(plan),
                                        style: scoredStyle(.cutOnOne()))
        let geometry = TransitionAutomation.Geometry(plan: planned.plan)
        let glide = TransitionAutomation.incomingGlide(for: planned.plan, geometry: geometry)
        #expect(glide != nil)

        // The seam itself sits *at* the swap, which is where the glide starts,
        // so a position several bars past it is what puts the integral under
        // load — the far end of the window, where a constant rate is worst.
        let late = TransitionScore(preBars: 1, postBars: 5, events: [
            ScoredEvent(at: .seam, .cutOut),
            ScoredEvent(at: GridPosition(bar: 4, beat: 0), .slamIn),
        ])
        let c = ScoreCompiler.compile(
            late, planned: planned,
            outgoing: ScoreFixtures.analysis(bpm: 120),
            incoming: ScoreFixtures.analysis(bpm: 125), outgoingURL: nil)
        #expect(c.didCompile, "\(c.refusalReason ?? "")")
        let placed = try #require(c.events.first { $0.event == "slamIn" })

        // The map the renderer will use, run forwards: the compiled offset has
        // to put the deck exactly on the downbeat the compiler named.
        let clock = StemTechniqueLayer.SourceClock(rate: Double(plan.incomingRate), glide: glide)
        let bar = 4 * 60 / 125.0
        let target = c.seamIncoming + 4 * bar
        let arrived = plan.inPoint + clock.sourceAdvance(to: placed.offset)
        #expect(abs(arrived - target) < 1e-3,
                "the compiled grid point must land on the downbeat itself, not near it")

        // And the constant-rate shortcut would have been audibly wrong — this
        // is the integral actually mattering rather than being a formality.
        let naive = plan.inPoint + placed.offset * Double(plan.incomingRate)
        #expect(abs(naive - target) > 0.02,
                "if a constant rate agreed here the test would be proving nothing")
    }

    @Test func theSlamPrefersAPhraseLineOverTheNearestBar() throws {
        // The incoming deck has been running silently since the top of the
        // overlap, so where the slam lands *in the incoming song* is where the
        // new track appears to start. Landing four-bar phrases from the in
        // point is what makes that a phrase entry rather than a bar-group edge.
        let plan = matchedPlan(bassSwapOffset: 10)
        let planned = PlannedTransition(plan: .beatMatched(plan),
                                        style: scoredStyle(.cutOnOne()))
        let c = ScoreCompiler.compile(.cutOnOne(), planned: planned,
                                      outgoing: ScoreFixtures.analysis(bpm: 120),
                                      incoming: ScoreFixtures.analysis(bpm: 120),
                                      outgoingURL: nil)
        #expect(c.didCompile, "\(c.refusalReason ?? "")")
        // Downbeats every 2 s from an in point of 0: the nearest bar to the
        // swap is 10 s (five bars in, mid-phrase) and the phrase line is 8 s.
        #expect(abs(c.seamIncoming - 8) < 1e-6)
        #expect(abs(c.seamOffset - 8) < 1e-6)
    }

    @Test func aDriftingGridIsRefusedRatherThanCutOn() {
        let planned = PlannedTransition(plan: .beatMatched(matchedPlan()),
                                        style: scoredStyle(.cutOnOne()))
        // A human drummer's bar, 15 % long, right where the cut goes: the seam
        // lands ~16 s into the outgoing track, which is beat 32.
        let drifting = ScoreFixtures.analysis(bpm: 120, jitterAt: 32, jitter: 0.3)
        let c = ScoreCompiler.compile(.cutOnOne(), planned: planned,
                                      outgoing: drifting,
                                      incoming: ScoreFixtures.analysis(bpm: 120),
                                      outgoingURL: nil)
        #expect(!c.didCompile)
        #expect(c.refusalReason?.contains("抖动") == true, "\(c.refusalReason ?? "compiled")")
    }

    @Test func aScoreOnlyMakesSenseOnABeatMatchedPlan() {
        let crossfade = PlannedTransition(
            plan: .crossfade(duration: 6, outPoint: 8, inPoint: 0),
            style: scoredStyle(.cutOnOne()))
        let c = ScoreCompiler.compile(.cutOnOne(), planned: crossfade,
                                      outgoing: ScoreFixtures.analysis(bpm: 120),
                                      incoming: ScoreFixtures.analysis(bpm: 120),
                                      outgoingURL: nil)
        #expect(!c.didCompile)
    }

    @Test func theLanesCutOneSideAndBringTheOtherInOnTheSameFrame() throws {
        let planned = PlannedTransition(plan: .beatMatched(matchedPlan()),
                                        style: scoredStyle(.cutOnOne()))
        let c = ScoreCompiler.compile(.cutOnOne(), planned: planned,
                                      outgoing: ScoreFixtures.analysis(bpm: 120),
                                      incoming: ScoreFixtures.analysis(bpm: 120),
                                      outgoingURL: nil)
        let lanes = try #require(c.lanes)
        #expect(lanes.ownsGainLaw)
        let edge = WholeMixLane.cutEdgeSeconds
        // Full level right up to the edge, gone by the seam.
        #expect(abs(lanes.outgoing.gain(at: c.seamOffset - edge) - 1) < 1e-6)
        #expect(lanes.outgoing.gain(at: c.seamOffset) < 0.002)
        #expect(lanes.outgoing.gain(at: c.seamOffset + 1) < 0.002)
        // …and the mirror image on the way in.
        #expect(lanes.incoming.gain(at: c.seamOffset - edge) < 0.002)
        #expect(abs(lanes.incoming.gain(at: c.seamOffset) - 1) < 1e-6)
        // The edge is inside the predev's 5–10 ms.
        #expect(edge >= 0.005 && edge <= 0.010)
    }

    @Test func theEchoThrowAimsAtTheLastLineEndBeforeTheSeamAndDegradesWithoutOne() throws {
        let planned = PlannedTransition(plan: .beatMatched(matchedPlan()),
                                        style: scoredStyle(.cutOnOne(throwingEcho: true)))
        let outgoing = ScoreFixtures.analysis(bpm: 120)
        let incoming = ScoreFixtures.analysis(bpm: 120)

        // No `.lrc`: the throw degrades to the plain cut and says so, rather
        // than throwing a delay at an instant nobody sang on.
        let bare = ScoreCompiler.compile(.cutOnOne(throwingEcho: true), planned: planned,
                                         outgoing: outgoing, incoming: incoming,
                                         outgoingURL: ScoreFixtures.outgoing)
        #expect(bare.didCompile)
        #expect(bare.echoThrow == nil)
        #expect(bare.degradations.count == 1)

        // With one, the throw lands on the last line end before the seam.
        let lyricTrack = ScoreFixtures.dir.appendingPathComponent("score-lyrics.caf")
        try? FileManager.default.removeItem(at: lyricTrack)
        try FileManager.default.copyItem(at: ScoreFixtures.outgoing, to: lyricTrack)
        let lrc = Audition.Lyrics.sidecarURL(for: lyricTrack)
        try """
        [00:09.00]一句
        [00:12.00]又一句
        [00:20.00]再一句
        """.write(to: lrc, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: lrc)
            try? FileManager.default.removeItem(at: lyricTrack)
        }
        let thrown = ScoreCompiler.compile(.cutOnOne(throwingEcho: true), planned: planned,
                                           outgoing: outgoing, incoming: incoming,
                                           outgoingURL: lyricTrack)
        let directive = try #require(thrown.echoThrow)
        // Line ends are the *next* line's timestamp: 12 s and 20 s. The seam is
        // ~16 s into the outgoing track, so the 12 s end is the one to throw.
        #expect(abs(directive.throwAt - (12 - 8)) < 0.05)
        #expect(thrown.echoLine == "一句")
        // Beat-synced: a dotted eighth at 120 BPM is 375 ms.
        #expect(abs(directive.delayTime - 0.375) < 0.01)
        #expect(thrown.degradations.isEmpty)
    }
}

// MARK: - The lanes

@Suite struct WholeMixLaneTests {

    @Test func aStepLandsOnTheFrameItNames() {
        let sampleRate = 44_100.0
        let clock = StemTechniqueLayer.SourceClock(rate: 1, glide: nil)
        let cut = 1.0
        let lane = WholeMixLane([
            .init(t: 0, gainDB: 0),
            .init(t: cut - WholeMixLane.cutEdgeSeconds, gainDB: 0),
            .init(t: cut, gainDB: WholeMixLane.minGainDB),
            .init(t: 2, gainDB: WholeMixLane.minGainDB),
        ])
        let gains = WholeMixLaneLayer.perSampleGains(lane, clock: clock,
                                                     frames: Int(2 * sampleRate),
                                                     sampleRate: sampleRate)
        let edgeStart = Int((cut - WholeMixLane.cutEdgeSeconds) * sampleRate)
        let cutFrame = Int(cut * sampleRate)
        // Unity until the last frame before the edge…
        #expect(abs(gains[edgeStart - 1] - 1) < 1e-6)
        // …silent from the frame the cut names, and never before it.
        #expect(gains[cutFrame] < 0.002)
        #expect(gains[cutFrame - 1] > gains[cutFrame])
        // The whole move happens inside the edge and nowhere else.
        #expect(gains[edgeStart + 1] < 1)
        #expect(gains[..<edgeStart].allSatisfy { abs($0 - 1) < 1e-6 })
    }

    @Test func aBentDeckPutsTheStepOnTheSourceFrameTheOverlapClockNames() {
        // The lane speaks overlap time; the buffer is source frames. At a 4 %
        // bend one second of overlap is 1.04 s of song, and the step has to be
        // there rather than at 1.0 s — the same map the stem lanes use.
        let sampleRate = 44_100.0
        let clock = StemTechniqueLayer.SourceClock(rate: 1.04, glide: nil)
        let lane = WholeMixLane([
            .init(t: 0, gainDB: 0),
            .init(t: 1 - WholeMixLane.cutEdgeSeconds, gainDB: 0),
            .init(t: 1, gainDB: WholeMixLane.minGainDB),
        ])
        let gains = WholeMixLaneLayer.perSampleGains(lane, clock: clock,
                                                     frames: Int(2 * sampleRate),
                                                     sampleRate: sampleRate)
        #expect(gains[Int(1.04 * sampleRate)] < 0.002)
        #expect(abs(gains[Int(1.0 * sampleRate) - 1] - 1) < 1e-6)
    }

    @Test func aPassThroughLaneTouchesNothing() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
        buffer.frameLength = 44_100
        for channel in 0..<2 {
            for i in 0..<44_100 { buffer.floatChannelData![channel][i] = 0.5 }
        }
        let side = StemTechniqueLayer.Side(buffer: buffer, source: ScoreFixtures.outgoing,
                                           windowStart: 0, overlapStartFrame: 0, rate: 1)
        let frames = try WholeMixLaneLayer.apply(WholeMixLane(), to: side, overlap: 1)
        #expect(frames == 0)
        #expect(buffer.floatChannelData![0][100] == 0.5)
    }
}

// MARK: - Rendering

@Suite(.serialized) struct ScoreRenderTests {

    /// The compiled lanes for the shipped P1 score on the fixture pair.
    private func lanes(cutAt seam: TimeInterval, overlap: TimeInterval) -> WholeMixLanes {
        let edge = WholeMixLane.cutEdgeSeconds
        var lanes = WholeMixLanes(ownsGainLaw: true)
        lanes.outgoing = WholeMixLane([
            .init(t: 0, gainDB: 0), .init(t: seam - edge, gainDB: 0),
            .init(t: seam, gainDB: WholeMixLane.minGainDB),
            .init(t: overlap, gainDB: WholeMixLane.minGainDB),
        ])
        lanes.incoming = WholeMixLane([
            .init(t: 0, gainDB: WholeMixLane.minGainDB),
            .init(t: seam - edge, gainDB: WholeMixLane.minGainDB),
            .init(t: seam, gainDB: 0), .init(t: overlap, gainDB: 0),
        ])
        return lanes
    }

    @Test func aScoreOnlyRenderNeverAsksForAStem() throws {
        // The whole cost argument for P1 is this assertion: a full-band gesture
        // needs no separation, so a score-only segment is a render and nothing
        // else — ~1 s, and a runway that collapses to the margin.
        final class Flag: @unchecked Sendable { var asked = false }
        let flag = Flag()
        let provider: VocalStemProvider = { request in
            flag.asked = true
            return VocalStem(channels: request.samples.map {
                [Float](repeating: 0, count: $0.count)
            })
        }

        var options = OfflineTransitionRenderer.Options()
        options.preRoll = 2
        options.postRoll = 2
        options.normalizeToLUFS = nil
        options.vocalStemProvider = provider
        options.mixLanes = lanes(cutAt: 8, overlap: 16)

        let planned = PlannedTransition(plan: .beatMatched(matchedPlan()),
                                        style: scoredStyle(.cutOnOne()))
        let mix = try OfflineTransitionRenderer.renderMix(
            planned, outgoing: ScoreFixtures.outgoing, incoming: ScoreFixtures.incoming,
            options: options)
        #expect(!flag.asked, "a score-only render must not reach for a separator")
        #expect(mix.lanesApplied != nil)
        #expect(mix.stemApplied == nil)
    }

    @Test func theCutIsAudibleInTheRenderedSamples() throws {
        var options = OfflineTransitionRenderer.Options()
        options.preRoll = 2
        options.postRoll = 2
        options.normalizeToLUFS = nil
        // Both lanes muted after the seam: whatever is left in the file past
        // the cut is the lanes not having been applied per sample.
        var muted = lanes(cutAt: 8, overlap: 16)
        muted.incoming = WholeMixLane([
            .init(t: 0, gainDB: WholeMixLane.minGainDB),
            .init(t: 16, gainDB: WholeMixLane.minGainDB),
        ])
        options.mixLanes = muted

        let planned = PlannedTransition(plan: .beatMatched(matchedPlan()),
                                        style: scoredStyle(.cutOnOne()))
        let mix = try OfflineTransitionRenderer.renderMix(
            planned, outgoing: ScoreFixtures.outgoing, incoming: ScoreFixtures.incoming,
            options: options)
        #expect(mix.lanesApplied != nil)

        func peak(_ from: TimeInterval, _ to: TimeInterval) -> Float {
            let rate = mix.sampleRate
            let lo = max(0, Int(from * rate)), hi = min(mix.channels[0].count, Int(to * rate))
            guard lo < hi else { return 0 }
            return mix.channels[0][lo..<hi].map(abs).max() ?? 0
        }
        let seam = mix.overlapStart + 8
        #expect(peak(seam - 1, seam - 0.1) > 0.05, "the outgoing track plays up to the cut")
        #expect(peak(seam + 0.1, seam + 3) < 0.005, "and nothing at all after it")
    }

    @Test func anEchoThrowLeavesATailTheCutCannotTakeWithIt() throws {
        var options = OfflineTransitionRenderer.Options()
        options.preRoll = 2
        options.postRoll = 2
        options.normalizeToLUFS = nil
        var thrown = lanes(cutAt: 8, overlap: 16)
        thrown.incoming = WholeMixLane([
            .init(t: 0, gainDB: WholeMixLane.minGainDB),
            .init(t: 16, gainDB: WholeMixLane.minGainDB),
        ])
        thrown.echoThrow = EchoThrowDirective(throwAt: 6, delayTime: 0.375)
        options.mixLanes = thrown

        let planned = PlannedTransition(plan: .beatMatched(matchedPlan()),
                                        style: scoredStyle(.cutOnOne(throwingEcho: true)))
        let mix = try OfflineTransitionRenderer.renderMix(
            planned, outgoing: ScoreFixtures.outgoing, incoming: ScoreFixtures.incoming,
            options: options)
        let rate = mix.sampleRate
        let seam = Int((mix.overlapStart + 8) * rate)
        let after = mix.channels[0][(seam + Int(0.1 * rate))..<min(mix.channels[0].count,
                                                                   seam + Int(rate))]
        // The lane cut the *source*, which is upstream of the deck's delay, so
        // the tail outlives the track it came from.
        #expect((after.map(abs).max() ?? 0) > 0.005,
                "the thrown delay has to ring on past the cut")
    }
}

// MARK: - Byte identity

@Suite(.serialized) struct ScoreByteIdentityTests {

    @Test func aStyleCarryingAScoreDecidesAndAutomatesIdentically() {
        // A score is a *marker*: until `ScoreCompiler` turns it into lanes it
        // must not move a single automated parameter.
        let plan = TransitionPlan.beatMatched(matchedPlan())
        let geometry = TransitionAutomation.Geometry(plan: plan)
        for elapsed in stride(from: 0.0, through: 16.0, by: 0.25) {
            let without = TransitionAutomation.frame(plan: plan, style: scoredStyle(nil),
                                                     elapsed: elapsed, geometry: geometry)
            let with = TransitionAutomation.frame(
                plan: plan, style: scoredStyle(.cutOnOne(throwingEcho: true)),
                elapsed: elapsed, geometry: geometry)
            #expect(without == with, "at +\(elapsed)s")
        }
    }

    @Test func theShippedPlannerOffersNoScoreAtAll() {
        // P1 ships dark. Every knob at its default has to produce `nil`, or the
        // "byte-identical fall-back" claim is a test's promise rather than a
        // structural one.
        let confident = ScoreFixtures.analysis(bpm: 120, duration: 240, confidence: 0.99)
        #expect(TransitionPlanner.score(outgoing: confident, incoming: confident,
                                        context: TransitionPlanner.PlanContext(),
                                        config: .standard) == nil)
        var enabled = TransitionPlanner.Config.standard
        enabled.scoreEnabled = true
        #expect(TransitionPlanner.score(outgoing: confident, incoming: confident,
                                        context: TransitionPlanner.PlanContext(),
                                        config: enabled) == .cutOnOne())
        // …and the echo throw only when there are words to throw.
        #expect(TransitionPlanner.score(
            outgoing: confident, incoming: confident,
            context: TransitionPlanner.PlanContext(outgoingLyricLineEnds: [12, 20]),
            config: enabled) == .cutOnOne(throwingEcho: true))
        // A grid the tracker is unsure about gets no score however keen the knob.
        let vague = ScoreFixtures.analysis(bpm: 120, duration: 240, confidence: 0.5)
        #expect(TransitionPlanner.score(outgoing: vague, incoming: confident,
                                        context: TransitionPlanner.PlanContext(),
                                        config: enabled) == nil)
    }

    @Test func anUncompiledScoreRendersTheSameSamplesAsNoScore() throws {
        var options = OfflineTransitionRenderer.Options()
        options.preRoll = 1
        options.postRoll = 1
        options.normalizeToLUFS = nil

        func render(_ score: TransitionScore?) throws -> [[Float]] {
            let planned = PlannedTransition(plan: .beatMatched(matchedPlan(overlap: 4)),
                                            style: scoredStyle(score))
            return try OfflineTransitionRenderer.renderMix(
                planned, outgoing: ScoreFixtures.outgoing, incoming: ScoreFixtures.incoming,
                options: options).channels
        }
        let plain = try render(nil)
        let scored = try render(.cutOnOne(throwingEcho: true))
        #expect(plain.count == scored.count)
        for channel in 0..<plain.count {
            #expect(plain[channel] == scored[channel],
                    "a score with no compiled lanes must render byte-identically")
        }
    }
}

// MARK: - Segment admission and runway

@Suite struct ScoreSegmentAdmissionTests {

    @Test func aSegmentIsWorthRenderingForAStemTechniqueOrAScoreAndNothingElse() {
        let bare = PlannedTransition(plan: .beatMatched(matchedPlan(overlap: 2)),
                                     style: scoredStyle(nil))
        #expect(throws: TransitionSegmentRenderer.SegmentError.self) {
            _ = try TransitionSegmentRenderer.render(
                TransitionSegmentRenderer.Request(
                    planned: bare, outgoingURL: ScoreFixtures.outgoing,
                    incomingURL: ScoreFixtures.incoming),
                provider: { _ in throw StemTechniqueLayer.StemError.noProvider })
        }
    }

    @Test func aScoreWithoutAnalysesIsRefusedBeforeAnythingIsRendered() {
        let scored = PlannedTransition(plan: .beatMatched(matchedPlan(overlap: 2)),
                                       style: scoredStyle(.cutOnOne()))
        #expect(throws: TransitionSegmentRenderer.SegmentError.self) {
            _ = try TransitionSegmentRenderer.render(
                TransitionSegmentRenderer.Request(
                    planned: scored, outgoingURL: ScoreFixtures.outgoing,
                    incomingURL: ScoreFixtures.incoming),
                provider: { _ in throw StemTechniqueLayer.StemError.noProvider })
        }
    }

    @MainActor
    @Test func aScoreOnlySegmentAsksForTheMarginAndNothingMore() {
        // Separation is the whole runway; without it there is a render pass and
        // the margin already covers that. A 16 s hand-over that needed 47 s of
        // lead needs 15.
        #expect(PlayerService.stemPrerenderRunway(overlapDuration: 16) == 47)
        #expect(PlayerService.stemPrerenderRunway(overlapDuration: 16,
                                                  separatesStems: false) == 15)
        #expect(PlayerService.stemPrerenderRunway(overlapDuration: 30,
                                                  separatesStems: false) == 15)
    }
}
