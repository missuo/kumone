import AVFoundation
import Foundation
import Testing

@testable import KumoneCore

// The four-lane orchestration layer: the contract, the `vocalExchange`
// template that compiles into it, and the renderer path that plays it on both
// decks at once.
//
// Same discipline as `StemTechniqueTests`: no model anywhere. The "separation"
// is a stub that hands back a vocal it knows is there, so every assertion is
// about the orchestration rather than about how well a RoFormer finds a singer.
@Suite struct StemEnvelopeTests {

    // MARK: - The contract

    @Test func emptyLanesArePassThrough() {
        let envelope = StemEnvelope()
        #expect(envelope.isPassThrough)
        for lane in StemEnvelope.Lane.allCases {
            #expect(envelope.gainDB(lane, at: 0) == 0)
            #expect(envelope.gainDB(lane, at: 5) == 0)
            #expect(envelope.gain(lane, at: 5) == 1)
        }
    }

    /// A lane written entirely at 0 dB is still pass-through: it changes no
    /// audio, so its side must not be separated for it.
    @Test func allZeroLaneIsStillPassThrough() {
        var envelope = StemEnvelope()
        envelope.incomingBed = [.init(t: 0, gainDB: 0), .init(t: 8, gainDB: 0)]
        #expect(envelope.isPassThrough(.incomingBed))
        #expect(envelope.isPassThrough)
        envelope.incomingVocal = [.init(t: 0, gainDB: -1)]
        #expect(!envelope.isPassThrough(.incomingVocal))
        #expect(!envelope.isPassThrough)
    }

    @Test func gainInterpolatesInDecibelsAndClampsOutside() {
        var envelope = StemEnvelope()
        envelope.outgoingVocal = [
            .init(t: 2, gainDB: 0),
            .init(t: 6, gainDB: -20),
            .init(t: 8, gainDB: -20),
        ]
        // Outside the range, the endpoints hold — not silence, not a ramp to 0.
        #expect(envelope.gainDB(.outgoingVocal, at: 0) == 0)
        #expect(envelope.gainDB(.outgoingVocal, at: 2) == 0)
        #expect(envelope.gainDB(.outgoingVocal, at: 12) == -20)
        // Linear *in dB*: halfway between 0 and −20 dB is −10 dB, which is
        // 0.316 in amplitude, not 0.5.
        #expect(abs(envelope.gainDB(.outgoingVocal, at: 4) - (-10)) < 1e-4)
        #expect(abs(envelope.gain(.outgoingVocal, at: 4) - 0.31623) < 1e-4)
        #expect(abs(envelope.gainDB(.outgoingVocal, at: 3) - (-5)) < 1e-4)
    }

    @Test func aSinglePointLaneIsAFlatHold() {
        var envelope = StemEnvelope()
        envelope.outgoingBed = [.init(t: 4, gainDB: -9)]
        #expect(envelope.gainDB(.outgoingBed, at: 0) == -9)
        #expect(envelope.gainDB(.outgoingBed, at: 40) == -9)
    }

    @Test func signatureIsStableAndDistinguishing() {
        var a = StemEnvelope()
        a.outgoingVocal = [.init(t: 0, gainDB: 0), .init(t: 9, gainDB: -40)]
        var b = a
        b.outgoingVocal[1].gainDB = -39
        #expect(a.signature == a.signature)
        #expect(a.signature != b.signature)
        #expect(StemTechnique.custom(a).label == "custom(\(a.signature))")
    }

    // MARK: - Validation boundaries

    private func point(_ t: TimeInterval, _ db: Float) -> StemEnvelope.Breakpoint {
        .init(t: t, gainDB: db)
    }

    @Test func validationAcceptsTheEdgesOfEveryRange() throws {
        var envelope = StemEnvelope()
        envelope.outgoingVocal = [point(0, StemEnvelope.maxGainDB),
                                  point(10, StemEnvelope.minGainDB)]
        // Repeated times are fine (a step); only going *backwards* is not.
        envelope.outgoingBed = [point(0, 0), point(5, -9), point(5, -30), point(10, -30)]
        envelope.incomingBed = (0..<StemEnvelope.maxBreakpoints).map {
            point(Double($0) * 10 / Double(StemEnvelope.maxBreakpoints - 1), 0)
        }
        try envelope.validate(overlap: 10)
    }

