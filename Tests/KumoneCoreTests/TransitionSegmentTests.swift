import Testing
@testable import KumoneCore
import AVFoundation
import Foundation

// Pre-rendered stem hand-overs (S3): the geometry of a rendered segment, the
// engine's rules for accepting one, and what the splice actually sounds like.
//
// Nothing here needs a separation model. The stem layer takes its vocal from an
// injected provider, so these tests inject one that returns silence: the bed is
// then the whole mixture and the render is a plain transition — which is
// exactly what a continuity assertion wants, and still exercises every line of
// the pre-render and splice paths.

// MARK: - Fixtures and helpers

private enum SegmentFixtures {

    static let dir: URL = {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransitionSegment-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// 44.1 kHz stereo — matches the graph format, so decks take the
    /// sample-accurate `.file` path the splice needs.
    static let outgoing: URL = try! sine(hz: 440, seconds: 10, name: "seg-out")
    static let incoming: URL = try! sine(hz: 660, seconds: 10, name: "seg-in")

    /// The same incoming track at 96 kHz — the format the graph does *not*
    /// run at, so the deck loads it as `.convertedFile` and the splice has to
    /// hand back through a feeder instead of a frame-exact `scheduleSegment`.
    /// About two fifths of a real library is hi-res, and every one of those
    /// seams used to lose its pre-rendered segment.
    static let incomingHiRes: URL =
        try! sine(hz: 660, seconds: 10, sampleRate: 96_000, name: "seg-in-96k")

    static func sine(hz: Double, seconds: Double, sampleRate: Double = 44_100,
                     name: String) throws -> URL {
        let url = dir.appendingPathComponent("\(name).caf")
        if FileManager.default.fileExists(atPath: url.path) { return url }
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
}

/// A separator that hears no vocal: the bed is the whole mixture, so every
/// lane gain lands on material that is really there and the render stays a
/// plain transition. Model-free by construction.
private let silentVocals: VocalStemProvider = { request in
    VocalStem(channels: request.samples.map { [Float](repeating: 0, count: $0.count) })
}

private let failingSeparator: VocalStemProvider = { _ in
    throw StemTechniqueLayer.StemError.emptyWindow
}

private func plan(overlap: TimeInterval = 2, outPoint: TimeInterval = 5,
                  inPoint: TimeInterval = 0,
                  technique: StemTechnique? = .vocalDuck(depthDB: -9)) -> PlannedTransition {
    var style = TransitionStyle(outroEffect: .fade, stagedEQ: true)
    style.stemTechnique = technique
    return PlannedTransition(
        plan: .crossfade(duration: overlap, outPoint: outPoint, inPoint: inPoint),
        style: style)
}

private func request(_ planned: PlannedTransition,
                     incoming: URL = SegmentFixtures.incoming
) -> TransitionSegmentRenderer.Request {
    TransitionSegmentRenderer.Request(
        planned: planned,
        outgoingURL: SegmentFixtures.outgoing, incomingURL: incoming)
}

/// Runs `body` on its own thread, failing the test rather than hanging the run.
private final class Box<T>: @unchecked Sendable { var value: T? }

private func withWatchdog<T>(_ label: String, timeout: TimeInterval,
                             _ body: @escaping () -> T) -> T? {
    let box = Box<T>()
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        box.value = body()
        done.signal()
    }
    thread.name = "segment-\(label)"
    thread.stackSize = 1 << 21
    thread.start()
    if done.wait(timeout: .now() + timeout) == .timedOut {
        Issue.record("Watchdog: '\(label)' did not finish within \(timeout)s")
        return nil
    }
    return box.value
}

private let audioOutputAvailable: Bool = {
    let engine = AVAudioEngine()
    engine.mainMixerNode.outputVolume = 0
    engine.prepare()
    do {
        try engine.start()
        engine.stop()
        return true
    } catch {
        print("TransitionSegment: no usable audio output; playback assertions skipped")
        return false
    }
}()

// MARK: - Geometry

// Declared *inside* the smoke suite, which is `.serialized`: that trait is
// recursive, so these tests never run alongside the other engine tests. Two
// `PlaybackEngine`s starting, tapping and stopping AVAudioEngine nodes at the
// same time deadlock CoreAudio — `removeTap` waits for an in-flight tap
// callback while that callback waits for the graph lock the teardown holds.
extension PlaybackEngineSmokeTests {

@Suite("TransitionSegment")
struct TransitionSegmentTests {

    // The splice's whole contract in one test: where the segment starts on the
    // outgoing track, where it hands back on the incoming one, and that its two
    // handoff windows are the duplicated material they are supposed to be.
    @Test func segmentMapsOntoBothTracks() throws {
        let planned = plan(overlap: 4, outPoint: 6, inPoint: 1)
        let segment = try TransitionSegmentRenderer.render(request(planned),
                                                           provider: silentVocals)
        let handoff = TransitionSegmentRenderer.handoff

        #expect(abs(segment.handoffIn - handoff) < 0.01)
        #expect(abs(segment.spliceStart - (6 - handoff)) < 0.01,
                "the segment takes over one head window before the out point")
        #expect(abs(segment.outgoingStart - (6 - handoff)) < 0.01,
                "and its first sample is that same instant of the outgoing track")

