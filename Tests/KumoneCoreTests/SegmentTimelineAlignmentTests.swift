import Testing
@testable import KumoneCore
import AVFoundation
import Foundation

// Does a rendered segment's audio actually sit where the segment *says* it
// sits?
//
// Everything downstream of `OfflineTransitionRenderer` treats the two
// `TimelinePoint` lists as ground truth: the live splice reads `incomingResume`
// off them to cue the deck for the tail crossfade, and playback position is
// reported through them. So a segment whose map is right in shape but shifted
// in time is worse than a broken one — it splices confidently onto the wrong
// sample. The field symptom was exactly that: the incoming deck came back
// ~93 ms ahead of the segment, the tail crossfade played the same bar twice,
// and it read as the drums stuttering ("卡拍子").
//
// The measurement here is the direct one. Both songs are click trains at known
// source times, so any rendered instant can be converted through the segment's
// own map and asked "does this land on a click?" — a question the render cannot
// answer correctly unless every deck really did join where the map claims. The
// two spacings are chosen coprime-ish and the two sides are rendered against
// silence on the other deck, so a peak can only ever have come from one song.
// That costs a second render and buys an unambiguous reading; the plan drives
// the automation and the rates, never the audio, so both passes are the same
// transition to the frame (asserted below).

// MARK: - Fixtures

private enum ClickTrainAudio {

    static let sampleRate = 44_100.0
    /// Spacings deliberately unrelated, so no outgoing click can be mistaken
    /// for an incoming one even if the two renders were ever merged.
    static let outgoingSpacing: TimeInterval = 0.11
    static let incomingSpacing: TimeInterval = 0.29

    static let outgoingClicks: URL =
        try! clicks(every: outgoingSpacing, seconds: 32, name: "click-out")
    static let incomingClicks: URL =
        try! clicks(every: incomingSpacing, seconds: 24, name: "click-in")
    static let silentLong: URL = try! clicks(every: 0, seconds: 32, name: "silence-long")
    static let silentShort: URL = try! clicks(every: 0, seconds: 24, name: "silence-short")