    @Test func validationRejectsTimesOutsideTheOverlap() {
        var envelope = StemEnvelope()
        envelope.incomingVocal = [point(0, 0), point(10.5, -20)]
        #expect(throws: StemEnvelope.ValidationFailure.timeOutOfRange(
            lane: "inVocal", t: 10.5, overlap: 10)) {
            try envelope.validate(overlap: 10)
        }
    }

    @Test func validationRejectsBackwardsTime() {
        var envelope = StemEnvelope()
        envelope.outgoingBed = [point(0, 0), point(6, -9), point(3, -30)]
        #expect(throws: StemEnvelope.ValidationFailure.timeNotMonotonic(
            lane: "outBed", previous: 6, t: 3)) {
            try envelope.validate(overlap: 10)
        }
    }

    @Test func validationRejectsGainsOutsideTheRange() {
        var tooLoud = StemEnvelope()
        tooLoud.outgoingVocal = [point(0, 7)]
        #expect(throws: StemEnvelope.ValidationFailure.gainOutOfRange(
            lane: "outVocal", gainDB: 7)) { try tooLoud.validate(overlap: 10) }

        var tooQuiet = StemEnvelope()
        tooQuiet.outgoingVocal = [point(0, -61)]
        #expect(throws: StemEnvelope.ValidationFailure.gainOutOfRange(
            lane: "outVocal", gainDB: -61)) { try tooQuiet.validate(overlap: 10) }
    }

    @Test func validationRejectsTooManyBreakpoints() {
        var envelope = StemEnvelope()
        envelope.incomingBed = (0...StemEnvelope.maxBreakpoints).map { point(Double($0) * 0.5, 0) }
        #expect(throws: StemEnvelope.ValidationFailure.tooManyBreakpoints(
            lane: "inBed", count: StemEnvelope.maxBreakpoints + 1)) {
            try envelope.validate(overlap: 10)
        }
    }

    // MARK: - The JSON spelling

    @Test func jsonEnvelopeParses() throws {
        let raw: [String: Any] = [
            "outVocal": [[0, 0], [9, 0], [10, -40]],
            "inBed": [[0, -6], [8, 0]],
            "inVocal": NSNull(),
        ]
        let envelope = try Audition.StemEnvelopeInput.parse(raw)
        #expect(envelope.outgoingVocal.count == 3)
        #expect(envelope.outgoingVocal[2] == point(10, -40))
        #expect(envelope.incomingBed == [point(0, -6), point(8, 0)])
        // Omitted and null lanes are pass-through, not silence.
        #expect(envelope.isPassThrough(.incomingVocal))
        #expect(envelope.isPassThrough(.outgoingBed))
    }

    /// The long lane names are accepted too, so a reply that echoes the Swift
    /// spelling back is not thrown away over a synonym.
    @Test func jsonEnvelopeAcceptsBothLaneSpellings() throws {
        let envelope = try Audition.StemEnvelopeInput.parse(["outgoingBed": [[0, -3]]])
        #expect(envelope.outgoingBed == [point(0, -3)])
    }

    @Test func jsonEnvelopeRejectsMalformedInput() {
        #expect(throws: Audition.StemEnvelopeInput.Failure.unknownLane("vocals")) {
            try Audition.StemEnvelopeInput.parse(["vocals": [[0, 0]]])
        }
        #expect(throws: Audition.StemEnvelopeInput.Failure.laneNotAnArray(lane: "outBed")) {
            try Audition.StemEnvelopeInput.parse(["outBed": 3])
        }
        #expect(throws: Audition.StemEnvelopeInput.Failure.self) {
            try Audition.StemEnvelopeInput.parse(["outBed": [[0, 0, 1]]])
        }
        #expect(throws: Audition.StemEnvelopeInput.Failure.self) {
            try Audition.StemEnvelopeInput.parse(["outBed": [[0, "loud"]]])
        }
        #expect(throws: Audition.StemEnvelopeInput.Failure.notAnObject(given: "12")) {
            try Audition.StemEnvelopeInput.parse(12)
        }
        // Range and order are judged at parse time; only *time bounds* wait for
        // the overlap, which is not known yet.
        #expect(throws: StemEnvelope.ValidationFailure.self) {
            try Audition.StemEnvelopeInput.parse(["outVocal": [[0, -80]]])
        }
        #expect(throws: StemEnvelope.ValidationFailure.self) {
            try Audition.StemEnvelopeInput.parse(["outVocal": [[5, 0], [1, 0]]])
        }
        // …and a time of 900 s parses, because only `decide` knows the overlap.
        #expect(throws: Never.self) {
            try Audition.StemEnvelopeInput.parse(["outVocal": [[900, 0]]])
        }
    }

    @Test func stemAndStemEnvelopeAreMutuallyExclusive() {
        let message = Audition.StemEnvelopeInput.Failure.conflictsWithStem.errorDescription ?? ""
        #expect(message.contains("stemEnvelope"))
        #expect(message.contains("exchange"))
    }

    @Test func exchangeIsAPickableStemOverride() {
        #expect(Audition.StemOverride.parse("exchange") == .exchange)
        #expect(Audition.StemOverride.parse("vocalExchange") == .exchange)
        #expect(Audition.StemOverride.names.contains("exchange"))
        #expect(Audition.StemOverride.exchange.technique == .vocalExchange)
        #expect(StemTechnique.vocalExchange.label == "vocalExchange")
    }

    // MARK: - Compiling `vocalExchange`

    private func analysis(duration: TimeInterval, vocalActivity: [Float]) -> TrackAnalysis {
        TrackAnalysis(version: TrackAnalysis.currentVersion, bpm: 120, bpmConfidence: 0.9,
                      beats: [], downbeats: [], phraseBoundaries: [],
                      rmsEnvelope: [Float](repeating: 0.5, count: Int(duration)),
                      outroFadeStart: nil, introEnd: 0, duration: duration,
                      melProfile: [], keyPitchClass: nil, keyIsMinor: false,
                      keyConfidence: 0, vocalActivity: vocalActivity)
    }

    /// A `.lrc` written next to a path that need not hold any audio: the
    /// compiler only ever reads the sidecar.
    private func withLyrics(_ lrc: String, _ body: (URL) -> Void) {
        let track = FileManager.default.temporaryDirectory
            .appendingPathComponent("exchange-\(UUID().uuidString).flac")
        let sidecar = Audition.Lyrics.sidecarURL(for: track)
        try? Data(lrc.utf8).write(to: sidecar)
        defer { try? FileManager.default.removeItem(at: sidecar) }
        body(track)
    }

    private func crossfade(outPoint: TimeInterval, overlap: TimeInterval) -> PlannedTransition {
        PlannedTransition(plan: .crossfade(duration: overlap, outPoint: outPoint, inPoint: 0),
                          style: .plain)
    }

    /// The single-clock behaviour, pinned: the hand-over lands where a lyric
    /// line ends, picking the end nearest the middle of the overlap.
    ///
    /// This is what `twoClockExchange = false` still compiles, field for field.
    /// With the knob on its default the same `.lrc` gives 10 s instead — the
    /// line-end just past the 6 s floor swap — which is the whole point of the
    /// two clocks and is pinned separately below.
    @Test func exchangeLandsOnTheLyricLineEndNearestTheMiddle() {
        let lrc = """
        [01:36.00]第一句
        [01:40.00]第二句
        [01:45.00]第三句
        [01:50.00]第四句
        """
        withLyrics(lrc) { track in
            let a = analysis(duration: 200,
                             vocalActivity: [Float](repeating: 0.8, count: 200))
            let (technique, compiled) = Audition.VocalExchange.compile(
                outgoingURL: track, outgoing: a,
                planned: crossfade(outPoint: 100, overlap: 12),
                config: twoClockConfig(on: false))
            // Ends inside [100, 112] are 100, 105 and 110; the middle is 106,
            // so 105 wins — the singer finishes 第二句 and hands over.
            #expect(abs(compiled.handover - 5) < 1e-6)
            #expect(abs(compiled.handoverAbsolute - 105) < 1e-6)
            #expect(compiled.source == "lyric")
            #expect(compiled.lyricLine == "第二句")
            #expect(compiled.clampedFrom == nil)
            #expect(compiled.fallbackReason == nil)
            guard case .custom(let envelope) = technique else {
                Issue.record("expected a compiled envelope")
                return
            }
            #expect(envelope == compiled.envelope)
        }
    }

    /// A line-end too near the top of the overlap is pulled into the window
    /// rather than accepted: before 30 % the incoming bed has not arrived.
    @Test func exchangeClampsAnEarlyLineEndIntoTheWindow() {
        let lrc = """
        [01:38.00]倒数第二句
        [01:41.00]最后一句
        """
        withLyrics(lrc) { track in
            let a = analysis(duration: 200,
                             vocalActivity: [Float](repeating: 0.8, count: 200))
            let (_, compiled) = Audition.VocalExchange.compile(
                outgoingURL: track, outgoing: a,
                planned: crossfade(outPoint: 100, overlap: 12),
                config: .standard)
            // The only end inside [100, 112] is 101 (rel 1); the floor is
            // 0.30 × 12 = 3.6 s.
            #expect(abs(compiled.handover - 3.6) < 1e-6)
            #expect(abs((compiled.clampedFrom ?? 0) - 1) < 1e-6)
            #expect(compiled.source == "lyric")
        }
    }

    /// No `.lrc` at all: the vocal contour's quietest mid-overlap second is the
    /// same question asked of a different signal.
    @Test func exchangeFallsBackToTheVocalTroughWithoutLyrics() {
        var contour = [Float](repeating: 0.9, count: 200)
        contour[107] = 0.05                       // the gap between two phrases
        let a = analysis(duration: 200, vocalActivity: contour)
        let track = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-lyrics-\(UUID().uuidString).flac")

        let (technique, compiled) = Audition.VocalExchange.compile(
            outgoingURL: track, outgoing: a,
            planned: crossfade(outPoint: 100, overlap: 12), config: .standard)
        #expect(compiled.source == "vocalTrough")
        #expect(abs(compiled.handover - 7) < 1e-6)
        #expect(compiled.lyricLine == nil)
        #expect(compiled.fallbackReason == nil)
        if case .custom = technique {} else { Issue.record("expected a compiled envelope") }
    }

    /// Neither lyrics nor a contour: degrade to the duck, and say so. The
    /// degradation is the one thing that must never be silent.
    @Test func exchangeDegradesToADuckWhenItCannotAim() {
        let a = analysis(duration: 200, vocalActivity: [])
        let track = FileManager.default.temporaryDirectory
            .appendingPathComponent("blind-\(UUID().uuidString).flac")
        let (technique, compiled) = Audition.VocalExchange.compile(
            outgoingURL: track, outgoing: a,
            planned: crossfade(outPoint: 100, overlap: 12), config: .standard)
        #expect(technique == .vocalDuck(
            depthDB: -Float(TransitionPlanner.Config.standard.stemDuckDepthDB)))
        #expect(compiled.source == "duck")
        #expect(compiled.envelope == nil)
        #expect(compiled.fallbackReason?.contains("vocal duck") == true)
    }

    /// An overlap too short to schedule anything in also degrades rather than
    /// producing a curve nobody could hear.
    @Test func exchangeDegradesOnATinyOverlap() {
        let a = analysis(duration: 200, vocalActivity: [Float](repeating: 0.8, count: 200))
        let track = FileManager.default.temporaryDirectory
            .appendingPathComponent("tiny-\(UUID().uuidString).flac")
        let (technique, compiled) = Audition.VocalExchange.compile(
            outgoingURL: track, outgoing: a,
            planned: crossfade(outPoint: 100, overlap: 0.8), config: .standard)
        if case .vocalDuck = technique {} else { Issue.record("expected a duck") }
        #expect(compiled.fallbackReason != nil)
    }

    // MARK: - The template's shape

    private func template(overlap: TimeInterval, handover: TimeInterval) -> StemEnvelope {
        let plan = TransitionPlan.crossfade(duration: overlap, outPoint: 100, inPoint: 0)
        return Audition.VocalExchange.template(
            overlap: overlap, handover: handover, plan: plan, style: .plain,
            geometry: TransitionAutomation.Geometry(plan: plan))
    }

    @Test func templateIsAlwaysAValidEnvelope() throws {
        for overlap in [5.0, 12.0, 16.0, 30.0] {
            for share in [0.30, 0.5, 0.6, 0.85] {
                try template(overlap: overlap, handover: overlap * share)
                    .validate(overlap: overlap)
            }
        }
    }

    /// The four movements of the template, in order: the incoming bed arrives
    /// first, the outgoing bed leaves early, the outgoing vocal holds its line
    /// to the hand-over, and the incoming vocal is silent until it.
    @Test func templateSchedulesOneVocalAtATime() {
        let overlap = 12.0, h = 7.0
        let e = template(overlap: overlap, handover: h)

        // Before the hand-over: the outgoing vocal is at or above the mix
        // level, the incoming one is inaudible.
        for t in [0.0, 2.0, 4.0, 6.5] {
            #expect(e.gainDB(.outgoingVocal, at: t) >= -0.01)
            #expect(e.gainDB(.incomingVocal, at: t) <= -30)
        }
        // After it, exactly the other way round.
        #expect(e.gainDB(.outgoingVocal, at: h + 0.8) <= -40)
        #expect(e.gainDB(.outgoingVocal, at: overlap) <= -40)
        #expect(e.gainDB(.incomingVocal, at: h + 1.0) >= -0.01)

        // The beds cross over: the outgoing one steps back before the hand-over
        // and only collapses once the vocal it was holding up has gone, while
        // the incoming one is back at its own level before the swap.
        #expect(abs(e.gainDB(.outgoingBed, at: 0)) < 1e-6)
        #expect(e.gainDB(.outgoingBed, at: h * 0.4) <= -2.9)
        #expect(e.gainDB(.outgoingBed, at: h) <= -7.9)
        #expect(e.gainDB(.outgoingBed, at: h) >= -9)      // still a floor, not silence
        #expect(e.gainDB(.outgoingBed, at: h + 0.8) <= -29.9)
        #expect(e.gainDB(.outgoingBed, at: overlap) <= -39.9)
        // The incoming bed enters at its own level, is lifted while it alone
        // holds the middle up, and is released once the new vocal lands on it.
        #expect(abs(e.gainDB(.incomingBed, at: 0)) < 1e-6)
        #expect(e.gainDB(.incomingBed, at: h * 0.5) >= 2.9)
        #expect(e.gainDB(.incomingBed, at: h) >= 2.9)
        #expect(abs(e.gainDB(.incomingBed, at: h + 1.0)) < 1e-6)
        #expect(abs(e.gainDB(.incomingBed, at: overlap)) < 1e-6)
    }

    /// The vocal lanes carry the inverse of the fader they will be multiplied
    /// by, so the outgoing singer finishes the line at a constant *audible*
    /// level instead of receding through an equal-power fade.
    @Test func templateCompensatesTheFadeItRidesOn() {
        let overlap = 12.0, h = 7.0
        let plan = TransitionPlan.crossfade(duration: overlap, outPoint: 100, inPoint: 0)
        let geometry = TransitionAutomation.Geometry(plan: plan)
        let e = template(overlap: overlap, handover: h)

        var levels: [Float] = []
        for t in stride(from: 0.0, through: h - 0.01, by: 0.5) {
            let fader = TransitionAutomation.frame(plan: plan, style: .plain,
                                                   elapsed: t, geometry: geometry).outgoing.fader
            levels.append(e.gain(.outgoingVocal, at: t) * fader)
        }
        // Equal power over 7/12 of the overlap only drops the fader to 0.62,
        // which the +6 dB ceiling covers comfortably: the audible level holds
        // within a decibel across the whole hold.
        let ratio = Double(levels.max()! / levels.min()!)
        #expect(ratio < 1.13)
        #expect(e.gainDB(.outgoingVocal, at: 0) == 0)
        #expect(e.gainDB(.outgoingVocal, at: h - 0.01) > 3)
        #expect(e.outgoingVocal.allSatisfy { $0.gainDB <= StemEnvelope.maxGainDB })
    }

    // MARK: - Two clocks

    // Every case below runs on a 12 s crossfade from 100 s, whose floor swap
    // `Geometry` puts at S = 6.0 and whose share clamp is [3.6, 10.2]. The
    // whole point of the feature is that L is chosen against S rather than
    // against the middle of the overlap, so each test names both.

    private func twoClockConfig(on: Bool = true,
                                carryWindow: TimeInterval = 8) -> TransitionPlanner.Config {
        var c = TransitionPlanner.Config.standard
        c.twoClockExchange = on
        c.vocalCarryWindowSeconds = carryWindow
        return c
    }

    /// Line-ends at 4, 9 and 11 s into the overlap. Only 9 is inside
    /// `(S, S + carryWindow]` clamped to the share ceiling — so the singer
    /// carries three seconds past the floor swap and finishes the line there.
    ///
    /// The single-clock rule would have taken 4 (nearest the 6 s middle), which
    /// is the same seam heard as a mix rather than a move: the contrast is the
    /// feature.
    private static let carryoverLRC = """
    [01:40.00]第一句
    [01:44.00]第二句
    [01:49.00]第三句
    [01:51.00]第四句
    """

    @Test func twoClockCarriesTheVocalPastTheFloorSwap() {
        withLyrics(Self.carryoverLRC) { track in
            let a = analysis(duration: 200,
                             vocalActivity: [Float](repeating: 0.8, count: 200))
            let (technique, compiled) = Audition.VocalExchange.compile(
                outgoingURL: track, outgoing: a,
                planned: crossfade(outPoint: 100, overlap: 12),
                config: twoClockConfig())

            #expect(compiled.gesture == .carryover)
            #expect(abs(compiled.swapOffset - 6) < 1e-6)
            #expect(abs(compiled.handover - 9) < 1e-6)      // 3 s past the swap
            #expect(compiled.lyricLine == "第二句")
            #expect(compiled.source == "lyric")
            #expect(compiled.clampedFrom == nil)
            guard case .custom(let e) = technique else {
                Issue.record("expected a compiled envelope")
                return
            }
            #expect((try? e.validate(overlap: 12)) != nil)

            // The beds keep the *floor* clock: the outgoing bed is already down
            // at its hand-over level by S and stays there, and the incoming bed
            // is fully lifted by S because from S on it is the only bed under
            // the carried singer.
            #expect(e.gainDB(.outgoingBed, at: 6) <= -7.9)
            #expect(e.gainDB(.outgoingBed, at: 9) <= -7.9)
            #expect(e.gainDB(.incomingBed, at: 6) >= 2.9)
            #expect(e.gainDB(.incomingBed, at: 9) >= 2.9)

            // The vocal keeps its own: still up at the swap, still up two
            // seconds past it, gone only after L.
            #expect(e.gainDB(.outgoingVocal, at: 6) >= 0)
            #expect(e.gainDB(.outgoingVocal, at: 8) >= 0)
            #expect(e.gainDB(.outgoingVocal, at: 9.8) <= -40)
        }
    }

    /// The same `.lrc` as `exchangeLandsOnTheLyricLineEndNearestTheMiddle`,
    /// which pins the single-clock answer at 5 s: with the two clocks the
    /// singer instead carries four seconds past the floor swap to finish 第三句.
    /// One sidecar, one knob, two different musical gestures.
    @Test func theSameLyricsGiveADifferentHandOverUnderTwoClocks() {
        let lrc = """
        [01:36.00]第一句
        [01:40.00]第二句
        [01:45.00]第三句
        [01:50.00]第四句
        """
        withLyrics(lrc) { track in
            let a = analysis(duration: 200,
                             vocalActivity: [Float](repeating: 0.8, count: 200))
            let (_, compiled) = Audition.VocalExchange.compile(
                outgoingURL: track, outgoing: a,
                planned: crossfade(outPoint: 100, overlap: 12),
                config: twoClockConfig())
            #expect(compiled.gesture == .carryover)
            #expect(abs(compiled.handover - 10) < 1e-6)
            #expect(compiled.lyricLine == "第三句")
        }
    }

    /// No line-end past the swap: the singer finishes *before* it instead, and
    /// the floor swap lands on a bar nobody is singing over. Deliberate, named
    /// and reported — not the accident of a nearest-the-middle pick.
    @Test func twoClockYieldsWhenNoLineEndsAfterTheSwap() {
        let lrc = """
        [01:37.00]第一句
        [01:41.00]第二句
        [01:45.00]第三句
        """
        withLyrics(lrc) { track in
            let a = analysis(duration: 200,
                             vocalActivity: [Float](repeating: 0.8, count: 200))
            let (_, compiled) = Audition.VocalExchange.compile(
                outgoingURL: track, outgoing: a,
                planned: crossfade(outPoint: 100, overlap: 12),
                config: twoClockConfig())
            // Ends inside the overlap are 1 and 5; nothing in (6, 10.2], so the
            // latest at or before the swap wins.
            #expect(compiled.gesture == .yield)
            #expect(abs(compiled.handover - 5) < 1e-6)
            #expect(compiled.handover <= compiled.swapOffset)
            #expect(compiled.lyricLine == "第二句")
            #expect(compiled.incomingDuckWindow == nil)
            #expect(compiled.carryShortfallDB == 0)
        }
    }

    /// A yield compiles the single-clock curves exactly — there is nothing to
    /// carry across the swap, so there is nothing to reshape.
    @Test func aYieldCompilesTheSingleClockTemplate() {
        let lrc = """
        [01:37.00]第一句
        [01:41.00]第二句
        [01:45.00]第三句
        """
        withLyrics(lrc) { track in
            let a = analysis(duration: 200,
                             vocalActivity: [Float](repeating: 0.8, count: 200))
            let (_, compiled) = Audition.VocalExchange.compile(
                outgoingURL: track, outgoing: a,
                planned: crossfade(outPoint: 100, overlap: 12),
                config: twoClockConfig())
            #expect(compiled.envelope == template(overlap: 12, handover: 5))
        }
    }

    /// The knob off is the compile this replaced, curve for curve: same L (the
    /// line-end nearest the middle, not the one past the swap), same four
    /// lanes, and no gesture claimed.
    @Test func twoClockOffIsByteIdenticalToTheSingleClockCompile() {
        withLyrics(Self.carryoverLRC) { track in
            let a = analysis(duration: 200,
                             vocalActivity: [Float](repeating: 0.8, count: 200))
            let (_, compiled) = Audition.VocalExchange.compile(
                outgoingURL: track, outgoing: a,
                planned: crossfade(outPoint: 100, overlap: 12),
                config: twoClockConfig(on: false))
            // Nearest the 6 s middle among {4, 9, 11} is 4 — the old answer,
            // where the two-clock rule takes 9.
            #expect(abs(compiled.handover - 4) < 1e-6)
            #expect(compiled.lyricLine == "第一句")
            #expect(compiled.gesture == nil)
            #expect(compiled.incomingDuckWindow == nil)
            #expect(compiled.envelope == template(overlap: 12, handover: 4))
        }
    }

    /// A carry window too short to reach the next line-end falls back to the
    /// yield, which is the same knob-driven contrast from the other side.
    @Test func aShortCarryWindowYieldsInstead() {
        withLyrics(Self.carryoverLRC) { track in
            let a = analysis(duration: 200,
                             vocalActivity: [Float](repeating: 0.8, count: 200))
            let (_, compiled) = Audition.VocalExchange.compile(
                outgoingURL: track, outgoing: a,
                planned: crossfade(outPoint: 100, overlap: 12),
                config: twoClockConfig(carryWindow: 1))
            // (6, 7] holds no line-end; the latest at or before 6 is 4.
            #expect(compiled.gesture == .yield)
            #expect(abs(compiled.handover - 4) < 1e-6)
        }
    }

    /// The compensating envelope is what lets the carried voice survive the
    /// post-swap fader collapse, and it is capped: never past
    /// `compensationCeilingDB`, which is `StemEnvelope`'s own maximum, so no
    /// division by a nearly-gone fader can push a lane out of range.
    @Test func theCarryCompensationNeverExceedsItsCap() throws {
        let ceiling = Audition.VocalExchange.compensationCeilingDB
        #expect(ceiling == StemEnvelope.maxGainDB)
        for overlap in [8.0, 12.0, 16.0, 30.0] {
            let plan = TransitionPlan.crossfade(duration: overlap, outPoint: 100, inPoint: 0)
            let geometry = TransitionAutomation.Geometry(plan: plan)
            let swap = geometry.swapOffset
            // Every hand-over the carry rule could legally return, including
            // ones right up against the share ceiling where the fader is
            // smallest and the naive 1/fader would blow past the cap.
            for h in stride(from: swap + 0.2, through: overlap * 0.85, by: 0.3) {
                let e = Audition.VocalExchange.template(
                    overlap: overlap, handover: h, plan: plan, style: .plain,
                    geometry: geometry, carryFrom: swap)
                try e.validate(overlap: overlap)
                #expect(e.outgoingVocal.allSatisfy { $0.gainDB <= ceiling + 1e-4 })
                #expect(e.incomingVocal.allSatisfy { $0.gainDB <= ceiling + 1e-4 })
                for t in stride(from: 0.0, through: h, by: 0.25) {
                    #expect(e.gainDB(.outgoingVocal, at: t) <= ceiling + 1e-4)
                }
            }
        }
    }

    /// The incoming vocal is held down over exactly the stretch the outgoing
    /// one is borrowing the incoming bed for — `(S, L]` — and is released at L,
    /// not before and not after.
    @Test func theIncomingVocalIsDuckedExactlyAcrossTheCarry() {
        withLyrics(Self.carryoverLRC) { track in
            let a = analysis(duration: 200,
                             vocalActivity: [Float](repeating: 0.8, count: 200))
            let (_, compiled) = Audition.VocalExchange.compile(
                outgoingURL: track, outgoing: a,
                planned: crossfade(outPoint: 100, overlap: 12),
                config: twoClockConfig())
            let s = compiled.swapOffset, l = compiled.handover
            #expect(compiled.incomingDuckWindow == s...l)
            guard let e = compiled.envelope else {
                Issue.record("expected a compiled envelope")
                return
            }
            // At S it is still fully muted — the explicit breakpoint that makes
            // the window a window rather than an accident of the ramp.
            #expect(e.gainDB(.incomingVocal, at: s)
                    == Audition.VocalExchange.incomingVocalMutedDB)
            // Across the whole carry it stays at or below the level it is only
            // allowed to reach *at* the hand-over.
            for t in stride(from: s, to: l, by: 0.2) {
                #expect(e.gainDB(.incomingVocal, at: t)
                        <= Audition.VocalExchange.incomingVocalAtHandoverDB + 1e-4)
            }
            // Released at L, and up on its own bed a second later.
            #expect(e.gainDB(.incomingVocal, at: l)
                    == Audition.VocalExchange.incomingVocalAtHandoverDB)
            #expect(e.gainDB(.incomingVocal, at: l + 1.0) >= -0.01)
        }
    }

    /// The degradations are untouched by the two clocks: no lyrics means the
    /// contour, no contour means the duck, and neither claims a gesture it did
    /// not make.
    @Test func theDegradationPathClaimsNoGesture() {
        var contour = [Float](repeating: 0.9, count: 200)
        contour[107] = 0.05
        let troughTrack = FileManager.default.temporaryDirectory
            .appendingPathComponent("two-clock-trough-\(UUID().uuidString).flac")
        let (_, trough) = Audition.VocalExchange.compile(
            outgoingURL: troughTrack, outgoing: analysis(duration: 200, vocalActivity: contour),
            planned: crossfade(outPoint: 100, overlap: 12), config: twoClockConfig())
        #expect(trough.source == "vocalTrough")
        #expect(abs(trough.handover - 7) < 1e-6)
        #expect(trough.gesture == nil)
        #expect(trough.envelope == template(overlap: 12, handover: 7))

        let blindTrack = FileManager.default.temporaryDirectory
            .appendingPathComponent("two-clock-blind-\(UUID().uuidString).flac")
        let (technique, duck) = Audition.VocalExchange.compile(
            outgoingURL: blindTrack, outgoing: analysis(duration: 200, vocalActivity: []),
            planned: crossfade(outPoint: 100, overlap: 12), config: twoClockConfig())
        #expect(technique == .vocalDuck(
            depthDB: -Float(TransitionPlanner.Config.standard.stemDuckDepthDB)))
        #expect(duck.source == "duck")
        #expect(duck.gesture == nil)
        #expect(duck.envelope == nil)
    }

    // MARK: - End to end, on two decks

    /// A file whose vocal is a known harmonic stack and whose bed is noise, so
    /// the two decks can be told apart in the rendered mix by fundamental.
    private struct Synthetic {
        let url: URL
        let vocal: [Float]
        let fundamental: Double
    }

    private func makeSynthetic(fundamental: Double, seconds: Double = 60) throws -> Synthetic {
        let sampleRate = 44_100.0
        let frames = Int(seconds * sampleRate)
        var generator = SystemRandomNumberGenerator()
        var vocal = [Float](repeating: 0, count: frames)
        var mixture = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            let t = Double(i) / sampleRate
            let v = Float(0.25 * (sin(2 * .pi * fundamental * t)
                                  + 0.5 * sin(2 * .pi * fundamental * 2 * t)))
            vocal[i] = v
            mixture[i] = v + Float.random(in: -0.15...0.15, using: &generator)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("env-synth-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                      frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<2 {
            mixture.withUnsafeBufferPointer {
                buffer.floatChannelData![channel].update(from: $0.baseAddress!, count: frames)
            }
        }
        try file.write(from: buffer)
        return Synthetic(url: url, vocal: vocal, fundamental: fundamental)
    }

    /// Ground-truth "separation", keyed by which file the renderer asked about.
    private func stubProvider(_ tracks: [Synthetic]) -> VocalStemProvider {
        let table = Dictionary(uniqueKeysWithValues: tracks.map { ($0.url.path, $0.vocal) })
        return { request in
            let vocal = table[request.source.path] ?? []
            let start = Int((request.start * request.sampleRate).rounded())
            let count = request.samples[0].count
            let slice = (0..<count).map { i -> Float in
                let index = start + i
                return index < vocal.count ? vocal[index] : 0
            }
            return VocalStem(channels: request.samples.map { _ in slice }, cached: false)
        }
    }

    private func render(_ technique: StemTechnique?,
                        outgoing: Synthetic, incoming: Synthetic,
                        overlap: TimeInterval, provider: VocalStemProvider?) throws
        -> OfflineTransitionRenderer.Result {
        var style = TransitionStyle.plain
        style.stemTechnique = technique
        let plan = TransitionPlan.crossfade(duration: overlap, outPoint: 30, inPoint: 5)
        var options = OfflineTransitionRenderer.Options()
        options.preRoll = 4
        options.postRoll = 4
        options.vocalStemProvider = provider
        // Absolute band energies are compared *between* renders here, and the
        // blind-test normalization exists precisely to erase level differences.
        options.normalizeToLUFS = nil
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("env-render-\(UUID().uuidString).wav")
        return try OfflineTransitionRenderer.render(
            PlannedTransition(plan: plan, style: style),
            outgoing: outgoing.url, incoming: incoming.url,
            to: output, options: options)
    }

    private func samples(_ url: URL, from: TimeInterval, seconds: TimeInterval) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        file.framePosition = AVAudioFramePosition(from * rate)
        let count = AVAudioFrameCount(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count)!
        try file.read(into: buffer, frameCount: count)
        let frames = Int(buffer.frameLength)
        let data = buffer.floatChannelData![0]
        return Array(UnsafeBufferPointer(start: data, count: frames))
    }

    /// Correlation energy at `hz` — how much of that fundamental is present.
    private func bandEnergy(_ url: URL, from: TimeInterval, seconds: TimeInterval,
                            hz: Double) throws -> Double {
        let x = try samples(url, from: from, seconds: seconds)
        let rate = 44_100.0
        var real = 0.0, imaginary = 0.0
        for (i, sample) in x.enumerated() {
            let phase = 2 * Double.pi * hz * Double(i) / rate
            real += Double(sample) * cos(phase)
            imaginary += Double(sample) * sin(phase)
        }
        return (real * real + imaginary * imaginary).squareRoot() / Double(max(x.count, 1))
    }

    private func rms(_ url: URL, from: TimeInterval, seconds: TimeInterval) throws -> Double {
        let x = try samples(url, from: from, seconds: seconds)
        guard !x.isEmpty else { return 0 }
        return (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count)).squareRoot()
    }

    /// The whole point, measured: before the hand-over only the outgoing vocal
    /// is there; after it, only the incoming one; and the bed never holes out.
    @Test func exchangeHandsTheVocalOverAndKeepsTheBedContinuous() throws {
        let outgoing = try makeSynthetic(fundamental: 220)
        let incoming = try makeSynthetic(fundamental: 330)
        defer {
            try? FileManager.default.removeItem(at: outgoing.url)
            try? FileManager.default.removeItem(at: incoming.url)
        }
        let overlap = 12.0, h = 7.0
        let envelope = template(overlap: overlap, handover: h)

        let plain = try render(nil, outgoing: outgoing, incoming: incoming,
                               overlap: overlap, provider: nil)
        let exchanged = try render(.custom(envelope), outgoing: outgoing, incoming: incoming,
                                   overlap: overlap,
                                   provider: stubProvider([outgoing, incoming]))
        defer {
            try? FileManager.default.removeItem(at: plain.outputURL)
            try? FileManager.default.removeItem(at: exchanged.outputURL)
        }

        #expect(exchanged.stemFallbackReason == nil)
        #expect(exchanged.stemTechnique == "custom(\(envelope.signature))")
        // Both decks were split — that is what a four-lane envelope costs.
        #expect(exchanged.stemSeparatedSides == ["出曲", "入曲"])
        #expect(exchanged.stemIncomingSeparatedSeconds != nil)

        let start = exchanged.overlapStart

        // Before the hand-over the incoming singer is not there…
        let inBefore = try bandEnergy(exchanged.outputURL, from: start + 2, seconds: 3, hz: 330)
        let inBeforePlain = try bandEnergy(plain.outputURL, from: start + 2, seconds: 3, hz: 330)
        #expect(inBefore < inBeforePlain * 0.1)

        // …and after it, the outgoing one is gone.
        let outAfter = try bandEnergy(exchanged.outputURL, from: start + h + 1.2,
                                      seconds: 3, hz: 220)
        let outAfterPlain = try bandEnergy(plain.outputURL, from: start + h + 1.2,
                                           seconds: 3, hz: 220)
        #expect(outAfter < outAfterPlain * 0.1)

        // The outgoing singer really does hold the line up to the hand-over,
        // rather than receding through the fade.
        let outEarly = try bandEnergy(exchanged.outputURL, from: start + 0.5, seconds: 2, hz: 220)
        let outLate = try bandEnergy(exchanged.outputURL, from: start + h - 2.5,
                                     seconds: 2, hz: 220)
        #expect(outLate > outEarly * 0.75)

        // No energy hole: every second of the overlap stays within 6 dB of the
        // level at its two ends. A hand-over you can hear a gap in is a hand-over
        // that failed however correct its curves were.
        let head = try rms(exchanged.outputURL, from: start + 0.2, seconds: 1)
        let tail = try rms(exchanged.outputURL, from: start + overlap - 1.2, seconds: 1)
        let ends = max(head, tail)
        var worst = Double.infinity
        var t = 0.2
        while t < overlap - 1 {
            let window = try rms(exchanged.outputURL, from: start + t, seconds: 1)
            worst = min(worst, window)
            t += 0.5
        }
        #expect(worst > ends * 0.5)
    }

    /// A one-sided envelope never pays for the incoming separation — which is
    /// the whole reason the renderer asks lane by lane instead of always
    /// splitting both decks.
    @Test func aPassThroughSideIsNeverSeparated() throws {
        let outgoing = try makeSynthetic(fundamental: 220, seconds: 40)
        let incoming = try makeSynthetic(fundamental: 330, seconds: 40)
        defer {
            try? FileManager.default.removeItem(at: outgoing.url)
            try? FileManager.default.removeItem(at: incoming.url)
        }
        var envelope = StemEnvelope()
        envelope.outgoingVocal = [.init(t: 0, gainDB: -12), .init(t: 8, gainDB: -12)]

        nonisolated(unsafe) var asked: [String] = []
        let base = stubProvider([outgoing, incoming])
        let watching: VocalStemProvider = { request in
            asked.append(request.source.lastPathComponent)
            return try base(request)
        }
        let result = try render(.custom(envelope), outgoing: outgoing, incoming: incoming,
                                overlap: 8, provider: watching)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        #expect(result.stemFallbackReason == nil)
        #expect(asked == [outgoing.url.lastPathComponent])
        #expect(result.stemSeparatedSides == ["出曲"])
        #expect(result.stemIncomingSeparatedSeconds == nil)
    }

    /// An uncompiled `.vocalExchange` must never reach the renderer silently:
    /// it is a marker, and rendering it as if it were a curve would produce a
    /// plain crossfade wearing a technique's name.
    @Test func anUncompiledExchangeDegradesLoudly() throws {
        let outgoing = try makeSynthetic(fundamental: 220, seconds: 40)
        let incoming = try makeSynthetic(fundamental: 330, seconds: 40)
        defer {
            try? FileManager.default.removeItem(at: outgoing.url)
            try? FileManager.default.removeItem(at: incoming.url)
        }
        let result = try render(.vocalExchange, outgoing: outgoing, incoming: incoming,
                                overlap: 8, provider: stubProvider([outgoing, incoming]))
        defer { try? FileManager.default.removeItem(at: result.outputURL) }
        #expect(result.stemTechnique == nil)
        #expect(result.stemFallbackReason?.contains("vocalExchange") == true)
    }
}
