import Testing
@testable import KumoneCore
import AVFoundation
import Foundation

// The capture path's own coverage, after the tap block stopped doing the work.
//
// The field bug these guard: an output-tap capture used to write its file, ask
// the file how long it was, and then run the whole level analysis (2.4 s of
// LUFS, true peak and autocorrelation) inside the tap block. While a tap block
// runs, `AVAudioPlayerNode.stop()` on any node of the same engine blocks — so
// the splice that armed in that window sat 1.9 s inside `stop()`, released its
// deck 1.67 s late, and put a 1.19 s hole of exact zeros in the output.
//
// Two things had to become true and stay true: the bookkeeping is arithmetic
// rather than a question for the file (`TapWriteLedger`), and `done` is called
// from the writer queue rather than from whoever called `tee`.

@Suite struct TapWriteLedgerTests {

    @Test func theBufferThatReachesTheWantedLengthCompletesItOnce() {
        var ledger = TapWriteLedger(want: 1024)
        #expect(ledger.accept(frames: 512, hostTime: 1) == false)
        #expect(ledger.remaining == 512)
        #expect(ledger.accept(frames: 512, hostTime: 2) == true)
        #expect(ledger.isComplete)
        #expect(ledger.remaining == 0)
        // Nothing after it counts, and nothing after it reports done again.
        #expect(ledger.accept(frames: 512, hostTime: 3) == false)
        #expect(ledger.written == 1024)
    }

    @Test func anOvershootingBufferStillCompletesExactlyOnce() {
        var ledger = TapWriteLedger(want: 100)
        #expect(ledger.accept(frames: 4096, hostTime: nil) == true)
        #expect(ledger.accept(frames: 4096, hostTime: nil) == false)
        #expect(ledger.written == 4096)
    }

    @Test func theStartHostTimeComesFromTheFirstBufferThatCarriedFrames() {
        var ledger = TapWriteLedger(want: 8)
        // An empty buffer wrote nothing, so it cannot be sample zero.
        #expect(ledger.accept(frames: 0, hostTime: 111) == false)
        #expect(ledger.startHostTime == nil)
        #expect(ledger.accept(frames: 4, hostTime: 222) == false)
        #expect(ledger.startHostTime == 222)
        // And a later buffer never moves it.
        #expect(ledger.accept(frames: 4, hostTime: 333) == true)
        #expect(ledger.startHostTime == 222)
    }

    @Test func aCaptureThatWantsNothingIsCompleteOnItsFirstBuffer() {
        var ledger = TapWriteLedger(want: 0)
        #expect(ledger.accept(frames: 1, hostTime: nil) == true)
        #expect(ledger.isComplete)
    }

    @Test func anInvalidTimestampLeavesTheStartUnmeasurable() {
        var ledger = TapWriteLedger(want: 4)
        #expect(ledger.accept(frames: 4, hostTime: nil) == true)
        #expect(ledger.startHostTime == nil)
    }
}

@Suite struct TapCaptureThreadingTests {

    private final class Box: @unchecked Sendable {
        var thread: Thread?
        var startHostTime: UInt64?
        var calls = 0
    }

    private func buffer(frames: AVAudioFrameCount, in format: AVAudioFormat)
        -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<Int(frames) {
                buffer.floatChannelData![channel][frame] =
                    Float(channel) + Float(frame) / 10_000
            }
        }
        return buffer
    }

    @Test func doneRunsOffTheThreadThatCalledTee() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                   channels: 2, interleaved: false)!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tap-capture-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forWriting: url,
                                   settings: PlaybackEngine.captureFileSettings(format),
                                   commonFormat: .pcmFormatFloat32, interleaved: true)
        // The file a capture writes is interleaved, so AVAudioFile never has
        // to build a converter for the writer's buffers.
        #expect(file.processingFormat.isInterleaved)

        let capture = PlaybackEngine.TapCapture()
        let box = Box()
        let finished = DispatchSemaphore(value: 0)
        capture.withLock { state in
            state.open(file: file, want: 1024) { _, startHostTime in
                box.thread = Thread.current
                box.startHostTime = startHostTime
                box.calls += 1
                finished.signal()
            }
        }
        #expect(capture.withLock { $0.file != nil })
        #expect(capture.withLock { $0.want } == 1024)

        let half = buffer(frames: 512, in: format)
        let caller = Thread.current
        capture.tee(half, at: AVAudioTime(hostTime: 4_242))
        capture.tee(half, at: AVAudioTime(hostTime: 9_999))
        #expect(finished.wait(timeout: .now() + 5) == .success)

        #expect(box.calls == 1)
        #expect(box.thread !== caller)
        // The first buffer's timestamp, not the completing one's.
        #expect(box.startHostTime == 4_242)
        // The slot is free again before `done` gets to do its reading, so the
        // next capture never has to wait for the last one's analysis.
        #expect(capture.withLock { $0.file == nil })

        // A buffer that arrives after the capture closed is dropped, not
        // written, and never reports done a second time.
        capture.tee(half, at: AVAudioTime(hostTime: 12_000))
        #expect(finished.wait(timeout: .now() + 0.2) == .timedOut)
        #expect(box.calls == 1)

        let written = try AVAudioFile(forReading: url)
        #expect(written.length == 1024)
        // And the audio survived the interleave: channel 1 was written as 1+n.
        let read = AVAudioPCMBuffer(pcmFormat: written.processingFormat,
                                    frameCapacity: 1024)!
        try written.read(into: read)
        #expect(read.floatChannelData![0][0] == 0)
        #expect(read.floatChannelData![1][0] == 1)
    }

    @Test func theTapCostIsRecordedAndReadingItClearsTheWindow() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                   channels: 2, interleaved: false)!
        let capture = PlaybackEngine.TapCapture()
        // No capture open: `tee` is a lock and a branch, and still measured.
        capture.tee(buffer(frames: 512, in: format), at: nil)
        let first = capture.takeTeeCost()
        #expect(first.maxMilliseconds >= 0)
        #expect(first.slow == 0)
        #expect(capture.takeTeeCost().maxMilliseconds == 0)
    }
}