        // head window + overlap + tail window, with no settling for a crossfade.
        #expect(abs(segment.duration - (handoff + 4 + handoff)) < 0.05,
                "got \(segment.duration)s")

        // Head: the segment plays the outgoing track at rate 1 up to the out point.
        #expect(abs(segment.outgoingTime(at: 0) - (6 - handoff)) < 0.01)
        #expect(abs(segment.outgoingTime(at: handoff) - 6) < 0.02)

        // The incoming track does not start until the overlap does, then runs
        // at rate 1 to the hand-back.
        #expect(abs(segment.incomingTime(at: 0) - 1) < 0.01)
        #expect(abs(segment.incomingTime(at: handoff) - 1) < 0.01)
        #expect(abs(segment.incomingResume - (1 + 4)) < 0.05,
                "the incoming deck should be cued to in point + overlap, got \(segment.incomingResume)")
        #expect(abs(segment.handoffOutStart - (segment.duration - handoff)) < 0.001)

        // The audible hand-over sits at the middle of a plain crossfade.
        #expect(abs(segment.midpointOffset - (handoff + 2)) < 0.05)
        #expect(segment.incomingRideDB == 0, "no ride was planned")
        #expect(segment.signature == TransitionSegment.Signature(plan: planned.plan))
    }

    // A beat-matched deck consumes `rate` source seconds per rendered second,
    // and keeps doing so through the rate restore. The cue point has to follow
    // the rates, not the wall clock, or the incoming deck resumes off by a beat.
    @Test func beatMatchedSegmentFollowsTheStretchedClock() throws {
        let beat = BeatMatchedPlan(
            outPoint: 6, inPoint: 1, overlapBars: 4,
            outgoingRate: 1.0, incomingRate: 1.04,
            bassSwapOffset: 2, overlapDuration: 4)
        var style = TransitionStyle(outroEffect: .fade, stagedEQ: true)
        style.stemTechnique = .vocalDuck(depthDB: -9)
        let planned = PlannedTransition(plan: .beatMatched(beat), style: style)
        var req = request(planned)
        req.planned = planned
        let segment = try TransitionSegmentRenderer.render(req, provider: silentVocals)

        // Overlap at 1.04×, then the rate restore glides back to 1.0 — so the
        // deck has eaten more than 4 s of its own track by the hand-back, but
        // less than 1.04 × (overlap + restore).
        let consumed = segment.incomingResume - 1
        let restore = TransitionAutomation.rateRestoreDuration
        #expect(consumed > 4 * 1.03, "got \(consumed)s of incoming source")
        #expect(consumed < (4 + restore + TransitionSegmentRenderer.handoff) * 1.04,
                "got \(consumed)s of incoming source")
        // The settling phase is inside the segment, so the deck resumes at
        // rate 1 and the tail window is the last half second.
        #expect(segment.duration > TransitionSegmentRenderer.handoff + 4 + restore)
    }

    // The post-swap glide's contract, seen from the splice — where it matters
    // most, because a segment is *pre-rendered* and the deck has to pick the
    // track up from it at the right place and the right speed.
    //
    // Three things have to hold at once, and the old hold-then-release curve
    // satisfied them differently: the deck resumes at unity (so the tail window
    // is an identity crossfade against audio the segment rendered unbent), it
    // resumes at the position the glide's *integral* puts it at (not
    // `overlap × incomingRate`), and the segment no longer has to carry a
    // settling phase at all, which makes it shorter.
    @Test func aGlidingSegmentHandsBackAtUnityAndAtTheGlidesIntegral() throws {
        let beat = BeatMatchedPlan(
            outPoint: 6, inPoint: 1, overlapBars: 4,
            outgoingRate: 1.0, incomingRate: 1.04,
            bassSwapOffset: 2, overlapDuration: 4,
            rampLeadSeconds: 13, rampReleaseSeconds: 3,
            rampGlideBackFromSwap: true)
        var style = TransitionStyle(outroEffect: .fade, stagedEQ: true)
        style.stemTechnique = .vocalDuck(depthDB: -9)
        let planned = PlannedTransition(plan: .beatMatched(beat), style: style)
        var req = request(planned)
        req.planned = planned
        let segment = try TransitionSegmentRenderer.render(req, provider: silentVocals)

        let plan = TransitionPlan.beatMatched(beat)
        let geometry = TransitionAutomation.Geometry(plan: plan)
        let glide = try #require(TransitionAutomation.incomingGlide(for: plan,
                                                                   geometry: geometry))
        let handoff = TransitionSegmentRenderer.handoff
        // Swap at 2 s of a 4 s overlap, so the glide is floored at the plan's
        // 3 s release and spills 1 s past the overlap into the settling phase.
        let spill = TransitionAutomation.rateReleaseDuration(plan, geometry: geometry)
        #expect(abs(spill - 1) < 1e-9)
        #expect(abs(segment.duration - (handoff + 4 + spill + handoff)) < 0.05,
                "head + overlap + what is left of the glide + tail (\(segment.duration))")
        // Strictly shorter than the old curve, which always paid the full
        // `rampReleaseSeconds` after the overlap.
        #expect(segment.duration < handoff + 4 + beat.rampReleaseSeconds + handoff)

        // The hand-back position is the glide's integral across the overlap and
        // its spill — measurably *not* what a constant `incomingRate` gives.
        let consumed = segment.incomingResume - beat.inPoint
        let expected = glide.sourceAdvance(to: geometry.overlapDuration + spill)
        #expect(abs(consumed - expected) < 0.05,
                "expected \(expected)s of incoming source, got \(consumed)s")
        let naive = (4 + spill) * Double(beat.incomingRate)
        #expect(consumed < naive - 0.02,
                "a gliding deck eats less than a held one (\(consumed) vs \(naive))")

        // And the tail the deck crossfades against was rendered at unity, which
        // is what makes the identity crossfade an identity: past the hand-back
        // the segment advances one source second per rendered second, matching
        // a deck that resumes unbent.
        let tailEnd = segment.incomingTime(at: segment.duration - 0.02)
        #expect(abs((tailEnd - segment.incomingResume) - (handoff - 0.02)) < 0.02,
                "the tail window must be unbent (\(segment.incomingResume) → \(tailEnd))")
    }

    // MARK: - Refusals

    // Every way the pre-render declines, so the caller falls back to the live
    // hand-over instead of splicing something wrong.
    @Test func aSegmentIsOnlyRenderedWhenItCanBeRenderedProperly() throws {
        // No stem technique: there is nothing a segment would add.
        #expect(throws: TransitionSegmentRenderer.SegmentError.self) {
            _ = try TransitionSegmentRenderer.render(
                request(plan(technique: nil)), provider: silentVocals)
        }
        // `.gapless` has no overlap to render.
        var style = TransitionStyle(outroEffect: .fade, stagedEQ: false)
        style.stemTechnique = .vocalDuck(depthDB: -9)
        #expect(throws: TransitionSegmentRenderer.SegmentError.self) {
            _ = try TransitionSegmentRenderer.render(
                request(PlannedTransition(plan: .gapless, style: style)),
                provider: silentVocals)
        }
        // The separator failed: the render would be a whole-mix transition, and
        // the live path does that better (it can still be seeked and re-planned).
        #expect(throws: TransitionSegmentRenderer.SegmentError.self) {
            _ = try TransitionSegmentRenderer.render(request(plan()),
                                                     provider: failingSeparator)
        }
        // Longer than the pre-render budget.
        #expect(throws: TransitionSegmentRenderer.SegmentError.self) {
            _ = try TransitionSegmentRenderer.render(
                request(plan(overlap: TransitionSegmentRenderer.maxOverlap + 5, outPoint: 60)),
                provider: silentVocals)
        }
    }

    // `.vocalExchange` is a marker the planner emits and only the decision layer
    // can compile. The renderer refuses to render one, so the pre-render has to
    // compile it first — here, with no analysis to aim at, into a plain duck.
    @Test func vocalExchangeIsCompiledBeforeRendering() throws {
        let segment = try TransitionSegmentRenderer.render(
            request(plan(overlap: 4, outPoint: 6, technique: .vocalExchange)),
            provider: silentVocals)
        #expect(segment.duration > 0)
    }

    // MARK: - Arming rules

    @Test func theEngineOnlyTakesASegmentForTheSeamItIsWaitingOn() throws {
        guard audioOutputAvailable else { return }
        let planned = plan(overlap: 2, outPoint: 6)
        let segment = try TransitionSegmentRenderer.render(request(planned),
                                                           provider: silentVocals)
        let other = try TransitionSegmentRenderer.render(
            request(plan(overlap: 2, outPoint: 7)), provider: silentVocals)

        let result = withWatchdog("armingRules", timeout: 30) { () -> (Bool, Bool, Bool) in
            let engine = PlaybackEngine()
            defer { engine.stopAll() }
            guard (try? engine.loadFile(at: SegmentFixtures.outgoing, on: .a)) != nil,
                  (try? engine.loadFile(at: SegmentFixtures.incoming, on: .b)) != nil
            else { return (false, false, false) }
            engine.outputVolume = 0
            engine.play(deck: .a, from: 0)
            engine.scheduleTransition(planned, from: .a, to: .b)
            Thread.sleep(forTimeInterval: 0.3)

            // A segment cut for a different seam is refused outright.
            engine.armTransitionSegment(other)
            let refusedForeign = !engine.hasArmedSegment
            engine.armTransitionSegment(segment)
            let accepted = engine.hasArmedSegment

            // A seek past the splice point degrades the plan; the segment goes
            // with it rather than splicing audio from where the playhead no
            // longer is.
            engine.seek(deck: .a, to: 5.9)
            Thread.sleep(forTimeInterval: 0.4)
            return (refusedForeign, accepted, !engine.hasArmedSegment)
        }
        guard let (refusedForeign, accepted, droppedOnSeek) = result else { return }
        #expect(refusedForeign, "a segment for another seam must not be armed")
        #expect(accepted, "a segment matching the waiting plan should be armed")
        #expect(droppedOnSeek, "a seek past the splice must drop the segment")
    }

    @Test func cancellingTheTransitionDropsTheSegment() throws {
        guard audioOutputAvailable else { return }
        let planned = plan(overlap: 2, outPoint: 6)
        let segment = try TransitionSegmentRenderer.render(request(planned),
                                                           provider: silentVocals)
        let result = withWatchdog("cancelDropsSegment", timeout: 30) { () -> (Bool, Bool) in
            let engine = PlaybackEngine()
            defer { engine.stopAll() }
            guard (try? engine.loadFile(at: SegmentFixtures.outgoing, on: .a)) != nil,
                  (try? engine.loadFile(at: SegmentFixtures.incoming, on: .b)) != nil
            else { return (false, false) }
            engine.outputVolume = 0
            engine.play(deck: .a, from: 0)
            engine.scheduleTransition(planned, from: .a, to: .b)
            Thread.sleep(forTimeInterval: 0.3)
            engine.armTransitionSegment(segment)
            let armed = engine.hasArmedSegment
            engine.cancelScheduledTransition()
            Thread.sleep(forTimeInterval: 0.2)
            return (armed, !engine.hasPendingTransition)
        }
        guard let (armed, cancelled) = result else { return }
        #expect(armed)
        #expect(cancelled, "cancelling takes the whole hand-over, segment included")
    }

    // MARK: - The splice itself

    // The real thing, end to end: a segment is armed, the outgoing deck hands
    // over to it, and it hands over to the incoming deck. What must be true
    // throughout is that *something* is sounding — a hole would be a dropout —
    // and that no two sources are ever at full level at once, which is what a
    // splice that failed to silence one side would look like.
    @Test func aSplicedHandOverIsContinuousAndNeverDoubled() throws {
        guard audioOutputAvailable else { return }
        let planned = plan(overlap: 2, outPoint: 4)
        let segment = try TransitionSegmentRenderer.render(request(planned),
                                                           provider: silentVocals)

        struct Sample { var t: TimeInterval; var deckA: Float; var deckB: Float; var seg: Float }
        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private var samples: [(TimeInterval, Int, Float)] = []
            let start = Date()
            func record(_ source: Int, _ peak: Float) {
                lock.lock(); defer { lock.unlock() }
                samples.append((Date().timeIntervalSince(start), source, peak))
            }
            func snapshot() -> [(TimeInterval, Int, Float)] {
                lock.lock(); defer { lock.unlock() }
                return samples
            }
        }

        let result = withWatchdog("splice", timeout: 45) {
            () -> ([(TimeInterval, Int, Float)], Bool, TimeInterval) in
            let engine = PlaybackEngine()
            let events = SegmentEventLog(engine)
            defer {
                engine.setOutputMonitor(on: .a, nil)
                engine.setOutputMonitor(on: .b, nil)
                engine.setSegmentOutputMonitor(nil)
                engine.stopAll()
            }
            guard (try? engine.loadFile(at: SegmentFixtures.outgoing, on: .a)) != nil,
                  (try? engine.loadFile(at: SegmentFixtures.incoming, on: .b)) != nil
            else { return ([], false, 0) }
            engine.outputVolume = 0
            let recorder = Recorder()
            engine.setOutputMonitor(on: .a) { recorder.record(0, $0) }
            engine.setOutputMonitor(on: .b) { recorder.record(1, $0) }
            engine.setSegmentOutputMonitor { recorder.record(2, $0) }
            engine.play(deck: .a, from: 1.5)
            engine.scheduleTransition(planned, from: .a, to: .b)
            Thread.sleep(forTimeInterval: 0.3)
            engine.armTransitionSegment(segment)
            let completed = events.wait(timeout: 20) {
                if case .transitionCompleted(from: .a, to: .b) = $0 { return true }
                return false
            }
            let completedAt = Date().timeIntervalSince(recorder.start)
            Thread.sleep(forTimeInterval: 0.5)
            return (recorder.snapshot(), completed, completedAt)
        }
        guard let (samples, completed, completedAt) = result, !samples.isEmpty else {
            Issue.record("no audio was captured")
            return
        }
        #expect(completed, "the spliced hand-over should complete on its own")

        // The segment really carried the middle of the hand-over.
        let segmentPeak = samples.filter { $0.1 == 2 }.map(\.2).max() ?? 0
        #expect(segmentPeak > 0.05, "the segment never sounded (peak \(segmentPeak))")

        // Per-source level over time. The three taps fire independently, so a
        // bucket is judged on each source's most recent peak rather than on
        // whatever happened to be delivered inside it.
        let window = samples.filter { $0.0 > 0.4 && $0.0 < completedAt }
        let buckets = Set(window.map { Int($0.0 * 10) }).sorted()
        var levels: [Int: [Float]] = [:]
        for bucket in buckets {
            let until = Double(bucket + 1) / 10
            levels[bucket] = (0..<3).map { source in
                window.last { $0.1 == source && $0.0 <= until }?.2 ?? 0
            }
        }
        let timeline = buckets.map { bucket -> String in
            let level = levels[bucket]!
            return String(format: "%.1f:%.2f/%.2f/%.2f", Double(bucket) / 10,
                          level[0], level[2], level[1])
        }.joined(separator: " ")
        print("splice a/seg/b: \(timeline)")

        // A hole in the output is a dropout; two sources at full level at once
        // is a splice that forgot to silence one side (0.25 each, so ~0.5).
        let silent = buckets.filter { (levels[$0]!.max() ?? 0) < 0.03 }
        let doubled = buckets.filter { levels[$0]!.reduce(0, +) > 0.42 }
        #expect(silent.isEmpty,
                "the output went silent at \(silent.map { Double($0) / 10 })")
        #expect(doubled.isEmpty,
                "two sources were at full level at once at \(doubled.map { Double($0) / 10 })")
    }

    // MARK: - Rate and pad hygiene across the splice

    /// **The splice has to leave both decks as clean as the live overlap does.**
    ///
    /// Every rate/pad test in the suite drives the *live* hand-over. The
    /// segment path reaches the same two decks by a completely different route
    /// — `beginOverlapLocked` never runs, so the incoming deck is never bent or
    /// padded by the engine at all (its rate restore is rendered *into* the
    /// audio), and the outgoing deck is bent by the pre-seam glide and then
    /// retired by `retireOutgoingForSegmentLocked`, which deliberately stops
    /// short of `resetDeckLocked` so an abort can resume it. That leaves a
    /// window where the deck is stopped, still loaded, and still carrying the
    /// pad bookkeeping of a bend that is over.
    ///
    /// So: run a beat-matched seam through the segment, on 0 dBFS masters so
    /// both decks really owe a headroom pad, and ask the deck the segment
    /// replaced and the deck that took over the same questions the live path is
    /// held to — by polling, because a stale glide target is re-applied by a
    /// later tick and never by the first one.
    @Test func theSegmentSplicePathKeepsBothDecksClean() throws {
        guard audioOutputAvailable else { return }
        enum Ending: String, CaseIterable {
            /// The splice runs to its own end and hands back normally.
            case completes
            /// Torn down while the segment is sounding.
            case cancelledMidSegment
            /// The deck the segment replaced is put back on the air *after*
            /// `retireOutgoingForSegmentLocked` has stopped it but before the
            /// splice finishes — the one window where a retired deck is
            /// stopped, still loaded, and never reset.
            case playRetiredDeckMidSegment
        }
        /// Worst reading seen on one deck across a poll.
        ///
        /// The pad is judged on where it is *heading* and on whether it got any
        /// deeper, never on its absolute value — an aborted splice puts the
        /// outgoing deck back on the air still wearing the pad its bend needed,
        /// and letting go of that at an inaudible 0.3 dB/s is the design, so
        /// 6.5 dB takes 21 s to walk off and any absolute check just measures
        /// how long the test waited. What must be true is that it is on its way
        /// to zero and nothing is pushing it back down.
        struct Worst: CustomStringConvertible {
            var rateDeviation: Float = 0
            var padTargetDB: Double = 0
            var firstPadDB: Double?
            var padDB: Double = 0
            var padDeepenedBy: Double = 0
            var neutral = true
            var volume: Float = 0
            var description: String {
                "rate 1±\(rateDeviation), pad \(padDB) dB → \(padTargetDB) dB "
                    + "(deepened \(padDeepenedBy) dB), effectsNeutral \(neutral), "
                    + "volume \(volume)"
            }
        }

        // A bent seam with a real pre-seam glide: the ramp window sits at
        // [outPoint − handoff − lead, outPoint − handoff] = [3.5, 5.5] on the
        // outgoing track, and the splice takes over at 5.5.
        let beat = BeatMatchedPlan(
            outPoint: 6, inPoint: 1, overlapBars: 4,
            outgoingRate: 0.96, incomingRate: 1.05,
            bassSwapOffset: 1.5, overlapDuration: 3,
            rampLeadSeconds: 2, rampReleaseSeconds: 2)
        var style = TransitionStyle(outroEffect: .fade, stagedEQ: true)
        style.stemTechnique = .vocalDuck(depthDB: -9)
        let planned = PlannedTransition(plan: .beatMatched(beat), style: style)
        var req = request(planned)
        req.planned = planned
        let segment = try TransitionSegmentRenderer.render(req, provider: silentVocals)

        for ending in Ending.allCases {
            let result = withWatchdog("spliceHygiene-\(ending.rawValue)",
                                      timeout: 70) { () -> [(String, Deck, Worst)]? in
                var observations: [(String, Deck, Worst)] = []
                let engine = PlaybackEngine()
                let events = SegmentEventLog(engine)
                defer { engine.stopAll() }
                guard (try? engine.loadFile(at: SegmentFixtures.outgoing, on: .a,
                                            peakDBFS: 0)) != nil,
                      (try? engine.loadFile(at: SegmentFixtures.incoming, on: .b,
                                            peakDBFS: 0)) != nil
                else { return nil }
                engine.outputVolume = 0

                func poll(_ label: String, seconds: TimeInterval) {
                    var worst: [Deck: Worst] = [.a: Worst(), .b: Worst()]
                    let deadline = Date().addingTimeInterval(seconds)
                    while Date() < deadline {
                        for deck in [Deck.a, Deck.b] {
                            let s = engine.effectSnapshot(of: deck)
                            var w = worst[deck]!
                            w.rateDeviation = max(w.rateDeviation, abs(s.rate - 1))
                            if abs(s.ratePadTargetDB) > abs(w.padTargetDB) {
                                w.padTargetDB = s.ratePadTargetDB
                            }
                            let first = w.firstPadDB ?? s.ratePadDB
                            w.firstPadDB = first
                            w.padDeepenedBy = max(w.padDeepenedBy, first - s.ratePadDB)
                            w.padDB = s.ratePadDB
                            w.neutral = w.neutral && s.effectsAreNeutral
                            w.volume = s.volume
                            worst[deck] = w
                        }
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                    for deck in [Deck.a, Deck.b] {
                        observations.append((label, deck, worst[deck]!))
                    }
                }

                // Start inside the pre-seam ramp's approach so deck A is really
                // bent and padded by the time the splice takes over.
                engine.play(deck: .a, from: 3.0)
                engine.scheduleTransition(planned, from: .a, to: .b)
                Thread.sleep(forTimeInterval: 0.3)
                engine.armTransitionSegment(segment)
                guard engine.hasArmedSegment else { return nil }

                // Teeth: everything below is only worth asserting if the deck
                // the segment is about to replace really is bent and padded
                // when it hands over. Recorded, not assumed — a plan whose ramp
                // silently resolved away would make every check that follows
                // pass by doing nothing.
                Thread.sleep(forTimeInterval: 1.2)
                let bent = engine.effectSnapshot(of: .a)
                observations.append(("\(ending.rawValue)/PRE-SPLICE BEND", .a, Worst(
                    rateDeviation: abs(bent.rate - 1), padTargetDB: bent.ratePadTargetDB,
                    padDB: bent.ratePadDB, neutral: bent.effectsAreNeutral,
                    volume: bent.volume)))

                switch ending {
                case .completes:
                    guard events.wait(timeout: 25, for: {
                        if case .transitionCompleted(from: .a, to: .b) = $0 { return true }
                        return false
                    }) else { return nil }
                case .cancelledMidSegment, .playRetiredDeckMidSegment:
                    // Wait until the segment is actually sounding and past its
                    // head crossfade, i.e. deck A has been retired.
                    let deadline = Date().addingTimeInterval(20)
                    while Date() < deadline, !engine.segmentIsPlaying {
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                    guard engine.segmentIsPlaying else { return nil }
                    Thread.sleep(forTimeInterval: 1.2)
                    if ending == .playRetiredDeckMidSegment {
                        engine.play(deck: .a, from: 1.0)
                    } else {
                        engine.cancelScheduledTransition()
                    }
                }

                // Let every release the teardown started run its course.
                let settle = Date().addingTimeInterval(14)
                while Date() < settle, engine.hasPendingTransition {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                Thread.sleep(forTimeInterval: 1.0)
                poll("\(ending.rawValue)/after the splice", seconds: 1.5)

                // The alternation check: the next track lands on whichever deck
                // is spent, and must not inherit anything from this seam.
                let spent: Deck = ending == .completes ? .a : .b
                guard (try? engine.loadFile(at: SegmentFixtures.outgoing, on: spent,
                                            peakDBFS: 0)) != nil else { return observations }
                engine.play(deck: spent, from: 0.5)
                poll("\(ending.rawValue)/next track on \(spent)", seconds: 1.5)
                return observations
            }
            guard let observations = result ?? nil else { continue }

            for (label, deck, worst) in observations {
                let here = "\(label): deck \(deck)"
                if label.hasSuffix("PRE-SPLICE BEND") {
                    // The inverse assertion, and the reason the rest mean
                    // anything: this deck must be genuinely bent and padded on
                    // its way into the splice.
                    let toothless = "\(here) was never bent or padded on its way into "
                        + "the splice, so every hygiene check below passes vacuously "
                        + "— the plan's tempo ramp or headroom pad resolved away (\(worst))"
                    #expect(worst.rateDeviation > 0.005 && worst.padDB < -0.05,
                            "\(toothless)")
                    continue
                }
                let detuned = "\(here) is detuned — the splice left the phase vocoder "
                    + "engaged on a deck nothing is bending (\(worst))"
                let aiming = "\(here) is still aiming at a headroom pad from the seam "
                    + "the segment carried (\(worst))"
                let held = "\(here) is being padded *down* — a headroom pad is being "
                    + "acquired by a deck the splice is no longer bending (\(worst))"
                let coloured = "\(here) has a chain the splice never handed back (\(worst))"
                #expect(worst.rateDeviation < 0.001, "\(detuned)")
                #expect(abs(worst.padTargetDB) < 0.001, "\(aiming)")
                #expect(worst.padDeepenedBy < 0.001, "\(held)")
                #expect(worst.neutral, "\(coloured)")
            }
        }
    }

    // MARK: - A hi-res incoming deck

    /// **The splice must survive an incoming track the graph cannot play
    /// natively.**
    ///
    /// A file whose rate or channel count differs from the 44.1 kHz stereo graph
    /// loads as `.convertedFile`, because reconnecting a running graph throws.
    /// The engine used to refuse every pre-rendered segment aimed at such a
    /// deck — silently, and reported as "the seam moved" — so on a library that
    /// is roughly two fifths hi-res, two fifths of all stem hand-overs were
    /// quietly never performed.
    ///
    /// The hand-back is the whole difficulty: a `.file` deck is cued frame-exact
    /// in one call, a feeder has to be pre-rolled and then released on the same
    /// host clock. So this asks the two questions that separates a working
    /// splice from a plausible one — did it complete with both decks clean, and
    /// did the incoming deck come back at the position the segment handed it.
    @Test func aHiResIncomingDeckIsSplicedAndResumesWhereTheSegmentLeftIt() throws {
        guard audioOutputAvailable else { return }
        let planned = plan(overlap: 2, outPoint: 4)
        let segment = try TransitionSegmentRenderer.render(
            request(planned, incoming: SegmentFixtures.incomingHiRes),
            provider: silentVocals)

        struct Outcome {
            var declined: PlaybackEngine.SegmentDecline?
            var armed = false
            var completed = false
            var positionAtCompletion: TimeInterval = 0
            var deckA: PlaybackEngine.DeckEffectSnapshot?
            var deckB: PlaybackEngine.DeckEffectSnapshot?
        }

        let result = withWatchdog("hiResSplice", timeout: 45) { () -> Outcome? in
            var outcome = Outcome()
            let engine = PlaybackEngine()
            let events = SegmentEventLog(engine)
            defer { engine.stopAll() }
            guard (try? engine.loadFile(at: SegmentFixtures.outgoing, on: .a)) != nil,
                  (try? engine.loadFile(at: SegmentFixtures.incomingHiRes, on: .b)) != nil
            else { return nil }
            engine.outputVolume = 0
            engine.play(deck: .a, from: 1.5)
            engine.scheduleTransition(planned, from: .a, to: .b)
            Thread.sleep(forTimeInterval: 0.3)
            engine.armTransitionSegment(segment)
            outcome.declined = engine.lastSegmentDecline
            outcome.armed = engine.hasArmedSegment
            guard outcome.armed else { return outcome }
            outcome.completed = events.wait(timeout: 25) {
                if case .transitionCompleted(from: .a, to: .b) = $0 { return true }
                return false
            }
            // Read the hand-back position first and the chains after: the
            // position is the perishable one.
            outcome.positionAtCompletion = engine.position(of: .b)
            Thread.sleep(forTimeInterval: 1.0)
            outcome.deckA = engine.effectSnapshot(of: .a)
            outcome.deckB = engine.effectSnapshot(of: .b)
            return outcome
        }
        guard let outcome = result ?? nil else { return }

        let notDeclined = "a hi-res incoming deck must not be a reason to decline a "
            + "segment (got \(String(describing: outcome.declined)))"
        #expect(outcome.declined == nil, "\(notDeclined)")
        #expect(outcome.armed, "the segment should have been armed")
        guard outcome.armed else { return }
        #expect(outcome.completed, "the spliced hand-over should complete on its own")

        // Where the deck should be when the splice finishes: the segment handed
        // it the track at `incomingResume` and it has been playing the tail
        // window since. The tolerance is the event's own delivery latency, not
        // the feeder's accuracy — a feeder that resumed at the wrong *place*
        // would be out by whole seconds, which is the failure this catches.
        let expected = segment.incomingResume + segment.handoffOut
        let drifted = "the incoming deck resumed at \(outcome.positionAtCompletion)s, "
            + "but the segment handed it the track at \(segment.incomingResume)s and the "
            + "tail is \(segment.handoffOut)s long (expected ≈\(expected)s)"
        #expect(abs(outcome.positionAtCompletion - expected) < 0.4, "\(drifted)")

        // And the splice left both decks as clean as the live overlap does.
        if let deckB = outcome.deckB {
            #expect(abs(deckB.rate - 1) < 0.001,
                    "the incoming deck is detuned after the splice (\(deckB.rate))")
            #expect(deckB.effectsAreNeutral,
                    "the incoming deck kept a chain the splice never handed back")
        }
        if let deckA = outcome.deckA {
            #expect(abs(deckA.rate - 1) < 0.001,
                    "the retired deck is detuned after the splice (\(deckA.rate))")
            #expect(deckA.effectsAreNeutral,
                    "the retired deck kept a chain the splice never handed back")
        }
    }

    // MARK: - Honest refusals

    /// **Every decline says which rule declined it.**
    ///
    /// The offer is fire-and-forget, so for a long time the caller reported a
    /// guess — one sentence covering four different rules — and the field
    /// journal duly recorded renders that had finished half a minute early as
    /// seams that had moved. Each case below trips exactly one guard.
    @Test func aDeclinedSegmentSaysWhichRuleDeclinedIt() throws {
        guard audioOutputAvailable else { return }
        let planned = plan(overlap: 2, outPoint: 4)
        let segment = try TransitionSegmentRenderer.render(request(planned),
                                                           provider: silentVocals)
        let foreign = try TransitionSegmentRenderer.render(
            request(plan(overlap: 2, outPoint: 7)), provider: silentVocals)

        typealias Decline = PlaybackEngine.SegmentDecline
        struct Seen {
            var noPlan: Decline?
            var deckEmpty: Decline?
            var otherSeam: Decline?
            var accepted: Decline?
            var offeredTwice: Decline?
            var tooLate: Decline?
        }
        let result = withWatchdog("declineReasons", timeout: 40) { () -> Seen? in
            var seen = Seen()
            let engine = PlaybackEngine()
            defer { engine.stopAll() }
            guard (try? engine.loadFile(at: SegmentFixtures.outgoing, on: .a)) != nil
            else { return nil }
            engine.outputVolume = 0
            engine.play(deck: .a, from: 0)
            Thread.sleep(forTimeInterval: 0.2)

            // No plan is waiting at all.
            engine.armTransitionSegment(segment)
            seen.noPlan = engine.lastSegmentDecline

            // A plan is waiting, but its incoming deck was never loaded, so
            // there is nothing for the segment's tail to hand back to.
            engine.scheduleTransition(planned, from: .a, to: .b)
            Thread.sleep(forTimeInterval: 0.2)
            engine.armTransitionSegment(segment)
            seen.deckEmpty = engine.lastSegmentDecline

            // Loaded now, but with a segment cut for a different seam.
            guard (try? engine.loadFile(at: SegmentFixtures.incoming, on: .b)) != nil
            else { return nil }
            engine.scheduleTransition(planned, from: .a, to: .b)
            Thread.sleep(forTimeInterval: 0.2)
            engine.armTransitionSegment(foreign)
            seen.otherSeam = engine.lastSegmentDecline

            // The right segment is taken, and a second offer of it is not.
            engine.armTransitionSegment(segment)
            seen.accepted = engine.lastSegmentDecline
            engine.armTransitionSegment(segment)
            seen.offeredTwice = engine.lastSegmentDecline

            // A genuinely late render: the playhead is already past the point
            // where the segment would have taken over. (`spliceStart` is one
            // half-second head window before the 4 s out point.)
            engine.cancelScheduledTransition()
            engine.play(deck: .a, from: 3.6)
            engine.scheduleTransition(planned, from: .a, to: .b)
            Thread.sleep(forTimeInterval: 0.2)
            engine.armTransitionSegment(segment)
            seen.tooLate = engine.lastSegmentDecline
            return seen
        }
        guard let seen = result ?? nil else { return }

        #expect(seen.noPlan == .wrongPhase)
        #expect(seen.deckEmpty == .unsupportedSource)
        #expect(seen.otherSeam == .signatureMismatch)
        let taken = "the matching segment should have been taken "
            + "(declined: \(String(describing: seen.accepted)))"
        #expect(seen.accepted == nil, "\(taken)")
        #expect(seen.offeredTwice == .alreadyArmed)
        let late = "a render that lands after the splice point must say so, got "
            + "\(String(describing: seen.tooLate))"
        #expect(seen.tooLate == .splicePassed, "\(late)")
    }
}

} // extension PlaybackEngineSmokeTests

/// Minimal event collector; the smoke-test suite's own is file-private.
private final class SegmentEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [PlaybackEngineEvent] = []
    private var task: Task<Void, Never>?

    init(_ engine: PlaybackEngine) {
        task = Task {
            for await event in engine.events { self.append(event) }
        }
    }

    deinit { task?.cancel() }

    private func append(_ event: PlaybackEngineEvent) {
        lock.lock(); defer { lock.unlock() }
        events.append(event)
    }

    func wait(timeout: TimeInterval, for predicate: (PlaybackEngineEvent) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let hit = events.contains(where: predicate)
            lock.unlock()
            if hit { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }
}
