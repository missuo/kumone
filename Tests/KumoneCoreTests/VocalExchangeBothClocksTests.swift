import Testing
@testable import KumoneCore
import Foundation

/// The vocal hand-over reads **both** lyric clocks.
///
/// Until now the compile picked one instant, L, off the *outgoing* track's
/// line ends, and held the incoming vocal at −40 dB from the top of the overlap
/// until it. Two field seams showed what that costs when deck B is already
/// singing: an incoming rap track entered 27.97 s in and singing every ~1.6 s
/// had its first 8.4 s muted and was then released **mid-line**, and an
/// in-point of 0.012 s with L at 16.9 s of a 28.9 s overlap threw away the
/// first seventeen seconds of the new singer. 用户: "deck B 的人声接入太迟了".
///
/// So the exchange is now a *pair* of instants — one line ending as the next
/// begins — and, when no such pair exists, the incoming voice waits for its own
/// next line start instead of being unmuted in the middle of one. And the
/// planner, one layer up, makes room for the gesture by entering deck B in its
/// own pre-vocal gap.
@Suite struct VocalExchangeBothClocksTests {

    // MARK: - Fixtures

    private func analysis(duration: TimeInterval = 200,
                          level: Float = 0.8) -> TrackAnalysis {
        TrackAnalysis(version: TrackAnalysis.currentVersion, bpm: 120, bpmConfidence: 0.9,
                      beats: [], downbeats: [], phraseBoundaries: [],
                      rmsEnvelope: [Float](repeating: 0.5, count: Int(duration)),
                      outroFadeStart: nil, introEnd: 0, duration: duration,
                      melProfile: [], keyPitchClass: nil, keyIsMinor: false,
                      keyConfidence: 0,
                      vocalActivity: [Float](repeating: level, count: Int(duration)))
    }

    /// A `.lrc` next to a path that holds no audio: the compile only ever reads
    /// the sidecar.
    private func sidecar(_ lrc: String) -> URL {
        let track = FileManager.default.temporaryDirectory
            .appendingPathComponent("clock-\(UUID().uuidString).flac")
        try? Data(lrc.utf8).write(to: Audition.Lyrics.sidecarURL(for: track))
        return track
    }

    private func remove(_ track: URL) {
        try? FileManager.default.removeItem(at: Audition.Lyrics.sidecarURL(for: track))
    }

    /// Both sidecars for one hand-over, cleaned up together.
    private func withBothClocks(outgoing: String, incoming: String?,
                                _ body: (URL, URL?) -> Void) {
        let out = sidecar(outgoing)
        let inc = incoming.map { sidecar($0) }
        defer {
            remove(out)
            if let inc { remove(inc) }
        }
        body(out, inc)
    }

    /// 12 s of overlap at out point 100 s: the floor swap sits at 6 s, the
    /// hand-over window at [3.6 s, 10.2 s], and the exchange window is the
    /// 0.35 s ceiling (a crossfade has no grid to ask).
    private func crossfade(outPoint: TimeInterval = 100,
                           overlap: TimeInterval = 12) -> PlannedTransition {
        PlannedTransition(plan: .crossfade(duration: overlap, outPoint: outPoint, inPoint: 0),
                          style: .plain)
    }

    /// The outgoing side of every pair test: lines at 100/105/108/112 s, so the
    /// line **ends** inside the overlap are 5 s, 8 s and 12 s.
    private let outgoingLRC = """
    [01:40.00]甲
    [01:45.00]乙
    [01:48.00]丙
    [01:52.00]丁
    """

    // MARK: - The pair