    static let dir: URL = {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClickTrain-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// Half the burst, in seconds. A burst is symmetric and is *centred* on its
    /// click time, so the envelope peak the detector finds is the click time —
    /// no half-burst bias to subtract, at either rate.
    static let halfBurst: TimeInterval = 0.003

    /// A train of Hann-windowed 1 kHz bursts, one every `spacing` seconds
    /// (`spacing == 0` writes silence).
    ///
    /// 1 kHz because it sits in the mid band, which no part of this plan
    /// touches: a click made of an impulse would be mostly bass, and the
    /// incoming deck's bass cut would swallow it exactly where the test needs
    /// to see it. Windowed because a phase vocoder smears a bare step into
    /// something with no defined position, and the whole measurement is a
    /// position.
    static func clicks(every spacing: TimeInterval, seconds: Double,
                       name: String) throws -> URL {
        let url = dir.appendingPathComponent("\(name).caf")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let total = Int(seconds * sampleRate)
        var samples = [Float](repeating: 0, count: total)
        if spacing > 0 {
            let half = Int(halfBurst * sampleRate)
            var click = spacing
            while click < seconds - 0.05 {
                let centre = Int(click * sampleRate)
                for i in -half..<half where centre + i >= 0 && centre + i < total {
                    let phase = Float(i + half) / Float(2 * half)
                    let window = 0.5 - 0.5 * cosf(2 * .pi * phase)
                    samples[centre + i] =
                        0.9 * window * sinf(2 * .pi * 1000 * Float(i) / Float(sampleRate))
                }
                click += spacing
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 4096
        let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                      frameCapacity: AVAudioFrameCount(chunk))!
        var frame = 0
        while frame < total {
            let n = min(chunk, total - frame)
            for channel in 0..<2 {
                let data = buffer.floatChannelData![channel]
                for i in 0..<n { data[i] = samples[frame + i] }
            }
            buffer.frameLength = AVAudioFrameCount(n)
            try file.write(from: buffer)
            frame += n
        }
        return url
    }
}

/// A separator that hears no vocal, so a duck lands on a silent lane and the
/// render is bit-for-bit the plain transition. The technique is only there
/// because `TransitionSegmentRenderer` refuses to pre-render a hand-over that
/// asks for nothing; it must not change a sample of the audio being measured.
private let noVocals: VocalStemProvider = { request in
    VocalStem(channels: request.samples.map { [Float](repeating: 0, count: $0.count) })
}

// MARK: - Peak picking

/// Rendered times of the click bursts in one channel.
///
/// A short moving average of |x| turns each burst into a single hump; the
/// detector reports the hump's argmax, which for a symmetric burst is its
/// centre whatever the rate stretched it into. `floor` is relative to the
/// loudest hump, because both decks are under a fader ramp for the whole
/// overlap and an absolute threshold would simply stop seeing the deck that is
/// on its way out.
private func clickTimes(_ channel: [Float], sampleRate: Double,
                        floor relativeFloor: Float = 0.06) -> [TimeInterval] {
    let window = 96
    var envelope = [Float](repeating: 0, count: channel.count)
    var running: Float = 0
    for i in 0..<channel.count {
        running += abs(channel[i])
        if i >= window { running -= abs(channel[i - window]) }
        envelope[i] = running / Float(window)
    }
    let ceiling = envelope.max() ?? 0
    guard ceiling > 0 else { return [] }
    let threshold = ceiling * relativeFloor
    var times: [TimeInterval] = []
    var i = 0
    while i < envelope.count {
        guard envelope[i] > threshold else { i += 1; continue }
        var best = i, end = i
        while end < envelope.count, envelope[end] > threshold {
            if envelope[end] > envelope[best] { best = end }
            end += 1
        }
        // The average lags the signal by half its window; undo that so the
        // reported time is the burst's, not the detector's.
        times.append((Double(best) - Double(window) / 2) / sampleRate)
        i = end
    }
    return times
}

/// How far a source time is from the nearest click on a train's grid.
private func gridError(_ source: TimeInterval, spacing: TimeInterval) -> TimeInterval {
    let k = (source / spacing).rounded()
    return abs(source - k * spacing)
}

// MARK: - The test

@Suite struct SegmentTimelineAlignmentTests {

    /// The plan under test: a tempo ramp on the outgoing deck (so the pre-roll
    /// is a glide and its rendered length is not its source length) and an
    /// incoming deck at a bent rate (so the incoming deck's own clock runs at a
    /// different speed from the render's, which is what makes "schedule it at
    /// the right frame" a conversion rather than a copy).
    private var planned: PlannedTransition {
        let matched = BeatMatchedPlan(
            outPoint: 20, inPoint: 3, overlapBars: 8,
            outgoingRate: 1.03, incomingRate: 0.9616,
            bassSwapOffset: 2, overlapDuration: 6,
            rampLeadSeconds: 12, rampReleaseSeconds: 2)
        return PlannedTransition(plan: .beatMatched(matched),
                                 style: TransitionStyle(outroEffect: .fade, stagedEQ: false,
                                                        stemTechnique: .vocalDuck(depthDB: -9)))
    }

    private func segment(outgoing: URL, incoming: URL) throws -> TransitionSegment {
        var request = TransitionSegmentRenderer.Request(
            planned: planned, outgoingURL: outgoing, incomingURL: incoming)
        request.outgoingTrimDB = 0
        request.incomingTrimDB = 0
        return try TransitionSegmentRenderer.render(request, provider: noVocals)
    }

    /// The whole defect, stated as an assertion: every burst in the rendered
    /// segment, converted through the segment's own map, has to land on the
    /// grid the burst was written on.
    ///
    /// A deck that joined late shows up as a *constant* offset on its side of
    /// the map — the render believes the deck started when it was told to, the
    /// audio started ~4092 frames later, and every position on that deck's
    /// timeline is wrong by the difference. Before the fix this reported ≈93 ms
    /// on the incoming side; the outgoing side, whose player has always started
    /// before the first render, was already exact.
    @Test func aRenderedSegmentsMapLandsOnTheAudioItDescribes() throws {
        let outgoingOnly = try segment(outgoing: ClickTrainAudio.outgoingClicks,
                                       incoming: ClickTrainAudio.silentShort)
        let incomingOnly = try segment(outgoing: ClickTrainAudio.silentLong,
                                       incoming: ClickTrainAudio.incomingClicks)

        // The two passes are the same transition: nothing in the render reads
        // the audio, so the maps must agree to the sample. If they ever stop
        // agreeing, the comparison below is meaningless and this says so first.
        #expect(outgoingOnly.duration == incomingOnly.duration)
        #expect(outgoingOnly.incoming == incomingOnly.incoming)
        #expect(outgoingOnly.outgoing == incomingOnly.outgoing)

        let sampleRate = ClickTrainAudio.sampleRate
        let tolerance = 0.002
        let head = outgoingOnly.handoffIn

        // How far the map is allowed to be from the audio, at a burst rendered
        // `elapsed` seconds after its deck started playing.
        //
        // 2 ms is the whole budget for *joining* — the thing this test is
        // about. The per-second term is a second, unrelated inaccuracy that has
        // always been here and is not fixable from this side:
        // `AVAudioUnitTimePitch` does not honour a bent rate exactly (measured
        // at ~0.7–0.8 parts per thousand, always overshooting the bend; unity
        // is exact), so a map built from the *requested* rate walks away from
        // the audio at ~0.8 ms per rendered second for as long as the deck is
        // bent. Both decks show it, at the same slope, before and after this
        // fix — which is exactly why it is allowed for rather than asserted
        // away, and why the allowance is a slope and not a constant. A deck
        // that joined late is a *constant* error from its very first sample, so
        // no amount of elapsed time can hide one: at the tail hand-over, the
        // furthest point measured here, the bound is still under 8 ms against a
        // defect of 93.
        func allowance(since elapsed: TimeInterval) -> TimeInterval {
            tolerance + 0.001 * max(0, elapsed)
        }

        // --- The outgoing side, across the head window the live deck is
        // crossfaded out over. This is the control: it was already right, and
        // it is what "right" looks like.
        let outChannel = channel(of: outgoingOnly.buffer)
        let outClicks = clickTimes(outChannel, sampleRate: sampleRate)
            .filter { $0 < head + outgoingOnly.signature.overlapDuration * 0.4 }
        #expect(outClicks.count >= 4, "expected clicks across the head (\(outClicks.count))")
        var worstOutgoing = 0.0
        for click in outClicks {
            let error = gridError(outgoingOnly.outgoingTime(at: click),
                                  spacing: ClickTrainAudio.outgoingSpacing)
            // The outgoing deck is bent from the segment's first sample.
            #expect(error < allowance(since: click),
                    "outgoing map is off by \(error * 1000) ms at \(click) s")
            worstOutgoing = max(worstOutgoing, error)
        }

        // --- The incoming side, across the overlap and the post-roll. The
        // fader opens over the overlap, so the first bursts are genuinely
        // quiet; start looking once the blend is past its knee.
        let inChannel = channel(of: incomingOnly.buffer)
        let inClicks = clickTimes(inChannel, sampleRate: sampleRate)
            .filter { $0 > head + incomingOnly.signature.overlapDuration * 0.15 }
        #expect(inClicks.count >= 8, "expected clicks across the tail (\(inClicks.count))")
        var worstIncoming = 0.0
        var worstPostRoll = 0.0
        for click in inClicks {
            let error = gridError(incomingOnly.incomingTime(at: click),
                                  spacing: ClickTrainAudio.incomingSpacing)
            // The incoming deck joins at the seam, so its drift clock starts
            // there — and its join error is the number this whole test exists
            // to bound.
            #expect(error < allowance(since: click - head),
                    "incoming map is off by \(error * 1000) ms at \(click) s")
            worstIncoming = max(worstIncoming, error)
            if click >= incomingOnly.handoffOutStart - 0.5 {
                worstPostRoll = max(worstPostRoll, error)
            }
        }

        // --- And the number the live splice actually reads. The deck is cued
        // to `incomingResume` and crossfaded against the segment's last half
        // second, so if that number is early by 93 ms the deck plays a bar the
        // segment is still playing and the listener hears it twice.
        //
        // Checked against real audio, and deliberately *not* against the map:
        // comparing the map to itself would cancel the very offset being
        // hunted. So take the burst nearest the hand-over, name the grid click
        // it must be (the bursts were written on exact multiples, and the map
        // is nowhere near half a spacing out even when it is broken), and walk
        // that known source time back to `handoffOutStart`. The tail is
        // post-roll, where the incoming deck is home at rate 1, so the walk is
        // one subtraction — and what comes out is what `incomingResume` owes
        // the live deck.
        // The join itself, with no drift allowance to hide behind: the first
        // burst the opening fader lets through is barely a second past the
        // seam, so whatever the map is wrong by there is what the deck joined
        // wrong by. This is the assertion the defect fails outright.
        let firstIn = try #require(inClicks.first)
        #expect(gridError(incomingOnly.incomingTime(at: firstIn),
                          spacing: ClickTrainAudio.incomingSpacing) < tolerance,
                "the incoming deck joined \(gridError(incomingOnly.incomingTime(at: firstIn), spacing: ClickTrainAudio.incomingSpacing) * 1000) ms off the seam")

        let handoff = incomingOnly.handoffOutStart
        #expect(worstPostRoll < allowance(since: handoff - head),
                "the tail hand-over point is off by \(worstPostRoll * 1000) ms")
        let nearest = try #require(inClicks.min {
            abs($0 - handoff) < abs($1 - handoff)
        })
        #expect(abs(nearest - handoff) < ClickTrainAudio.incomingSpacing,
                "no burst near the hand-over to measure against")
        let spacing = ClickTrainAudio.incomingSpacing
        let known = (incomingOnly.incomingTime(at: nearest) / spacing).rounded() * spacing
        let resume = incomingOnly.incomingResume
        #expect(abs(resume - (known + handoff - nearest))
                < allowance(since: handoff - head),
                "incomingResume \(resume) cues the deck \((resume - known - handoff + nearest) * 1000) ms from the audio")
        // And it is somewhere the incoming track actually is.
        #expect(resume > incomingOnly.signature.inPoint)
    }

    /// The dry run and the pump loop are the same arithmetic, which is the only
    /// reason the incoming deck can be scheduled before the render starts: the
    /// frame the overlap will land on has to be knowable, and knowable by the
    /// *same* rule the loop will use, or the deck joins a sample or two off the
    /// seam it was measured against.
    @Test func thePreRollDryRunAgreesWithThePumpLoop() throws {
        let matched = BeatMatchedPlan(
            outPoint: 20, inPoint: 3, overlapBars: 4,
            outgoingRate: 0.95, incomingRate: 1.04,
            bassSwapOffset: 1, overlapDuration: 3,
            rampLeadSeconds: 10, rampReleaseSeconds: 2)
        let ramp = try #require(TransitionAutomation.tempoRamp(for: .beatMatched(matched)))
        var options = OfflineTransitionRenderer.Options()
        options.preRoll = 6
        options.postRoll = 1
        let mix = try OfflineTransitionRenderer.renderMix(
            .plain(.beatMatched(matched)),
            outgoing: ClickTrainAudio.outgoingClicks,
            incoming: ClickTrainAudio.incomingClicks, options: options)

        let outStart = try #require(mix.outgoing.first?.source)
        let dry = OfflineTransitionRenderer.preRollFrames(
            from: outStart, to: matched.outPoint, ramp: ramp,
            tickSeconds: 1.0 / options.tickRate, sampleRate: 44_100)
        #expect(Int((mix.overlapStart * 44_100).rounded()) == Int(dry),
                "dry run \(dry) frames vs rendered \(mix.overlapStart * 44_100)")
        // …and it is not the trivial answer: the glide really does stretch the
        // pre-roll away from its source span.
        #expect(abs(Double(dry) / 44_100 - (matched.outPoint - outStart)) > 0.05)
    }

    // MARK: - Helpers

    private func channel(of buffer: AVAudioPCMBuffer) -> [Float] {
        let data = buffer.floatChannelData![0]
        return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }
}
