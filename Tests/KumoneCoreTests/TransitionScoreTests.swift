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

/// Shared with `ScoreGestureLibraryTests` (P4), which builds its gestures on
/// exactly these grids so the two files cannot disagree about what a bar is.
enum ScoreFixtures {

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
                         jitterAt: Int? = nil, jitter: Double = 0,
                         rms: [Float]? = nil, vocal: [Float]? = nil) -> TrackAnalysis {
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
            rmsEnvelope: rms ?? [Float](repeating: 0.5, count: Int(duration)),
            outroFadeStart: nil, introEnd: 0, duration: duration,
            melProfile: [], keyPitchClass: nil, keyIsMinor: false, keyConfidence: 0,
            vocalActivity: vocal ?? [Float](repeating: 0.5, count: Int(duration)))
    }
}

/// A beat-matched plan whose grids line up: 120 BPM both sides, 2 s bars, the
/// out point and the in point both on a downbeat.
func matchedPlan(overlap: TimeInterval = 16,
                         outPoint: TimeInterval = 8, inPoint: TimeInterval = 0,
                         outgoingRate: Float = 1,
                         incomingRate: Float = 1, glideBack: Bool = false,
                         bassSwapOffset: TimeInterval = 8) -> BeatMatchedPlan {
    var plan = BeatMatchedPlan(
        outPoint: outPoint, inPoint: inPoint, overlapBars: Int(overlap / 2),
        outgoingRate: outgoingRate, incomingRate: incomingRate,
        bassSwapOffset: bassSwapOffset, overlapDuration: overlap)
    plan.rampGlideBackFromSwap = glideBack
    return plan
}

func scoredStyle(_ score: TransitionScore?) -> TransitionStyle {
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

    @Test func aScoreNeedsAtMostOneEventThatEndsTheOutgoingSide() {
        // A slam with nothing cut is not a gesture, it is a level jump: the
        // incoming deck arrives full-band while the outgoing one is still
        // blending underneath it. Same for a beat of silence in the middle of a
        // crossfade that then resumes.
        let noOwner = TransitionScore(preBars: 1, postBars: 1,
                                      events: [ScoredEvent(at: .seam, .slamIn)])
        #expect(throws: TransitionScore.ValidationFailure
            .gestureNeedsASeamOwner(event: "slamIn")) { try noOwner.validate() }
        let orphanSilence = TransitionScore(preBars: 1, postBars: 1,
                                            events: [ScoredEvent(at: .seam, .silence(beats: 1))])
        #expect(throws: TransitionScore.ValidationFailure.self) { try orphanSilence.validate() }

        // But a score with **no** owner and nothing that needs one is legal,
        // and P4 needed it to be: a bed decorates the blend the planner already
        // made and has no opinion about how the outgoing track leaves.
        #expect(throws: Never.self) { try TransitionScore.bedIntro(bars: 4).validate() }
        #expect(!TransitionScore.bedIntro(bars: 4).ownsSeam)
        #expect(TransitionScore.cutOnOne().ownsSeam)

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

    @Test func theWholeVocabularyIsPerformableNow() {
        // P1 named five gestures and could play three. P4 built the other two,
        // so this property — which the compiler still guards on, for the
        // gestures the model has yet to grow — is uniformly true.
        #expect(ScoreEvent.silence(beats: 1).isSupportedInV1)
        #expect(ScoreEvent.bedIntro(bars: 2).isSupportedInV1)
        #expect(ScoreEvent.cutOut.isSupportedInV1 && ScoreEvent.echoThrow.isSupportedInV1)
    }

    @Test func theSpansHaveSizesThatAreGestures() {
        // A span is only a gesture inside a range. Four beats of nothing is the
        // player having stopped; a nine-bar bed is the arrangement.
        for beats in [0.0, -1, 5, Double.nan] {
            #expect(throws: TransitionScore.ValidationFailure.self) {
                try TransitionScore.tensionCut(beats: beats).validate()
            }
        }
        #expect(throws: Never.self) { try TransitionScore.tensionCut(beats: 1).validate() }
        for bars in [0, TransitionScore.maxBedIntroBars + 1] {
            #expect(throws: TransitionScore.ValidationFailure
                .bedIntroOutOfRange(bars: bars)) {
                try TransitionScore.bedIntro(bars: bars).validate()
            }
        }
    }

    @Test func everyTemplateNamesItselfAfterTheGestureNotTheEvents() {
        // Nobody hears "a cutOut and a slamIn at the same grid point"; the
        // listening notes are written in gestures, so the labels are too.
        #expect(TransitionScore.cutOnly().label == "cutOnly")
        #expect(TransitionScore.cutOnly(throwingEcho: true).label == "cutOnly+echoThrow")
        #expect(TransitionScore.tensionCut(beats: 1).label == "tensionCut(1)+cutOnOne")
        #expect(TransitionScore.bedIntro(bars: 4).label == "bedIntro(4)")
    }

    @Test func onlyTheBedCostsASeparationPass() {
        // The runway class is the whole cost story of the library, and it is a
        // property of the score rather than a derivation, so the arming path
        // and the compiler cannot disagree about the bill.
        for score in [TransitionScore.cutOnOne(), .cutOnOne(throwingEcho: true),
                      .cutOnly(), .tensionCut(beats: 1)] {
            #expect(score.runwayClass == .scoreOnly)
            #expect(!score.needsIncomingStems)
        }
        #expect(TransitionScore.bedIntro(bars: 4).runwayClass == .incomingStems)
        #expect(TransitionScore.bedIntro(bars: 4).needsIncomingStems)
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
        //
        // **This is now the degradation path, and it still has to hold.** P2
        // aims the seam at a drop / chorus / core start and the phrase snap
        // then never runs; with no aim on the style — no structure on the
        // incoming track, or a gate that refused the aimed entry — the seam
        // goes exactly where P1 put it, which is what this pins.
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

    @Test func theEchoThrowIsOnlyEarnedByALineThatEndsOnTheSeam() throws {
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
        // …and the report calls it what the listener will hear: a cut.
        #expect(bare.label == "cutOnOne")

        let lyricTrack = ScoreFixtures.dir.appendingPathComponent("score-lyrics.caf")
        try? FileManager.default.removeItem(at: lyricTrack)
        try FileManager.default.copyItem(at: ScoreFixtures.outgoing, to: lyricTrack)
        let lrc = Audition.Lyrics.sidecarURL(for: lyricTrack)
        defer {
            try? FileManager.default.removeItem(at: lrc)
            try? FileManager.default.removeItem(at: lyricTrack)
        }
        func compile(_ lyrics: String) throws -> ScoreCompiler.Compilation {
            try lyrics.write(to: lrc, atomically: true, encoding: .utf8)
            return ScoreCompiler.compile(.cutOnOne(throwingEcho: true), planned: planned,
                                         outgoing: outgoing, incoming: incoming,
                                         outgoingURL: lyricTrack)
        }

        // **P1's own case, now refused.** The seam is ~16 s into the outgoing
        // track and line ends are the *next* line's timestamp, so this last
        // line ended at 12 s — eight beats before the cut. P1 threw it anyway,
        // which is why every scored seam in the field carried a throw and why
        // the tail read as a wash rather than as a gesture. Eight beats of open
        // delay over a track that is about to be cut is `.echoOut`, not a throw.
        let stale = try compile("""
        [00:09.00]一句
        [00:12.00]又一句
        [00:20.00]再一句
        """)
        #expect(stale.didCompile)
        #expect(stale.echoThrow == nil, "a line that ended eight beats ago is not a throw")
        #expect(stale.label == "cutOnOne")
        #expect(stale.degradations.count == 1)

        // A line that ends *on* the seam is the gesture: the singer lands on
        // the one, the dry signal is cut on the same frame, the tail rings on.
        // 15.75 s is a quarter of a beat before the 16 s seam, inside the
        // one-beat (0.5 s at 120 BPM) window.
        let earned = try compile("""
        [00:09.00]一句
        [00:15.75]又一句
        [00:24.00]再一句
        """)
        let directive = try #require(earned.echoThrow)
        #expect(abs(directive.throwAt - (15.75 - 8)) < 0.05)
        // A line *ends* where the next one starts, so the thrown line is the one
        // that runs up to 15.75 s.
        #expect(earned.echoLine == "一句")
        // Beat-synced: a dotted eighth at 120 BPM is 375 ms.
        #expect(abs(directive.delayTime - 0.375) < 0.01)
        #expect(earned.degradations.isEmpty)
        #expect(earned.label == "cutOnOne+echoThrow")

        // Just outside the window on the same side: a beat and a half early is
        // a line that stopped mid-bar, and the gate is what makes the throw a
        // decision rather than a default.
        let missed = try compile("""
        [00:09.00]一句
        [00:15.20]又一句
        [00:24.00]再一句
        """)
        #expect(missed.echoThrow == nil)
    }

    @Test func theThrownTailSitsBelowTheOutroEchoItBorrowedItsNumbersFrom() {
        // A throw rings *over a track that has already started*; `.echoOut`'s
        // tail has nothing underneath it. Same numbers on both was P1's, and it
        // is what put the old song's wet tail level with the new song's
        // downbeat.
        let ratio = EchoThrowDirective.throwWetMix / TransitionAutomation.echoWetMix
        #expect(abs(20 * log10(ratio) - EchoThrowDirective.throwTailTrimDB) < 0.01)
        #expect(EchoThrowDirective.throwTailTrimDB == -4)
        #expect(EchoThrowDirective.throwFeedback < TransitionAutomation.echoFeedback)
        // A directive built without an opinion gets the tamed numbers, so the
        // discipline cannot be lost by a producer that forgets to ask.
        let plain = EchoThrowDirective(throwAt: 1, delayTime: 0.375)
        #expect(plain.wetDryMix == EchoThrowDirective.throwWetMix)
        #expect(plain.feedback == EchoThrowDirective.throwFeedback)
    }
}

