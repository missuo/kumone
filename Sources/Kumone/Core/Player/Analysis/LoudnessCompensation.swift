import Foundation

/// Cross-track loudness compensation: one constant playback gain per song, so
/// two songs meeting at a hand-over arrive at the same perceived level.
///
/// Pain point ④ of docs/automix-research-notes.md — "the next song is suddenly
/// 6 dB louder" — is a *mastering* difference, not a transition bug. No fade
/// curve can fix it, because both sides of the curve are wrong by a constant.
/// The fix is walkywalker's: a per-track trim applied to the whole song
/// (`dj.cpp:18-24` / `tune.cpp:153-173`), with Sony's clip guard on top
/// (`utils_data_normalization.py:79-80`).
///
/// ### Absolute, not pairwise
///
/// The trim is a function of **one** track: `target − referenceLoudness`. It is
/// deliberately not "match the incoming song to the outgoing one", because a
/// deck is loaded before the player knows what follows it, and a pairwise trim
/// would have to change under a running song when the queue changes. An
/// absolute target makes the trim a property of the loaded track, fixed for as
/// long as it plays — which is also why `PlaybackEngine` takes it as a
/// load-time argument and never as a setter.
///
/// ### Attenuate freely, boost barely
///
/// Modern masters sit well above −14 LUFS, so almost every trim is a cut, and a
/// cut is always safe. A boost is capped at `maxBoostDB` (+3 dB) *and* held to
/// whatever headroom the track's own peak leaves — a quiet master with a hot
/// peak gets no boost at all. What a boost cannot recover is exactly the
/// residual the planner's loudness gate still sees (see
/// `TransitionPlanner.signals`).
enum LoudnessCompensation {

    struct Config: Sendable, Equatable {
        /// House level. −14 LUFS is the streaming-platform convention
        /// (Spotify/YouTube/Amazon normalize there), so trims come out small
        /// and mostly negative for contemporary masters.
        var targetLUFS: Double = -14
        /// A quiet master may be lifted at most this far.
        var maxBoostDB: Double = 3
        /// A loud master may be pulled down at most this far. Wide, because a
        /// cut can never misbehave; it exists only to bound absurd input.
        var maxCutDB: Double = 12
        /// A boost must leave the track's peak under this.
        var peakCeilingDBFS: Double = -1
        /// The analyzer measures the peak of a **mono downmix**, which sits at
        /// or below the loudest channel's peak (up to ~3 dB below for wide
        /// stereo). Charge that difference against the headroom so the guard
        /// stays conservative on the real stereo file — and cover
        /// inter-sample overshoot with the same allowance.
        var downmixPeakAllowanceDB: Double = 3
        /// How far above its input peak `AVAudioUnitTimePitch` can push a
        /// signal while it is running at a **non-unity rate**.
        ///
        /// Measured, not guessed: four masters × six rates × five `overlap`
        /// settings, peak in vs peak out through `player → timePitch`.
        ///
        ///   | master | worst overshoot |
        ///   |---|---|
        ///   | Kendrick "LOVE." (0 dBFS-peak) | +6.41 dB |
        ///   | Kelela "Happy Ending" | +6.17 dB |
        ///   | KnowKnow "Uh" | +5.25 dB |
        ///   | 刘珂矣 "半壶纱" | +4.69 dB |
        ///
        /// Two findings shape how it is used. First, it does **not** scale with
        /// the bend: a 0.65 % rate change already costs the full overshoot, and
        /// a 10 % one costs no more. The phase vocoder is either engaged or it
        /// is not, so the pad is binary-on-bent rather than proportional.
        /// Second, `overlap` does not help — the figures are flat from 8 to 32
        /// within measurement noise, at 3.5× the CPU — so there is no way to
        /// tune the overshoot away and it has to be paid for in headroom.
        ///
        /// 5.5 dB is the *typical* worst case (the mean of the four maxima),
        /// deliberately not the absolute one. Padding to 6.5 would cost every
        /// hot master another dB of real loudness to prevent the last handful
        /// of single-sample overs, and on the material that provoked this the
        /// unpadded excursion was 100 samples in 1.3 million. Guaranteeing the
        /// last of those is not worth a dB of the song.
        var timePitchOvershootDB: Double = 5.5

