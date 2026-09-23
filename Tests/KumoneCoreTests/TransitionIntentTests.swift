import Testing
@testable import KumoneCore
import Foundation

/// P3, the intent layer (docs/automix-score-predev.md §2.4) and the cue-selection
/// fix that shipped with it.
///
/// Six claims, and they are the ones the layer stands or falls on:
///
///   1. the rules fire in the documented order, and the last one is "blend";
///   2. every class can be turned off on its own, and turning one off drops the
///      pair through to the next rule rather than to nothing;
///   3. with `intentEnabled` false **nothing** the layer owns is read;
///   4. the climax's no-cut zone runs past the final chorus over a passage the
///      singer has not finished — the 476081904 seam;
///   5. a candidate on a vocal cliff outranks one that is not;
///   6. the edge-window arithmetic means what it says.
@Suite struct TransitionIntentTests {

    // MARK: - Fixtures

    /// A downbeat grid at `bpm`, jittered by ±`drift` of a bar in an
    /// alternating pattern, so the CV is a number the test can predict rather
    /// than a random draw.
    private func downbeats(
        bpm: Double, duration: TimeInterval, drift: Double = 0
    ) -> [TimeInterval] {
        let bar = 4 * 60 / bpm
        var out: [TimeInterval] = []
        var t = 0.4
        var i = 0
        while t < duration {
            out.append(t)
            t += bar * (1 + (i % 2 == 0 ? drift : -drift))
            i += 1
        }
        return out
    }

    /// A maximally *spread* fingerprint: every band the same magnitude, zero
    /// sum, unit norm. Participation ratio N, so flatness 1.0 — a wall.
    private static let wallProfile: [Float] = {
        let raw = (0..<40).map { Float($0 % 2 == 0 ? 1 : -1) }
        let norm = raw.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        return raw.map { $0 / norm }
    }()

    /// A maximally *concentrated* one: one band carries the shape. Flatness
    /// ≈ 0.10 — anything but a wall.
    private static let peakedProfile: [Float] = {
        let raw = [Float(39)] + [Float](repeating: -1, count: 39)
        let norm = raw.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        return raw.map { $0 / norm }
    }()

    private func makeAnalysis(
        bpm: Double = 128,
        confidence: Double = 0.9,
        duration: TimeInterval = 240,
        drift: Double = 0,
        melProfile: [Float]? = nil,
        vocalActivity: [Float]? = nil,
        sections: [TrackAnalysis.Section] = [],
        structureConfidence: Double = 0.8,
        // Deliberately reaching into the tail window: the beat-matched search
        // only looks at the last quarter of the track, and a fixture whose
        // candidates all sit at 150 s proves nothing about a rule that only
        // matters on a pair that *can* beat-match.
        phraseBoundaries: [TimeInterval] = [200, 150, 90],
        rmsEnvelope: [Float]? = nil,
        introEnd: TimeInterval = 2
    ) -> TrackAnalysis {
        var a = TrackAnalysis(
            version: TrackAnalysis.currentVersion,
            bpm: bpm, bpmConfidence: confidence,
            beats: stride(from: 0.4, to: duration, by: 60 / bpm).map { $0 },
            downbeats: downbeats(bpm: bpm, duration: duration, drift: drift),
            phraseBoundaries: phraseBoundaries,
            rmsEnvelope: rmsEnvelope ?? [Float](repeating: 0.5, count: Int(duration)),
            outroFadeStart: nil, introEnd: introEnd, duration: duration,
            melProfile: melProfile ?? Self.peakedProfile,
            keyPitchClass: nil, keyIsMinor: false, keyConfidence: 0,
            vocalActivity: vocalActivity ?? [],
            referenceLoudness: nil, peakDBFS: -6)
        a.sections = sections
        a.structureConfidence = structureConfidence
        return a
    }

    private func section(
        _ kind: TrackAnalysis.Section.Kind, _ start: TimeInterval, _ end: TimeInterval,
        repetition: Int = 1, vocalDensity: Float = 1, energy: Float = 0.7
    ) -> TrackAnalysis.Section {
        TrackAnalysis.Section(start: start, end: end, kind: kind, repetition: repetition,
                              energy: energy, vocalDensity: vocalDensity)
    }

    private var intentOn: TransitionPlanner.Config {
        var config = TransitionPlanner.Config.standard
        config.intentEnabled = true
        return config
    }