// MARK: - Aiming (P2)

/// A section list over a track whose bars are `bar` seconds long, so every
/// `start` is a real downbeat of `ScoreFixtures.analysis`'s grid.
private func sections(_ spec: [(TrackAnalysis.Section.Kind, TimeInterval, TimeInterval)])
    -> [TrackAnalysis.Section] {
    spec.map { .init(start: $0.1, end: $0.2, kind: $0.0, repetition: 2,
                     energy: 0.8, vocalDensity: 0.5) }
}

private func aimable(bpm: Double = 120, duration: TimeInterval = 120,
                     confidence: Double = 0.9,
                     _ spec: [(TrackAnalysis.Section.Kind, TimeInterval, TimeInterval)])
    -> TrackAnalysis {
    var a = ScoreFixtures.analysis(bpm: bpm, duration: duration)
    a.sections = sections(spec)
    a.structureConfidence = confidence
    return a
}

@Suite struct TransitionAimTests {

    /// A plan with an in point the aiming layer will want to move: 16 bars of
    /// overlap at 120 BPM (2 s bars), entered at the top of the track.
    private func plan() -> BeatMatchedPlan {
        matchedPlan(overlap: 32, outPoint: 60, inPoint: 0, bassSwapOffset: 16)
    }

    private var config: TransitionPlanner.Config {
        var c = TransitionPlanner.Config.standard
        c.scoreEnabled = true
        return c
    }

