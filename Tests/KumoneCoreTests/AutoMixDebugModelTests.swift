import Testing
@testable import KumoneCore
import Foundation

// The AutoMix debug panel's mapping layer. The window itself cannot be tested
// here, but everything it *prints* is a pure function of a `PlannedTransition`
// and the two analyses it came from — including the one judgement the panel
// makes on its own, "did the engine run what it was handed".
@Suite struct AutoMixDebugModelTests {

    // MARK: - Fixtures

    private func analysis(
        duration: TimeInterval = 200,
        introEnd: TimeInterval = 8,
        phraseBoundaries: [TimeInterval] = [150, 90, 30],
        sections: [TrackAnalysis.Section] = [],
        keyPitchClass: Int? = nil,
        keyIsMinor: Bool = false,
        keyConfidence: Double = 0
    ) -> TrackAnalysis {
        var a = TrackAnalysis(
            version: TrackAnalysis.currentVersion,
            bpm: 120, bpmConfidence: 0.9,
            beats: stride(from: 0.0, to: duration, by: 0.5).map { $0 },
            downbeats: stride(from: 0.0, to: duration, by: 2).map { $0 },
            phraseBoundaries: phraseBoundaries,
            rmsEnvelope: [Float](repeating: 0.5, count: Int(duration)),
            outroFadeStart: nil, introEnd: introEnd, duration: duration,
            melProfile: [],
            keyPitchClass: keyPitchClass, keyIsMinor: keyIsMinor,
            keyConfidence: keyConfidence,
            vocalActivity: [],
            referenceLoudness: -9.5, peakDBFS: -1)
        a.sections = sections
        a.structureConfidence = sections.isEmpty ? 0 : 0.8
        return a
    }

    private func section(_ kind: TrackAnalysis.Section.Kind,
                         _ start: TimeInterval, _ end: TimeInterval,
                         repetition: Int = 1) -> TrackAnalysis.Section {
        TrackAnalysis.Section(start: start, end: end, kind: kind,
                              repetition: repetition, energy: 0.7, vocalDensity: 1)
    }

    // MARK: - Plan flattening

    @Test func beatMatchedPlanCarriesBarsAndRates() {
        let planned = PlannedTransition(
            plan: .beatMatched(BeatMatchedPlan(
                outPoint: 150, inPoint: 8, overlapBars: 8,
                outgoingRate: 1.01, incomingRate: 0.99,
                bassSwapOffset: 8, overlapDuration: 16)),
            style: TransitionStyle(outroEffect: .filterSweep, stagedEQ: true,
                                   stemTechnique: .vocalDuck(depthDB: -9)),
            rideDB: -1.5)
        let outgoing = analysis(sections: [section(.chorus, 130, 170, repetition: 3)])
        let plan = AutoMixDebugPlan(planned: planned, outgoing: outgoing,
                                    incoming: analysis(introEnd: 8))

        #expect(plan.kind == "beatMatched")
        #expect(plan.outPoint == 150)
        #expect(plan.inPoint == 8)
        #expect(plan.overlap == 16)
        #expect(plan.overlapBars == 8)
        #expect(plan.outgoingRate == 1.01)
        #expect(plan.outroEffect == "filterSweep")
        #expect(plan.stagedEQ)
        #expect(plan.stemTechnique == "vocalDuck(-9.0dB)")
        #expect(plan.rideDB == -1.5)
        // The out point sits inside the final chorus, and the panel says so.
        #expect(plan.outSection?.hasPrefix("chorus") == true)
        #expect(plan.inPointSource == "introEnd")
    }

    @Test func gaplessPlanHasNoGeometry() {
        let plan = AutoMixDebugPlan(planned: .plain(.gapless), outgoing: nil, incoming: nil)
        #expect(plan.kind == "gapless")
        #expect(plan.outPoint == nil)
        #expect(plan.inPoint == nil)
        #expect(plan.overlap == 0)
        #expect(plan.outSection == nil)
    }

