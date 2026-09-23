import Testing
@testable import KumoneCore
import AVFoundation
import Foundation

// The master peak limiter, and the bent-rate pad it replaces.
//
// Two claims are being tested, and they are the two halves of one trade. The
// pad prevented the time-pitch unit's peak overshoot by ducking the deck for
// up to twenty-five seconds ahead of a seam; the limiter catches the same
// overshoot in the samples that commit it. So: the pad has to actually go
// away when the limiter is in circuit (and stay exactly as it was when it is
// not), and the ceiling the pad was protecting has to actually hold without
// it.
//
// The second one is measured through a real graph rather than reasoned about,
// because everything interesting here is in an Apple AU we do not own: that
// `AUPeakLimiter` limits to 0 dBFS with no ceiling parameter, and therefore
// that the +1 dB pre-gain / −1 dB post-trim pair really does land the ceiling
// at −1 dBFS. Manual rendering mode, so this needs no audio hardware.

@Suite struct MasterLimiterTests {

    // MARK: - The pad's retirement rule

    /// The rule is unconditional: with a limiter downstream holding the same
    /// ceiling, nothing is owed in advance. Not "less pad" — none.
    @Test func theLimiterRetiresTheBentRatePadEntirely() {
        // "LOVE.": +0.60 dBFS peak on a −4.06 dB trim, the corpus's hottest —
        // ~3 dB of pad, i.e. ten seconds of lead-in, under the old regime.
        #expect(abs(LoudnessCompensation.timePitchPadDB(
            forPeakDBFS: 0.596, afterTrimDB: -4.06) - -3.04) < 0.01)
        #expect(LoudnessCompensation.timePitchPadDB(
            forPeakDBFS: 0.596, afterTrimDB: -4.06, masterLimiterActive: true) == 0)
        // The −11 LUFS body level makes the trims shallower and the pads
        // deeper; the field's own two numbers, retired.
        for (peak, trim) in [(0.6, -1.5), (-0.2, 1.0), (0.0, 0.0)] {
            #expect(LoudnessCompensation.timePitchPadDB(
                forPeakDBFS: peak, afterTrimDB: trim) < 0)
            #expect(LoudnessCompensation.timePitchPadDB(
                forPeakDBFS: peak, afterTrimDB: trim, masterLimiterActive: true) == 0)
        }
        // A pad-free track is pad-free either way — the retirement can never
        // be the thing that *creates* a level difference.
        #expect(LoudnessCompensation.timePitchPadDB(
            forPeakDBFS: -12, afterTrimDB: -4.06, masterLimiterActive: true) == 0)
        #expect(LoudnessCompensation.timePitchPadDB(
            forPeakDBFS: nil, afterTrimDB: -4, masterLimiterActive: true) == 0)
    }

    /// …and with the override off, the pad player survives untouched. This is
    /// the property that makes the A/B mean anything, so it is pinned rather
    /// than assumed from the default argument.
    @Test func theOldRegimeIsUnchangedWithTheLimiterOff() {
        for peak in stride(from: -20.0, through: 3.0, by: 0.5) {
            for trim in [-6.0, -4.06, -2.0, 0.0, 1.5] {
                let unchanged = LoudnessCompensation.timePitchPadDB(
                    forPeakDBFS: peak, afterTrimDB: trim, masterLimiterActive: false)
                #expect(unchanged == LoudnessCompensation.timePitchPadDB(
                    forPeakDBFS: peak, afterTrimDB: trim))
                // The lead-in the engine schedules is a function of the pad,
                // so it comes back untouched too — and vanishes with the pad.
                #expect(TransitionAutomation.ratePadLeadSeconds(unchanged)
                    == abs(unchanged) / TransitionAutomation.ratePadGlideDBPerSecond)
            }
        }
        #expect(TransitionAutomation.ratePadLeadSeconds(
            LoudnessCompensation.timePitchPadDB(
                forPeakDBFS: 0.596, afterTrimDB: -4.06, masterLimiterActive: true)) == 0)
    }

    /// The switch is one flag, defaults off in the struct (so the neutral
    /// overrides still mirror the shipped player), and asks for a re-arm —
    /// the pad it retires is *baked into* a rendered segment.
    @Test func theLimiterOverrideIsOffByDefaultAndForcesAReArm() {
        #expect(!AutoMixOverrides().enableMasterLimiter)
        #expect(!AutoMixOverrides().isActive)
        var on = AutoMixOverrides()
        on.enableMasterLimiter = true
        #expect(on.isActive)
        #expect(on.badges == ["limiter"])
        #expect(on.needsReArm(comparedTo: AutoMixOverrides()))
        #expect(AutoMixOverrides().needsReArm(comparedTo: on))
    }

    // MARK: - The ceiling, through the real graph

    /// The whole claim, measured: a signal 6 dB over full scale comes out of
    /// the master path at the ceiling, and comes out of the same path without
    /// the limiter node far above it.
    ///
    /// The tolerance is 0.1 dB on the high side, which is the side that
    /// matters — the ceiling is a promise about what cannot be exceeded. On
    /// the low side it is loose on purpose: `AUPeakLimiter` is not a brickwall
    /// and settles a dB or two under the ceiling on material driven 7 dB into
    /// it, which is far outside anything the master path will ever see. What
    /// would be a real fault is the limiter eating headroom *below* the
    /// ceiling, and `aBodyBelowTheCeilingPassesTheMasterPathAtUnity` is where
    /// that is pinned, on the level the corpus actually plays at.
    @Test func theMasterPathHoldsTheCeilingAndWithoutItTheSignalDoesNot() throws {
        let ceiling = DeckChain.masterCeilingDBFS
        let limited = try renderHotSine(throughLimiter: true)
        let unlimited = try renderHotSine(throughLimiter: false)

        #expect(limited <= ceiling + 0.1, "limited peak \(limited) dBFS")
        #expect(limited >= ceiling - 3, "limited peak \(limited) dBFS")
        #expect(unlimited > ceiling + 0.1, "unlimited peak \(unlimited) dBFS")
        // …and the thing it is standing in for: the +5.5 dB the time-pitch
        // unit can add to an already-hot master is the excursion the pad used
        // to buy off in advance, and it is comfortably inside what the same
        // path swallows here.
        let excursion = unlimited - limited
        #expect(excursion >= LoudnessCompensation.Config.standard.timePitchOvershootDB,
                "the unlimited excursion \(excursion) dB must cover the overshoot")
    }

    /// Bodies must not move. Everything below the ceiling passes the master
    /// path at unity — the AU's +1 dB pre-gain and the mixer's −1 dB trim are
    /// an exactly matched pair — so switching the limiter on cannot make a
    /// song quieter, which is the failure mode the deep pad already was.
    ///
    /// −4.1 dBFS is where the corpus actually sits after compensation: the
    /// hottest master analyses at +0.60 dBFS and takes a −4.06 dB trim (see
    /// `LoudnessCompensation.Config.timePitchOvershootDB`), and everything
    /// else is quieter than that.
    @Test func aBodyBelowTheCeilingPassesTheMasterPathAtUnity() throws {
        let amplitude = LoudnessCompensation.gain(fromDB: 0.596 - 4.06)
        let limited = try renderSine(amplitude: amplitude, throughLimiter: true)
        let bypassed = try renderSine(amplitude: amplitude, throughLimiter: false)
        let asked = 20 * log10(Double(amplitude))
        #expect(asked < DeckChain.masterCeilingDBFS)
        #expect(abs(limited - asked) < 0.05, "limited \(limited) vs asked \(asked)")
        #expect(abs(limited - bypassed) < 0.05, "limited \(limited) vs bypassed \(bypassed)")
    }

    // MARK: - The evidence the journal prints

    /// The capture line's two peak figures have to be able to tell the two
    /// interesting cases apart, which is the only reason the oversampled one
    /// exists.
    @Test func truePeakSeesWhatTheSamplesMissAndNeverUndercutsThem() {
        let sampleRate = 44100.0
        // A full-scale quarter-rate sine, offset so every sample lands at 45°
        // either side of a crest the grid never touches: sample peak −3.01 dB,
        // real peak 0. The textbook case for why sample peak is not enough.
        let sine = (0..<4096).map {
            sin(2 * Float.pi * Float(sampleRate / 4) * Float($0) / Float(sampleRate)
                + Float.pi / 4)
        }
        let samplePeak = LoudnessMeter.peakDBFS(sine)!
        let truePeak = LoudnessMeter.truePeakDBTP(sine)!
        #expect(abs(samplePeak - -3.01) < 0.05,
                "an off-grid sine undersamples its own crest: \(samplePeak)")
        #expect(truePeak > samplePeak)
        // Full scale, within the 48-coefficient kernel's error near the top of
        // the band: it recovers 2.8 of the 3.0 dB the samples lost, which is
        // the accuracy the spec's minimum oversampler has and two orders below
        // anything read off this line.
        #expect(truePeak > -0.3 && truePeak < 0.4, "the crest is full scale: \(truePeak) dBTP")

        // A flat-topped run — what a limiter leaves behind — reconstructs
        // above its own samples. This is why a capture may legitimately show
        // `truePeak` a little over the ceiling while `peak` sits on it.
        let clipped = sine.map { Swift.max(-0.5, Swift.min(0.5, $0)) }
        #expect(LoudnessMeter.truePeakDBTP(clipped)! > LoudnessMeter.peakDBFS(clipped)!)

        // Never below the samples themselves, and no opinion on silence.
        let dc = [Float](repeating: 0.5, count: 1000)
        #expect(abs(LoudnessMeter.truePeakDBTP(dc)! - LoudnessMeter.peakDBFS(dc)!) < 0.01)
        #expect(LoudnessMeter.truePeakDBTP([Float](repeating: 0, count: 100)) == nil)
        #expect(LoudnessMeter.truePeakDBTP([]) == nil)
    }

    // MARK: - Harness

    /// A 1 kHz sine at +6 dBFS — float buffers carry it happily — pushed
    /// through the engine's master path.
    private func renderHotSine(throughLimiter: Bool) throws -> Double {
        try renderSine(amplitude: 2, throughLimiter: throughLimiter)
    }

    /// Render a 1 kHz sine through `player → mixer → [limiter] → masterMixer →
    /// output`, i.e. `PlaybackEngine.connectMasterChainLocked`'s order, and
    /// report the peak of the settled second half.
    ///
    /// The first half is discarded deliberately: the limiter's attack is its
    /// look-ahead and its decay is 50 ms, so the opening moments are the
    /// transient response rather than the steady state the ceiling claim is
    /// about. Manual rendering mode throughout — no device, no clock, and
    /// reproducible on a machine with no audio output at all.
    private func renderSine(amplitude: Float, throughLimiter: Bool) throws -> Double {
        let sampleRate = 44100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let masterMixer = AVAudioMixerNode()
        let limiter = DeckChain.makeMasterLimiter()
        engine.attach(player)
        engine.attach(masterMixer)
        engine.attach(limiter)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1
        if throughLimiter {
            engine.connect(engine.mainMixerNode, to: limiter, format: format)
            engine.connect(limiter, to: masterMixer, format: format)
            masterMixer.outputVolume = DeckChain.masterCeilingTrimGain
        } else {
            engine.connect(engine.mainMixerNode, to: masterMixer, format: format)
            // Unity, exactly as `applyMasterVolumeLocked` writes it with the
            // limiter bypassed: the −1 dB trim is the AU pre-gain's other half
            // and comes off with it. This is the pre-limiter master path.
            masterMixer.outputVolume = 1
        }
        engine.connect(masterMixer, to: engine.outputNode, format: format)

        let frames = AVAudioFrameCount(sampleRate)      // one second
        let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        source.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            let samples = source.floatChannelData![channel]
            for frame in 0..<Int(frames) {
                samples[frame] = amplitude
                    * sin(2 * .pi * 1000 * Float(frame) / Float(sampleRate))
            }
        }

        try engine.enableManualRenderingMode(.offline, format: format,
                                             maximumFrameCount: 4096)
        try engine.start()
        defer { engine.stop() }
        player.scheduleBuffer(source, at: nil, options: [], completionHandler: nil)
        player.play()

        let scratch = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                       frameCapacity: engine.manualRenderingMaximumFrameCount)!
        var rendered: AVAudioFrameCount = 0
        var peak: Float = 0
        while rendered < frames {
            let want = min(engine.manualRenderingMaximumFrameCount, frames - rendered)
            let status = try engine.renderOffline(want, to: scratch)
            guard status == .success else { break }
            let produced = Int(scratch.frameLength)
            // Only the settled half counts; see the doc comment.
            let skip = max(0, Int(frames / 2) - Int(rendered))
            if produced > skip, let data = scratch.floatChannelData {
                for channel in 0..<Int(scratch.format.channelCount) {
                    for frame in skip..<produced {
                        peak = max(peak, abs(data[channel][frame]))
                    }
                }
            }
            rendered += scratch.frameLength
        }
        #expect(peak > 0, "the render produced silence")
        return 20 * log10(Double(peak))
    }
}