    @Test func theDropOutranksTheChorusAndTheChorusOutranksTheCore() {
        let out = ScoreFixtures.analysis(bpm: 120, duration: 120)
        // One incoming track, three readings of it: with a drop, with the drop
        // relabelled, and with neither. The priority is the predev's, and it is
        // a priority rather than a search because a `.drop` *is* the thing a
        // slam was invented for.
        let all = aimable([(.intro, 0, 8), (.verse, 8, 40), (.chorus, 40, 56),
                           (.drop, 56, 88), (.outro, 88, 120)])
        #expect(TransitionPlanner.aim(plan: plan(), outgoing: out, incoming: all,
                                      config: config).aim?.target == .drop)

        let chorusOnly = aimable([(.intro, 0, 8), (.verse, 8, 40), (.chorus, 40, 56),
                                  (.verse, 56, 88), (.outro, 88, 120)])
        let c = TransitionPlanner.aim(plan: plan(), outgoing: out, incoming: chorusOnly,
                                      config: config)
        #expect(c.aim?.target == .chorus)
        #expect(c.aim?.time == 40)

        // No chorus and no drop: the first *core* section — which is
        // `inPointChoice`'s own answer, aimed at rather than entered on.
        // (A `bridge` is the segmenter's catch-all for a passage that happens
        // once, so a first verse that never repeats verbatim comes back
        // labelled that way — core is defined by exclusion, exactly as
        // `inPointChoice` defines it.)
        let plain = aimable([(.intro, 0, 24), (.bridge, 24, 88), (.outro, 88, 120)])
        let core = TransitionPlanner.aim(plan: plan(), outgoing: out, incoming: plain,
                                         config: config)
        #expect(core.aim?.target == .core)
        #expect(core.aim?.time == 24)
    }

    @Test func aTrackWithNoUsableStructureIsNotAimedAtAtAll() {
        let out = ScoreFixtures.analysis(bpm: 120, duration: 120)
        let p = plan()

        // No sections at all — every pre-v7 sidecar, and everything the
        // segmenter was unsure about. The entry is the plan's own, field for
        // field: this is not "equivalent to" P1's placement, it *is* it.
        let bare = ScoreFixtures.analysis(bpm: 120, duration: 120)
        let none = TransitionPlanner.aim(plan: p, outgoing: out, incoming: bare,
                                         config: config)
        #expect(none.aim == nil)
        #expect(none.inPoint == p.inPoint)
        #expect(none.detail == "no structure")

        // Sections, but below the planner's own structure gate. The gate is not
        // re-litigated here — aiming reads exactly the sections the in-point
        // layer would have read, or it reads none.
        var c = config
        let shy = aimable(confidence: c.structureConfidenceGate - 0.01,
                          [(.intro, 0, 8), (.drop, 8, 88), (.outro, 88, 120)])
        let gated = TransitionPlanner.aim(plan: p, outgoing: out, incoming: shy, config: c)
        #expect(gated.aim == nil)
        #expect(gated.inPoint == p.inPoint)
        #expect(gated.detail.contains("structure confidence"))

        // And the layer's own switch, for the A/B.
        c.scoreAimEnabled = false
        let confident = aimable([(.intro, 0, 8), (.drop, 8, 88), (.outro, 88, 120)])
        #expect(TransitionPlanner.aim(plan: p, outgoing: out, incoming: confident,
                                      config: c).aim == nil)
    }

    @Test func theEntryIsComposedBackwardsSoTheAimLandsOnTheSeam() throws {
        // The arithmetic the whole layer is: the aim minus however much of the
        // incoming track runs before the hand-over. At 120 BPM with a 32 s
        // overlap the swap is 16 s in, which is eight 2 s bars, so a drop at
        // 56 s is entered at 40 s.
        let out = ScoreFixtures.analysis(bpm: 120, duration: 120)
        let inc = aimable([(.intro, 0, 8), (.verse, 8, 56), (.drop, 56, 96),
                           (.outro, 96, 120)])
        let outcome = TransitionPlanner.aim(plan: plan(), outgoing: out, incoming: inc,
                                            config: config)
        let aim = try #require(outcome.aim)
        #expect(aim.time == 56)
        #expect(aim.leadBars == 8)
        #expect(abs(outcome.inPoint - 40) < 1e-9)

        // …and the compiler, given the aimed plan, puts the seam on the aim
        // itself rather than on the phrase line P1 would have snapped to.
        let aimed = plan().enteringIncoming(at: outcome.inPoint)
        var style = scoredStyle(.cutOnOne())
        style.aim = aim
        let planned = PlannedTransition(plan: .beatMatched(aimed), style: style)
        let c = ScoreCompiler.compile(.cutOnOne(), planned: planned,
                                      outgoing: out, incoming: inc, outgoingURL: nil)
        #expect(c.didCompile, "\(c.refusalReason ?? "")")
        #expect(abs(c.seamIncoming - 56) < 1e-6)
        #expect(c.aim?.target == .drop)
    }

    @Test func theSeamReachesTheAimThroughTheGlidesIntegral() throws {
        // The same claim under a bent, gliding incoming deck, where overlap
        // seconds and source seconds stop being proportional. A rate-shaped
        // shortcut lands the slam tens of milliseconds off the drop, which on a
        // cut is the one error there is no hiding.
        let out = ScoreFixtures.analysis(bpm: 120, duration: 120)
        let inc = aimable(bpm: 125, [(.intro, 0, 7.68), (.verse, 7.68, 53.76),
                                     (.drop, 53.76, 96), (.outro, 96, 120)])
        var p = matchedPlan(overlap: 32, outPoint: 60, inPoint: 0,
                            incomingRate: 1.04, glideBack: true, bassSwapOffset: 16)
        p = p.enteringIncoming(at: 0)
        let outcome = TransitionPlanner.aim(plan: p, outgoing: out, incoming: inc,
                                            config: config)
        let aim = try #require(outcome.aim)
        #expect(aim.target == .drop)

        let aimed = p.enteringIncoming(at: outcome.inPoint)
        var style = scoredStyle(.cutOnOne())
        style.aim = aim
        let planned = PlannedTransition(plan: .beatMatched(aimed), style: style)
        let c = ScoreCompiler.compile(.cutOnOne(), planned: planned,
                                      outgoing: out, incoming: inc, outgoingURL: nil)
        #expect(c.didCompile, "\(c.refusalReason ?? "")")
        #expect(abs(c.seamIncoming - aim.time) < 1e-6)

        // Walk the renderer's own map forward from the in point: the deck has
        // to be standing on the drop at the compiled offset.
        let geometry = TransitionAutomation.Geometry(plan: planned.plan)
        let glide = TransitionAutomation.incomingGlide(for: planned.plan, geometry: geometry)
        let clock = StemTechniqueLayer.SourceClock(rate: Double(aimed.incomingRate),
                                                   glide: glide)
        let arrived = aimed.inPoint + clock.sourceAdvance(to: c.seamOffset)
        #expect(abs(arrived - aim.time) < 1e-3)
    }

    @Test func aGateBeatsAnAim() {
        let out = ScoreFixtures.analysis(bpm: 120, duration: 120)
        let p = plan()

        // The aim is too near the top of the track to compose an entry from:
        // eight bars before a drop at 8 s is a negative in point, and there is
        // no aim worth entering a track before it starts for.
        let early = aimable([(.intro, 0, 8), (.drop, 8, 96), (.outro, 96, 120)])
        let tooEarly = TransitionPlanner.aim(plan: p, outgoing: out, incoming: early,
                                             config: config)
        #expect(tooEarly.aim == nil)
        #expect(tooEarly.inPoint == p.inPoint)

        // The aimed window runs off the end of the incoming track. The overlap
        // still has to fit — the in-point clamp is a gate like any other, and
        // aiming does not get to spend audio the track does not have.
        let late = aimable(duration: 70, [(.intro, 0, 8), (.verse, 8, 56),
                                          (.drop, 56, 70)])
        let tooLate = TransitionPlanner.aim(plan: p, outgoing: out, incoming: late,
                                            config: config)
        #expect(tooLate.aim == nil)
        #expect(tooLate.inPoint == p.inPoint)

        // The clamp on how much of the incoming song an aim may skip.
        var c = config
        c.scoreAimMaxLeadSeconds = 10
        let deep = aimable([(.intro, 0, 8), (.verse, 8, 56), (.drop, 56, 96),
                            (.outro, 96, 120)])
        #expect(TransitionPlanner.aim(plan: p, outgoing: out, incoming: deep,
                                      config: c).aim == nil)

        // And the incoming window's own steadiness gate, on an aimed entry that
        // straddles a lurch the plain in point never saw.
        var lurching = ScoreFixtures.analysis(
            bpm: 120, duration: 120,
            rms: (0..<120).map { $0 >= 40 && $0 < 48 ? 0.02 : 0.9 })
        lurching.sections = sections([(.intro, 0, 8), (.verse, 8, 56), (.drop, 56, 96),
                                      (.outro, 96, 120)])
        lurching.structureConfidence = 0.9
        let unsteady = TransitionPlanner.aim(plan: p, outgoing: out, incoming: lurching,
                                             config: config)
        #expect(unsteady.aim == nil)
        #expect(unsteady.inPoint == p.inPoint)
    }

    @Test func aimingNeverTouchesTheOutgoingTracksExit() {
        // The out point is the climax guard's, the lyric snap's and the
        // candidate ordering's business, and this layer is structurally unable
        // to reach it: `enteringIncoming` copies every other field. Asserted
        // rather than assumed, because "the gates cannot be bought" is the
        // safety argument for the whole layer.
        let p = plan()
        let moved = p.enteringIncoming(at: 40)
        #expect(moved.inPoint == 40)
        #expect(moved.outPoint == p.outPoint)
        #expect(moved.overlapBars == p.overlapBars)
        #expect(moved.overlapDuration == p.overlapDuration)
        #expect(moved.bassSwapOffset == p.bassSwapOffset)
        #expect(moved.outgoingRate == p.outgoingRate)
        #expect(moved.incomingRate == p.incomingRate)
        #expect(moved.rampLeadSeconds == p.rampLeadSeconds)
        #expect(moved.rampReleaseSeconds == p.rampReleaseSeconds)
        #expect(moved.rampGlideBackFromSwap == p.rampGlideBackFromSwap)
    }

    @Test func anAimThatNoLongerDescribesTheGeometryLosesToThePhraseLine() {
        // A plan override moved the seam after the aim was chosen. The aim now
        // points at a bar that is nowhere near the hand-over, and the answer is
        // P1's placement with the swap it actually has — not a cut aimed at a
        // bar that has drifted out of the window.
        let out = ScoreFixtures.analysis(bpm: 120, duration: 120)
        let inc = aimable([(.intro, 0, 8), (.verse, 8, 56), (.drop, 56, 96),
                           (.outro, 96, 120)])
        var style = scoredStyle(.cutOnOne())
        style.aim = TransitionAim(target: .drop, time: 56, leadBars: 8)
        // Entered at 8 s rather than the 40 s the aim was composed for: the
        // drop is now 48 s past the entry and the swap is 16 s past it.
        let planned = PlannedTransition(
            plan: .beatMatched(matchedPlan(overlap: 32, outPoint: 60, inPoint: 8,
                                           bassSwapOffset: 16)),
            style: style)
        let c = ScoreCompiler.compile(.cutOnOne(), planned: planned,
                                      outgoing: out, incoming: inc, outgoingURL: nil)
        #expect(c.didCompile, "\(c.refusalReason ?? "")")
        #expect(c.aim == nil)
        #expect(c.degradations.count == 1)
        #expect(abs(c.seamIncoming - 24) < 1e-6, "the phrase line eight bars past the entry")
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
        #expect(TransitionPlanner.scoreFamily(outgoing: confident, incoming: confident,
                                              config: .standard) == nil)
        var enabled = TransitionPlanner.Config.standard
        enabled.scoreEnabled = true
        #expect(TransitionPlanner.scoreFamily(outgoing: confident, incoming: confident,
                                              config: enabled) == .cutCulture)
        // A grid the tracker is unsure about gets no family however keen the knob.
        let vague = ScoreFixtures.analysis(bpm: 120, duration: 240, confidence: 0.5)
        #expect(TransitionPlanner.scoreFamily(outgoing: vague, incoming: confident,
                                              config: enabled) == nil)
        // With the intent layer on, the class picks the ladder — and only two
        // of the five classes have one.
        enabled.intentEnabled = true
        for (klass, family) in [(TransitionIntent.Class.cutCulture, ScoreTemplate.Family.cutCulture),
                                (.dropAlign, .dropAlign)] {
            #expect(TransitionPlanner.scoreFamily(
                outgoing: confident, incoming: confident,
                intent: TransitionIntent(klass, reasons: []), config: enabled) == family)
        }
        for klass in [TransitionIntent.Class.blend, .restrained, .standDown] {
            #expect(TransitionPlanner.scoreFamily(
                outgoing: confident, incoming: confident,
                intent: TransitionIntent(klass, reasons: []), config: enabled) == nil)
        }
    }

    @Test func theShippedPlannerAimsAtNothingBecauseItScoresNothing() {
        // Aiming is the one thing a score *moves* — the incoming entry — so the
        // byte-identity claim has to survive it. It does structurally: the layer
        // runs inside the `style.score != nil` branch, which is unreachable at
        // the shipped config. Asserted end to end anyway, on a pair whose
        // incoming track has a drop the layer would very much like to aim at.
        let outgoing = ScoreFixtures.analysis(bpm: 120, duration: 240, confidence: 0.95)
        var incoming = ScoreFixtures.analysis(bpm: 120, duration: 240, confidence: 0.95)
        incoming.sections = sections([(.intro, 0, 8), (.verse, 8, 56), (.drop, 56, 200),
                                      (.outro, 200, 240)])
        incoming.structureConfidence = 0.95

        func planned(_ config: TransitionPlanner.Config) -> PlannedTransition {
            TransitionPlanner.plan(outgoing: outgoing, incoming: incoming, config: config)
        }
        let shipped = planned(.standard)
        #expect(shipped.style.score == nil)
        #expect(shipped.style.aim == nil)

        var enabled = TransitionPlanner.Config.standard
        enabled.scoreEnabled = true
        let scored = planned(enabled)
        // The aim moved the entry and nothing else: same out point, same bars,
        // same rates. That is the gates-win claim, at the planner's own level.
        guard case .beatMatched(let a) = shipped.plan,
              case .beatMatched(let b) = scored.plan else {
            Issue.record("both plans should be beat-matched")
            return
        }
        #expect(b.outPoint == a.outPoint)
        #expect(b.overlapBars == a.overlapBars)
        #expect(b.overlapDuration == a.overlapDuration)
        #expect(b.outgoingRate == a.outgoingRate)
        #expect(b.incomingRate == a.incomingRate)
        #expect(scored.style.aim?.target == .drop)
        #expect(b.inPoint != a.inPoint, "the entry is the one field aiming writes")

        // …and with the aim switched off, the plan is the shipped one again,
        // score or no score: the A/B's control arm.
        enabled.scoreAimEnabled = false
        let unaimed = planned(enabled)
        #expect(unaimed.style.score != nil)
        #expect(unaimed.style.aim == nil)
        guard case .beatMatched(let u) = unaimed.plan else { return }
        #expect(u.inPoint == a.inPoint)
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

// MARK: - Vetting the score before anything is rendered (P2 addendum)

@MainActor
@Suite struct ScoreVettingTests {

    /// A score the compiler will refuse: a grid that lurches right where the
    /// cut goes, which is the self-check of predev §4.2. A drifting grid is the
    /// commonest real refusal and the one the field flood was made of.
    private func ungriddable() -> (PlannedTransition, TrackAnalysis, TrackAnalysis) {
        let planned = PlannedTransition(plan: .beatMatched(matchedPlan()),
                                        style: scoredStyle(.cutOnOne()))
        return (planned,
                ScoreFixtures.analysis(bpm: 120, jitterAt: 32, jitter: 0.3),
                ScoreFixtures.analysis(bpm: 120))
    }

    @Test func aScoreTheCompilerWillRefuseIsTakenOffThePlanBeforeArming() throws {
        let (planned, out, inc) = ungriddable()
        // The compiler's own verdict, first — this is the case being caught.
        let compiled = ScoreCompiler.compile(.cutOnOne(), planned: planned,
                                             outgoing: out, incoming: inc, outgoingURL: nil)
        #expect(!compiled.didCompile)

        let vetted = PlayerService.vettingScore(planned, outgoing: out, incoming: inc,
                                                outgoingURL: nil)
        // Stripped, so nothing downstream can spawn a render for it: the
        // segment renderer's own admission is "a stem technique **or** a
        // score", and with neither there is nothing to attempt.
        #expect(vetted.planned.style.score == nil)
        #expect(vetted.planned.style.stemTechnique == nil)
        // …with the compiler's actual sentence, not a shrug. This is the string
        // the journal's `score refused:` line and the panel both print, and it
        // is the reason "render produced nothing" used to be standing in for.
        let refusal = try #require(vetted.refusal)
        #expect(refusal == compiled.refusalReason)
        #expect(!refusal.isEmpty)

        // Everything else about the plan is untouched: this removes a gesture,
        // it does not re-decide the hand-over. The seam plays today's blend.
        guard case .beatMatched(let before) = planned.plan,
              case .beatMatched(let after) = vetted.planned.plan else {
            Issue.record("both plans should be beat-matched"); return
        }
        #expect(after.outPoint == before.outPoint)
        #expect(after.inPoint == before.inPoint)
        #expect(after.overlapDuration == before.overlapDuration)
        #expect(vetted.planned.style.outroEffect == planned.style.outroEffect)
    }

    @Test func aScoreThatCompilesIsArmedExactlyAsPlanned() {
        let out = ScoreFixtures.analysis(bpm: 120, duration: 60)
        let inc = ScoreFixtures.analysis(bpm: 120, duration: 60)
        let planned = PlannedTransition(plan: .beatMatched(matchedPlan()),
                                        style: scoredStyle(.cutOnOne()))
        let vetted = PlayerService.vettingScore(planned, outgoing: out, incoming: inc,
                                                outgoingURL: nil)
        #expect(vetted.refusal == nil)
        #expect(vetted.planned.style.score?.label == "cutOnOne")
    }

    @Test func aScoreWithNoAnalysisToPlaceItOnNeverReachesARender() throws {
        // The other half of the same problem, and the commoner one: the toggle
        // is flipped on a track heard for the first time. There is no grid to
        // compile against, so there is nothing to render either.
        let planned = PlannedTransition(plan: .beatMatched(matchedPlan()),
                                        style: scoredStyle(.cutOnOne()))
        let inc = ScoreFixtures.analysis(bpm: 120, duration: 60)
        for pair in [(nil, inc), (inc, nil)] as [(TrackAnalysis?, TrackAnalysis?)] {
            let vetted = PlayerService.vettingScore(planned, outgoing: pair.0,
                                                    incoming: pair.1, outgoingURL: nil)
            #expect(vetted.planned.style.score == nil)
            #expect(vetted.refusal?.isEmpty == false)
        }
    }

    @Test func anUnscoredPlanIsHandedBackUntouchedAndUnexplained() {
        // Every shipped seam. The vetting has to be a no-op on it, refusal
        // included: a `nil` there is what keeps the journal quiet.
        let planned = PlannedTransition(plan: .beatMatched(matchedPlan()),
                                        style: scoredStyle(nil))
        let vetted = PlayerService.vettingScore(
            planned, outgoing: ScoreFixtures.analysis(bpm: 120, duration: 60),
            incoming: ScoreFixtures.analysis(bpm: 120, duration: 60), outgoingURL: nil)
        #expect(vetted.refusal == nil)
        #expect(vetted.planned.style.score == nil)
    }

    @Test func aRefusalIsPlanNewsAndTheRenderRowSaysThereIsNothingToRender() {
        // Fix 1, as the panel model sees it. Three states of one row, and the
        // refusal is the one that used to be printed somewhere else entirely.
        var snapshot = AutoMixDebugSnapshot()
        snapshot.plan = AutoMixDebugPlan()
        #expect(snapshot.scoreRow == "none — today's blend")

        snapshot.plan?.score = "cutOnOne+echoThrow"
        #expect(snapshot.scoreRow == "score=cutOnOne+echoThrow")

        // Arming strips the score off the plan and hands back the reason, so
        // the row is asked to print a refusal *and* a nil score at once. It
        // must name the refusal — that is the whole content of the seam.
        snapshot.plan?.score = nil
        snapshot.scoreRefusal = "入曲在交接点附近的小节长度抖动 10.0%"
        #expect(snapshot.scoreRow.hasPrefix("refused: "))
        #expect(snapshot.scoreRow.contains("抖动"))

        // And the pre-render row, which used to carry all of that, is back to
        // its own subject: a plan with neither stems nor a score has nothing to
        // render, which is a state and not a failure.
        #expect(AutoMixPrerenderState.notNeeded.label == "nothing to pre-render")
        #expect(AutoMixPrerenderState.notNeeded != .idle)
        for failed in [AutoMixPrerenderState.refused("x"), .abandoned("x")] {
            #expect(failed != .notNeeded)
        }
    }

    @Test func theSameRefusalOnTheSameSeamIsOneJournalLine() {
        // Fix 3. The key is the seam, so the ~2.9 arms per seam — and the extra
        // disarm/re-arm pair a seek adds — write one line between them.
        let reason = "入曲在交接点附近的小节长度抖动 10.0%"
        func key(outgoing: Int? = 1, incoming: Int? = 2, outPoint: TimeInterval?,
                 reason: String = reason) -> PlayerService.ScoreRefusalKey {
            PlayerService.scoreRefusalKey(outgoing: outgoing, incoming: incoming,
                                          outPoint: outPoint, reason: reason)
        }
        #expect(key(outPoint: 184.2) == key(outPoint: 184.2))
        // A re-plan that nudges the out point by a frame is the same hand-over
        // being re-derived; the journal must not report it as a second problem.
        #expect(key(outPoint: 184.2) == key(outPoint: 183.9))

        // What *does* earn a fresh line: a different pair, a seam that really
        // moved, and a different verdict.
        #expect(key(outPoint: 184.2) != key(incoming: 3, outPoint: 184.2))
        #expect(key(outPoint: 184.2) != key(outgoing: nil, outPoint: 184.2))
        #expect(key(outPoint: 184.2) != key(outPoint: 171))
        #expect(key(outPoint: 184.2) != key(outPoint: 184.2, reason: "别的理由"))
        #expect(key(outPoint: nil) != key(outPoint: 184.2))
    }

    @Test func everySegmentRefusalCarriesASentenceForThePanel() {
        // The panel prints `error.localizedDescription` now, so every case has
        // to have one — the point of the change is that "render produced
        // nothing" stops standing in for reasons it was never describing.
        let errors: [TransitionSegmentRenderer.SegmentError] = [
            .noOverlap, .overlapTooLong(120), .nothingToRender,
            .stemsNotApplied("因由"), .stemsNotApplied(nil),
            .scoreNotCompiled("因由"), .scoreNotCompiled(nil),
            .scoreNotApplied("因由"), .scoreNotApplied(nil), .emptyRender,
        ]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
            #expect(error.localizedDescription == error.errorDescription)
        }
    }
}