    @Test func structurelessOutgoingReportsNoSection() {
        let planned = PlannedTransition.plain(
            .crossfade(duration: 6, outPoint: 150, inPoint: 0))
        let plan = AutoMixDebugPlan(planned: planned, outgoing: analysis(),
                                    incoming: analysis())
        #expect(plan.outSection == nil)
        #expect(plan.inPointSource == "track start")
    }

    // MARK: - In-point provenance

    @Test func inPointMatchesSectionStartAndPhraseBoundary() {
        let incoming = analysis(sections: [section(.verse, 40, 80)])
        #expect(AutoMixDebugFormat.inPointSource(40, incoming: incoming)
                == "section start (verse)")
        #expect(AutoMixDebugFormat.inPointSource(90, incoming: incoming) == "phrase boundary")
        // On the beat grid but none of the named landmarks.
        #expect(AutoMixDebugFormat.inPointSource(52, incoming: incoming) == "downbeat")
        #expect(AutoMixDebugFormat.inPointSource(52.3, incoming: incoming) == "free")
        #expect(AutoMixDebugFormat.inPointSource(40, incoming: nil) == nil)
    }

    // MARK: - Fallback detection

    @Test func identicalPlanIsNoFallback() {
        let planned = PlannedTransition.plain(
            .crossfade(duration: 6, outPoint: 150, inPoint: 0))
        let plan = AutoMixDebugPlan(planned: planned, outgoing: nil, incoming: nil)
        #expect(AutoMixDebugFormat.fallback(
            planned: plan,
            executed: .crossfade(duration: 6, outPoint: 150, inPoint: 0)) == nil)
    }

    @Test func degradedKindIsReported() {
        let planned = PlannedTransition(
            plan: .beatMatched(BeatMatchedPlan(
                outPoint: 150, inPoint: 0, overlapBars: 8,
                outgoingRate: 1, incomingRate: 1,
                bassSwapOffset: 8, overlapDuration: 16)),
            style: .plain)
        let plan = AutoMixDebugPlan(planned: planned, outgoing: nil, incoming: nil)
        let reason = AutoMixDebugFormat.fallback(planned: plan, executed: .gapless)
        #expect(reason == "beatMatched → gapless (out point unreachable)")
    }

    @Test func reAnchoredCrossfadeIsReported() {
        // The engine's own degradation: same kind, shorter, anchored at the end.
        let planned = PlannedTransition.plain(
            .crossfade(duration: 12, outPoint: 150, inPoint: 0))
        let plan = AutoMixDebugPlan(planned: planned, outgoing: nil, incoming: nil)
        let reason = AutoMixDebugFormat.fallback(
            planned: plan, executed: .crossfade(duration: 4, outPoint: 196, inPoint: 0))
        #expect(reason?.hasPrefix("re-anchored:") == true)
    }

    @Test func nothingArmedMeansNothingToCompare() {
        #expect(AutoMixDebugFormat.fallback(planned: nil, executed: .gapless) == nil)
    }

    // MARK: - Field formatting

    @Test func keyReadsAsPitchAndMode() {
        let minor = analysis(keyPitchClass: 6, keyIsMinor: true, keyConfidence: 0.71)
        #expect(AutoMixDebugFormat.key(minor) == "F♯ min (0.71)")
        #expect(AutoMixDebugFormat.key(analysis()) == nil)
    }

    @Test func clockFormatsMinutesAndSeconds() {
        #expect(AutoMixDebugFormat.clock(0) == "0:00")
        #expect(AutoMixDebugFormat.clock(125) == "2:05")
        #expect(AutoMixDebugFormat.clock(nil) == "—")
    }

    // MARK: - Force-beat-switch override

    @Test func overrideOffIsExactlyTheConfigItWasGiven() {
        // The whole safety claim of the override in one assertion: off, the
        // planner is handed the identical value, so planning is byte-identical
        // for everyone who never opens the panel.
        var base = TransitionPlanner.Config.standard
        base.loudnessCompensation = false
        #expect(AutoMixDebugOverrides.plannerConfig(base, overrides: AutoMixOverrides()) == base)
        #expect(AutoMixDebugOverrides.plannerConfig(.standard, overrides: AutoMixOverrides())
                == TransitionPlanner.Config.standard)
    }

    @Test func overrideMakesEveryAdmissionGateAbstain() {
        let forced = AutoMixDebugOverrides.plannerConfig(.standard, overrides: AutoMixOverrides(forceBeatMatch: true))

        // A cosine distance cannot exceed 2, a folded tempo ratio cannot exceed
        // 0.5, and a confidence cannot exceed 1 — so each of these gates is
        // unreachable by construction, not merely unlikely.
        #expect(forced.neutralTimbreDistance >= 2)
        #expect(forced.clashTimbreDistance >= 2)
        #expect(forced.clashTempoRatio >= 1)
        #expect(forced.keyConfidenceThreshold > 1)
        #expect(forced.neutralLoudnessDB >= 240)
        #expect(forced.clashLoudnessDB >= 240)
        #expect(forced.vocalClashRatio >= 1000)

        // A pair that clashes on every signal now reads compatible.
        let clashing = TransitionPlanner.Signals(
            loudnessGapDB: 18, trimmedLoudnessGapDB: 18, rawLoudnessGapDB: 18,
            outgoingTrimDB: 0, incomingTrimDB: 0, rideDB: 0,
            timbreDistance: 0.9, tempoRatio: 0.45)
        #expect(TransitionPlanner.tier(of: clashing, config: .standard) == .clash)
        #expect(TransitionPlanner.tier(of: clashing, config: forced) == .compatible)
    }

    @Test func overrideWidensTheWindowInBothTempoRegimes() {
        let forced = AutoMixDebugOverrides.plannerConfig(.standard, overrides: AutoMixOverrides(forceBeatMatch: true))
        #expect(forced.beatMatchBPMDeltaCap == AutoMixDebugOverrides.forcedBPMDeltaCap)
        #expect(forced.beatMatchRateCap == AutoMixDebugOverrides.forcedRateCap)

        // Which regime is in force must not change the answer.
        var stepped = forced
        stepped.tempoRampEnabled = false
        #expect(stepped.beatMatchBPMDeltaCap == AutoMixDebugOverrides.forcedBPMDeltaCap)
        #expect(stepped.beatMatchRateCap == AutoMixDebugOverrides.forcedRateCap)

        // Wider than shipped, but the bend stays somewhere a time-pitch unit
        // can go without announcing itself.
        #expect(forced.beatMatchBPMDeltaCap > TransitionPlanner.Config.standard
                    .beatMatchBPMDeltaCap)
        #expect(forced.beatMatchRateCap <= 0.08)
    }

    @Test func overrideLeavesThePhysicalRequirementsAlone() {
        let standard = TransitionPlanner.Config.standard
        let forced = AutoMixDebugOverrides.plannerConfig(standard, overrides: AutoMixOverrides(forceBeatMatch: true))
        // Without a confident tempo there is no grid to align, without room
        // there is no overlap, and without the track being long enough there is
        // nothing to transition out of. The panel does not get to pretend.
        #expect(forced.bpmConfidenceThreshold == standard.bpmConfidenceThreshold)
        #expect(forced.minTrackDuration == standard.minTrackDuration)
        #expect(forced.maxOverlap == standard.maxOverlap)
        #expect(forced.minOverlap == standard.minOverlap)
        #expect(forced.maxOverlapShare == standard.maxOverlapShare)
        #expect(forced.tailWindowSeconds == standard.tailWindowSeconds)
        #expect(forced.tailWindowShare == standard.tailWindowShare)
        #expect(forced.stableCV == standard.stableCV)
        #expect(forced.useStructureOutPoints == standard.useStructureOutPoints)
        #expect(forced.tempoRampEnabled == standard.tempoRampEnabled)
    }

    @Test func overrideCarriesTheCallersLoudnessCompensation() {
        // The override must not quietly re-enable a setting the user turned off:
        // the gate has to keep measuring what the decks will actually play.
        var base = TransitionPlanner.Config.standard
        base.loudnessCompensation = false
        #expect(!AutoMixDebugOverrides.plannerConfig(base, overrides: AutoMixOverrides(forceBeatMatch: true))
            .loudnessCompensation)
    }

    @Test func forcedPlanBeatMatchesAPairTheGatesWouldHaveRefused() {
        // 100 vs 112 BPM: 12 % apart, past the shipped 11.5 % window, and the
        // two tracks are given clashing timbre so the tier would refuse anyway.
        // The candidates have to sit in the tail window the out-point search
        // restricts itself to (`max(duration/2, outLimit − 60 s)` = 180 s here),
        // or the pair fails on a physical requirement the override cannot lift
        // and the test would be measuring the wrong refusal.
        var outgoing = analysis(duration: 240, phraseBoundaries: [200, 190, 182])
        var incoming = analysis(duration: 240, phraseBoundaries: [200, 190, 182])
        outgoing = withBPM(outgoing, 100, melProfile: [1, 0, 0, 0])
        incoming = withBPM(incoming, 112, melProfile: [0, 0, 0, 1])

        let organic = TransitionPlanner.plan(outgoing: outgoing, incoming: incoming)
        if case .beatMatched = organic.plan {
            Issue.record("fixture is supposed to be refused by the shipped gates")
        }
        let forced = TransitionPlanner.plan(
            outgoing: outgoing, incoming: incoming,
            config: AutoMixDebugOverrides.plannerConfig(.standard, overrides: AutoMixOverrides(forceBeatMatch: true)))
        guard case .beatMatched = forced.plan else {
            Issue.record("the override should have produced a beat-matched plan")
            return
        }
    }

    /// Rebuild an analysis at a given tempo, with a beat/downbeat grid that
    /// actually matches it — the beat-match rule reads both.
    private func withBPM(_ a: TrackAnalysis, _ bpm: Double,
                         melProfile: [Float]) -> TrackAnalysis {
        let beat = 60 / bpm
        return TrackAnalysis(
            version: a.version, bpm: bpm, bpmConfidence: 0.9,
            beats: stride(from: 0.0, to: a.duration, by: beat).map { $0 },
            downbeats: stride(from: 0.0, to: a.duration, by: beat * 4).map { $0 },
            phraseBoundaries: a.phraseBoundaries,
            rmsEnvelope: a.rmsEnvelope, outroFadeStart: nil,
            introEnd: a.introEnd, duration: a.duration,
            melProfile: melProfile,
            keyPitchClass: nil, keyIsMinor: false, keyConfidence: 0,
            vocalActivity: [], referenceLoudness: a.referenceLoudness,
            peakDBFS: a.peakDBFS)
    }

    // MARK: - Override composition

    @Test func everySwitchOffIsIdentityWhateverElseIsSet() {
        // The claim the whole feature rests on, stated over the *set* rather
        // than one flag: nobody who never opens the panel is planned for
        // differently.
        var base = TransitionPlanner.Config.standard
        base.loudnessCompensation = false
        base.tempoRampEnabled = false          // a caller-set knob must survive
        #expect(AutoMixDebugOverrides.plannerConfig(base, overrides: AutoMixOverrides())
                == base)
        #expect(!AutoMixOverrides().isActive)
        #expect(AutoMixOverrides().badges.isEmpty)
    }

    @Test func featureSwitchesTurnOffExactlyTheirOwnGesture() {
        let standard = TransitionPlanner.Config.standard
        let ramp = AutoMixDebugOverrides.plannerConfig(
            standard, overrides: AutoMixOverrides(disableTempoRamp: true))
        #expect(!ramp.tempoRampEnabled)
        #expect(ramp.dominantDeckBlend == standard.dominantDeckBlend)
        #expect(ramp.twoClockExchange == standard.twoClockExchange)

        let blend = AutoMixDebugOverrides.plannerConfig(
            standard, overrides: AutoMixOverrides(disableDominantDeckBlend: true))
        #expect(!blend.dominantDeckBlend)
        #expect(blend.tempoRampEnabled == standard.tempoRampEnabled)

        let exchange = AutoMixDebugOverrides.plannerConfig(
            standard, overrides: AutoMixOverrides(disableTwoClockExchange: true))
        #expect(!exchange.twoClockExchange)

        // `forceLivePath` is not a planner knob at all: it short-circuits the
        // pre-render, so the config must come back untouched.
        #expect(AutoMixDebugOverrides.plannerConfig(
            standard, overrides: AutoMixOverrides(forceLivePath: true)) == standard)
    }

    @Test func switchesComposeWithTheForceOverride() {
        // Force + no ramp is the interesting composition: with the ramp off the
        // *stepped* caps are what the beat-match rule reads, and the force
        // block sets both pairs precisely so this still opens the window.
        let both = AutoMixDebugOverrides.plannerConfig(
            .standard,
            overrides: AutoMixOverrides(forceBeatMatch: true, disableTempoRamp: true))
        #expect(!both.tempoRampEnabled)
        #expect(both.beatMatchBPMDeltaCap == AutoMixDebugOverrides.forcedBPMDeltaCap)
        #expect(both.beatMatchRateCap == AutoMixDebugOverrides.forcedRateCap)
        #expect(both.neutralTimbreDistance >= 2)

        let all = AutoMixOverrides(
            forceBeatMatch: true, disableTempoRamp: true, disableDominantDeckBlend: true,
            disableTwoClockExchange: true, forceLivePath: true)
        #expect(all.badges.count == 5)
        #expect(all.needsReArm(comparedTo: AutoMixOverrides()))
        #expect(!AutoMixOverrides(forceBeatMatch: true)
            .needsReArm(comparedTo: AutoMixOverrides()))
    }

    // MARK: - Jump-to-seam lead

    @Test func aPlainCrossfadeGetsTheFloorLead() {
        let result = AutoMixSeamJump.compute(.init(outPoint: 180))
        #expect(result.lead == AutoMixSeamJump.floorLead)
        #expect(result.target == 150)
        #expect(result.reason == "floor")
        #expect(!result.losesPrerender)
    }

    @Test func aBeatMatchedSeamGetsItsWholeGlide() {
        // 13 s of glide plus a 4 dB pad at 0.3 dB/s = 13.3 s of lead-in: 26.3 s
        // in total, still under the floor, so the floor wins and the glide is
        // covered anyway.
        let short = AutoMixSeamJump.compute(
            .init(outPoint: 200, isBeatMatched: true, rampLeadSeconds: 13, padDB: -4))
        #expect(short.lead == AutoMixSeamJump.floorLead)

        // A deeper pad pushes the run-up past the floor, and then the ramp sets
        // the lead and says so.
        let deep = AutoMixSeamJump.compute(
            .init(outPoint: 200, isBeatMatched: true, rampLeadSeconds: 13, padDB: -8))
        #expect(deep.lead > AutoMixSeamJump.floorLead)
        #expect(deep.reason.hasPrefix("tempo ramp"))
        #expect(abs(deep.lead - (13 + 8 / 0.3)) < 0.001)
    }

    @Test func anUnrenderedStemSeamWaitsForItsRunway() {
        let result = AutoMixSeamJump.compute(.init(
            outPoint: 200, needsStemPrerender: true, segmentArmed: false,
            prerenderLead: 60, prerenderHandoff: 0.5))
        #expect(abs(result.lead - 60.5) < 0.001)
        #expect(result.reason.hasPrefix("stem pre-render runway"))
        #expect(!result.losesPrerender)

        // Already rendered and armed: the runway is spent, so the floor is
        // enough and the listener gets to the seam sooner.
        let armed = AutoMixSeamJump.compute(.init(
            outPoint: 200, needsStemPrerender: true, segmentArmed: true,
            prerenderLead: 60, prerenderHandoff: 0.5))
        #expect(armed.lead == AutoMixSeamJump.floorLead)
    }

    @Test func aShortTrackClampsAndSaysWhatThatCosts() {
        // The out point is 40 s in; a 60.5 s runway does not fit before it.
        let result = AutoMixSeamJump.compute(.init(
            outPoint: 40, needsStemPrerender: true, segmentArmed: false,
            prerenderLead: 60, prerenderHandoff: 0.5))
        #expect(result.target == 0)
        #expect(result.lead == 40)
        #expect(result.reason.contains("clamped"))
        // …and the seam will therefore be carried by the live path.
        #expect(result.losesPrerender)
    }

    // MARK: - Feedback corpus

    @Test func aFeedbackLineIsOneVersionedRoundTrippableObject() throws {
        let entry = AutoMixFeedbackEntry(
            at: Date(timeIntervalSince1970: 1_700_000_000),
            verdict: .bad,
            note: "vocal came in\nover the outgoing chorus",
            outgoing: .init(id: 1, title: "A"),
            incoming: .init(id: 2, title: "B"),
            planned: .init(AutoMixDebugPlan(
                planned: .plain(.crossfade(duration: 6, outPoint: 150, inPoint: 0)),
                outgoing: nil, incoming: nil)),
            executed: .init(kind: "gapless", outPoint: nil, overlap: 0),
            gesture: "vocalExchange",
            path: "liveOverlap",
            overrides: ["forceBeatMatch"],
            config: "deadbeef")

        let line = try AutoMixFeedbackLog.line(entry)
        // The file's whole contract is one object per line, and a note is free
        // text a listener types in a hurry.
        #expect(!line.contains("\n"))
        #expect(line.contains("\"v\":1"))

        let decoded = try AutoMixFeedbackLog.decoder()
            .decode(AutoMixFeedbackEntry.self, from: Data(line.utf8))
        #expect(decoded.v == AutoMixFeedbackEntry.currentVersion)
        #expect(decoded.verdict == .bad)
        #expect(decoded.note == "vocal came in over the outgoing chorus")
        #expect(decoded.outgoing?.id == 1)
        #expect(decoded.incoming?.title == "B")
        #expect(decoded.planned?.outPoint == 150)
        #expect(decoded.executed?.kind == "gapless")
        #expect(decoded.gesture == "vocalExchange")
        #expect(decoded.path == "liveOverlap")
        #expect(decoded.overrides == ["forceBeatMatch"])
        #expect(decoded.config == "deadbeef")
        #expect(decoded.at == entry.at)
    }

    @Test func appendingKeepsOneObjectPerLine() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("automix-feedback-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        for index in 0..<3 {
            let entry = AutoMixFeedbackEntry(
                at: Date(timeIntervalSince1970: TimeInterval(index)),
                verdict: index.isMultiple(of: 2) ? .good : .bad,
                note: nil, outgoing: nil, incoming: nil, planned: nil, executed: nil,
                gesture: nil, path: nil, overrides: [], config: "0")
            #expect(AutoMixFeedbackLog.append(entry, to: url))
        }
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 3)
        let decoder = AutoMixFeedbackLog.decoder()
        for line in lines {
            _ = try decoder.decode(AutoMixFeedbackEntry.self, from: Data(line.utf8))
        }
    }

    @Test func theConfigFingerprintIsStableAndDiscriminating() {
        let standard = TransitionPlanner.Config.standard
        // Stable across calls — a seeded hash would not be, and a corpus keyed
        // on one could never be joined across sessions.
        #expect(AutoMixFeedbackLog.configFingerprint(standard)
                == AutoMixFeedbackLog.configFingerprint(standard))
        // …and it moves when the calibration does.
        var moved = standard
        moved.rampMaxBPMDeltaRatio += 0.001
        #expect(AutoMixFeedbackLog.configFingerprint(moved)
                != AutoMixFeedbackLog.configFingerprint(standard))
        #expect(AutoMixFeedbackLog.configFingerprint(
            AutoMixDebugOverrides.plannerConfig(
                standard, overrides: AutoMixOverrides(forceBeatMatch: true)))
                != AutoMixFeedbackLog.configFingerprint(standard))
    }

    // MARK: - Model bookkeeping

    @Test @MainActor func seamHistoryKeepsTheLastThreeNewestFirst() {
        let model = AutoMixDebugModel.shared
        for index in 0..<5 {
            model.recordSeam(AutoMixDebugSeam(
                from: "from \(index)", to: "to \(index)", planned: nil,
                path: "liveOverlap", executedKind: "crossfade",
                executedOutPoint: nil, executedOverlap: 6,
                fallback: nil, prerender: "idle"))
        }
        let seams = model.currentSeamsForTesting
        #expect(seams.count == AutoMixDebugModel.seamHistoryLimit)
        #expect(seams.first?.from == "from 4")
        #expect(seams.last?.from == "from 2")
    }
}
