#if os(macOS)
import AVFoundation
import AudioToolbox

/// The one description of a playback deck's effect chain: which nodes, in what
/// order, with which EQ band layout, and what "transparent" means for every
/// automated parameter.
///
/// `PlaybackEngine` builds its two live decks from this, and
/// `OfflineTransitionRenderer` (behind `Audition.render`) builds its two
/// offline decks from it — so an auditioned transition is rendered through the
/// same graph the player uses, not a look-alike.
///
/// Chain: player → timePitch → EQ (low shelf + parametric mid + high shelf +
/// high-pass) → delay → mixer.
enum DeckChain {

    /// Fixed band assignment of every deck's 4-band EQ.
    enum Band: Int, CaseIterable {
        /// Low shelf @200 Hz — the bass swap (both plain and staged).
        case low = 0
        /// Parametric @900 Hz — the staged hand-over's mid stage.
        case mid = 1
        /// High shelf @3.5 kHz — the staged hand-over's first stage.
        case high = 2
        /// High-pass — `.filterSweep`. Bypassed unless sweeping.
        case highPass = 3
    }

    static let bandCount = Band.allCases.count

    /// The format every deck chain is wired with. Fixed: reconnecting a
    /// running engine's graph throws while the other deck renders, so sources
    /// that don't match are converted into it instead.
    static let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!

    static func makeEQ() -> AVAudioUnitEQ {
        let eq = AVAudioUnitEQ(numberOfBands: bandCount)
        configureBands(eq)
        return eq
    }

    /// Band types/frequencies/bandwidths — set once at init and never touched
    /// again; only the gains (and the high-pass bypass/frequency) are automated.
    static func configureBands(_ eq: AVAudioUnitEQ) {
        let low = eq.bands[Band.low.rawValue]
        low.filterType = .lowShelf
        low.frequency = 200
        low.gain = 0
        low.bypass = false

        let mid = eq.bands[Band.mid.rawValue]
        mid.filterType = .parametric
        mid.frequency = 900
        mid.bandwidth = 2.0   // octaves
        mid.gain = 0
        mid.bypass = false

        let high = eq.bands[Band.high.rawValue]
        high.filterType = .highShelf
        high.frequency = 3500
        high.gain = 0
        high.bypass = false

        // Wired now, bypassed at rest: the graph may never be rebuilt, so
        // `.filterSweep` only flips this band's bypass/frequency.
        let highPass = eq.bands[Band.highPass.rawValue]
        highPass.filterType = .highPass
        highPass.frequency = TransitionAutomation.sweepStartHz
        highPass.bandwidth = 0.5
        highPass.gain = 0
        highPass.bypass = true
    }

    /// Tail effect for `.echoOut`; 100% dry (transparent) at rest.
    static func configureDelay(_ delay: AVAudioUnitDelay) {
        delay.delayTime = TransitionAutomation.echoDefaultDelayTime
        delay.feedback = 0
        delay.lowPassCutoff = 8000
        delay.wetDryMix = 0
    }

    // MARK: - Time-pitch bypass

    /// **Is this deck's time-pitch unit doing nothing?** The one predicate that
    /// decides whether the unit is engaged, and deliberately an exact float
    /// comparison: the automation writes literal `1` at every unity site, and a
    /// tolerance here would leave a hair-off rate engaged while claiming unity.
    ///
    /// See `syncBypass` for why the answer is acted on rather than ignored.
    static func shouldBypassTimePitch(rate: Float, pitch: Float) -> Bool {
        rate == 1 && pitch == 0
    }