// MARK: - Pre-render start (P2 addendum)

@MainActor
@Suite struct StemPrerenderStartTests {

    private let lead = PlayerService.stemPrerenderLead
    private let settle = PlayerService.stemPrerenderSettleSeconds

    private func trigger(remaining: TimeInterval, stableFor: TimeInterval,
                         runway: TimeInterval) -> PlayerService.StemPrerenderTrigger? {
        PlayerService.stemPrerenderTrigger(remaining: remaining, stableFor: stableFor,
                                           runway: runway)
    }

    @Test func anArmedPlanThatHoldsStillStartsAheadOfTheLeadWindow() {
        // The change itself. Two minutes from the splice — far outside the 60 s
        // lead — a plan that has held still for the settle window starts, and
        // the same plan a second earlier does not.
        #expect(trigger(remaining: 120, stableFor: settle, runway: 47) == .settled)
        #expect(trigger(remaining: 120, stableFor: settle - 1, runway: 47) == nil)

        // Why it matters: a 30 s overlap needs 75 s of runway and the flat lead
        // window only ever offered 60. The settle trigger was the first answer
        // to that, and it is still the answer far out from the splice — but a
        // seam this wide now also gets a lead window sized to its own work, so
        // `wide + 1` is *inside* that window and starts on the spot rather than
        // waiting to be believed.
        let wide = PlayerService.stemPrerenderRunway(overlapDuration: 30)
        #expect(wide > lead)
        #expect(trigger(remaining: wide + 1, stableFor: settle, runway: wide) == .late)
        #expect(trigger(remaining: wide + 40, stableFor: settle, runway: wide) == .settled)
        #expect(trigger(remaining: wide + 40, stableFor: 0, runway: wide) == nil)
        // And the feasibility guard is untouched: 60 s is still not 75 s.
        #expect(trigger(remaining: lead, stableFor: settle, runway: wide) == nil)
    }