    /// The earliest outgoing line end that has an incoming line start landing
    /// on it wins — not the latest, and not the carryover the single-clock rule
    /// would have preferred. Earliest is the shortest stretch with deck B's
    /// voice muted, which is the whole complaint.
    @Test func theExchangeTakesTheEarliestPairOfLines() {
        withBothClocks(outgoing: outgoingLRC, incoming: """
        [00:05.20]新句一
        [00:08.10]新句二
        """) { out, inc in
            let (technique, compiled) = Audition.VocalExchange.compile(
                outgoingURL: out, incomingURL: inc, outgoing: analysis(),
                planned: crossfade(), config: .standard)
            // Ends at 5 s and 8 s are both eligible (5 s yields, 8 s carries),
            // and both have an incoming line within the tolerance — so the
            // earlier one wins even though it is the *yield*.
            #expect(abs(compiled.handover - 5) < 1e-6)
            #expect(compiled.lyricLine == "甲")
            #expect(compiled.gesture == .yield)
            #expect(abs(compiled.incomingRelease - 5.2) < 1e-6)
            #expect(compiled.incomingLine == "新句一")
            #expect(compiled.pairSource == "pair")
            guard case .custom(let envelope) = technique else {
                Issue.record("expected a compiled envelope")
                return
            }
            // The new singer is still muted at the old one's last syllable and
            // audible a fraction of a beat after their own line starts.
            #expect(envelope.gainDB(.incomingVocal, at: 4.9)
                        == Audition.VocalExchange.incomingVocalMutedDB)
            #expect(envelope.gainDB(.incomingVocal, at: 5.6) > -6)
        }
    }

    /// The pair is a pair only inside the tolerance — one beat, or the exchange
    /// window when the grid is faster than that. A line start 0.6 s after the
    /// old line ends is a different phrase, so the earlier end is passed over
    /// and the *later* pair is taken.
    @Test func aLineStartPastTheToleranceIsNotAPair() {
        withBothClocks(outgoing: outgoingLRC, incoming: """
        [00:05.60]太晚了
        [00:08.10]正好
        """) { out, inc in
            let (_, compiled) = Audition.VocalExchange.compile(
                outgoingURL: out, incomingURL: inc, outgoing: analysis(),
                planned: crossfade(), config: .standard)
            #expect(abs(compiled.handover - 8) < 1e-6)
            #expect(compiled.gesture == .carryover)
            #expect(abs(compiled.incomingRelease - 8.1) < 1e-6)
            #expect(compiled.incomingLine == "正好")
            #expect(compiled.pairSource == "pair")
        }
    }

    /// No pair at all: L is today's single-clock pick, and the incoming voice
    /// then waits for **its own** next line rather than being unmuted in the
    /// middle of one. The gap between the two is a breath between singers, and
    /// it is intended.
    @Test func withoutAPairTheIncomingWaitsForItsOwnNextLine() {
        withBothClocks(outgoing: outgoingLRC, incoming: """
        [00:09.00]我的第一句
        """) { out, inc in
            let (technique, compiled) = Audition.VocalExchange.compile(
                outgoingURL: out, incomingURL: inc, outgoing: analysis(),
                planned: crossfade(), config: .standard)
            // The single-clock rule's answer, unchanged: the earliest line end
            // past the floor swap, so a carryover at 8 s.
            #expect(abs(compiled.handover - 8) < 1e-6)
            #expect(compiled.gesture == .carryover)
            #expect(compiled.pairSource == "nextLine")
            #expect(abs(compiled.incomingRelease - 9) < 1e-6)
            #expect(compiled.incomingLine == "我的第一句")
            guard case .custom(let envelope) = technique else {
                Issue.record("expected a compiled envelope")
                return
            }
            // Both voices are gone in between — the breath — and neither is
            // ever heard over the other.
            #expect(envelope.gainDB(.outgoingVocal, at: 8.6) == StemEnvelope.minGainDB)
            #expect(envelope.gainDB(.incomingVocal, at: 8.6)
                        == Audition.VocalExchange.incomingVocalMutedDB)
            #expect(envelope.gainDB(.incomingVocal, at: 9.4) > -6)
        }
    }

    /// The incoming voice is **never** released before L: two singers must not
    /// overlap. Incoming lines that all sit before the hand-over leave the
    /// release exactly at L.
    @Test func theIncomingIsNeverReleasedBeforeTheHandover() {
        withBothClocks(outgoing: outgoingLRC, incoming: """
        [00:01.00]太早
        [00:02.00]还是太早
        """) { out, inc in
            let (_, compiled) = Audition.VocalExchange.compile(
                outgoingURL: out, incomingURL: inc, outgoing: analysis(),
                planned: crossfade(), config: .standard)
            #expect(compiled.incomingRelease >= compiled.handover)
            #expect(abs(compiled.incomingRelease - compiled.handover) < 1e-6)
            #expect(compiled.pairSource == "handover")
            #expect(compiled.incomingLine == nil)
        }
    }

    /// An incoming track with no `.lrc` compiles to what this template always
    /// produced, curve for curve. The second clock is an addition, not a
    /// rewrite: without it there is nothing to add.
    @Test func withNoIncomingLyricsTheCompileIsUnchanged() {
        withBothClocks(outgoing: outgoingLRC, incoming: nil) { out, _ in
            let (_, before) = Audition.VocalExchange.compile(
                outgoingURL: out, outgoing: analysis(),
                planned: crossfade(), config: .standard)
            let (_, after) = Audition.VocalExchange.compile(
                outgoingURL: out, incomingURL: sidecarWithNoFile(), outgoing: analysis(),
                planned: crossfade(), config: .standard)
            #expect(before.envelope == after.envelope)
            #expect(after.pairSource == "handover")
            #expect(abs(after.incomingRelease - after.handover) < 1e-6)
            #expect(after.incomingLine == nil)
        }
    }

    /// A URL with no sidecar behind it — "the app had no words for this track".
    private func sidecarWithNoFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("absent-\(UUID().uuidString).flac")
    }

    // MARK: - The mapping

    /// The incoming deck plays at its own rate, so its lyric stamps are mapped
    /// `(t − inPoint) / rateIn` before anything compares them with the outgoing
    /// side's. A 1.25× deck reaches a stamp five seconds in after four seconds
    /// of overlap.
    @Test func incomingLineStartsAreMappedThroughTheIncomingRate() {
        withBothClocks(outgoing: outgoingLRC, incoming: """
        [00:30.00]零
        [00:35.00]四
        [00:40.00]八
        [01:00.00]窗口之外
        """) { _, inc in
            let plan = TransitionPlan.beatMatched(BeatMatchedPlan(
                outPoint: 100, inPoint: 30, overlapBars: 4,
                outgoingRate: 1, incomingRate: 1.25,
                bassSwapOffset: 6, overlapDuration: 12))
            let starts = Audition.VocalExchange.incomingLineStarts(
                incomingURL: inc, plan: plan, overlap: 12)
            #expect(starts.count == 3)
            #expect(abs(starts[0].start - 0) < 1e-6)
            #expect(abs(starts[1].start - 4) < 1e-6)
            #expect(abs(starts[2].start - 8) < 1e-6)
            // A stamp from elsewhere in the song is not an instant this
            // hand-over can aim at.
            #expect(starts.allSatisfy { $0.text != "窗口之外" })
        }
    }

    // MARK: - The planner makes room

    private func downbeats(bpm: Double, duration: TimeInterval) -> [TimeInterval] {
        let bar = 4 * 60 / bpm
        return Array(stride(from: 0.4, to: duration, by: bar))
    }

    private func plannerAnalysis(bpm: Double, introEnd: TimeInterval) -> TrackAnalysis {
        let duration: TimeInterval = 240
        var a = TrackAnalysis(
            version: TrackAnalysis.currentVersion, bpm: bpm, bpmConfidence: 0.9,
            beats: Array(stride(from: 0.4, to: duration, by: 60 / bpm)),
            downbeats: downbeats(bpm: bpm, duration: duration),
            phraseBoundaries: [200, 150, 90],
            rmsEnvelope: [Float](repeating: 0.5, count: Int(duration)),
            outroFadeStart: nil, introEnd: introEnd, duration: duration,
            melProfile: Self.peakedProfile, keyPitchClass: nil, keyIsMinor: false,
            keyConfidence: 0,
            vocalActivity: [Float](repeating: 0.8, count: Int(duration)),
            referenceLoudness: nil, peakDBFS: -6)
        a.structureConfidence = 0.8
        return a
    }

    private static let peakedProfile: [Float] = {
        let raw = [Float(39)] + [Float](repeating: -1, count: 39)
        let norm = raw.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        return raw.map { $0 / norm }
    }()

    private var intentOn: TransitionPlanner.Config {
        var config = TransitionPlanner.Config.standard
        config.intentEnabled = true
        return config
    }

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

    /// An incoming track whose first line arrives 20 s in and then sings every
    /// 1.6 s, entered at its structural in-point of 22 s: the compile would
    /// have nothing to work with, because deck B is mid-verse from the first
    /// sample of the overlap. The planner moves the entry back into the song's
    /// own pre-vocal gap and shortens the overlap, so the incoming singer's
    /// first line lands just past the floor swap.
    @Test func theInPointMovesIntoThePreVocalGapForAVocalExchange() {
        let outgoing = plannerAnalysis(bpm: 128, introEnd: 2)
        let incoming = plannerAnalysis(bpm: 130, introEnd: 22)
        var starts: [TimeInterval] = []
        var t: TimeInterval = 20
        while t < 200 { starts.append(t); t += 1.6 }
        let timing = TransitionPlanner.PlanContext.LyricTiming(
            lineStarts: starts, lineEnds: Array(starts.dropFirst()) + [starts.last! + 1.6])

        let blind = TransitionPlanner.plan(outgoing: outgoing, incoming: incoming,
                                           stems: .ready, config: intentOn)
        let aimed = TransitionPlanner.plan(
            outgoing: outgoing, incoming: incoming, stems: .ready, config: intentOn,
            context: .init(incomingLyricTiming: timing))

        #expect(aimed.style.stemTechnique == .vocalExchange)
        guard case .beatMatched(let before) = blind.plan,
              case .beatMatched(let after) = aimed.plan else {
            Issue.record("expected two beat-matched plans")
            return
        }
        // Entered earlier — into the 0–20 s gap — and over a shorter window.
        #expect(after.inPoint < before.inPoint - 1)
        #expect(after.overlapBars <= 8)
        #expect(after.overlapBars < before.overlapBars)
        // …and the first line then lands on the late side of the floor swap
        // rather than under eight seconds of mute — within a bar of it, which
        // is the granularity the downbeat grid leaves this rule.
        let landing = (20 - after.inPoint) / Double(after.incomingRate)
        let bar = after.overlapDuration / Double(after.overlapBars)
        #expect(landing > after.overlapDuration / 2)
        #expect(landing < after.overlapDuration / 2 + bar)
        // The decision is explained where the intent layer explains itself —
        // the `intent=blend (…)` string the journal's `plan armed` line prints.
        #expect(aimed.style.intent?.reasons
            .contains { $0.contains("vocal entry") } == true)
        #expect(aimed.style.intent?.label.contains("pre-vocal gap") == true)
    }

    /// No lyric timing, or no exchange to aim: the planner's output is
    /// byte-identical to today's. This is the whole safety argument for the
    /// layer — a library without `.lrc` sidecars decides exactly as it did.
    @Test func nilLyricTimingLeavesThePlannerUnchanged() {
        let outgoing = plannerAnalysis(bpm: 128, introEnd: 2)
        let incoming = plannerAnalysis(bpm: 130, introEnd: 22)
        let timing = TransitionPlanner.PlanContext.LyricTiming(
            lineStarts: [20, 21.6, 23.2], lineEnds: [21.6, 23.2, 24.8])

        for stems in [StemAvailability.none, .ready] {
            for config in [TransitionPlanner.Config.standard, intentOn] {
                let none = TransitionPlanner.plan(outgoing: outgoing, incoming: incoming,
                                                  stems: stems, config: config)
                let nilTiming = TransitionPlanner.plan(
                    outgoing: outgoing, incoming: incoming, stems: stems, config: config,
                    context: .init(incomingLyricTiming: nil))
                #expect(describe(none) == describe(nilTiming))
                #expect(none.style.intent == nilTiming.style.intent)
            }
        }
        // And with timing but no exchange requested — the intent layer off, so
        // nothing asks for a `.vocalExchange` — the aim never runs either.
        let off = TransitionPlanner.plan(outgoing: outgoing, incoming: incoming,
                                         stems: .ready)
        let offWithTiming = TransitionPlanner.plan(
            outgoing: outgoing, incoming: incoming, stems: .ready,
            context: .init(incomingLyricTiming: timing))
        #expect(describe(off) == describe(offWithTiming))
    }
}