    /// A whole-mix instrumental contour: constant, so every window's ratio is
    /// 1 — which is *above* the instrumental line and therefore never lets a
    /// pair cut by accident.
    private func flatVocal(_ duration: TimeInterval, level: Float) -> [Float] {
        [Float](repeating: level, count: Int(duration))
    }

    /// Sung from 40 s to 110 s and nowhere else: the contour that makes both
    /// **edge windows** instrumental — the entry at the intro end and the exit
    /// behind the 200 s candidate — without making the *track* instrumental (a
    /// track with no vocal at all has no usable contour and abstains).
    private func edgesInstrumental(_ duration: TimeInterval) -> [Float] {
        (0..<Int(duration)).map { i in (i > 40 && i < 110) ? 0.9 : 0.02 }
    }

    // MARK: - 1. Rule precedence

    @Test func albumSequentialStandsDownBeforeEveryOtherRule() {
        // A pair that would otherwise be pure cut culture: hard grids, high
        // confidence, instrumental edges. The album rule still wins.
        let a = makeAnalysis(vocalActivity: edgesInstrumental(240))
        let context = TransitionPlanner.PlanContext(sameAlbum: true, listedAdjacent: true)
        let planned = TransitionPlanner.plan(outgoing: a, incoming: a,
                                             config: intentOn, context: context)
        #expect(planned.style.intent?.class == .standDown)
        #expect(planned.style.intent?.budget == 0)
        // …and stand-down *is* the plain path, not a short version of the
        // AutoMix one.
        if case .gapless = planned.plan {} else { Issue.record("expected gapless") }
        #expect(planned.rideDB == 0)
        #expect(planned.style.outroEffect == TransitionStyle.plain.outroEffect)
        #expect(planned.style.stagedEQ == TransitionStyle.plain.stagedEQ)
    }

    /// Same album but shuffled apart, or adjacent but from different records:
    /// neither is an album in sequence, and both halves are required.
    @Test func halfOfTheAlbumTestIsNotTheAlbumTest() {
        let a = makeAnalysis()
        for context in [TransitionPlanner.PlanContext(sameAlbum: true, listedAdjacent: false),
                        TransitionPlanner.PlanContext(sameAlbum: false, listedAdjacent: true)] {
            let planned = TransitionPlanner.plan(outgoing: a, incoming: a,
                                                 config: intentOn, context: context)
            #expect(planned.style.intent?.class != .standDown)
        }
    }

    @Test func aDriftingGridIsRestrainedAndRefusesTheBeatMatch() {
        // 5 % bar drift on the outgoing side: a person keeping time.
        let drifting = makeAnalysis(drift: 0.05)
        let steady = makeAnalysis(bpm: 130)
        let planned = TransitionPlanner.plan(outgoing: drifting, incoming: steady,
                                             config: intentOn)
        #expect(planned.style.intent?.class == .restrained)
        #expect(planned.style.intent?.budget == 0.25)
        // The beat-match is off the table, and the window is capped at the
        // neutral overlap however compatible the pair is.
        if case .beatMatched = planned.plan { Issue.record("restrained must not beat-match") }
        let overlap = TransitionAutomation.Geometry(plan: planned.plan).overlapDuration
        #expect(overlap <= TransitionPlanner.Config.standard.neutralOverlapCap + 1e-6)
        // The same pair beat-matches with the layer off — so the restraint is
        // the rule's doing, not the fixture's.
        let baseline = TransitionPlanner.plan(outgoing: drifting, incoming: steady)
        if case .beatMatched = baseline.plan {} else {
            Issue.record("the fixture must beat-match without the layer, or the test proves nothing")
        }
    }