    @Test func startingEarlyDoesNotExcuseNotHavingTheRunway() {
        // Feasibility is unchanged and is asked first: settling for an hour
        // buys nothing when the work does not fit in what is left.
        #expect(trigger(remaining: 46, stableFor: 600, runway: 47) == nil)
        // Exactly enough is enough — and inside the lead window it is the lead
        // window's own trigger that names it, settled or not.
        #expect(trigger(remaining: 47, stableFor: 600, runway: 47) == .late)
        // A 47 s runway asks for a 62 s window, so 61 s out is inside it and
        // the settle clock is not consulted. This used to read `.settled` and
        // the difference is only the journal's word for it: both start now.
        #expect(trigger(remaining: lead + 1, stableFor: 600, runway: 47) == .lead)
        #expect(trigger(remaining: lead + 1, stableFor: 0, runway: 47) == .lead)
        #expect(trigger(remaining: 120, stableFor: 600, runway: 47) == .settled)
        // And nothing starts inside the abandon guard, however cheap it is.
        #expect(trigger(remaining: 4, stableFor: 600, runway: 1) == nil)
    }

    @Test func theOldTriggersKeepTheirNamesAndTheirBehaviour() {
        // Inside the lead window the settle clock is not consulted at all — a
        // seam that arrives late arrives late, and refusing it for being new
        // would lose the very hand-overs this window exists to catch.
        #expect(trigger(remaining: lead, stableFor: 0, runway: 15) == .lead)
        #expect(trigger(remaining: lead - 1, stableFor: 0, runway: 15) == .lead)
        // Short of the full lead: the seam moved under a finished render, which
        // is what a deadline-committed pick does.
        #expect(trigger(remaining: lead - 3, stableFor: 0, runway: 15) == .late)
        #expect(trigger(remaining: 20, stableFor: 600, runway: 15) == .late)
    }