    /// **Bypass the time-pitch unit whenever it is at unity; engage it the
    /// instant it is not.** Returns whether the bypass state actually changed,
    /// so a caller that journals the edge does not have to track it.
    ///
    /// # Why the unit is bypassed at unity — the fast-path desync
    ///
    /// A field capture caught a deck whose `AVAudioUnitTimePitch` had been
    /// glided to ×0.9859 and then written back to `1`: from that point the AU
    /// kept **time-stretching at the last non-unity rate forever** while `rate`
    /// — and its parameter tree, read through AudioToolbox — read exactly 1.0.
    /// The output stayed 0.9–0.99 correlated inside any single 50 ms window but
    /// with a monotonically drifting lag, so a fixed-lag correlation over 2 s
    /// collapsed to ~0. That is the "underwater" report: not a filter, a clock.
    ///
    /// A standalone repro harness reproduced it in 5 of 8 runs and measured
    /// every candidate fix, 8 runs each:
    ///
    /// - `timePitch.reset()` after the deck stops — **no effect** (2/8 vs 2/8
    ///   for the same baseline). It clears the vocoder's buffers, not whatever
    ///   decides which path renders.
    /// - `auAudioUnit.reset()` — **partial** (1/8 vs 5/8).
    /// - re-writing `rate = 1.0`, or nudging 1.0001 → 1.0 — **no effect**. The
    ///   parameter was never the thing that was wrong.
    /// - **`bypass = true` while at unity and `false` when leaving it — 0/8 vs
    ///   5/8.** And toggling bypass on for 150 ms then off *while playing*
    ///   clears an already-corrupt AU (0/8), which is what identifies the state
    ///   as an engaged-path latch rather than parameter corruption.
    ///
    /// So the bypass is not an optimisation, it is the fix: the unit is only
    /// ever engaged while it has work to do, and re-engaging it is what makes
    /// it re-read its rate.
    ///
    /// # The toggle is free — measured, not assumed
    ///
    /// This is the same measurement that used to argue *against* adding a
    /// bypass, and it is what makes adding one safe. Rendered offline through
    /// this exact chain, against real cached material:
    ///
    /// - **active at rate 1.0 vs `shouldBypassEffect = true`** — the difference
    ///   signal sits 141 dB below the programme, and every octave band from
    ///   20 Hz to 20 kHz matches to ±0.000 dB. Peak sample difference 2.4e-7:
    ///   one float32 ULP, i.e. rounding, not filtering. The unit also reports
    ///   `latency == 0` and `tailTime == 0` at unity.
    /// - **after a full seam-shaped bend cycle** (step to ×1.05, hold, glide
    ///   back, neutralize) with the player node never stopped, the same
    ///   comparison at the same instant gives the same 141 dB null. Compared
    ///   instead against a never-bent render of the same music — aligned at the
    ///   14.559 s the bend advanced the source, which is itself the proof the
    ///   alignment is exact — 140 dB down, ±0.000 dB per band.
    ///
    /// Controls: two active renders are bit-identical, and a ×1.02 bend puts
    /// the residual only 3 dB below programme, so the method resolves real
    /// differences ~137 dB above the floor it reported here.
    ///
    /// A toggle between two states that null at 141 dB with latency 0 and tail
    /// 0 cannot click; the earlier conclusion ("do not add a bypass, it buys
    /// nothing") was right about the audio and wrong about the bug.
    ///
    /// # Why every rate write goes through here
    ///
    /// The live engine and `OfflineTransitionRenderer` render the same seam
    /// through the same graph, so a rule that held on only one of them would be
    /// a parity surface nobody could see. `setRate` below is the only sanctioned
    /// way to write the rate, in both.
    @discardableResult
    static func syncBypass(_ timePitch: AVAudioUnitTimePitch) -> Bool {
        let wanted = shouldBypassTimePitch(rate: timePitch.rate, pitch: timePitch.pitch)
        guard timePitch.bypass != wanted else { return false }
        timePitch.bypass = wanted
        return true
    }

    /// Write a deck's time-pitch rate (and optionally its pitch) and put the
    /// unit's bypass where `shouldBypassTimePitch` says it belongs. Returns
    /// whether the bypass edge was crossed.
    ///
    /// Order matters and this is the safe one: the rate lands first, so leaving
    /// unity engages a unit that already holds the new rate, and reaching unity
    /// bypasses a unit that has already been told to stop stretching.
    @discardableResult
    static func setRate(_ rate: Float, pitch: Float? = nil,
                        on timePitch: AVAudioUnitTimePitch) -> Bool {
        timePitch.rate = rate
        if let pitch { timePitch.pitch = pitch }
        return syncBypass(timePitch)
    }