// The chain capture's one-number verdict, and the predicate that decides when a
// deck's effect chain may have its DSP state cleared.
//
// The field bug behind both: a deck's `AVAudioUnitTimePitch` was glided down to
// ×0.9859, stopped mid-glide, snapped back to ×1 seven milliseconds later, left
// idle for three minutes and then pre-rolled again — from which point its output
// was decorrelated from its input at every lag, with the spectral envelope, the
// level and the stereo correlation all still looking normal. Every per-stage
// number in a chain capture was therefore useless; only a correlation *against
// the stage's own input* could see it.

@Suite struct ChainCoherenceTests {

    /// Deterministic pseudo-noise, so a threshold in a test means something.
    private func noise(_ count: Int, seed: UInt64) -> [Float] {
        // SplitMix64: a plain LCG will not do here, because two of its seeds
        // are usually two points on the *same* orbit — i.e. lag-shifted copies
        // of one another, which is precisely what this sweep goes looking for.
        var state = seed
        return (0..<count).map { _ in
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Float(Int32(truncatingIfNeeded: z)) / Float(Int32.max)
        }
    }

    @Test func aStageThatPassesItsInputThroughReadsOne() {
        let x = noise(8_000, seed: 7)
        let peak = ChainCoherence.peakCorrelation(x, x)
        #expect(peak != nil)
        #expect((peak ?? 0) > 0.999)
    }

    @Test func aPureLatencyIsFoundWithinTheLagSweep() {
        let x = noise(8_000, seed: 11)
        // The stage's output, delayed 500 samples — what an honest AU with
        // latency looks like, and it must still read ≈1.
        var delayed = [Float](repeating: 0, count: x.count)
        for i in 500..<x.count { delayed[i] = x[i - 500] }
        #expect((ChainCoherence.peakCorrelation(x, delayed) ?? 0) > 0.999)
    }

    @Test func aStageWhoseOutputDoesNotExplainItsInputReadsNearZero() {
        // The underwater deck: same kind of signal, no relationship to it.
        let peak = ChainCoherence.peakCorrelation(noise(8_000, seed: 3),
                                                  noise(8_000, seed: 4))
        #expect((peak ?? 1) < 0.2)
    }

    @Test func aScaledOrInvertedCopyIsStillTheSameProgramme() {
        let x = noise(8_000, seed: 21)
        let quiet = x.map { $0 * -0.25 }
        #expect((ChainCoherence.peakCorrelation(x, quiet) ?? 0) > 0.999)
    }

    @Test func silenceAndShortCapturesAreUndecidableRatherThanZero() {
        let x = noise(8_000, seed: 5)
        #expect(ChainCoherence.peakCorrelation(x, [Float](repeating: 0, count: 8_000)) == nil)
        #expect(ChainCoherence.peakCorrelation([Float](repeating: 0, count: 8_000), x) == nil)
        // Not enough room for the ±2048 sweep plus a window.
        #expect(ChainCoherence.peakCorrelation(Array(x.prefix(4_000)),
                                               Array(x.prefix(4_000))) == nil)
        #expect(ChainCoherence.peakCorrelation([], []) == nil)
    }

    @Test func aNarrowerSweepStillFindsALagInsideIt() {
        let x = noise(8_000, seed: 9)
        var delayed = [Float](repeating: 0, count: x.count)
        for i in 10..<x.count { delayed[i] = x[i - 10] }
        #expect((ChainCoherence.peakCorrelation(x, delayed, maxLag: 64) ?? 0) > 0.999)
    }

    @Test func monoSumAddsTheChannelsAndPassesMonoThrough() {
        #expect(ChainCoherence.monoSum([[1, 2, 3]]) == [1, 2, 3])
        #expect(ChainCoherence.monoSum([[1, 2, 3], [10, 20, 30]]) == [11, 22, 33])
        // A ragged pair stops at the shorter channel rather than trapping.
        #expect(ChainCoherence.monoSum([[1, 2, 3], [10]]) == [11, 2, 3])
        #expect(ChainCoherence.monoSum([]).isEmpty)
    }
}

@Suite struct DeckChainDSPResetTests {