    @Test func anIdenticalSignatureKeepsTheRenderFinishedOrInFlight() {
        let signature = try! #require(
            TransitionSegment.Signature(plan: .beatMatched(matchedPlan(overlap: 16))))
        // The same plan, rebuilt by value — which is what every one of the 2.9
        // arms per seam is. Both arms of "already have it" hold it.
        let again = try! #require(
            TransitionSegment.Signature(plan: .beatMatched(matchedPlan(overlap: 16))))
        #expect(!PlayerService.stemPrerenderDiscards(held: .running(signature), armed: again))
        #expect(!PlayerService.stemPrerenderDiscards(held: .settled(signature), armed: again))
        // Nothing held is not something to discard either.
        #expect(!PlayerService.stemPrerenderDiscards(held: .idle, armed: again))
    }

    @Test func aSeamThatActuallyMovedIsRenderedAgain() {
        // The other half, and the one that makes the reuse safe: a splice that
        // moved is different audio, and the render in hand is the wrong audio.
        let held = try! #require(
            TransitionSegment.Signature(plan: .beatMatched(matchedPlan(overlap: 16))))
        for moved in [matchedPlan(overlap: 16, outPoint: 121),
                      matchedPlan(overlap: 16, inPoint: 9),
                      matchedPlan(overlap: 20)] {
            let armed = try! #require(TransitionSegment.Signature(plan: .beatMatched(moved)))
            #expect(PlayerService.stemPrerenderDiscards(held: .running(held), armed: armed))
            #expect(PlayerService.stemPrerenderDiscards(held: .settled(held), armed: armed))
        }
    }

    @Test func aSeekThatLandsOnTheSameSeamKeepsTheRenderItParked() {
        // Fix 2, and the exact shape of the field report: the panel's jump to
        // the seam disarms and re-arms one second after a render started, onto
        // a plan that answers `Signature` identically. Nothing moved, so the
        // work in hand — in flight or finished — is the work wanted.
        let signature = try! #require(
            TransitionSegment.Signature(plan: .beatMatched(matchedPlan(overlap: 16))))
        let rearmed = try! #require(
            TransitionSegment.Signature(plan: .beatMatched(matchedPlan(overlap: 16))))
        #expect(PlayerService.prerenderSurvivesReArm(parked: .running(signature),
                                                     rearmed: rearmed))
        #expect(PlayerService.prerenderSurvivesReArm(parked: .settled(signature),
                                                     rearmed: rearmed))
    }

    @Test func aSeekThatMovesTheSeamStillThrowsTheRenderAway() {
        // The safety half. A parked render only survives on an identical
        // signature — a seek that degrades the plan, or that re-arms nothing at
        // all, must not leave stale audio aimed at a splice that changed.
        let held = try! #require(
            TransitionSegment.Signature(plan: .beatMatched(matchedPlan(overlap: 16))))
        for moved in [matchedPlan(overlap: 16, outPoint: 121),
                      matchedPlan(overlap: 16, inPoint: 9),
                      matchedPlan(overlap: 20)] {
            let armed = try! #require(TransitionSegment.Signature(plan: .beatMatched(moved)))
            #expect(!PlayerService.prerenderSurvivesReArm(parked: .running(held),
                                                          rearmed: armed))
        }
        // No re-arm (the plan degraded to gapless, or the prefetch is gone) and
        // nothing parked in the first place: neither is something to keep.
        #expect(!PlayerService.prerenderSurvivesReArm(parked: .running(held), rearmed: nil))
        #expect(!PlayerService.prerenderSurvivesReArm(parked: .idle, rearmed: held))

        // The two rules are each other's complement, which is what makes the
        // rescue safe: whatever a re-arm would have discarded, a seek does too.
        for state in [PlayerService.StemPrerenderState.running(held), .settled(held), .idle] {
            for plan in [matchedPlan(overlap: 16), matchedPlan(overlap: 20)] {
                let armed = try! #require(TransitionSegment.Signature(plan: .beatMatched(plan)))
                #expect(PlayerService.prerenderSurvivesReArm(parked: state, rearmed: armed)
                        != PlayerService.stemPrerenderDiscards(held: state, armed: armed)
                        || state.signature == nil)
            }
        }
    }
}

// MARK: - The field sample of 2026-08-31 (P4 addendum)

/// One seam, one journal line, three separate faults:
///
///     refused — not enough runway (60.0s left, 74.1s needed for a 29.6s overlap)
///
/// with the panel's countdown reading T−01:45 underneath it. The numbers below
/// are that line's, recomputed from the formula rather than pasted, so the
/// tests move if the formula ever does.
@MainActor
@Suite struct StemPrerenderFieldSampleTests {

    /// A `bedIntro`: the incoming deck only, so one side, and the four-stem
    /// checkpoint doubles what that side costs.
    private let overlap: TimeInterval = 29.6
    private var fourLane: TimeInterval {
        PlayerService.stemPrerenderRunway(overlapDuration: overlap, sides: 1, fourLane: true)
    }
    private var twoLane: TimeInterval {
        PlayerService.stemPrerenderRunway(overlapDuration: overlap, sides: 1, fourLane: false)
    }

    @Test func theSampleReproducesItsOwnArithmetic() {
        #expect(abs(twoLane - 44.6) < 0.05)
        #expect(abs(fourLane - 74.2) < 0.05)
        // The shape of the whole problem in one line: the work costs more than
        // the flat window was ever going to offer, so under the old rule the
        // only way in was the settle clock, and a deadline-committed pick
        // spends its life resetting that.
        #expect(fourLane > PlayerService.stemPrerenderLead)
    }

    @Test func theWindowNowOpensWhileTheFourLaneRenderStillFits() {
        let window = PlayerService.stemPrerenderLeadWindow(runway: fourLane)
        #expect(abs(window - (fourLane + PlayerService.stemPrerenderLeadSlack)) < 0.001)
        // Inside its own window, with the plan freshly re-armed and no
        // stability to its name, the render starts. This is the tick the old
        // code did not have.
        #expect(PlayerService.stemPrerenderTrigger(
            remaining: window - 4, stableFor: 0, runway: fourLane) != nil)
        // And 60 s out it still does not fit, which was never in dispute.
        #expect(PlayerService.stemPrerenderTrigger(
            remaining: 60, stableFor: 600, runway: fourLane) == nil)
    }

    @Test func sixtySecondsBuysTwoLanesRatherThanNothing() {
        // Defect A. At the moment of the refusal there were 60 s left and the
        // two-lane bed wanted 44.6 — which is to say the seam was refused for
        // being unable to afford an upgrade, and lost the gesture it *could*
        // afford in the process. Installing the four-stem checkpoint made this
        // seam worse than not having it.
        #expect(PlayerService.stemPrerenderDegradesToTwoLanes(
            remaining: 60, fourLaneRunway: fourLane, twoLaneRunway: twoLane))
        #expect(PlayerService.stemPrerenderTrigger(
            remaining: 60, stableFor: 0, runway: twoLane) == .lead)

        // Not a licence to spend fewer lanes than the seam can pay for: with
        // room for four, four it is, and the wait for the plan to hold still is
        // the settle clock's business, not the lane count's.
        #expect(!PlayerService.stemPrerenderDegradesToTwoLanes(
            remaining: 120, fourLaneRunway: fourLane, twoLaneRunway: twoLane))
        // Below the two-lane bill there is nothing left to shop down to.
        #expect(!PlayerService.stemPrerenderDegradesToTwoLanes(
            remaining: 40, fourLaneRunway: fourLane, twoLaneRunway: twoLane))

        // What the journal and the panel say about it. A bare `lanes=2` would
        // read as "this machine has the vocals model", which is the one thing
        // it does not mean here.
        #expect(PlayerService.stemPrerenderLaneTag(
            separates: true, fourLane: false, degraded: true)
                == "2 (degraded from 4: runway)")
        #expect(PlayerService.stemPrerenderLaneTag(
            separates: true, fourLane: true, degraded: false) == "4")
        #expect(PlayerService.stemPrerenderLaneTag(
            separates: true, fourLane: false, degraded: false) == "2")
        #expect(PlayerService.stemPrerenderLaneTag(
            separates: false, fourLane: true, degraded: false) == "0")
    }

    @Test func theRefusalLiftsWhenTheSeamMovesBackOutOfReach() {
        // Defect B, and the countdown that made it visible: T−01:45 is 105 s,
        // which is ample for a 74.2 s render, and the seam sat refused anyway.
        #expect(PlayerService.stemPrerenderRefusalStands(remaining: 60, runway: fourLane))
        #expect(!PlayerService.stemPrerenderRefusalStands(remaining: 105, runway: fourLane))
        // The boundary is the runway itself: exactly enough is enough, here as
        // everywhere else in this file.
        #expect(!PlayerService.stemPrerenderRefusalStands(remaining: fourLane,
                                                          runway: fourLane))
    }

    @Test func aRefusalIsNeverCarriedAcrossASeek() {
        let signature = try! #require(
            TransitionSegment.Signature(plan: .beatMatched(matchedPlan(overlap: 16))))
        let rearmed = try! #require(
            TransitionSegment.Signature(plan: .beatMatched(matchedPlan(overlap: 16))))
        // The asymmetry with `.running` and `.settled` is the point. Those two
        // park a piece of work that is still the right piece of work. A refusal
        // parks a *clock reading*, and a seek is precisely the event that
        // rewrites it — so it is dropped and the seam is judged again.
        #expect(!PlayerService.prerenderSurvivesReArm(
            parked: .refused(signature, runway: 74.2), rearmed: rearmed))
        #expect(PlayerService.prerenderSurvivesReArm(parked: .settled(signature),
                                                     rearmed: rearmed))
        // It still answers `signature`, so a seam that genuinely moved throws
        // it away by the ordinary rule rather than by this one.
        let moved = try! #require(
            TransitionSegment.Signature(plan: .beatMatched(matchedPlan(overlap: 20))))
        #expect(PlayerService.stemPrerenderDiscards(
            held: .refused(signature, runway: 74.2), armed: moved))
        #expect(!PlayerService.stemPrerenderDiscards(
            held: .refused(signature, runway: 74.2), armed: rearmed))
    }

    @Test func theWidestSeamStillDecidesInsideThePickDeadline() {
        // Why the 120 s decision lead does not have to move for any of this:
        // the window is bounded by the widest render that can exist, and that
        // bound is 90 s. `updateAutoMixPick` commits at 120 s, so the winner is
        // always known before its own window opens — and the pick deadline
        // keeps budgeting downloads on its own terms.
        let widest = PlayerService.stemPrerenderRunway(
            overlapDuration: TransitionSegmentRenderer.maxOverlap, sides: 2)
        let bed = PlayerService.stemPrerenderRunway(
            overlapDuration: TransitionSegmentRenderer.maxOverlap, sides: 1, fourLane: true)
        #expect(bed == widest)
        #expect(PlayerService.stemPrerenderLeadWindow(runway: widest) == 90)
        #expect(PlayerService.stemPrerenderLeadWindow(runway: widest) < 120)
    }
}