    /// A wall of sound over a grid we do not fully trust is the *other* half of
    /// rock-like, and it needs both halves: the same wall over a confident grid
    /// is not restrained.
    @Test func aWallOnlyRestrainsWhenTheGridIsAlsoWeak() {
        let wallWeak = makeAnalysis(confidence: 0.7, melProfile: Self.wallProfile,
                                    rmsEnvelope: [Float](repeating: 0.9, count: 240))
        let wallSure = makeAnalysis(confidence: 0.95, melProfile: Self.wallProfile,
                                    rmsEnvelope: [Float](repeating: 0.9, count: 240))
        #expect(TransitionPlanner.plan(outgoing: wallWeak, incoming: wallWeak,
                                       config: intentOn).style.intent?.class == .restrained)
        #expect(TransitionPlanner.plan(outgoing: wallSure, incoming: wallSure,
                                       config: intentOn).style.intent?.class != .restrained)
    }

    /// An orchestra is not a drummer. With neither side's tempo believable the
    /// pair stands down; it must not be filed under rock just because a
    /// rubato grid drifts and a full orchestration is flat.
    @Test func noBeatOnEitherSideStandsDownRatherThanRestrains() {
        let classical = makeAnalysis(confidence: 0.3, drift: 0.06,
                                     melProfile: Self.wallProfile)
        let planned = TransitionPlanner.plan(outgoing: classical, incoming: classical,
                                             config: intentOn)
        #expect(planned.style.intent?.class == .standDown)
        if case .gapless = planned.plan {} else { Issue.record("expected gapless") }
    }

    @Test func aConfidentDropOnHardGridsAimsTheOverlapEnd() {
        let outgoing = makeAnalysis()
        let incoming = makeAnalysis(
            bpm: 128,
            sections: [section(.intro, 0, 15), section(.verse, 15, 60, repetition: 2),
                       section(.drop, 60, 100, repetition: 2),
                       section(.chorus, 100, 160, repetition: 2),
                       section(.outro, 160, 240)])
        let planned = TransitionPlanner.plan(outgoing: outgoing, incoming: incoming,
                                             config: intentOn)
        #expect(planned.style.intent?.class == .dropAlign)
        #expect(planned.style.intent?.budget == 0.75)
        // Still the blend family — a drop worth landing on is not permission to
        // cut into it — and the aim lands on the end of the overlap, not the
        // seam.
        #expect(planned.style.score == nil)
        #expect(planned.style.aim?.target == .drop)
        #expect(planned.style.aim?.landing == .overlapEnd)
    }

    @Test func hardGridsAndInstrumentalEdgesAreTheCutCulture() {
        let a = makeAnalysis(vocalActivity: edgesInstrumental(240))
        let planned = TransitionPlanner.plan(outgoing: a, incoming: a, config: intentOn)
        #expect(planned.style.intent?.class == .cutCulture)
        #expect(planned.style.intent?.budget == 1)
    }

    /// The predev's first rule, and the branch that changes nothing: two sung
    /// edges on ordinary grids get today's blend.
    @Test func whenInDoubtItBlends() {
        let a = makeAnalysis(vocalActivity: flatVocal(240, level: 0.8))
        let planned = TransitionPlanner.plan(outgoing: a, incoming: a, config: intentOn)
        #expect(planned.style.intent?.class == .blend)
        #expect(planned.style.intent?.budget == 0.5)
        #expect(planned.style.intent?.reasons.contains { $0.contains("both edges are sung") }
                == true)
    }

    // MARK: - 2. Per-class switches

    /// A class turned off drops its pairs through to the **next** rule, not out
    /// of the layer: that is what makes each rule independently revertible.
    @Test func eachClassCanBeTurnedOffOnItsOwn() {
        var config = intentOn
        config.intentStandDownEnabled = false
        let album = TransitionPlanner.plan(
            outgoing: makeAnalysis(vocalActivity: edgesInstrumental(240)),
            incoming: makeAnalysis(vocalActivity: edgesInstrumental(240)),
            config: config,
            context: TransitionPlanner.PlanContext(sameAlbum: true, listedAdjacent: true))
        // Falls through past rules 2 and 3 to the cut culture it otherwise is.
        #expect(album.style.intent?.class == .cutCulture)

        var noRestraint = intentOn
        noRestraint.intentRestrainedEnabled = false
        #expect(TransitionPlanner.plan(outgoing: makeAnalysis(drift: 0.05),
                                       incoming: makeAnalysis(bpm: 130),
                                       config: noRestraint).style.intent?.class == .blend)

        var noDrop = intentOn
        noDrop.intentDropAlignEnabled = false
        let dropping = makeAnalysis(
            bpm: 128,
            sections: [section(.intro, 0, 15), section(.drop, 60, 100, repetition: 2)])
        #expect(TransitionPlanner.plan(outgoing: makeAnalysis(), incoming: dropping,
                                       config: noDrop).style.intent?.class == .blend)

        var noCut = intentOn
        noCut.intentCutCultureEnabled = false
        #expect(TransitionPlanner.plan(
            outgoing: makeAnalysis(vocalActivity: edgesInstrumental(240)),
            incoming: makeAnalysis(vocalActivity: edgesInstrumental(240)),
            config: noCut).style.intent?.class == .blend)
    }

    /// A score is offered on the cut culture and on nothing else. The gates it
    /// already had still apply — intent is a veto, never a licence.
    @Test func onlyTheCutCultureMayBeOfferedAScore() {
        var config = intentOn
        config.scoreEnabled = true
        let instrumental = makeAnalysis(vocalActivity: edgesInstrumental(240))
        #expect(TransitionPlanner.plan(outgoing: instrumental, incoming: instrumental,
                                       config: config).style.score != nil)
        // Sung edges: same grids, same confidence, no score.
        let sung = makeAnalysis(vocalActivity: flatVocal(240, level: 0.8))
        #expect(TransitionPlanner.plan(outgoing: sung, incoming: sung,
                                       config: config).style.score == nil)
        // Restrained: never, whatever the knob says.
        #expect(TransitionPlanner.plan(outgoing: makeAnalysis(drift: 0.05),
                                       incoming: makeAnalysis(bpm: 130),
                                       config: config).style.score == nil)
    }

    // MARK: - 3. Off is off

    /// Every knob the layer owns, moved as far as it goes, with the layer off:
    /// the plan must not move by one field. This is the structural claim behind
    /// "P3 ships dark", and it is a stronger statement than "the defaults
    /// happen to agree".
    @Test func withTheLayerOffNoneOfItsKnobsAreRead() {
        var absurd = TransitionPlanner.Config.standard
        absurd.intentEnabled = false
        absurd.intentStandDownEnabled = false
        absurd.intentRestrainedEnabled = false
        absurd.intentDropAlignEnabled = false
        absurd.intentCutCultureEnabled = false
        absurd.intentEdgeWindowSeconds = 5
        absurd.intentDrummerDriftCV = 0.001
        absurd.intentHardGridCV = 0.9
        absurd.intentWallFlatness = 0.01
        absurd.intentWallOccupancy = 0.01
        absurd.intentInstrumentalEdgeRatio = 1.2

        let fixtures: [(TrackAnalysis, TrackAnalysis)] = [
            (makeAnalysis(), makeAnalysis(bpm: 130)),
            (makeAnalysis(drift: 0.05, melProfile: Self.wallProfile),
             makeAnalysis(confidence: 0.4)),
            (makeAnalysis(vocalActivity: edgesInstrumental(240)),
             makeAnalysis(vocalActivity: edgesInstrumental(240))),
            (makeAnalysis(confidence: 0.3), makeAnalysis(confidence: 0.3)),
        ]
        let context = TransitionPlanner.PlanContext(sameAlbum: true, listedAdjacent: true)
        for (outgoing, incoming) in fixtures {
            let shipped = TransitionPlanner.plan(outgoing: outgoing, incoming: incoming,
                                                 context: context)
            let twisted = TransitionPlanner.plan(outgoing: outgoing, incoming: incoming,
                                                 config: absurd, context: context)
            #expect(describe(shipped) == describe(twisted))
            #expect(shipped.style.intent == nil)
        }
    }

    /// The same pin with a separator in the room — the case the intent-driven
    /// stem request added. With the layer off, the stem layer is governed by
    /// `stemVocalActiveRatio` alone, exactly as it was before P3, and no
    /// intent knob (`intentInstrumentalEdgeRatio` above all) may reach it.
    @Test func withTheLayerOffTheStemRulesAreTheOldOnes() {
        var absurd = TransitionPlanner.Config.standard
        absurd.intentEnabled = false
        absurd.intentInstrumentalEdgeRatio = 0.01   // "everything is sung"
        absurd.intentEdgeWindowSeconds = 5
        absurd.intentHardGridCV = 0.9

        let fixtures: [(TrackAnalysis, TrackAnalysis)] = [
            // Ordinary sung edges: ratio 1.0 on both sides — over the intent
            // layer's line, under the 1.15 hot-spot gate. The pair the request
            // exists for, and the one that must not move with the layer off.
            (makeAnalysis(vocalActivity: flatVocal(240, level: 0.8)),
             makeAnalysis(bpm: 130, vocalActivity: flatVocal(240, level: 0.8))),
            (makeAnalysis(vocalActivity: edgesInstrumental(240)),
             makeAnalysis(vocalActivity: edgesInstrumental(240))),
            (makeAnalysis(), makeAnalysis(bpm: 130)),
        ]
        for (outgoing, incoming) in fixtures {
            let shipped = TransitionPlanner.plan(outgoing: outgoing, incoming: incoming,
                                                 stems: .ready)
            let twisted = TransitionPlanner.plan(outgoing: outgoing, incoming: incoming,
                                                 stems: .ready, config: absurd)
            #expect(describe(shipped) == describe(twisted))
            #expect(shipped.style.intent == nil)
        }
    }

    // MARK: - 7. The intent-driven stem request

    /// Two ordinary sung edges — ratio 1.00 on each side, which is over the
    /// intent layer's 0.50 "sung" line and under the stem layer's 1.15
    /// hot-spot gate. This is the field's `intent=blend (… both edges are sung
    /// …)` / `stem=none` seam in miniature: before the request, the reason text
    /// promised vocal management and the plan delivered a bare fader law.
    private func sungBothSides() -> (TrackAnalysis, TrackAnalysis) {
        (makeAnalysis(vocalActivity: flatVocal(240, level: 0.8)),
         makeAnalysis(bpm: 130, vocalActivity: flatVocal(240, level: 0.8)))
    }

    @Test func bothEdgesSungWithStemsReadyRequestsAnExchange() {
        let (a, b) = sungBothSides()
        // The gap, first: neither edge clears the hot-spot gate, so the old
        // rules name no technique even with a separator standing by.
        let ungoverned = TransitionPlanner.plan(outgoing: a, incoming: b, stems: .ready)
        #expect(ungoverned.style.stemTechnique == nil)

        let requested = TransitionPlanner.plan(outgoing: a, incoming: b, stems: .ready,
                                               config: intentOn)
        #expect(requested.style.intent?.class == .blend)
        #expect(requested.style.stemTechnique == .vocalExchange)
        #expect(requested.style.intent?.reasons
            .contains { $0.contains("vocalExchange requested") } == true)
        // …and the class stops claiming to be yesterday's plan, because on this
        // one branch it is not.
        #expect(requested.style.intent?.reasons
            .contains { $0.contains("field-for-field") } == false)
    }

    /// No separator, no promise. The class and the finding are unchanged — the
    /// pair really is two singing edges — but the sentence now says so instead
    /// of claiming a management that nothing performs, and the plan is
    /// field-for-field the one the layer-off build makes.
    @Test func bothEdgesSungWithoutStemsSaysUnmanaged() {
        let (a, b) = sungBothSides()
        let on = TransitionPlanner.plan(outgoing: a, incoming: b, config: intentOn)
        #expect(on.style.intent?.class == .blend)
        #expect(on.style.stemTechnique == nil)
        #expect(on.style.intent?.reasons
            .contains { $0.contains("no separator, unmanaged") } == true)
        #expect(on.style.intent?.reasons
            .contains { $0.contains("vocalExchange requested") } == false)
        #expect(on.style.intent?.reasons
            .contains { $0.contains("field-for-field") } == true)
        #expect(describe(TransitionPlanner.plan(outgoing: a, incoming: b)) == describe(on))
    }

    /// One instrumental edge and the finding never fires, so neither does the
    /// request: the stem layer is left to the 1.15 gate it always had.
    @Test func oneInstrumentalEdgeChangesNothing() {
        let a = makeAnalysis(vocalActivity: flatVocal(240, level: 0.8))
        let b = makeAnalysis(bpm: 130, vocalActivity: edgesInstrumental(240))
        let off = TransitionPlanner.plan(outgoing: a, incoming: b, stems: .ready)
        let on = TransitionPlanner.plan(outgoing: a, incoming: b, stems: .ready,
                                        config: intentOn)
        #expect(on.style.intent?.class == .blend)
        #expect(on.style.intent?.reasons
            .contains { $0.contains("both edges are sung") } == false)
        #expect(describe(off) == describe(on))
    }

    /// The request relaxes a threshold; it does not suspend the rest of the
    /// stem layer. `stemMinOverlap` past the overlap and the pair falls back to
    /// the whole-mix decision, request or no request.
    @Test func theRequestStillObeysTheOtherStemPreconditions() {
        let (a, b) = sungBothSides()
        var strict = intentOn
        strict.stemMinOverlap = 120
        let planned = TransitionPlanner.plan(outgoing: a, incoming: b, stems: .ready,
                                             config: strict)
        #expect(planned.style.stemTechnique == nil)
        // The sentence still tells the truth about what was asked for.
        #expect(planned.style.intent?.reasons
            .contains { $0.contains("vocalExchange requested") } == true)
    }

    /// The finding is one function, shared by the sentence and the request, so
    /// it cannot say two different things — and it abstains rather than
    /// asserting when a side has no usable vocal contour.
    @Test func theSungFindingIsOneDefinition() {
        let config = intentOn
        let sung = MaterialProfile.wholeTrack(
            makeAnalysis(vocalActivity: flatVocal(240, level: 0.8)), config: config)
        let silent = MaterialProfile.wholeTrack(makeAnalysis(), config: config)
        #expect(TransitionIntent.bothEdgesSung(sung, sung, config: config) != nil)
        #expect(TransitionIntent.bothEdgesSung(sung, silent, config: config) == nil)
        #expect(TransitionIntent.bothEdgesSung(silent, silent, config: config) == nil)
        // …and it is the negation of the line rule 5 refuses to cut above.
        #expect(config.intentInstrumentalEdgeRatio == 0.5)
    }

    /// …and a pair the layer classifies `blend` gets the identical plan with it
    /// on. The default branch is not "close to" today, it is today.
    @Test func theBlendClassChangesNothing() {
        let a = makeAnalysis(vocalActivity: flatVocal(240, level: 0.8))
        let b = makeAnalysis(bpm: 130, vocalActivity: flatVocal(240, level: 0.8))
        let off = TransitionPlanner.plan(outgoing: a, incoming: b)
        let on = TransitionPlanner.plan(outgoing: a, incoming: b, config: intentOn)
        #expect(on.style.intent?.class == .blend)
        #expect(describe(off) == describe(on))
    }

    /// Everything about a planned hand-over that is audible, as one string —
    /// the geometry, the rates and the whole style but the annotations.
    private func describe(_ p: PlannedTransition) -> String {
        var style = p.style
        style.intent = nil
        var body = ""
        switch p.plan {
        case .beatMatched(let m):
            body = String(format: "bm out=%.6f in=%.6f bars=%d out×%.6f in×%.6f",
                          m.outPoint, m.inPoint, m.overlapBars,
                          m.outgoingRate, m.incomingRate)
        case .crossfade(let d, let out, let inPoint):
            body = String(format: "xf %.6f out=%.6f in=%.6f", d, out, inPoint)
        case .gapless:
            body = "gapless"
        }
        return body + String(format: " ride=%.6f style=%@", p.rideDB, String(describing: style))
    }

    // MARK: - 4. The climax extension — the 476081904 seam

    /// The sidecar shape of the marked-bad seam, synthesized: `chorus
    /// 131.5–174.3`, a **unique** passage 174.3–208.6 at vocal density 1.03,
    /// then the outro. The hand-over landed at 204.7 s, four seconds from the
    /// end of a phrase the singer had not finished.
    private var snowTown: [TrackAnalysis.Section] {
        [section(.intro, 0, 18),
         section(.verse, 18, 60, repetition: 2),
         section(.chorus, 60, 100, repetition: 3),
         section(.verse, 100, 131.5, repetition: 2),
         section(.chorus, 131.5, 174.3, repetition: 3),
         section(.bridge, 174.3, 208.6, repetition: 1, vocalDensity: 1.03),
         section(.outro, 208.6, 240)]
    }

    /// With the fix off — the pre-P3 behaviour — a candidate inside the bridge
    /// is legal, and 204.7 is exactly the kind of point the machinery reaches
    /// for. With it on, the whole bridge is out.
    @Test func theNoCutZoneRunsPastTheFinalChorusOverAnUnfinishedPassage() {
        let a = makeAnalysis(bpm: 120, duration: 240,
                             vocalActivity: [Float](repeating: 0.6, count: 240),
                             sections: snowTown, phraseBoundaries: [204.7, 150])

        var off = TransitionPlanner.Config.standard
        off.climaxExtendPostChorus = false
        off.preferVocalCliffOutPoints = false
        let before = TransitionPlanner.outPointCandidates(a, context: .none, config: off)
        #expect(before.points.contains { abs($0 - 204.7) < 0.01 })

        var on = TransitionPlanner.Config.standard
        on.preferVocalCliffOutPoints = false
        let after = TransitionPlanner.outPointCandidates(a, context: .none, config: on)
        // The bad cut is gone…
        #expect(!after.points.contains { abs($0 - 204.7) < 0.01 })
        // …every candidate strictly inside the bridge is gone with it…
        #expect(!after.points.contains { $0 > 174.4 && $0 < 208.5 })
        // …and the two right answers are still there: the end of the final
        // chorus (the cut nobody argues with) and the outro's downbeat, which
        // is where the voice actually stops.
        #expect(after.points.contains { abs($0 - 174.3) < 0.01 })
        #expect(after.points.contains { abs($0 - 208.6) < 0.01 })
        #expect(after.climaxExtensionWindow?.end == 208.6)
    }

    /// Three conditions, each necessary. A passage that repeats is the song
    /// saying something it has already said; an instrumental tag is a fine
    /// place to leave; a gap in between makes it a different part of the song.
    @Test func theExtensionNeedsAllThreeOfItsConditions() {
        func endOfZone(_ sections: [TrackAnalysis.Section]) -> TimeInterval? {
            TransitionPlanner.outPointCandidates(
                makeAnalysis(bpm: 120, sections: sections, phraseBoundaries: [204.7, 150]),
                context: .none, config: .standard).climaxExtensionWindow?.end
        }
        var repeated = snowTown
        repeated[5] = section(.bridge, 174.3, 208.6, repetition: 2, vocalDensity: 1.03)
        #expect(endOfZone(repeated) == nil)

        var instrumental = snowTown
        instrumental[5] = section(.bridge, 174.3, 208.6, repetition: 1, vocalDensity: 0.2)
        #expect(endOfZone(instrumental) == nil)

        var detached = snowTown
        detached[5] = section(.bridge, 180, 208.6, repetition: 1, vocalDensity: 1.03)
        #expect(endOfZone(detached) == nil)

        // …and the unmodified shape does extend, so the three checks above are
        // testing the conditions and not a broken fixture.
        #expect(endOfZone(snowTown) == 208.6)
    }

    /// The final chorus's own end stays legal. The extension protects what
    /// comes *after* the climax, and taking away the best candidate there is
    /// would be a worse bug than the one it fixes.
    @Test func theExtensionNeverEatsTheFinalChorusEnd() {
        let candidates = TransitionPlanner.outPointCandidates(
            makeAnalysis(bpm: 120, sections: snowTown, phraseBoundaries: [204.7, 150]),
            context: .none, config: .standard)
        #expect(candidates.points.first == 174.3)
    }

    // MARK: - 5. The vocal cliff

    /// Two candidates, equal on every existing criterion; the one the voice
    /// stops at comes first. A **re-ordering**, so the other one is still there.
    @Test func aCandidateWhereTheVoiceStopsOutranksOneWhereItDoesNot() {
        // Singing throughout except from 160 s: 150 is mid-phrase, 160 is the
        // cliff. Both are phrase boundaries, and 150 is listed first.
        var vocal = [Float](repeating: 0.9, count: 240)
        for i in 160..<240 { vocal[i] = 0.05 }
        let a = makeAnalysis(bpm: 120, duration: 240, vocalActivity: vocal,
                             phraseBoundaries: [150, 160])

        var off = TransitionPlanner.Config.standard
        off.preferVocalCliffOutPoints = false
        #expect(TransitionPlanner.outPointCandidates(a, context: .none, config: off)
            .points.first == 150)

        let on = TransitionPlanner.outPointCandidates(a, context: .none, config: .standard)
        #expect(on.points.first == 160)
        #expect(on.vocalCliffPromoted == 1)
        // Nothing was removed: promotion is not a filter.
        #expect(Set(on.points) == Set([150, 160]))
    }

    /// A track with no vocal contour, or one that never stops singing, leaves
    /// the order exactly as it was.
    @Test func withNoCliffTheOrderIsUntouched() {
        for vocal in [[Float](), [Float](repeating: 0.9, count: 240)] {
            let a = makeAnalysis(bpm: 120, duration: 240, vocalActivity: vocal,
                                 phraseBoundaries: [150, 160])
            let candidates = TransitionPlanner.outPointCandidates(
                a, context: .none, config: .standard)
            #expect(candidates.points == [150, 160])
            #expect(candidates.vocalCliffPromoted == 0)
        }
    }

    // MARK: - 6. Edge-window arithmetic

    /// The grid statistic is a **bar** statistic over the window it was asked
    /// for, and a perfectly quantized grid reads as zero however long it runs.
    @Test func theDownbeatCVMeasuresTheWindowItIsGiven() {
        // Steady until 120 s, then 6 % alternating drift.
        let bar = 2.0
        var grid: [TimeInterval] = []
        var t = 0.0
        var i = 0
        while t < 240 {
            grid.append(t)
            t += t < 120 ? bar : bar * (1 + (i % 2 == 0 ? 0.06 : -0.06))
            i += 1
        }
        let steady = MaterialProfile.downbeatCV(grid, from: 0, to: 110)
        let drifting = MaterialProfile.downbeatCV(grid, from: 130, to: 240)
        #expect((steady ?? 1) < 1e-9)
        #expect(abs((drifting ?? 0) - 0.06) < 0.005)
        // Too few intervals to say anything is nil, not zero: "we do not know"
        // and "it is perfect" are the opposite conclusions for a cut.
        #expect(MaterialProfile.downbeatCV(grid, from: 0, to: 4) == nil)
    }

    /// A dropped downbeat is a detector failure, not a drummer. One doubled
    /// interval in a steady grid must not move the statistic.
    @Test func aDroppedDownbeatDoesNotReadAsDrift() {
        var grid = stride(from: 0.0, to: 60.0, by: 2).map { $0 }
        grid.remove(at: 10)
        let cv = MaterialProfile.downbeatCV(grid, from: 0, to: 60)
        #expect((cv ?? 1) < 1e-9)
    }

    /// Flatness runs the way the wall argument needs it to: a spread shape is
    /// high, a concentrated one is low.
    @Test func flatnessSeparatesAWallFromAShape() {
        let wall = MaterialProfile.flatness(Self.wallProfile) ?? 0
        let peaked = MaterialProfile.flatness(Self.peakedProfile) ?? 1
        #expect(abs(wall - 1) < 1e-6)
        #expect(peaked < 0.15)
        #expect(MaterialProfile.flatness([]) == nil)
    }

    /// Occupancy is a share of the window, and the window is the edge, not the
    /// track: a song that is loud only at the end reads quiet at its start.
    @Test func occupancyIsReadAtTheEdgeNotOverTheTrack() {
        let envelope = (0..<200).map { Float($0 < 100 ? 0.1 : 1.0) }
        #expect(abs((MaterialProfile.occupancy(envelope, from: 0, to: 100) ?? 0) - 1) < 1e-6)
        #expect(abs((MaterialProfile.occupancy(envelope, from: 0, to: 200) ?? 0) - 0.5) < 0.01)
        #expect(MaterialProfile.occupancy(envelope, from: 0, to: 2) == nil)
    }

    /// The two anchors point at opposite ends of their tracks — the exit
    /// behind the out point, the entry ahead of the in point — which is the
    /// whole reason the profile is not a whole-track statistic.
    @Test func theEdgeWindowsLookInOppositeDirections() {
        var config = TransitionPlanner.Config.standard
        config.intentEdgeWindowSeconds = 30
        let loudLate = makeAnalysis(rmsEnvelope: (0..<240).map { Float($0 < 200 ? 0.1 : 1.0) })
        // Exit at 240 s: the last 30 s, all of it loud.
        let exit = MaterialProfile.outgoing(loudLate, exitAt: 240, config: config)
        // Entry at 0 s: the first 30 s, none of it loud.
        let entry = MaterialProfile.incoming(loudLate, entryAt: 0, config: config)
        #expect((exit.occupancy ?? 0) > 0.9)
        #expect((entry.occupancy ?? 0) > 0.9)  // relative to its own quiet peak
        // The absolute statement: the exit window's material is the loud half.
        #expect(MaterialProfile.vocalMean([Float](repeating: 1, count: 240),
                                          from: 210, to: 240) == 1)
    }
}