    @Test func aStoppedDeckIsResetAndASoundingOneIsNot() {
        #expect(DeckChain.shouldResetDSPState(playerIsPlaying: false,
                                              keepingEchoTail: false))
        #expect(!DeckChain.shouldResetDSPState(playerIsPlaying: true,
                                               keepingEchoTail: false))
    }

    @Test func aDeliberatelyRingingEchoTailIsNeverCutShort() {
        #expect(!DeckChain.shouldResetDSPState(playerIsPlaying: false,
                                               keepingEchoTail: true))
        #expect(!DeckChain.shouldResetDSPState(playerIsPlaying: true,
                                               keepingEchoTail: true))
    }
}

// The time-pitch bypass rule.
//
// The unit is engaged only while a deck is actually bent. Not an optimisation:
// an `AVAudioUnitTimePitch` that has been glided off unity and back sometimes
// keeps stretching at its last non-unity rate forever while `rate` reads 1.0 —
// the "underwater" field bug. A repro harness measured 5/8 runs corrupt with
// no bypass and 0/8 with this rule (and `reset()` / re-writing the rate fixing
// nothing); the full argument, including the 141 dB null that says the toggle
// itself is inaudible, is on `DeckChain.syncBypass`.
@Suite struct DeckChainTimePitchBypassTests {

    @Test func unityIsBypassedAndAnyBendIsNot() {
        #expect(DeckChain.shouldBypassTimePitch(rate: 1, pitch: 0))
        #expect(!DeckChain.shouldBypassTimePitch(rate: 0.9859, pitch: 0))
        #expect(!DeckChain.shouldBypassTimePitch(rate: 1.05, pitch: 0))
        // Pitch is never automated today, but a bent pitch at rate 1 is still
        // work — the predicate must not call it transparent.
        #expect(!DeckChain.shouldBypassTimePitch(rate: 1, pitch: 100))
        #expect(!DeckChain.shouldBypassTimePitch(rate: 1, pitch: -1))
    }

    /// Exact, deliberately: the field rate was ×0.9859 and the sites that mean
    /// unity write a literal 1, so there is no tolerance to be had here — a
    /// rate a hair off unity is a rate the unit has to be engaged for.
    @Test func nearUnityIsNotUnity() {
        #expect(!DeckChain.shouldBypassTimePitch(rate: 1.0001, pitch: 0))
        #expect(!DeckChain.shouldBypassTimePitch(rate: 0.9999, pitch: 0))
        #expect(DeckChain.shouldBypassTimePitch(rate: Float(1.0), pitch: Float(0.0)))
    }

    @Test func setRateFollowsTheRuleAndReportsOnlyTheEdges() {
        let tp = AVAudioUnitTimePitch()
        // A fresh unit is at unity and not yet bypassed, so the first sync is
        // itself an edge — which is why the engine and the offline renderer
        // both call `syncBypass` when they build a deck.
        #expect(DeckChain.syncBypass(tp))
        #expect(tp.bypass)
        #expect(!DeckChain.syncBypass(tp))

        // Leaving unity engages the unit, once.
        #expect(DeckChain.setRate(0.9859, on: tp))
        #expect(!tp.bypass)
        #expect(tp.rate == 0.9859)
        // A glide is a monotone walk between unity and its target, so every
        // tick in between is a plain parameter write and no edge at all.
        #expect(!DeckChain.setRate(0.99, on: tp))
        #expect(!DeckChain.setRate(0.999, on: tp))
        #expect(!tp.bypass)

        // Arriving home bypasses it, once. Two edges for the whole glide.
        #expect(DeckChain.setRate(1, on: tp))
        #expect(tp.bypass)
        #expect(tp.rate == 1)
        #expect(!DeckChain.setRate(1, on: tp))
    }

    @Test func neutralizeAndApplyBothCarryTheRule() {
        let tp = AVAudioUnitTimePitch()
        let eq = DeckChain.makeEQ()
        let delay = AVAudioUnitDelay()
        DeckChain.configureDelay(delay)
        // As a deck is built: at unity, therefore bypassed.
        DeckChain.syncBypass(tp)
        #expect(tp.bypass)

        var bent = TransitionAutomation.DeckParameters()
        bent.rate = 1.05
        #expect(DeckChain.apply(bent, timePitch: tp, eq: eq, delay: delay))
        #expect(!tp.bypass)
        #expect(!DeckChain.apply(bent, timePitch: tp, eq: eq, delay: delay))

        // The exit path is the one that has to land it: this is the write the
        // field capture caught leaving a stuck stretch behind.
        #expect(DeckChain.neutralize(timePitch: tp, eq: eq, delay: delay))
        #expect(tp.bypass)
        #expect(tp.rate == 1)
        #expect(tp.pitch == 0)
        #expect(!DeckChain.neutralize(timePitch: tp, eq: eq, delay: delay))

        // And an automation frame at unity keeps it bypassed rather than
        // re-engaging it 50 times a second on a deck nothing is bending.
        #expect(!DeckChain.apply(TransitionAutomation.DeckParameters(),
                                 timePitch: tp, eq: eq, delay: delay))
        #expect(tp.bypass)
    }
}