// MARK: - The grid self-check, in two layers

/// The recalibration of `ScoreCompiler`'s grid self-check: a loose window
/// backstop for "this is not a bar grid", and a strict anchor-local check on
/// the downbeats that actually carry events.
///
/// The layers are tested apart because the bug being fixed was that there was
/// only one of them. A single window statistic cannot see a mis-detected
/// downbeat — the tests below synthesize two kinds and the window reads 0 %
/// jitter through both — and it fires on window-wide wobble that never moves a
/// cut, because every event here is anchored on a *measured* downbeat rather
/// than extrapolated from a bar length.
@Suite struct ScoreGridSelfCheckTests {

    /// An analysis with the two grids given explicitly, so a test can make them
    /// disagree. `ScoreFixtures.analysis` derives downbeats from beats — which
    /// is what the shipping analyzer does, and therefore exactly what cannot
    /// express the fault this check exists for.
    static func analysis(beats: [TimeInterval], downbeats: [TimeInterval],
                         bpm: Double = 120, duration: TimeInterval = 30) -> TrackAnalysis {
        TrackAnalysis(
            version: TrackAnalysis.currentVersion, bpm: bpm, bpmConfidence: 0.95,
            beats: beats, downbeats: downbeats, phraseBoundaries: downbeats,
            rmsEnvelope: [Float](repeating: 0.5, count: Int(duration)),
            outroFadeStart: nil, introEnd: 0, duration: duration,
            melProfile: [], keyPitchClass: nil, keyIsMinor: false, keyConfidence: 0,
            vocalActivity: [Float](repeating: 0.5, count: Int(duration)))
    }

    /// A clean 120 BPM grid: a beat every 0.5 s, a downbeat every 2 s.
    static func clean(duration: TimeInterval = 30)
    -> (beats: [TimeInterval], downbeats: [TimeInterval]) {
        let beats = stride(from: 0.0, to: duration, by: 0.5).map { $0 }
        return (beats, stride(from: 0, to: beats.count, by: 4).map { beats[$0] })
    }

    /// `matchedPlan()` puts the swap 8 s into a 16 s overlap and the incoming
    /// in point at 0, so the seam lands on the incoming downbeat at 8 s —
    /// index 4, whose flanking bars are `[6, 8]` and `[8, 10]`.
    static func compileCut(outgoing: TrackAnalysis,
                           incoming: TrackAnalysis) -> ScoreCompiler.Compilation {
        let planned = PlannedTransition(plan: .beatMatched(matchedPlan()),
                                        style: scoredStyle(.cutOnOne()))
        return ScoreCompiler.compile(.cutOnOne(), planned: planned,
                                     outgoing: outgoing, incoming: incoming,
                                     outgoingURL: nil)
    }

    // MARK: The relaxation this recalibration is for

