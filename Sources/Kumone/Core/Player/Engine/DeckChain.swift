import AVFoundation

/// The one description of a playback deck's effect chain: which nodes, in what
/// order, with which EQ band layout, and what "transparent" means for every
/// automated parameter.
///
/// `PlaybackEngine` builds its two live decks from this, and
/// `OfflineTransitionRenderer` (behind the `audition` CLI) builds its two
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

    /// Every automated parameter back to transparent. Deliberately does NOT
    /// touch the fader — raising a deck's gain while its chain may still be
    /// sounding is exactly what the callers guard against.
    static func neutralize(timePitch: AVAudioUnitTimePitch, eq: AVAudioUnitEQ,
                           delay: AVAudioUnitDelay) {
        timePitch.rate = 1
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
    }

    /// Apply one automation frame's parameters to a chain (everything except
    /// the fader, which its owner writes — the live engine routes it through a
    /// flush-window guard, the offline renderer writes it directly).
    static func apply(_ p: TransitionAutomation.DeckParameters,
                      timePitch: AVAudioUnitTimePitch, eq: AVAudioUnitEQ,
                      delay: AVAudioUnitDelay) {
        timePitch.rate = p.rate
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
    }
}