        static let standard = Config()
    }

    /// The playback trim, in dB, for a track that is about to be loaded.
    ///
    /// Zero — unity gain, byte-identical to the pre-compensation player — when
    /// compensation is off, when there is no analysis yet (first listen of a
    /// streamed track), or when the analysis carries no loudness reading.
    static func trimDB(
        for analysis: TrackAnalysis?, enabled: Bool = true, config: Config = .standard
    ) -> Double {
        guard enabled, let loudness = analysis?.referenceLoudness, loudness.isFinite else {
            return 0
        }
        let wanted = config.targetLUFS - loudness
        var trim = min(config.maxBoostDB, max(-config.maxCutDB, wanted))
        if trim > 0 {
            // Sony's clip guard, expressed as a ceiling on the boost instead of
            // a post-hoc rescale: we cannot rescale a live playback stream.
            let peak = (analysis?.peakDBFS ?? 0) + config.downmixPeakAllowanceDB
            trim = min(trim, max(0, config.peakCeilingDBFS - peak))
        }
        return trim
    }

    /// How much further a track already sitting at `trimDB` may be pushed up
    /// before its peak crosses the same ceiling `trimDB` was guarded against.
    ///
    /// The whole-track trim above spends this headroom once, at load time; the
    /// **transition gain ride** (`TransitionPlanner.rideDB`) is a second, time-
    /// varying boost stacked on the same deck, so it has to be told what is
    /// left. Returns 0 — no boost at all — when the peak is unknown, because
    /// the guard's whole job is to be conservative about what it cannot see.
    static func boostHeadroomDB(
        for analysis: TrackAnalysis?, afterTrimDB trimDB: Double,
        config: Config = .standard
    ) -> Double {
        guard let peak = analysis?.peakDBFS, peak.isFinite else { return 0 }
        return max(0, config.peakCeilingDBFS - (peak + config.downmixPeakAllowanceDB + trimDB))
    }

    /// **Bent-rate headroom pad**: how far a deck must be held down, in dB,
    /// while it is playing at a non-unity rate, so the time-pitch unit's
    /// overshoot (`timePitchOvershootDB`) does not push it past the ceiling.
    ///
    /// Negative or zero — this is only ever a cut. Zero for most of the
    /// library, which is the point of sizing it from the track's own peak: a
    /// master that already sits 6 dB below the ceiling after its trim absorbs
    /// the overshoot on its own and is left completely alone. Only genuinely
    /// hot masters on small trims pay anything.
    ///
    /// Zero, too, when the peak is unknown. That is the opposite of
    /// `boostHeadroomDB`'s conservatism, and deliberately: refusing a boost you
    /// cannot justify costs nothing, but padding a track you cannot measure
    /// costs real loudness on every track the analyzer has not reached yet.
    ///
    /// Unlike the boost guard this does **not** charge `downmixPeakAllowanceDB`
    /// against the budget. That allowance covers the analyzer's mono peak
    /// possibly sitting below the true stereo peak, and it is there to make an
    /// otherwise unbounded decision safe. Here the thing being guarded is
    /// already characterised end-to-end on stereo signal, and the 5.5 dB
    /// carries its own conservatism; stacking the two would spend several dB
    /// of loudness on an uncertainty neither measurement supports. (On the
    /// corpus the mono peak reads at or *above* the stereo peak anyway —
    /// "LOVE." analyses at +0.60 dBFS against a 0 dBFS stereo master.)
    /// Takes the peak directly rather than a `TrackAnalysis`, because the deck
    /// that needs it is handed one number at load time and never sees the
    /// analysis — the same shape as `trimDB`.
    static func timePitchPadDB(
        forPeakDBFS peakDBFS: Double?, afterTrimDB trimDB: Double,
        config: Config = .standard
    ) -> Double {
        guard let peak = peakDBFS, peak.isFinite else { return 0 }
        let bentPeak = peak + trimDB + config.timePitchOvershootDB
        return min(0, config.peakCeilingDBFS - bentPeak)
    }

    /// dB → linear gain, the multiplier a fader is scaled by.
    static func gain(fromDB db: Double) -> Float { Float(pow(10.0, db / 20.0)) }
}