    @Test func aWobblyWindowWithASoundAnchorNowCompiles() throws {
        // The field case, and the whole point of splitting the check: a window
        // that reads ~5 % because a bar three bars from the cut is long, while
        // the bar line the cut actually lands on is exact.
        //
        // The old single check refused this at 3 % and refused essentially
        // every score-eligible seam with it. Nothing about the cut is worse
        // here than on a metronomic grid — `place` reads
        // `inDownbeats[seamIndex]`, which is 8.0 either way.
        let drifting = ScoreFixtures.analysis(bpm: 120, jitterAt: 24, jitter: 0.10)
        let c = Self.compileCut(outgoing: ScoreFixtures.analysis(bpm: 120),
                                incoming: drifting)
        #expect(c.didCompile, "\(c.refusalReason ?? "")")
        #expect(abs(c.seamIncoming - 8) < 1e-6)

        // …and the window really is jittery enough that the old cap would have
        // thrown it away, so this is testing the relaxation and not the absence
        // of a fault.
        let jitter = try #require(ScoreCompiler.worstJitter(
            drifting.downbeats, around: 8, bars: ScoreCompiler.gridCheckBars))
        #expect(jitter > 0.03 && jitter < ScoreCompiler.gridJitterTolerance,
                "window CV \(jitter)")
    }

    // MARK: The backstop

    @Test func theBackstopStillRefusesAGridThatIsNotOne() {
        // 12.5 % of a bar, four bars from the cut. Past the point where the
        // detector is describing bars at all, and the layer that says so names
        // itself.
        let broken = ScoreFixtures.analysis(bpm: 120, jitterAt: 24, jitter: 0.25)
        let c = Self.compileCut(outgoing: ScoreFixtures.analysis(bpm: 120),
                                incoming: broken)
        #expect(!c.didCompile)
        let reason = c.refusalReason ?? ""
        #expect(reason.contains("[backstop]"), "\(reason)")
        #expect(!reason.contains("[anchor]"), "\(reason)")
    }

    @Test func theBackstopFiresExactlyAtItsCap() {
        // The cap is a number in a comment until something pins it. Just under
        // compiles, just over does not — scaled off the constant itself, so the
        // test cannot drift away from the check.
        let bar = 2.0
        for (jitter, shouldCompile) in [(ScoreCompiler.gridJitterTolerance * 0.9, true),
                                        (ScoreCompiler.gridJitterTolerance * 1.1, false)] {
            let grid = ScoreFixtures.analysis(bpm: 120, jitterAt: 24, jitter: jitter * bar)
            let c = Self.compileCut(outgoing: ScoreFixtures.analysis(bpm: 120), incoming: grid)
            #expect(c.didCompile == shouldCompile,
                    "at \(jitter * 100) %: \(c.refusalReason ?? "compiled")")
        }
    }

    // MARK: The anchor — a downbeat the beat grid disagrees with

    @Test func aDownbeatGridHalfABeatOutOfPhaseIsCaught() {
        // **The one unforgivable error, and the one a window statistic is
        // blind to.** Every downbeat is shifted half a beat off the beats. The
        // bar lengths are all still exactly 2 s, so the backstop reads 0 %
        // jitter and has nothing to say; the cut would land squarely on the
        // and-of-four.
        //
        // Today's analyzer cannot produce this — it takes every fourth beat, so
        // the two grids agree by construction — which is the point: this fails
        // closed on a corrupt sidecar and on the first analyzer that detects
        // downbeats independently instead of deriving them.
        let (beats, downbeats) = Self.clean()
        let outOfPhase = Self.analysis(beats: beats, downbeats: downbeats.map { $0 + 0.25 })
        #expect(ScoreCompiler.worstJitter(outOfPhase.downbeats, around: 8,
                                          bars: ScoreCompiler.gridCheckBars) ?? 1 < 1e-9,
                "the window has to be clean, or this tests the wrong layer")

        let c = Self.compileCut(outgoing: ScoreFixtures.analysis(bpm: 120),
                                incoming: outOfPhase)
        #expect(!c.didCompile)
        let reason = c.refusalReason ?? ""
        #expect(reason.contains("[anchor]"), "\(reason)")
        #expect(reason.contains("半拍"), "\(reason)")
    }

    @Test func aBarHoldingFiveBeatsIsCaught() {
        // The other way the grids can disagree while every bar stays 2 s long:
        // the tracker put five beats in the bar the cut lands on. The downbeat
        // still coincides with a beat, so the phase check passes and the meter
        // check is the one that has to fire.
        let (beats, downbeats) = Self.clean()
        let miscounted = Self.analysis(beats: (beats + [8.25]).sorted(),
                                       downbeats: downbeats)
        #expect(ScoreCompiler.worstJitter(miscounted.downbeats, around: 8,
                                          bars: ScoreCompiler.gridCheckBars) ?? 1 < 1e-9)

        let c = Self.compileCut(outgoing: ScoreFixtures.analysis(bpm: 120),
                                incoming: miscounted)
        #expect(!c.didCompile)
        let reason = c.refusalReason ?? ""
        #expect(reason.contains("[anchor]"), "\(reason)")
        #expect(reason.contains("5 拍"), "\(reason)")
    }

    // MARK: The anchor — a beat interval that skipped

    @Test func aBeatIntervalOutlierAtTheAnchorIsCaught() {
        // Four beats in the bar, on an evenly spaced downbeat grid, but the
        // tracker clearly lost one: 0.9 s then 0.1 s where 0.5 s belongs. Every
        // other check passes and the window reads exactly 0 %.
        let (beats, downbeats) = Self.clean()
        let skipped = Self.analysis(beats: beats.map { $0 == 8.5 ? 8.9 : $0 },
                                    downbeats: downbeats)
        #expect(ScoreCompiler.worstJitter(skipped.downbeats, around: 8,
                                          bars: ScoreCompiler.gridCheckBars) ?? 1 < 1e-9)

        let c = Self.compileCut(outgoing: ScoreFixtures.analysis(bpm: 120),
                                incoming: skipped)
        #expect(!c.didCompile)
        let reason = c.refusalReason ?? ""
        #expect(reason.contains("[anchor]"), "\(reason)")
        #expect(reason.contains("拍间隔"), "\(reason)")
    }

    @Test func theAnchorCheckLooksAtTheAnchorAndNotTheNeighbourhood() {
        // The same skipped beat, four bars from the cut instead of on it. The
        // anchor is sound, so the score compiles — a check that refused this
        // would be the window check again under another name.
        let (beats, downbeats) = Self.clean()
        let c = Self.compileCut(
            outgoing: ScoreFixtures.analysis(bpm: 120),
            incoming: Self.analysis(beats: beats.map { $0 == 16.5 ? 16.9 : $0 },
                                    downbeats: downbeats))
        #expect(c.didCompile, "\(c.refusalReason ?? "")")
    }

    @Test func aCleanGridPassesBothLayers() {
        let (beats, downbeats) = Self.clean()
        let c = Self.compileCut(outgoing: ScoreFixtures.analysis(bpm: 120),
                                incoming: Self.analysis(beats: beats, downbeats: downbeats))
        #expect(c.didCompile, "\(c.refusalReason ?? "")")
    }

    // MARK: Which layer fired

    @Test func everyGridRefusalNamesItsLayer() {
        // A report that only says "the grid was bad" leaves the reader unable
        // to tell a broken detector from one mis-placed bar line, which are
        // different problems with different answers.
        let (beats, downbeats) = Self.clean()
        let cases: [(String, TrackAnalysis)] = [
            ("[backstop]", ScoreFixtures.analysis(bpm: 120, jitterAt: 24, jitter: 0.25)),
            ("[anchor]", Self.analysis(beats: beats,
                                       downbeats: downbeats.map { $0 + 0.25 })),
        ]
        for (layer, incoming) in cases {
            let c = Self.compileCut(outgoing: ScoreFixtures.analysis(bpm: 120),
                                    incoming: incoming)
            #expect(!c.didCompile)
            #expect(c.refusalReason?.hasPrefix(layer) == true, "\(c.refusalReason ?? "")")
        }
    }

    // MARK: The anchor helper, directly

    @Test func theAnchorToleranceIsAFractionOfTheHalfBeatItGuards() {
        // The derivation, asserted rather than described. A downbeat detected
        // `δ` off shortens one flanking bar by `δ` and lengthens the other by
        // `δ`, so the disagreement is `2δ/bar` — half a beat (bar/8) reads
        // 25 %, and the tolerance is set at an eighth of a beat, 4× inside it.
        let bar = 2.0
        #expect(abs(ScoreCompiler.anchorFlankTolerance - 2.0 / 32) < 1e-12)
        #expect(2 * (bar / 8) / bar / ScoreCompiler.anchorFlankTolerance == 4)

        // And it reads that displacement back off a grid: a downbeat moved by
        // an eighth of a beat is inside the line, a quarter-beat is over it.
        //
        // Moved *earlier*, so that the flank check is what answers. A downbeat
        // dragged the same distance the other way slides past the beat it sits
        // on and puts five beats in the bar behind it, which the meter check
        // catches first — the layers overlap in the direction of a real fault,
        // which is the right way round, but it makes for a poor unit test of
        // either one.
        let (beats, _) = Self.clean()
        for (shift, faulted) in [(bar / 32 * 0.9, false), (bar / 16, true)] {
            var downbeats = stride(from: 0.0, to: 30.0, by: 2).map { $0 }
            downbeats[4] -= shift
            let fault = ScoreCompiler.anchorFault(
                downbeats: downbeats, beats: beats, index: 4,
                flankTolerance: ScoreCompiler.anchorFlankTolerance)
            #expect((fault != nil) == faulted, "shift \(shift): \(fault ?? "sound")")
        }
    }

    @Test func aGridTooShortToJudgeIsNotAFault() {
        // The score's span is checked against both grids before the anchors
        // are, so a missing neighbour here means "the first or last bar of the
        // track", not "a bad anchor". Inventing a refusal out of absent
        // evidence is the failure mode this whole recalibration is about.
        let (beats, downbeats) = Self.clean()
        #expect(ScoreCompiler.anchorFault(downbeats: downbeats, beats: beats, index: 0,
                                          flankTolerance: 0.0625) == nil)
        #expect(ScoreCompiler.anchorFault(downbeats: downbeats, beats: [], index: 4,
                                          flankTolerance: 0.0625) == nil)
        #expect(ScoreCompiler.anchorFault(downbeats: [], beats: beats, index: 0,
                                          flankTolerance: 0.0625) == nil)
    }

    @Test func aDecoratingScoreIsLoosenedOnTheAnchorAndNotTheBackstop() {
        // P4's relaxation, moved onto the layer that carries cut-grade
        // precision. A bed does not need the cut's tolerance at its landing —
        // but a bar grid the detector has lost is no better a place for a bed
        // than for a cut, so the backstop is not doubled for anybody.
        #expect(ScoreCompiler.decoratingJitterMultiple == 2)
        #expect(ScoreCompiler.anchorFlankTolerance * ScoreCompiler.decoratingJitterMultiple
                < 2 * (2.0 / 8) / 2.0, "a doubled anchor line must stay inside a half beat")
    }
}