    /// Every automated parameter back to transparent. Deliberately does NOT
    /// touch the fader — raising a deck's gain while its chain may still be
    /// sounding is exactly what the callers guard against.
    ///
    /// Returns whether the time-pitch bypass edge was crossed, for the caller's
    /// journal; see `syncBypass`.
    @discardableResult
    static func neutralize(timePitch: AVAudioUnitTimePitch, eq: AVAudioUnitEQ,
                           delay: AVAudioUnitDelay) -> Bool {
        let toggled = setRate(1, pitch: 0, on: timePitch)
        eq.globalGain = 0
        eq.bands[Band.low.rawValue].gain = 0
        eq.bands[Band.mid.rawValue].gain = 0
        eq.bands[Band.high.rawValue].gain = 0
        let highPass = eq.bands[Band.highPass.rawValue]
        highPass.bypass = true
        highPass.frequency = TransitionAutomation.sweepStartHz
        delay.wetDryMix = 0
        delay.feedback = 0
        delay.delayTime = TransitionAutomation.echoDefaultDelayTime
        return toggled
    }

    /// **May this deck's effect chain have its DSP state cleared right now?**
    ///
    /// `neutralize` above puts every *parameter* back to transparent, and for
    /// years that was assumed to be the whole of the cleanup. It is not. A
    /// field capture caught a deck whose `AVAudioUnitTimePitch` had been
    /// glided to ×0.9859, stopped mid-glide, snapped back to ×1 seven
    /// milliseconds later and then left idle for three minutes: when a feeder
    /// pre-rolled it again, the unit's output was decorrelated from its input
    /// at every lag (cross-correlation below 0.2, a 0.31 ms comb, the spectral
    /// envelope preserved) — "underwater" — and stayed that way until the app
    /// was restarted. The parameters were correct the whole time; the phase
    /// vocoder's *internal* state was not, and nothing in the engine ever
    /// cleared it. `AVAudioNode.reset()` does exactly that.
    ///
    /// The reset is free when the deck is silent and destructive when it is
    /// not — it drops whatever is mid-window inside the unit, which is a click
    /// on a sounding deck and the point on a stopped one. So this is the one
    /// predicate that decides, and it says no in exactly two cases:
    ///
    /// - the node is still playing (audible, or about to be),
    /// - an `.echoOut` tail was deliberately left ringing through this chain
    ///   (`resetDeckLocked(keepingEchoTail:)`) — the delay is *supposed* to be
    ///   sounding, and the settling phase neutralizes it properly once the
    ///   tail has decayed.
    static func shouldResetDSPState(playerIsPlaying: Bool,
                                    keepingEchoTail: Bool) -> Bool {
        !playerIsPlaying && !keepingEchoTail
    }

    /// Apply one automation frame's parameters to a chain (everything except
    /// the fader, which its owner writes — the live engine routes it through a
    /// flush-window guard, the offline renderer writes it directly).
    ///
    /// Returns whether the time-pitch bypass edge was crossed, for the caller's
    /// journal; see `syncBypass`.
    @discardableResult
    static func apply(_ p: TransitionAutomation.DeckParameters,
                      timePitch: AVAudioUnitTimePitch, eq: AVAudioUnitEQ,
                      delay: AVAudioUnitDelay) -> Bool {
        let toggled = setRate(p.rate, on: timePitch)
        eq.globalGain = p.eqGlobalGain
        eq.bands[Band.low.rawValue].gain = p.lowGain
        eq.bands[Band.mid.rawValue].gain = p.midGain
        eq.bands[Band.high.rawValue].gain = p.highGain
        let highPass = eq.bands[Band.highPass.rawValue]
        highPass.bypass = p.highPassBypassed
        highPass.frequency = p.highPassFrequency
        delay.wetDryMix = p.delayWetDryMix
        delay.feedback = p.delayFeedback
        delay.delayTime = p.delayTime
        return toggled
    }

    // MARK: - Master peak limiter

    /// Where the master path's peak is held, in dBFS.
    ///
    /// The same −1 dBFS `LoudnessCompensation.Config.peakCeilingDBFS` guards
    /// every *static* gain decision against, and deliberately the same number:
    /// the limiter is not a new policy, it is the enforcement of the one the
    /// trims already promise. What it adds is that the promise now holds for
    /// things no load-time arithmetic can see — two decks summing during an
    /// overlap, and `AVAudioUnitTimePitch`'s +5.5…+8.8 dB peak overshoot while
    /// a deck is bent.
    static let masterCeilingDBFS: Double = -1

    /// `AUPeakLimiter` limits to **0 dBFS** and has no ceiling parameter, so
    /// the −1 dB ceiling is built out of a matched pair: `+1 dB` of the AU's
    /// own `PreGain` going in, and this multiplier coming out.
    ///
    /// The pair is exactly transparent below the ceiling — `+1 dB` then `−1 dB`
    /// is unity to the float — which is the property that matters most here.
    /// **Bodies must not move.** A master path that simply attenuated by 1 dB
    /// to buy its headroom would take that dB off every song in the library,
    /// which is the same mistake the deep rate pad was making, one scale up.
    static var masterCeilingTrimGain: Float {
        LoudnessCompensation.gain(fromDB: masterCeilingDBFS)
    }

    /// Attack, in seconds. The minimum the AU accepts, and the choice is forced:
    /// `AUPeakLimiter`'s attack *is* its look-ahead, and what it has to catch is
    /// a single-sample transient the phase vocoder invented. A comfortable
    /// 12 ms (the AU's default) would let the first 12 ms of every overshoot
    /// through, which is the whole event.
    static let masterLimiterAttackSeconds: Float = 0.001

    /// Decay, in seconds. Slow, within the AU's range: the release is what
    /// decides whether limiting is heard as *limiting*. A fast release chases
    /// the waveform and reads as distortion on bass; 50 ms lets the gain walk
    /// back over a musical event rather than inside one. The signal being
    /// caught is a few dB on the loudest handful of samples of a seam, so
    /// there is nothing to be gained by hurrying back.
    static let masterLimiterDecaySeconds: Float = 0.05

    /// The peak limiter that sits between the mixer sum and the output.
    ///
    /// `kAudioUnitSubType_PeakLimiter` rather than `DynamicsProcessor`: this
    /// wants one job — never let a sample past the ceiling — and the peak
    /// limiter is the one Apple AU whose whole contract is that. (The cost is
    /// that it publishes **no gain-reduction metering**: its parameter tree is
    /// attack/decay/pre-gain and nothing readable, so "how hard did it work on
    /// this seam" cannot be journalled from the AU. The output tap's captured
    /// peak answers the question the other way round — see
    /// `PlaybackEngine.tapLevelDescription`.)
    static func makeMasterLimiter() -> AVAudioUnitEffect {
        let description = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        let limiter = AVAudioUnitEffect(audioComponentDescription: description)
        configureMasterLimiter(limiter)
        return limiter
    }

    /// Write the three parameters. Separate from the factory so a test can
    /// re-assert them on a node it built itself, and so the readback line has
    /// exactly one set of numbers to disagree with.
    static func configureMasterLimiter(_ limiter: AVAudioUnitEffect) {
        setMasterLimiterParameter(limiter, kLimiterParam_AttackTime,
                                  masterLimiterAttackSeconds)
        setMasterLimiterParameter(limiter, kLimiterParam_DecayTime,
                                  masterLimiterDecaySeconds)
        // The +1 dB half of the ceiling pair; see `masterCeilingTrimGain`.
        setMasterLimiterParameter(limiter, kLimiterParam_PreGain,
                                  Float(-masterCeilingDBFS))
    }

    /// Best-effort by construction: an AU that refuses a parameter leaves its
    /// default in place (12 ms / 24 ms / 0 dB), which still limits — it just
    /// limits less exactly than asked. There is nothing useful a playback
    /// engine can do with the failure, and throwing out of graph construction
    /// over it would trade a quieter ceiling for no audio at all.
    private static func setMasterLimiterParameter(
        _ limiter: AVAudioUnitEffect, _ parameter: AudioUnitParameterID, _ value: Float
    ) {
        AudioUnitSetParameter(limiter.audioUnit, parameter,
                              kAudioUnitScope_Global, 0, value, 0)
    }

    /// What the AU actually holds, for the readback journal line. Reads the
    /// unit rather than the constants above — a line that printed our own
    /// intent back at us could never catch a parameter the AU declined.
    static func masterLimiterReadback(_ limiter: AVAudioUnitEffect)
        -> (attack: Float, decay: Float, preGain: Float) {
        func read(_ parameter: AudioUnitParameterID) -> Float {
            var value: AudioUnitParameterValue = .nan
            AudioUnitGetParameter(limiter.audioUnit, parameter,
                                  kAudioUnitScope_Global, 0, &value)
            return value
        }
        return (read(kLimiterParam_AttackTime), read(kLimiterParam_DecayTime),
                read(kLimiterParam_PreGain))
    }
}
#endif
