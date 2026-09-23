#if os(macOS)
import Foundation

// Pure decision function: two analyses in, one TransitionPlan out (spec §5).
// Rules are checked top-down; the first hit wins:
//   1. Both analyzed, both confident, BPM delta (after double/half-time
//      folding) ≤ 8% → beatMatched.
//   2. Both analyzed but not beat-matchable → crossfade.
//   3. Anything missing, or either track shorter than 45 s → gapless.
enum TransitionPlanner {
    // Compatibility gate: how different two adjacent tracks are decides how
    // aggressive the transition is allowed to be. Very different songs
    // (ballad → banger, folk → electronic) get their boundary respected
    // with a short fade instead of a long blend.
    enum CompatibilityTier {
        case compatible   // full AutoMix: beat-match / long computed fades
        case neutral      // quick hand-over, no forced blending
        case clash        // boundary-respecting short fade
    }

    /// Every tunable the decision turns on, in one value. `Config.standard`
    /// holds the shipped numbers and is the default everywhere, so the
    /// product path behaves exactly as it did when these were bare
    /// constants; offline tuning (`Audition.decide(config:)`) swaps
    /// in a modified copy to explore what a different calibration would have
    /// decided.
    struct Config: Sendable, Equatable {
        var minTrackDuration: TimeInterval = 45
        var bpmConfidenceThreshold: Double = 0.6
        var maxBPMDeltaRatio: Double = 0.08
        var maxRateDeviation: Double = 0.04

        // --- Tempo ramp.
        //
        // A DJ does not *step* a deck onto a matched tempo, they glide into it
        // and back out of it. The two caps above are what a step costs: past
        // about ±4 % the move announces itself, so a pair 10 % apart had to be
        // refused and handed a plain crossfade instead. The glide moves the
        // audible quantity from "how far the rate jumped" to "how fast the rate
        // is changing", and that is a number the lead below can buy down.
        //
        // The whole block is coupled to `tempoRampEnabled` on purpose: with it
        // off, the two caps above apply, the plan carries no ramp fields, and
        // every path downstream — planner, engine, offline render — is what it
        // was. So a listening test can isolate the gesture from the widening.

        /// Glide into and out of the matched tempo instead of stepping. Off
        /// also puts `maxBPMDeltaRatio` / `maxRateDeviation` back in charge.
        var tempoRampEnabled: Bool = true
        /// Seconds of the outgoing track over which its deck glides onto the
        /// matched rate, finishing one `TransitionAutomation.segmentHandoff`
        /// before the out point.
        ///
        /// **Where 12 comes from.** What gives a tempo move away is its slope,
        /// not its size: a steady drift under roughly 0.5 % of rate per second
        /// (≈ 9 cents/s of pitch) reads as the room breathing rather than as an
        /// event — an order under the ~1 % step that is plainly audible on a
        /// sustained note, and comfortably under a beat-to-beat timing change a
        /// listener could tap against. At the widened `rampMaxRateDeviation`
        /// that bound sets the lead exactly: 0.065 / 0.005 = 13 s. Smaller bends
        /// glide slower still, since the lead is fixed at the worst case rather
        /// than scaled per pair — being *under* the bound costs nothing, and a
        /// fixed lead is one number to reason about at the seam.
        var rampLeadSeconds: TimeInterval = 13
        /// Seconds over which the incoming deck is let back to 1.0 once it is
        /// the only thing audible.
        ///
        /// **Not sized like the gain ride, and the difference matters.** A ride
        /// is let go of over ~13 s because gain is transparent: the only thing
        /// to hide is the *movement*, so slower is strictly better. A rate is
        /// not transparent. Every second a deck spends off unity is a second of
        /// phase-vocoder artifact — the watery, phasey colour of a time-pitch
        /// unit doing work — and that cost is roughly constant in the size of
        /// the bend, so stretching the release does not make it subtler, it
        /// makes it *last longer*. (Shipping 8 s here on the ride analogy is
        /// what a listener reported as the music being stuck underwater.)
        ///
        /// So the trade runs the other way from the lead: get out of the
        /// processing quickly, and spend just enough time to keep the exit a
        /// glide rather than a step. 3 s is about two bars at 120 BPM — long
        /// enough that 6 % unwinds as a settle instead of a click, short enough
        /// that the artifact is gone before the new track's first phrase is.
        var rampReleaseSeconds: TimeInterval = 3
        /// Start the incoming deck's walk back to unity **at the bass swap**,
        /// spending the outgoing deck's exit on it, instead of holding the bend
        /// for the whole overlap and releasing over `rampReleaseSeconds`
        /// afterwards.
        ///
        /// Same total bend either way; what changes is *where* it is spent. Held
        /// through the overlap, the artifact lands on the deck that owns the
        /// floor from the swap on and is alone from the seam on — the worst
        /// listening position in the whole hand-over, and what a listener
        /// described as the new song starting underwater and then healing.
        /// Glided from the swap, it is largest while the outgoing track is
        /// still there to mask it, smallest by the time the incoming one is
        /// exposed, and gone at `transition complete` rather than three seconds
        /// later. Off restores the old curve exactly; the plan carries the
        /// decision, so the engine, the offline render and a pre-rendered
        /// segment cannot disagree about it. See
        /// `TransitionAutomation.incomingGlide` for what it costs (beat
        /// alignment drifts after the swap, deliberately).
        var rampGlideBackFromSwap: Bool = true
        /// The beat-match caps that apply **instead** of `maxBPMDeltaRatio` /
        /// `maxRateDeviation` while `tempoRampEnabled` is on.
        ///
        /// Separate fields rather than new defaults on the old ones so a
        /// listening test can move the gesture and the gate independently, and
        /// so "what did this seam get judged against" is answerable from the
        /// config alone. 11.5 % apart is roughly the widest gap two decks can
        /// close by meeting in the middle without either exceeding ~6 %; the
        /// pair is therefore one decision, not two, and the trace says which of
        /// the two pairs was in force.
        ///
        /// The bend cap is 6.5 rather than 6.0 because the bend is *not* half
        /// the gap: meeting in the middle costs the deck being sped up more
        /// than the one being slowed (`(out−f)/2f` against `(f−out)/2out`), so
        /// a pair inside the gap window can still fail on the faster side by a
        /// few tenths of a percent. 6.5 % closes that lip — the corpus's one
        /// near-miss needed 6.48 % — without reaching a bend the glide cannot
        /// hide.
        ///
        /// At these two numbers the pair is exactly consistent and the rate
        /// gate becomes **unreachable**: the worst case inside an 11.5 % gap is
        /// a maximally slower incoming deck at `(1−d/2)/(1−d)` = 6.497 %. That
        /// is deliberate, not an accident to tidy away — `rateDeviation` stays
        /// as the thing that catches a config where someone has moved one of
        /// the two and not the other.
        var rampMaxBPMDeltaRatio: Double = 0.115
        var rampMaxRateDeviation: Double = 0.065

        /// What share of the tempo gap the **outgoing** deck absorbs, with the
        /// rest going to the incoming one. Only read while `tempoRampEnabled`
        /// is on; a stepped plan still meets exactly in the middle.
        ///
        /// **The two decks do not pay the same price for the same bend.** Time
        /// stretching costs a phase-vocoder artifact — the watery, phasey
        /// colour of the unit doing work — for as long as the deck is off
        /// unity, and the two decks are off unity in front of very different
        /// audiences. The outgoing deck's bend is spent while it is *leaving*:
        /// masked by the incoming track underneath it, then by the staged EQ
        /// carving its bands away, and finally by its own exit. The incoming
        /// deck's is spent while it is *arriving* — it takes the floor at the
        /// swap and then is the only thing playing, with nothing to hide behind
        /// and a listener's full attention on it. Splitting the gap evenly
        /// therefore puts the same artifact on the exposed side as on the
        /// masked one, which is what a listener reported as the new song
        /// opening underwater and then clearing up.
        ///
        /// 0.7 moves most of the work onto the side that can hide it. Combined
        /// with the post-swap glide back to unity
        /// (`TransitionAutomation.incomingGlide`), the exposed deck's worst
        /// case drops from about half the gap held for the whole overlap to
        /// under a third of it, shrinking from the swap onwards.
        ///
        /// **At the cap the split degrades toward 50/50, deliberately.** The
        /// share is applied first and then clamped: if 0.7 of the gap would
        /// bend the outgoing deck past `rampMaxRateDeviation`, it is held at
        /// the cap and the remainder falls to the incoming deck. So a pair at
        /// the very edge of `rampMaxBPMDeltaRatio` ends up close to an even
        /// split again — there is nowhere else for the deviation to go, and the
        /// alternative would be refusing the beat-match outright. 1.0 would put
        /// the whole gap on the outgoing deck (and, past ~9.3 %, be clamped
        /// back); 0.5 restores the old behaviour exactly.
        var rampBendShareOutgoing: Double = 0.7

        // --- Dominant-deck blend.

        /// Keep exactly one deck owning the floor across a **staged
        /// beat-matched** blend, instead of crossing both faders symmetrically.
        ///
        /// The symmetric law and the staged EQ were designed separately and
        /// fight each other over a long overlap: at the swap both decks sit at
        /// −3 dB *and* each holds only part of the spectrum, so the middle of a
        /// 30 s blend is audibly weaker than either side of it — the
        /// strong-weak-strong trough a listener reported. Off restores the
        /// symmetric curves exactly; nothing else about the hand-over changes
        /// either way. See `TransitionAutomation.dominantDeckFaders`.
        var dominantDeckBlend: Bool = true
        /// Where the incoming deck waits, as a fader level, while it sits under
        /// the outgoing one before the swap.
        ///
        /// High enough that the new track is established and audibly present
        /// before it is handed the low end — the point of the law — and low
        /// enough to stay under the outgoing deck, which is still the dominant
        /// one until the swap. 0.85 is −1.4 dB.
        ///
        /// It is also the headroom knob: if the sum ever clipped, this is what
        /// comes down. Measured on the offline renders of two real seams at the
        /// shipped trims and ride, the player-path peak across swap ± 2 s is
        /// −3.37 and −4.23 dBFS — about 2 dB hotter than the symmetric law,
        /// which is exactly the level it was throwing away — so 0.85 stands
        /// with three dB to spare. See `TransitionAutomation.dominantDeckFaders`.
        var preSwapPlateau: Double = 0.85

        /// The BPM-gap cap actually in force, and the rate cap that goes with
        /// it. Read only through this pair, so the two can never disagree
        /// about which regime a decision was made under.
        var beatMatchBPMDeltaCap: Double {
            tempoRampEnabled ? rampMaxBPMDeltaRatio : maxBPMDeltaRatio
        }
        var beatMatchRateCap: Double {
            tempoRampEnabled ? rampMaxRateDeviation : maxRateDeviation
        }
        /// The bend share actually in force. A stepped plan is always an even
        /// meet-in-the-middle: the asymmetry buys down an artifact that only
        /// the glide's widened caps make big enough to matter, and keeping the
        /// stepped split at 0.5 is what keeps a `tempoRampEnabled = false` plan
        /// bit-identical to the pre-ramp planner.
        var beatMatchBendShareOutgoing: Double {
            tempoRampEnabled ? Swift.min(1, Swift.max(0, rampBendShareOutgoing)) : 0.5
        }
        /// Coefficient of variation below which an RMS slice counts as steady.
        /// Deliberately loose: longer 8-bar overlaps are preferred whenever the
        /// energy is anywhere near stable.
        var stableCV: Double = 0.4
        /// The steadiness bar a window gets when it lies **entirely inside one
        /// labelled section** of the track it belongs to.
        ///
        /// `stableCV` is a proxy, and a crude one: it asks whether the 1 s RMS
        /// wobbles, because a wobbling window usually means the arrangement
        /// changes under the blend. But a chorus with a big dynamic shape and a
        /// verse that drops out for two bars both wobble, and only one of them
        /// is a place you cannot blend over. The structure layer measures the
        /// thing the CV was proxying for *directly* — a window inside a single
        /// section provably does not cross an arrangement change — so where the
        /// evidence exists, the proxy can be held to a looser bar.
        ///
        /// It is a relaxation, never a veto: a window inside one section still
        /// has to clear 0.5, so a genuinely lurching passage is still refused.
        /// Tracks with no usable `sections` are judged at `stableCV` exactly as
        /// they were, which is most of the library.
        var sectionSteadyCV: Double = 0.5
        /// Hard bounds on any overlap. Between them the length is computed from
        /// the audio: how long the outgoing tail stays steady, and how long the
        /// incoming opening can sit under a fade (see tailCapacity /
        /// intakeCapacity) — never a fixed number.
        var maxOverlap: TimeInterval = 30
        var minOverlap: TimeInterval = 2
        /// An overlap also never eats more than this share of the shorter track.
        var maxOverlapShare: Double = 0.25
        /// Looser steadiness bar for the tail search than for 8/16-bar upgrades.
        var tailStableCV: Double = 0.35

        /// Loudness gap (dB) between the outgoing tail and the incoming opening.
        var neutralLoudnessDB: Double = 4.5
        var clashLoudnessDB: Double = 6.5
        /// Cosine distance between the tracks' timbre fingerprints
        /// (level-removed log-mel shape, so the distance is one minus a shape
        /// correlation).
        ///
        /// Calibrated on the audition corpus (16 tracks, all 120 pairs). The
        /// natural unit of "definitely compatible" is a track measured against
        /// its own other half: median 0.028, worst case 0.11. Two different
        /// tracks sit at a median of 0.24 and reach 0.88. The neutral line is
        /// set above every same-song distance, so an arrangement change inside
        /// one track can never trip it; the clash line only catches the
        /// corpus's top decile — a modern bass-forward master against a thin,
        /// bass-light old recording. On the 15 adjacent pairs that leaves 5
        /// above the neutral line and 1 above the clash line. (The old
        /// fingerprint put all 15 between 0.001 and 0.032: this gate had never
        /// once fired.)
        var neutralTimbreDistance: Double = 0.35
        var clashTimbreDistance: Double = 0.45
        /// Folded BPM ratio beyond which confident tempos count as clashing.
        var clashTempoRatio: Double = 0.2
        /// Overlap ceilings for the two degraded tiers.
        ///
        /// The neutral cap was 6 s, and 6 s was a price paid for not trusting
        /// the cue points. A "quick hand-over" between two songs that are only
        /// *somewhat* alike is only quick because a longer blend, started
        /// wherever the energy heuristics happened to point, was as likely to
        /// land mid-phrase as on one. The structure layer changed that price:
        /// out points now come from section boundaries and in points from the
        /// first core section, so a neutral pair's 10 s is 10 s between two
        /// places that are actually musical edges. The cap still exists — a
        /// neutral pair does not get the compatible tier's computed length —
        /// it is just no longer paying for a cue point nobody trusted.
        ///
        /// The clash cap is unchanged at 2.5 s. That one is not about cue
        /// quality: two songs that genuinely fight should have their boundary
        /// respected, and a better-placed long blend is still a long blend.
        var neutralOverlapCap: TimeInterval = 10
        var clashOverlapCap: TimeInterval = 2.5

        /// Key gate: below this confidence a detected key never influences
        /// decisions. At `clashKeyDistance` fifths or more apart (minors folded
        /// to their relative major), harmony alone demotes compatible →
        /// neutral — it denies the long blend but never forces the clash tier
        /// by itself.
        var keyConfidenceThreshold: Double = 0.5
        var clashKeyDistance: Int = 3

        /// Vocal gate: overlap windows are scored relative to the track's own
        /// mean vocal activity (absolute levels drift with genre/mastering).
        /// Vocals on both sides at once — the one thing a DJ never lets
        /// happen — shortens the fade and blocks long beat-matched overlaps.
        var vocalClashRatio: Double = 1.1
        var vocalClashFadeCap: TimeInterval = 4

        // --- Shape parameters: less about *which* transition and more about
        // where it lands and how it sounds. Same story: constants promoted
        // to fields so the tuning surface can reach them.

        /// Overlap length at or above which a compatible crossfade earns the
        /// staged-EQ hand-over.
        var stagedEQMinOverlap: TimeInterval = 8
        /// Echo-out delay: a dotted eighth of the outgoing tempo, clamped.
        var echoBeatFraction: Double = 0.75
        var echoDelayMin: TimeInterval = 0.15
        var echoDelayMax: TimeInterval = 1.0
        /// Window (seconds of 1 s RMS) each side contributes to the loudness gap.
        var loudnessWindow: Int = 15
        /// Whether the two thresholds above are measured **after** the player's
        /// gain compensation — the per-track playback trim
        /// (`LoudnessCompensation`) *and* the transition gain ride (`rideDB`) —
        /// or on the raw masters. Mirrors the product's one user-visible
        /// switch, so the planner judges the hand-over the listener will
        /// actually hear; see `loudnessGapDB`. Off also means the ride itself
        /// is never applied: both gain stages are the same feature.
        var loudnessCompensation: Bool = true
        /// **The house level every track is trimmed to**, in LUFS — the one
        /// number that decides how loud a *body* plays.
        ///
        /// ### Why −14 was wrong
        ///
        /// −14 LUFS is the streaming convention, and it is the right number for
        /// a service that also *serves* the audio: Spotify normalizes to it and
        /// then hands you a file, so −14 is where the whole world sits and
        /// nothing is quieter than anything else. Here it is only ever a cut
        /// applied on top of the master, and the library is nowhere near it.
        /// Measured over the 157 cached analyses on the listening machine
        /// (`~/Library/Caches/Kumone/Audio/*.analysis.json`, 2026-09-02):
        ///
        /// | | min | p10 | median | p90 | max |
        /// |---|---|---|---|---|---|
        /// | `referenceLoudness` (LUFS) | −13.3 | −11.0 | −9.0 | −7.1 | −5.8 |
        /// | trim at −14 (dB) | −8.16 | −6.90 | −5.04 | −3.02 | −0.67 |
        /// | trim at −11 (dB) | −5.16 | −3.90 | −2.04 | −0.02 | 0 |
        ///
        /// **Not one track in the corpus is quieter than −14 LUFS.** So the
        /// target was not a level things were gathered *around*, it was a floor
        /// everything was pushed *down* to: a mean −4.94 dB, and 142 of 157
        /// tracks cut by more than 3 dB, before the mixer's own 0.8 master
        /// (−1.9 dB) and before any transition ride. That is the whole of the
        /// "every song sounds like it is playing underwater until the next
        /// transition wakes it up" report: an 8 s output tap of a muffled body
        /// measures **flat −8.76 dB from 60 Hz to 16 kHz** against its source
        /// file — no coloration anywhere, just level, heard as dullness through
        /// the equal-loudness contours.
        ///
        /// ### Why −11, and why raise the target rather than compress the curve
        ///
        /// The other way to narrow the trims is a ratio: `r·(target − L)` with
        /// r < 1. It is worse, because it gives up the property the trim exists
        /// for. At r = 0.5 *every* pair keeps half its mastering difference —
        /// about 2 dB across this corpus's p10…p90 — so pain point ④ comes
        /// back everywhere, in exchange for loudness. Raising the target keeps
        /// the trim exact (`target − L`, ratio 1) for every track *at or above*
        /// it, and concedes the match only below it, where the clip guard was
        /// already refusing to help: a master quieter than the target can only
        /// be lifted into whatever peak headroom it has, and on this corpus
        /// (median peak +0.5 dBFS) that is zero for all 157 files.
        ///
        /// So the target is a straight trade of "how many tracks are matched
        /// exactly" against "how loud the matched ones play":
        ///
        /// | target | median trim | tracks cut > 3 dB | tracks below target | body spread p10…p90 |
        /// |---|---|---|---|---|
        /// | −14 | −5.04 dB | 142/157 | 0 | 0.0 dB |
        /// | −12 | −3.04 dB | 81/157 | 4 | 0.0 dB |
        /// | **−11** | **−2.04 dB** | **35/157** | **15** | **0.0 dB** |
        /// | −10 | −1.04 dB | 13/157 | 39 | 1.0 dB |
        /// | −9 | −0.04 dB | 1/157 | 60 | 2.0 dB |
        ///
        /// −11 is the last row where the *whole* p10…p90 body of the library
        /// still lands exactly on the house level — 142 of 157 tracks matched
        /// to the dB, the other 15 (the quiet decile, −13.3…−11.0 LUFS) playing
        /// at their own level, at most 2.3 dB under. It buys back a median
        /// +3.0 dB and a p10 +3.0 dB of real loudness. −10 buys one more dB for
        /// a quarter of the library falling off the target and the body spread
        /// opening to 1 dB, which is the number this whole change is trying to
        /// keep seams and bodies inside; that is the wrong dB to spend.
        ///
        /// A raised target never makes clipping *more* likely than playing the
        /// file untouched: trims stay ≤ 0 unless `boostHeadroomDB` grants room,
        /// and that guard is untouched here. What it does move is the bent-rate
        /// pad (`LoudnessCompensation.timePitchPadDB`), which is sized from
        /// `peak + trim`: a shallower trim means a deeper pad while a deck is
        /// running off unity. That is a seam-time cut, in the direction this
        /// change wants anyway (seams no louder than bodies), and it is bounded
        /// by the same ceiling as before.
        ///
        /// Defaults to −14 so `Config.standard` is still the shipped player;
        /// the listening machine gets −11 through
        /// `AutoMixOverrides.enableBodyLevel`.
        var loudnessTargetLUFS: Double = -14
        /// The `LoudnessCompensation` config the trims are computed with — the
        /// house level above, everything else stock. Every path that has to
        /// agree about what a deck plays at (`TransitionPlanner.signals`, the
        /// ride's headroom guard, `PlayerService`'s load-time trim, and the two
        /// offline renderers through the signals they are handed) reads it from
        /// here, so a target can never be applied to the plan but not to the
        /// deck.
        var loudnessConfig: LoudnessCompensation.Config {
            .targeting(loudnessTargetLUFS)
        }
        /// How far the transition gain ride may **lift** the incoming deck, in
        /// dB. 0 turns the ride off entirely — both directions — and puts the
        /// loudness gate back on the trim-only residual. See `rideDB` for why
        /// the ride is one-sided and where the cap comes from.
        var rideMaxDB: Double = 4
        /// …and how far it may hold the incoming deck **down**.
        ///
        /// Deliberately larger than the boost cap, because the two directions
        /// are not the same operation. A cut is applied to a deck whose fader
        /// is still at 0, costs no headroom, adds no artefact, and is released
        /// while that deck is the only thing playing — the only limit on it is
        /// that it must not turn a level match into a mix decision. A boost
        /// pushes a real signal towards its own peak ceiling, which is what
        /// `boostHeadroomDB` is for, and gains nothing from being deeper.
        ///
        /// The tier gate sees the smaller residual automatically, which is the
        /// point: pairs whose seam is several dB apart in the direction the
        /// ride can absorb stop being demoted for a difference the player
        /// removes.
        ///
        /// **Why 4 and not the 6 this shipped at.** "A cut is free" was true of
        /// everything except its length. The release is a walk back to unity at
        /// a fixed dB/s, so the cap *is* how long the new track spends under
        /// the level its mastering engineer chose — and at 6 dB that was long
        /// enough for listeners to hear the arrival as muffled and the recovery
        /// as the track "getting better". The release slope is the other half
        /// of that fix (`TransitionAutomation.rideReleaseCutDBPerSecond`), and
        /// capping the depth here is the half that works at the source: it
        /// bounds the pit rather than climbing out of it faster. 4 dB matches
        /// the boost cap, which makes the ride one number in both directions
        /// again, and at 1.2 dB/s unwinds in ~3.3 s.
        var rideMaxCutDB: Double = 4
        /// Out-point search window for beat-matched plans: candidates must sit
        /// past `max(duration * tailWindowShare, outLimit - tailWindowSeconds)`.
        var tailWindowSeconds: TimeInterval = 60
        var tailWindowShare: Double = 0.5
        /// Crossfade out-point candidates must sit past this share of the track.
        var crossfadeOutPointShare: Double = 0.6
        /// Incoming intake capacity: seconds until the opening reaches this
        /// share of the track's peak, plus this much body.
        var intakePeakShare: Double = 0.7
        var intakeBodySeconds: TimeInterval = 8
        /// Fade length used when the outgoing tail never settles.
        var tailCapacityFallback: TimeInterval = 4

        // --- Stem layer. Read *only* when the caller passes
        // `StemAvailability.ready`; at `.none` — every product path today —
        // not one of these numbers is looked at, which is what makes the
        // stem work provably additive.

        /// How vocal-active the outgoing window has to be, relative to that
        /// track's own mean, before a stem technique is worth asking for.
        ///
        /// Calibrated on the audition corpus: sliding 8 s windows put the
        /// median at 1.00 and the 95th percentile between 1.16 and 1.58 per
        /// track (`vocalActivity` is level-normalized, so its dynamic range is
        /// narrow). 1.15 sits around each track's own 85th percentile — a
        /// window that is *noticeably* more sung than the song's average — and
        /// deliberately above `vocalClashRatio`, so anything the stem layer
        /// calls "vocal-active" is by definition also on the clash side of the
        /// two-lead-vocals rule.
        var stemVocalActiveRatio: Double = 1.15
        /// `acapellaOver` additionally needs the incoming opening to be
        /// instrumental-leaning: at or below this share of its own mean vocal
        /// density. Floating one track's vocal over another's is only a
        /// technique when the other one is not singing; at the corpus's median
        /// intake of ~1.0 it would just be the two-vocal pile-up the ducking
        /// rule exists to prevent.
        var stemAcapellaIncomingVocalMax: Double = 0.90
        /// No stem technique on an overlap shorter than this: the curves in
        /// `StemTechniqueLayer` (an accompaniment drop by 28 %, a vocal
        /// retired by 96 %) need room, and a separation pass is far too
        /// expensive to spend on a two-second clash-tier hand-over.
        var stemMinOverlap: TimeInterval = 5
        /// How far `vocalDuck` holds the outgoing vocal down, in dB of
        /// attenuation (S1's blind test liked 9). Also the depth
        /// `vocalExchange` degrades to when it cannot find a hand-over.
        var stemDuckDepthDB: Double = 9
        /// Where in the overlap `vocalExchange`'s hand-over may land, as a
        /// share of the overlap. The compiler picks the outgoing lyric line-end
        /// nearest the middle and then clamps it into this window: before 0.30
        /// the incoming bed has not established itself and the swap sounds like
        /// a cut; after 0.85 the new vocal has no room to arrive before the
        /// outgoing deck is gone. Only read when a separator is available.
        var stemExchangeHandoverMin: Double = 0.30
        var stemExchangeHandoverMax: Double = 0.85
        /// Two-clock hand-over: choose the vocal's hand-over instant L *relative
        /// to* the floor swap S (`Geometry.swapOffset`) rather than relative to
        /// the middle of the overlap. Off = the single-clock compile this
        /// replaced, field-for-field — the knob exists so the A/B is a knob flip
        /// and so the old shape stays pinned by a test.
        ///
        /// The two clocks are the whole idea: the instrumental floor changes
        /// decks at S because that is where the low end and the staged EQ say
        /// it does, and the *voice* changes decks at L because that is where a
        /// sung line ends. A DJ move is those two instants being deliberately
        /// different; a mix is them being the same instant twice.
        var twoClockExchange: Bool = true
        /// How far past the floor swap the outgoing singer may carry, in
        /// seconds. A line-end inside `(S, S + this]` makes the hand-over a
        /// `vocalCarryover`; nothing inside it makes it a `vocalYield`.
        ///
        /// 8 s is about two bars at 60 BPM and four at 120 — long enough to
        /// finish almost any single line, short enough that the carry does not
        /// outlive the outgoing deck's fader. It is capped by
        /// `stemExchangeHandoverMax` anyway, and that cap is the binding one on
        /// a typical 16 s overlap (see `VocalExchange.compensationCeilingDB`:
        /// past ~64 % of the post-swap stretch the compensation saturates and
        /// the carried voice starts riding the fader down regardless).
        var vocalCarryWindowSeconds: TimeInterval = 8
        /// How far the incoming in-point may be moved off the structural
        /// choice so that the incoming singer's first line lands on the vocal
        /// hand-over rather than eight seconds before it.
        ///
        /// The compile can only choose *when* to unmute deck B; it cannot
        /// choose when deck B starts singing. A track entered right on top of a
        /// verse has its first lines muted no matter how well the exchange is
        /// picked — which is what the field seams were: an in-point 0.012 s
        /// into a track that sings from the top, and 17 s of its voice gone.
        /// So the planner moves the entry back into the song's own pre-vocal
        /// gap when there is one within this bound. 8 s is about four bars at
        /// 120 BPM: enough to clear an intro or a pre-verse gap, short enough
        /// that the incoming track is still entered where structure said.
        var vocalEntryMaxMoveSeconds: TimeInterval = 8
        /// Where the incoming singer's first line should land relative to the
        /// floor swap S, in beats: `S + this`. One beat — a short carry, so the
        /// exchange happens just after the swap rather than in the middle of
        /// the incoming track's second phrase.
        var vocalEntryLeadBeats: Double = 1

        // --- Transition score (docs/automix-score-predev.md). P1 ships dark:
        // the knob is **off**, so the planner writes no `TransitionStyle.score`
        // and every decision, curve and rendered sample is field-for-field what
        // it was before the score model existed. The debug panel's A/B toggle
        // and offline `Audition` renders are how it gets heard.

        /// Emit a `TransitionScore` on hand-overs that qualify for one.
        ///
        /// A score is only ever *offered*: the live path never performs one, so
        /// with this on the seam still sounds like today's blend unless a
        /// pre-rendered segment arms in time. Refusal is the blend, never an
        /// approximated cut (predev §2.2).
        var scoreEnabled: Bool = false
        /// How sure the beat tracker has to be about **both** sides before a
        /// score is offered. Deliberately far above `bpmConfidenceThreshold`:
        /// a fade survives a grid that is half a beat out and a cut does not,
        /// so the gesture that cannot forgive a bad grid asks for a better one.
        var scoreMinBPMConfidence: Double = 0.8

        // --- Aiming (P2, predev §2.3). Only ever consulted when a score is
        // offered, so with `scoreEnabled` down these two decide nothing and the
        // plan is field-for-field what it was.

        /// Compose the incoming entry backwards from a target grid point — the
        /// drop, the chorus, or the start of the song proper — so the seam
        /// lands **on** it rather than some number of phrase lines past it.
        ///
        /// On by default *within the score path*, because an unaimed slam is
        /// the thing the first field listen rejected: the edge was clean and
        /// the moment was arbitrary. Off restores P1's placement exactly, which
        /// is what the A/B needs.
        var scoreAimEnabled: Bool = true
        /// How far past the incoming track's intro end an aim target may sit.
        ///
        /// Aiming skips whatever comes before the target, so an aim two minutes
        /// in throws away two minutes of the song to land on a drop nobody was
        /// waiting for. 120 s is deliberately permissive — a first drop is
        /// typically 60–75 s in and a first chorus 45–60 s — because the
        /// interesting refusals are the gates below, not this clamp; narrowing
        /// it is a corpus question and corpus questions are P3's.
        var scoreAimMaxLeadSeconds: TimeInterval = 120

        // --- Gesture library (P4, predev §2.5). Every knob below is read only
        // from inside `ScoreTemplate`, which is only reached when a family was
        // offered, which needs `scoreEnabled`. So with the score layer down
        // none of them decides anything, and each one is independently
        // switchable because the predev's first mitigation for "a bad score is
        // worse than a good blend" is per-gesture roll-back.

        /// Offer the tension cut: N beats of full silence ending on the seam,
        /// then the cut and the slam.
        ///
        /// On *within the score path*, off is the A/B's control. The gesture
        /// gates itself hard — it is offered only into a drop or a chorus — so
        /// the knob is for turning it off after a listening session, not for
        /// keeping it out of trouble.
        var scoreTensionCutEnabled: Bool = true
        /// How long the silence is, in beats.
        ///
        /// One beat, and the default is an opinion rather than a starting
        /// point. A single beat of nothing is a held breath; two is a mistake
        /// the listener has time to notice, and four is the player having
        /// stopped. The model refuses anything past a bar outright.
        var scoreTensionCutBeats: Double = TransitionScore.defaultTensionCutBeats

        /// Offer the accompaniment bed on `dropAlign` hand-overs.
        var scoreBedIntroEnabled: Bool = true
        /// How many bars of bed, at most. On an aimed hand-over this is a cap
        /// on the *overlap*, not a length the bed is padded to: the bed runs
        /// from the instant the incoming deck starts to the instant its singer
        /// joins, and both of those are already decided. See
        /// `TransitionScore.defaultBedIntroBars` for why the number is eight
        /// and the predev's is four.
        var scoreBedIntroBars: Int = TransitionScore.defaultBedIntroBars
        /// How sung the incoming track's entry window has to be, relative to
        /// its own mean, before a bed is worth making.
        ///
        /// This is the gesture's whole reason to exist as a *gate*: a bed is
        /// the incoming track with its vocal lane held down, so on an
        /// instrumental entry the bed is the mix, the render is identical, and
        /// a separation pass has been spent on nothing. 0.9 — just under the
        /// track's own average — is "there is a singer here", which is a much
        /// weaker claim than `stemVocalActiveRatio`'s and the right one: what
        /// matters is that muting the lane *changes* something.
        var scoreBedIntroMinIncomingVocal: Double = 0.9

        // --- Intent layer (P3, predev §2.4). See `TransitionIntent`.
        //
        // Ships dark: `intentEnabled` is **false**, and with it false the whole
        // block is one nil check at the front door — no profile is computed, no
        // rule is evaluated, and every decision, curve and rendered sample is
        // field-for-field what it was before the layer existed.
        //
        // The thresholds below are all corpus questions (predev risk #6), and
        // every one of them is set on the restrained side of what the cache
        // says: a class that fires too rarely costs a missed gesture, a class
        // that fires too often costs an offence.

        /// Run the intent layer at all.
        var intentEnabled: Bool = false
        /// Per-class switches. A class turned off is *skipped*, so its pairs
        /// fall through to the next rule — which is what makes each rule
        /// independently sweepable and independently revertible. `blend` has no
        /// switch because it is the fall-through itself.
        var intentStandDownEnabled: Bool = true
        var intentRestrainedEnabled: Bool = true
        var intentDropAlignEnabled: Bool = true
        var intentCutCultureEnabled: Bool = true
        /// Seconds of material the edge statistics are taken over, ending at
        /// the outgoing exit and starting at the incoming entry.
        ///
        /// 30 s is about ten to fifteen bars: long enough that a downbeat CV
        /// has a dozen intervals to work with, short enough that it is still a
        /// statement about *this* part of the song rather than about the album
        /// it came from.
        var intentEdgeWindowSeconds: TimeInterval = 30
        /// Downbeat-interval CV at or above which the grid reads as a human
        /// keeping time rather than a machine.
        ///
        /// **Bar intervals, not beat intervals**, and the whole threshold hangs
        /// on the difference: P1 measured 5–13 % CV on the *beats* of rigidly
        /// quantized dance tracks (a dropped beat costs a whole interval) and
        /// 0.7–3.4 % on the same tracks' *bars*. The owner's cache agrees from
        /// the other end: over 214 edge windows the bar CV runs 0.0 … 5.1 %
        /// with a median of 1.0 % and a 95th percentile of 3.3 %, so 4 % sits
        /// past where a produced pop library's grids end (1.4 % of windows
        /// reach it) and well inside where a person keeping time lives. The
        /// error is biased towards calling a drifting grid steady — which costs
        /// a missed cut, not a mis-timed one.
        var intentDrummerDriftCV: Double = 0.04
        /// …and the CV at or below which a grid is hard enough to place a
        /// gesture on. Deliberately far below the drift line rather than its
        /// complement: between the two lies a band of material the layer
        /// refuses to have an opinion about, and that band gets today's blend.
        var intentHardGridCV: Double = 0.02
        /// Normalized participation ratio of `melProfile` at or above which the
        /// spectrum reads as a wall (see `MaterialProfile.flatness`).
        ///
        /// **Calibrated, and provisionally so.** Over the owner's 108-track
        /// cache the statistic runs 0.29 … 0.75 with a median of 0.56 and a
        /// 90th percentile of 0.69, so 0.70 is "flatter than nine tracks in
        /// ten of this library". That cache contains no rock, which is exactly
        /// the material the line is *for* — so this number is where a pop
        /// distribution ends, not where a wall of guitars begins, and the
        /// honest re-check is an offline intent run over a rock-bearing
        /// corpus. It is reachable rather than validated. The branch it feeds
        /// also demands a grid we already mistrust, which is what keeps a
        /// provisional line from doing provisional damage.
        var intentWallFlatness: Double = 0.70
        /// …and the share of the edge window that must be loud with it, so a
        /// quiet noisy passage is not mistaken for a wall of guitars.
        var intentWallOccupancy: Double = 0.85
        /// Vocal activity, relative to the track's own mean, at or below which
        /// an edge counts as instrumental — the precondition for cutting.
        /// Well under `vocalClashRatio`: "nobody is singing here" is a much
        /// stronger claim than "these two will not fight".
        var intentInstrumentalEdgeRatio: Double = 0.5

        // --- Climax extension + vocal cliff.
        //
        // **Not the intent layer.** These two are a correctness fix in cue
        // selection and they apply to every class, intent on or off. They come
        // from a marked-bad seam in the field corpus (track 476081904, cut at
        // 204.7 s): the segmenter had `chorus 131.5–174.3`, then a *unique*,
        // vocally dense passage 174.3–208.6, then the outro. The climax guard
        // protected the sixteen bars before the last chorus and then stood
        // aside, so the cut landed in the middle of the passage the singer was
        // still finishing. The song's climax does not end where the chorus
        // cluster does.

        /// Extend the climax guard's forbidden window forward over a unique,
        /// vocally dense section that follows the final chorus immediately.
        var climaxExtendPostChorus: Bool = true
        /// How dense that section's vocal has to be, in `vocalDensity` units
        /// (1 = an average passage for this track). 0.9 keeps the extension to
        /// passages the singer is genuinely still working in — an instrumental
        /// tag or a repeat-out is not the climax and stays cuttable.
        var climaxExtendVocalDensity: Double = 0.9
        /// Prefer out-point candidates that sit on a **vocal cliff** — a drop
        /// in `vocalActivity` looking forward across the candidate. This is the
        /// same lesson from the other side: the right cut on that seam was
        /// 208.6 s, where the voice stops, and the machinery had no way to
        /// prefer it over 204.7 s where the voice is mid-phrase.
        ///
        /// A **stable** re-ordering, never a filter: candidates that sit on a
        /// cliff move ahead of ones that do not, each group keeping its own
        /// order, so nothing is ever removed and the fall-back list is intact.
        var preferVocalCliffOutPoints: Bool = true
        /// Seconds either side of a candidate the cliff is measured over.
        var vocalCliffWindowSeconds: TimeInterval = 4
        /// How far `vocalActivity` must fall across the candidate — in units of
        /// the track's own mean — to count as a cliff.
        var vocalCliffDrop: Double = 0.35

        // --- Structure layer (predev §2.3). Read *only* when the analysis on
        // the relevant side carries `sections` — a v7 sidecar the segmenter was
        // confident about. Every other track (older sidecar, ambient material,
        // broken beat tracking) leaves this whole block unread and decides
        // field-for-field what it decided before the layer existed.
        //
        // The principle the block is built to: **candidates change, gates do
        // not**. Nothing here can let a pair through a gate it used to fail; it
        // only changes *which* out/in points the unchanged five-signal / tier /
        // bar-upgrade machinery is offered, and in what order.

        /// Prefer section boundaries — the final chorus's end above all — over
        /// the RMS-jump-scored `phraseBoundaries` when picking an out point.
        /// Off puts all three out-point searches (beat-matched, crossfade,
        /// stem) back on the bare boundary list, which is what makes a listening
        /// test able to revert this one behaviour on its own.
        var useStructureOutPoints: Bool = true
        /// Take the in point from the first *core* section — the first one that
        /// is neither intro- nor outro-kind — instead of `introEnd`'s "first
        /// second above 25 % of peak". Off restores `introEnd` everywhere,
        /// `intakeCapacity`'s anchor included. See `inPointChoice` for why core
        /// is defined by exclusion.
        var useStructureInPoint: Bool = true
        /// Confidence a track's `sections` must carry before the planner will
        /// take points from them.
        ///
        /// The segmenter already drops sections below its own gate, so at the
        /// default this re-gate never fires — it is deliberately a *second*
        /// reading of the same number, so the console can raise the bar for a
        /// listening test ("only act on structure I am very sure about")
        /// without re-analyzing the library, and so a sidecar written by a
        /// future, looser segmenter cannot silently widen what the planner
        /// acts on.
        var structureConfidenceGate: Double = StructureSegmenter.confidenceGate
        /// How far back an out-point candidate may be pulled to land on a lyric
        /// line end. Four seconds is a little over one 4-bar phrase at 120 BPM:
        /// far enough to rescue a candidate that fell one line short of the full
        /// stop, short enough that it can never walk a candidate into the
        /// previous section. Beyond it the candidate is left where it was rather
        /// than dragged somewhere structurally different. 0 turns snapping off.
        var lyricSnapMaxSeconds: TimeInterval = 4
        /// **Climax guard**: how many bars before the final chorus's start an
        /// out point is forbidden. Sending the song away eight bars before its
        /// biggest moment is the single most offensive cut there is, and the
        /// energy heuristics have no concept of it — a pre-chorus lift reads as
        /// a fat RMS jump and scores *well*. Sixteen bars is the usual length of
        /// that lift. Bars are measured at the outgoing track's own tempo, or at
        /// a flat 4 s when its tempo is not confident.
        var climaxGuardBarsBefore: Int = 16
        /// …and how many bars *into* the final chorus stay forbidden. 0 — the
        /// default — makes the window `[start − before, start)`: landing exactly
        /// on the downbeat the chorus begins is a legitimate hand-over (the
        /// listener hears the new track arrive on the big one), it is the eight
        /// bars of anticipation before it that must not be cut.
        var climaxGuardBarsAfter: Int = 0
        /// Sanity clamp on the structural in point, against `introEnd`: a
        /// mislabelled "first core section" a minute in must not skip a third of
        /// the song. The back slack exists because a section boundary snapped to
        /// a downbeat can legitimately sit a hair before the energy threshold
        /// `introEnd` found; outside either bound the planner falls back to
        /// `introEnd` and says so in the trace.
        ///
        /// The lead was 60 s in the first corpus sweep and 30 s is defence in
        /// depth after it: a real intro that `introEnd` misses runs 10–25 s
        /// (the corpus's longest honest one is 32 s of build), so past 30 s the
        /// far more likely explanation is a mislabelled section than a very
        /// patient song — and the cost of being wrong is asymmetric, since a
        /// wrong fallback loses a slightly better in point while a wrong section
        /// silently eats a verse.
        var structureInPointSlackSeconds: TimeInterval = 2
        var structureInPointMaxLeadSeconds: TimeInterval = 30

        static let standard = Config()
    }

    /// Per-hand-over facts the planner cannot derive from two `TrackAnalysis`
    /// values, and which are therefore *given* to it rather than looked up.
    ///
    /// The planner is a pure function and stays one: no file is read here, no
    /// clock consulted. The one thing the structure layer wants that analysis
    /// does not carry is *where the outgoing singer stops singing* — words are
    /// not a signal the analyzer computes — so the caller that already knows
    /// the outgoing file's URL (`PlayerService`, `Audition.decide`) reads its
    /// `.lrc` and hands the timestamps over. Everything defaults to "unknown",
    /// and unknown means the decision is exactly what it was before this type
    /// existed.
    struct PlanContext: Sendable, Equatable {
        /// Ascending line-end timestamps of the **outgoing** track
        /// (`Audition.Lyrics.lineEnds`). Empty = no snapping.
        var outgoingLyricLineEnds: [TimeInterval] = []

        /// One track's lyric clock, in **track time**: where each line begins
        /// and where it stops being sung. Both arrays are ascending and the
        /// same length (`Audition.Lyrics.lineEnds` is one entry per line).
        ///
        /// Nil everywhere means "no `.lrc`", and every decision below is then
        /// field-for-field what it was before this type existed — which is
        /// what `plannerIgnoresNilLyricTiming` pins.
        struct LyricTiming: Sendable, Equatable {
            var lineStarts: [TimeInterval]
            var lineEnds: [TimeInterval]

            init(lineStarts: [TimeInterval], lineEnds: [TimeInterval]) {
                self.lineStarts = lineStarts
                self.lineEnds = lineEnds
            }
        }

        /// The outgoing track's clock. Carried for symmetry with the incoming
        /// one (and because the out-point snap is the same data said twice);
        /// nothing reads it today — `outgoingLyricLineEnds` above is still the
        /// snap grid.
        var outgoingLyricTiming: LyricTiming?
        /// The **incoming** track's clock. This is the one the vocal-exchange
        /// aim reads: where deck B starts singing decides whether entering it
        /// at the structural in-point throws its first lines away.
        var incomingLyricTiming: LyricTiming?

        /// The two tracks are on the same album (a real album, not the empty
        /// `AlbumRef` a search result carries).
        ///
        /// Queue metadata, which is why it arrives here rather than being
        /// sniffed: the planner sees two `TrackAnalysis` values and neither of
        /// them knows what record it came from. Nothing but the intent layer
        /// reads it, and with `intentEnabled` false nothing reads it at all.
        var sameAlbum: Bool = false
        /// …and the incoming track is the very next entry after the outgoing
        /// one in the **listed** queue — the order as the user sees it, not the
        /// shuffled or AutoMix-reordered one.
        ///
        /// Both halves are required for `standDown`: two tracks from one album
        /// that a shuffle happened to put together are not an album in
        /// sequence, and two adjacent playlist entries from different records
        /// are not a work.
        var listedAdjacent: Bool = false

        /// The album-sequential test the intent layer's first rule turns on.
        var albumSequential: Bool { sameAlbum && listedAdjacent }

        static let none = PlanContext()
    }

    // The shipped numbers, kept as the flat names the rest of the codebase and
    // the tests already read. Every one is `Config.standard`'s field, so there
    // is exactly one source of truth.
    static let minTrackDuration = Config.standard.minTrackDuration
    static let bpmConfidenceThreshold = Config.standard.bpmConfidenceThreshold
    static let maxBPMDeltaRatio = Config.standard.maxBPMDeltaRatio
    static let maxRateDeviation = Config.standard.maxRateDeviation
    static let stableCV = Config.standard.stableCV
    static let maxOverlap = Config.standard.maxOverlap
    static let minOverlap = Config.standard.minOverlap
    static let maxOverlapShare = Config.standard.maxOverlapShare
    static let tailStableCV = Config.standard.tailStableCV
    static let neutralLoudnessDB = Config.standard.neutralLoudnessDB
    static let clashLoudnessDB = Config.standard.clashLoudnessDB
    static let neutralTimbreDistance = Config.standard.neutralTimbreDistance
    static let clashTimbreDistance = Config.standard.clashTimbreDistance
    static let clashTempoRatio = Config.standard.clashTempoRatio
    static let neutralOverlapCap = Config.standard.neutralOverlapCap
    static let clashOverlapCap = Config.standard.clashOverlapCap
    static let keyConfidenceThreshold = Config.standard.keyConfidenceThreshold
    static let clashKeyDistance = Config.standard.clashKeyDistance
    static let vocalClashRatio = Config.standard.vocalClashRatio
    static let vocalClashFadeCap = Config.standard.vocalClashFadeCap

    /// - Parameter stems: whether a vocal/accompaniment separator is available
    ///   for this hand-over. At `.none` — the default, and what every product
    ///   path passes — the result is field-for-field what it was before the
    ///   stem layer existed; `.ready` lets the two rules in "Stem layer" below
    ///   re-aim the out point and add a `StemTechnique`.
    /// - Parameter context: facts about this particular hand-over that no
    ///   `TrackAnalysis` carries — today, the outgoing track's lyric line ends.
    ///   `.none` (the default) decides exactly what the planner decided before
    ///   the structure layer existed.
    static func plan(
        outgoing: TrackAnalysis?, incoming: TrackAnalysis?,
        stems: StemAvailability = .none,
        config: Config = .standard,
        context: PlanContext = .none
    ) -> PlannedTransition {
        var untraced: PlanTrace?
        return plan(outgoing: outgoing, incoming: incoming, stems: stems,
                    config: config, context: context, trace: &untraced)
    }

    /// The same decision, with an optional gate-by-gate ledger.
    ///
    /// Pass a non-nil `trace` and every gate this pair walked comes back in it,
    /// along with the first one it failed — which is what turns "beat-matching
    /// almost never fires on the real library" from a guess into a histogram.
    /// Pass nil (what `plan` above, and so every product path, does) and the
    /// ledger costs one nil check per gate: the numbers and the wording of each
    /// record are built inside autoclosures that are never called. The result is
    /// field-for-field identical either way — nothing written here is ever read
    /// back by the planner.
    static func plan(
        outgoing: TrackAnalysis?, incoming: TrackAnalysis?,
        stems: StemAvailability = .none,
        config: Config = .standard,
        context: PlanContext = .none,
        trace: inout PlanTrace?
    ) -> PlannedTransition {
        guard let outgoing, let incoming else {
            _ = note(&trace, .duration, "minDuration", false,
                     nil, config.minTrackDuration,
                     "one side has no analysis at all")
            return .plain(.gapless)
        }
        guard note(&trace, .duration, "minDuration",
                   outgoing.duration >= config.minTrackDuration
                       && incoming.duration >= config.minTrackDuration,
                   Swift.min(outgoing.duration, incoming.duration), config.minTrackDuration,
                   String(format: "durations %.0f s / %.0f s against a %.0f s floor",
                          outgoing.duration, incoming.duration, config.minTrackDuration))
        else { return .plain(.gapless) }

        let s = signals(outgoing: outgoing, incoming: incoming, config: config)
        var tier = Self.tier(of: s, config: config)
        // The three tier signals, each as its own gate. A pair only stays
        // `compatible` — the one tier that may beat-match — when all three sit
        // inside their tolerance line, so recording them separately is what
        // lets a sweep say *which* signal did the demoting.
        _ = note(&trace, .tier, "loudnessGap", s.loudnessGapDB <= config.neutralLoudnessDB,
                 s.loudnessGapDB, config.neutralLoudnessDB,
                 String(format: "%.2f dB gap against a %.1f dB tolerance line "
                        + "(%.1f dB is the clash line)",
                        s.loudnessGapDB, config.neutralLoudnessDB, config.clashLoudnessDB))
        _ = note(&trace, .tier, "timbreDistance",
                 s.timbreDistance <= config.neutralTimbreDistance,
                 s.timbreDistance, config.neutralTimbreDistance,
                 String(format: "%.3f distance against a %.2f tolerance line "
                        + "(%.2f is the clash line)",
                        s.timbreDistance, config.neutralTimbreDistance,
                        config.clashTimbreDistance))
        _ = note(&trace, .tier, "tempoClash", (s.tempoRatio ?? 0) <= config.clashTempoRatio,
                 s.tempoRatio, config.clashTempoRatio,
                 s.tempoRatio.map {
                     String(format: "folded tempo gap %.1f %% against a %.1f %% clash line",
                            $0 * 100, config.clashTempoRatio * 100)
                 } ?? "no confident tempo on both sides, so this gate never fires")

        let keyDist = keyDistance(outgoing, incoming, config: config)
        let demotedByKey = tier == .compatible && (keyDist ?? 0) >= config.clashKeyDistance
        _ = note(&trace, .key, "keyDistance", !demotedByKey,
                 keyDist.map(Double.init), Double(config.clashKeyDistance),
                 keyDist.map {
                     "circle-of-fifths distance \($0), demoting at ≥ \(config.clashKeyDistance)"
                 } ?? "at least one key is below the confidence gate, so harmony abstains")
        if demotedByKey { tier = .neutral }

        // --- Candidate generation (predev §2.3). Computed once and handed to
        // all three out-point searches and to both plan shapes, so beat-matched,
        // crossfade and stem hand-overs can never disagree about where this
        // pair's structure says the seams are.
        let candidates = outPointCandidates(outgoing, context: context, config: config)
        let inChoice = inPointChoice(incoming, config: config)
        // `passed` here is "nothing went wrong", not "structure was used": an
        // empty candidate list is a real problem, a list made only of phrase
        // boundaries is the ordinary path. See `PlanGate.Stage.structure`.
        _ = note(&trace, .structure, "structureCandidates", !candidates.points.isEmpty,
                 Double(candidates.structuralCount), nil,
                 String(format: "%d of %d candidates come from sections "
                        + "(%d phrase boundaries behind them; structure confidence %.2f "
                        + "against a %.2f gate)",
                        candidates.structuralCount, candidates.points.count,
                        outgoing.phraseBoundaries.count, outgoing.structureConfidence,
                        config.structureConfidenceGate))
        _ = note(&trace, .structure, "climaxGuard", !candidates.guardFellBack,
                 Double(candidates.guardRejected), nil,
                 candidates.guardWindow.map { window in
                     String(format: "final chorus starts at %.2f s; %d candidate(s) inside "
                            + "[%.2f s, %.2f s)%@",
                            candidates.climaxStart ?? 0, candidates.guardRejected,
                            window.start, window.end,
                            candidates.guardFellBack
                                ? " — every candidate was, so the guard stood down"
                                : "")
                 } ?? "no final chorus to protect, so the guard never fires")
        _ = note(&trace, .structure, "climaxExtension",
                 candidates.climaxExtensionWindow == nil, nil, nil,
                 candidates.climaxExtensionDetail
                     ?? "nothing unique and vocally dense follows the final chorus, "
                     + "so the no-cut zone ends where it always did")
        _ = note(&trace, .structure, "vocalCliff", true,
                 Double(candidates.vocalCliffPromoted), nil,
                 candidates.vocalCliffPromoted > 0
                     ? String(format: "%d candidate(s) sit where the voice stops and were "
                              + "moved ahead of the ones that do not",
                              candidates.vocalCliffPromoted)
                     : "no candidate sits on a vocal cliff, so the order is unchanged")
        _ = note(&trace, .structure, "inPointSource", true, inChoice.point, nil,
                 (inChoice.section == nil ? "introEnd: " : "section: ") + inChoice.detail)

        // --- Intent (P3, predev §2.4). The front door: what this pair is
        // culturally *for*, decided before any family is chosen, so it can say
        // which families and parameters are allowed at all.
        //
        // **Gates still win inside a family**, exactly as they win over aiming.
        // Intent can take a family off the table (`restrained` refuses the
        // beat-match, `standDown` refuses everything); it can never hand a pair
        // a geometry the five signals, the tier or the climax guard refused.
        // The reason the layer is allowed to *subtract* where aiming may only
        // *choose* is that subtraction is the safe direction: the worst a wrong
        // restraint can do is play today's shorter hand-over.
        //
        // The edge windows, anchored on the geometry the candidate layer has
        // already proposed — the best out-point candidate and the chosen in
        // point. Not the final seam (that is what the beat-match search is
        // about to decide), but the same part of each song to within a bar or
        // two, and a whole-track statistic would answer a different question
        // entirely. Held in locals because the stem request below is the *same*
        // finding as the reason sentence, read off the same two profiles.
        let outgoingEdge: MaterialProfile? = config.intentEnabled
            ? .outgoing(outgoing,
                        exitAt: candidates.points.first
                            ?? outgoing.outroFadeStart ?? outgoing.duration,
                        config: config)
            : nil
        let incomingEdge: MaterialProfile? = config.intentEnabled
            ? .incoming(incoming, entryAt: inChoice.point, config: config)
            : nil
        let intent: TransitionIntent? = {
            guard config.intentEnabled, let outgoingEdge, let incomingEdge else { return nil }
            return TransitionIntent.classify(
                outgoing: outgoing, incoming: incoming,
                outgoingEdge: outgoingEdge, incomingEdge: incomingEdge,
                context: context, stems: stems, config: config)
        }()
        if let intent {
            _ = note(&trace, .intent, "intentClass", intent.class != .standDown,
                     intent.budget, nil, intent.label)
        }
        // --- The intent-driven stem request (the P3→S1 seam).
        //
        // The intent layer's rule 6 can find that both edges are sung and say
        // so; until now nothing acted on it, because the stem layer qualified
        // an out point on `stemVocalActiveRatio` (1.15) — "is this window a
        // vocal hot spot", an S1 question — and an ordinary sung edge sits at
        // 1.0–1.1 and never clears it. So the one case `.vocalExchange` was
        // built for, two vocal-active windows with a hand-over to orchestrate
        // between them, was the case it could not be reached from.
        //
        // When the finding fires on a `blend` and a separator is ready, the
        // planner therefore *requests* the exchange, and the request carries
        // the intent layer's own definition of "sung"
        // (`intentInstrumentalEdgeRatio`) down to the stem search in place of
        // the hot-spot pair. Not a second definition of singing: the same
        // number rule 5 already refuses to cut above.
        //
        // Everything else the stem layer insists on is untouched —
        // `stemMinOverlap`, the tail-window/out-point geometry, the stability
        // bars on the 8/16-bar upgrades — and the request still has to *find* a
        // qualifying out point in the real overlap window; it is a relaxed
        // threshold, not a bypass of the search. Downstream, `.vocalExchange`
        // remains a marker that `Audition.decide` compiles against the outgoing
        // lyrics and degrades, visibly, to `.vocalDuck` when there is nothing to
        // hand over on.
        //
        // Restricted to `.blend` on purpose. `cutCulture` cannot produce the
        // finding (it requires instrumental edges), `restrained` and
        // `standDown` are the two classes that exist to spend *less* gesture,
        // and `dropAlign` is aiming at a drop rather than managing two voices.
        let intentVocalRequest: Double? = {
            guard let intent, intent.class == .blend, stems == .ready,
                  let outgoingEdge, let incomingEdge,
                  TransitionIntent.bothEdgesSung(outgoingEdge, incomingEdge,
                                                 config: config) != nil
            else { return nil }
            return config.intentInstrumentalEdgeRatio
        }()
        if config.intentEnabled {
            _ = note(&trace, .intent, "intentStemRequest", intentVocalRequest != nil,
                     intentVocalRequest, config.stemVocalActiveRatio,
                     intentVocalRequest != nil
                         ? String(format: "both edges sung on a blend and a separator is ready — "
                                  + "vocalExchange requested at the intent layer's own %.2f "
                                  + "line instead of the %.2f hot-spot gate",
                                  config.intentInstrumentalEdgeRatio,
                                  config.stemVocalActiveRatio)
                         : (stems == .ready
                            ? "no vocal-managed blend to request an exchange for"
                            : "no separator available, so the stem layer is not asked"))
        }
        // `standDown` **is** the plain path, not a shorter version of the
        // AutoMix one: `.plain(.gapless)` is precisely what this function
        // returns for a pair with no analysis and for a track under the
        // duration floor, and it is what the iOS build and the AutoMix-off
        // player do for every seam. Tail to head, no overlap, no ride, no
        // style — the most conservative path that already exists, reused rather
        // than re-invented.
        if intent?.class == .standDown {
            var style = TransitionStyle.plain
            style.intent = intent
            return PlannedTransition(plan: .gapless, style: style)
        }
        // `restrained` keeps the crossfade family only. It does not demote the
        // tier — a compatible pair still gets the staged EQ crossfade, which is
        // the "staged crossfade" half of the rule — it simply refuses the
        // beat-match and caps the window at the neutral overlap.
        let restrained = intent?.class == .restrained

        var matched: (plan: BeatMatchedPlan, stem: StemTechnique?, vocalEntry: String?)?
        if tier == .compatible, !restrained {
            matched = beatMatchedPlan(outgoing: outgoing, incoming: incoming,
                                      candidates: candidates.points, inAnchor: inChoice.point,
                                      stems: stems, intentVocalRequest: intentVocalRequest,
                                      incomingLyrics: context.incomingLyricTiming,
                                      config: config, trace: &trace)
        } else if trace != nil {
            // The tier already ended this pair's beat-match hopes, so the rest
            // of the chain never runs for real. Walk it anyway into a side
            // ledger — planning is a pure function over two cached analyses, so
            // it costs microseconds — to answer the counterfactual a corpus
            // sweep actually wants: had the tier let this pair through, would
            // anything else have stopped it?
            var shadow: PlanTrace? = PlanTrace()
            _ = beatMatchedPlan(outgoing: outgoing, incoming: incoming,
                                candidates: candidates.points, inAnchor: inChoice.point,
                                stems: stems, intentVocalRequest: intentVocalRequest,
                                incomingLyrics: context.incomingLyricTiming,
                                config: config, trace: &shadow)
            trace?.shadowGates = shadow?.gates ?? []
        }
        // One last structure note, once the seam is final: whether the point
        // this pair actually hands over on was pulled back onto a lyric line
        // end, and by how much.
        func finish(_ transition: PlannedTransition) -> PlannedTransition {
            if trace != nil, let outPoint = transition.plan.outPoint {
                let origin = candidates.snapOrigin(of: outPoint)
                _ = note(&trace, .structure, "lyricSnap", true,
                         (origin ?? outPoint) - outPoint, config.lyricSnapMaxSeconds,
                         origin.map {
                             String(format: "out point pulled back %.2f s, from %.2f s to the "
                                    + "lyric line ending at %.2f s (cap %.1f s)",
                                    $0 - outPoint, $0, outPoint, config.lyricSnapMaxSeconds)
                         } ?? (context.outgoingLyricLineEnds.isEmpty
                               ? "no lyrics for the outgoing track, so nothing snapped"
                               : String(format: "out point %.2f s stayed put — no line end "
                                        + "within %.1f s behind it",
                                        outPoint, config.lyricSnapMaxSeconds)))
            }
            return transition
        }
        if let matched {
            trace?.chosenBars = matched.plan.overlapBars
            // The full DJ hand-over: staged three-band EQ across the overlap.
            // A stem technique layers *under* that — it rewrites what the
            // outgoing deck is fed, and the fader / EQ / outro automation then
            // runs over it unchanged (see `StemTechniqueLayer`).
            var style = TransitionStyle(outroEffect: .fade, stagedEQ: true)
            style.stemTechnique = matched.stem
            // The one place the dominant-deck law is asked for: a staged
            // hand-over long enough to have a middle to collapse in. A staged
            // *crossfade* keeps the symmetric curves — it has no beat grid, so
            // its swap point is a guess rather than a downbeat, and holding one
            // deck up to it would be holding it up to nothing in particular.
            style.dominantDeck = config.dominantDeckBlend
            style.preSwapPlateau = Float(config.preSwapPlateau)
            // The vocal-entry aim is an intent-layer decision — it only runs
            // under `intentVocalRequest`, which is rule 6 firing — so it is
            // reported where that layer already reports: the `intent=blend (…)`
            // string the journal's `plan armed` line prints. Without this the
            // moved in-point and the shortened overlap are visible only as two
            // numbers nobody can explain.
            style.intent = matched.vocalEntry.flatMap { detail in
                intent.map { TransitionIntent($0.class, reasons: $0.reasons + [detail],
                                              budget: $0.budget) }
            } ?? intent
            // …and a score layers over *that*, as an alternative the segment
            // path may perform. Chosen at the end of this block, once the aim
            // is settled, because two of the four gestures depend on it. Off by
            // default, so it is nil on every shipped decision and the style is
            // field-for-field what it was.
            // Deliberately *not* a `PlanTrace` gate: the trace's stages are the
            // chain that decides whether a pair hands over at all, and a score
            // decides nothing — it is offered on top of a plan already made.
            // Where it went is reported by the compile (`Audition.describe`),
            // which is the only place that knows whether it was performed.
            //
            // Aiming is the one thing a score *does* move (P2, predev §2.3),
            // and it moves exactly one field: where the incoming deck is
            // entered, so that the drop / chorus / core start falls on the
            // seam instead of some number of phrase lines past it. It runs
            // only under a score, so with `scoreEnabled` down this whole block
            // is a nil check and the plan is what it was.
            //
            // Aiming runs under a score (P2) — and, since P3, under
            // `dropAlign` too, where the pair gets no score at all. The
            // difference between the two is one word: a scored seam wants the
            // target *on* the seam, because a cut is only motivated if the
            // thing it cuts to is the thing the listener came for; a blend
            // wants the target on the **end of the overlap**, so the outgoing
            // tail lies over the build and the hand-over completes on the drop
            // (predev §2.3). Same aiming machinery, same gates re-run, two
            // landings.
            //
            // **The order changed in P4, and only the order.** P1 chose the
            // score first and let its existence pick the landing; P4 has four
            // gestures to choose between and two of them — the tension cut and
            // the bed — cannot be chosen without knowing what the hand-over
            // aims at and where the incoming deck ends up entering. So the
            // *family* is settled first (which is what P1's `score()` really
            // decided: gates and intent class, neither of which needs a plan),
            // the aim runs on that, and the template is picked last, against
            // the aimed geometry. With `scoreEnabled` down the family is nil
            // and every line below is a nil check, so this reshuffle is
            // invisible to every shipped decision.
            var plan = matched.plan
            let family = scoreFamily(outgoing: outgoing, incoming: incoming,
                                     intent: intent, config: config)
            let landing: TransitionAim.Landing? = family == .cutCulture
                ? .seam
                : (intent?.class == .dropAlign ? .overlapEnd : nil)
            if let landing {
                let aimed = aim(plan: plan, outgoing: outgoing, incoming: incoming,
                                landing: landing, config: config)
                style.aim = aimed.aim
                style.aimDetail = aimed.detail
                if aimed.aim != nil, aimed.inPoint != plan.inPoint {
                    plan = plan.enteringIncoming(at: aimed.inPoint)
                }
                _ = note(&trace, .structure, "scoreAim", true, aimed.aim?.time, nil,
                         TransitionAim.report(aimed.aim,
                                              reason: aimed.aim == nil ? aimed.detail : nil)
                             + " — " + aimed.detail)
            }
            if let family {
                let selection = ScoreTemplate.select(
                    family: family,
                    material: ScoreTemplate.Material(
                        outgoing: outgoing, incoming: incoming, plan: plan, aim: style.aim,
                        hasLyrics: !context.outgoingLyricLineEnds.isEmpty,
                        stemsReady: stems == .ready,
                        hasStemTechnique: matched.stem != nil),
                    config: config)
                style.score = selection?.score
                _ = note(&trace, .structure, "scoreTemplate", selection != nil,
                         selection.map { Double($0.score.events.count) }, nil,
                         selection?.label
                             ?? "no template in the \(family.rawValue) ladder qualified")
            }
            return finish(PlannedTransition(plan: .beatMatched(plan), style: style,
                                            rideDB: s.rideDB))
        }
        var cap: TimeInterval
        switch tier {
        case .compatible: cap = config.maxOverlap
        case .neutral: cap = config.neutralOverlapCap
        case .clash: cap = config.clashOverlapCap
        }
        // Restraint's second half: the neutral cap, whatever the tier says.
        // A rock pair that clears every signal is exactly the pair this rule
        // exists for — the gates are about damage, and dissolving a rock track
        // does no damage the signals can see.
        if restrained { cap = Swift.min(cap, config.neutralOverlapCap) }
        let crossfade = crossfadePlan(outgoing: outgoing, incoming: incoming,
                                      candidates: candidates.points, inPoint: inChoice.point,
                                      tierCap: cap, tier: tier, stems: stems,
                                      intentVocalRequest: intentVocalRequest, config: config)
        // Same composition rule as above: the stem technique never replaces
        // the outro effect or the staged-EQ decision, it sits beneath them.
        // So a ducked vocal under a filter sweep is a swept exit whose vocal
        // is 9 dB down, not a different exit.
        var style = crossfadeStyle(tier: tier, outgoing: outgoing,
                                   plan: crossfade.plan, config: config)
        style.stemTechnique = crossfade.stem
        style.intent = intent
        // The ride only makes sense over an overlap — it *is* the seconds the
        // two decks share, held at a corrected level. A `.gapless` seam has no
        // such window (and `.plain(.gapless)`, the AutoMix-off / iOS path, must
        // stay bit-identical), so every early return above keeps ride 0.
        return finish(PlannedTransition(plan: crossfade.plan, style: style, rideDB: s.rideDB))
    }

    // MARK: - Transition score

    /// The score this pair is offered, or nil — which is everything today.
    ///
    /// **Naming an intent, not building one.** The planner is a pure function
    /// of two analyses: it can see that both grids are quantized and confident,
    /// which is the cultural precondition for cutting rather than blending, but
    /// it cannot see where bar 0 beat 0 lands in seconds. So it emits the score
    /// as a marker and `ScoreCompiler` places it — the same division of labour
    /// `.vocalExchange` has, one level up.
    ///
    /// P1 kept the selection rule deliberately thin: gates only, no material
    /// semantics. P3 adds the semantics as a **veto, never a licence** — the
    /// gates below are unchanged and still have to pass, and on top of them the
    /// intent layer must have said `cutCulture`. So turning the intent layer on
    /// can only ever *remove* scores, which is the direction a layer nobody has
    /// listened to yet is allowed to move things in.
    ///
    /// `restrained` and `standDown` never get a score (`standDown` never
    /// reaches here at all — it returned gapless at the front door), and
    /// neither does `blend`.
    ///
    /// **P4 gave `dropAlign` one gesture**, and it is worth being precise about
    /// why that is not a loosening of the rule above. `cutCulture` is still the
    /// only class that may *cut*. What `dropAlign` may now have is a score that
    /// does not cut at all: `bedIntro` writes one muted stem lane over the
    /// blend the class was already getting, leaves the fader law, the staged EQ
    /// and the aimed overlap end exactly where they were, and cannot make the
    /// hand-over more abrupt than it already was. The family a pair belongs to
    /// decides which ladder of gestures it is shown, and the two ladders do not
    /// overlap by a single event.
    static func scoreFamily(outgoing: TrackAnalysis, incoming: TrackAnalysis,
                            intent: TransitionIntent? = nil,
                            config: Config) -> ScoreTemplate.Family? {
        guard config.scoreEnabled else { return nil }
        // Both grids confident enough to address on the bar line, and long
        // enough to address at all: a gesture half a beat out is the one error
        // none of them survives.
        guard outgoing.bpmConfidence >= config.scoreMinBPMConfidence,
              incoming.bpmConfidence >= config.scoreMinBPMConfidence,
              outgoing.downbeats.count > TransitionScore.maxPreBars,
              incoming.downbeats.count > TransitionScore.maxPostBars
        else { return nil }
        guard config.intentEnabled else { return .cutCulture }
        switch intent?.class {
        case .cutCulture: return .cutCulture
        case .dropAlign: return .dropAlign
        default: return nil
        }
    }

    // MARK: - Aiming (P2, predev §2.3)

    /// What the aiming layer decided, including when it decided not to aim.
    struct AimOutcome {
        /// Nil when the incoming track offered nothing to aim at, or when a
        /// gate refused the geometry aiming asked for.
        var aim: TransitionAim?
        /// Where the incoming deck is entered. Unchanged from the plan's own
        /// `inPoint` whenever `aim` is nil — this is the degradation path, and
        /// it is not "equivalent to" today's placement, it *is* it.
        var inPoint: TimeInterval
        /// One sentence for the console, the panel and the seam history.
        var detail: String
    }

    /// Compose the incoming entry backwards from a target grid point.
    ///
    /// **The order is the whole idea** (predev §1.3): today the in point asks
    /// "where is it safe for the incoming song to start", and nobody asks
    /// "which bar of the incoming song should land on the hand-over". Here the
    /// second question is asked first — drop start, else chorus start, else the
    /// first core section's start — and the entry is whatever falls out of it.
    ///
    /// **Gates win, always.** The out point is not touched, so the candidate
    /// ordering, the lyric snap and the climax guard are structurally unable to
    /// notice this layer at all. The two gates that *do* depend on the entry —
    /// the incoming track having room for the overlap, and both sides' vocal
    /// and energy behaviour over it — are re-run here on the aimed entry, and a
    /// failure means no aim rather than an aim that overrode them. An aim is a
    /// preference among geometries the gates already pass.
    static func aim(plan p: BeatMatchedPlan, outgoing: TrackAnalysis,
                    incoming: TrackAnalysis,
                    landing: TransitionAim.Landing = .seam,
                    config: Config) -> AimOutcome {
        func unaimed(_ why: String) -> AimOutcome {
            AimOutcome(aim: nil, inPoint: p.inPoint, detail: why)
        }
        guard config.scoreAimEnabled else { return unaimed("aiming is off") }
        guard let sections = usableSections(incoming, config: config) else {
            return unaimed(incoming.sections.isEmpty
                           ? "no structure"
                           : String(format: "structure confidence %.2f below the %.2f gate",
                                    incoming.structureConfidence,
                                    config.structureConfidenceGate))
        }

        // The target, by priority. `first` is by time and not by array position
        // for the same reason `finalClimax` is: sections arrive in time order
        // today, and an aim derived from the wrong one would silently point at
        // the second drop if that ever stopped being true.
        func firstStart(_ kind: TrackAnalysis.Section.Kind) -> TimeInterval? {
            sections.filter { $0.kind == kind }.map(\.start).filter { $0.isFinite && $0 > 0 }
                .min()
        }
        let target: (TransitionAim.Target, TimeInterval)
        if let drop = firstStart(.drop) {
            target = (.drop, drop)
        } else if let chorus = firstStart(.chorus) {
            target = (.chorus, chorus)
        } else if let core = sections.first(where: { $0.kind != .intro && $0.kind != .outro }),
                  core.start.isFinite, core.start > 0 {
            target = (.core, core.start)
        } else {
            return unaimed("every section is an intro or an outro")
        }
        guard target.1 - incoming.introEnd <= config.scoreAimMaxLeadSeconds else {
            return unaimed(String(format: "the first %@ sits at %.2f s, more than %.0f s past "
                                  + "the intro end — too much of the song to skip",
                                  target.0.rawValue, target.1, config.scoreAimMaxLeadSeconds))
        }

        // The aim has to be a bar line the compiler can actually address. The
        // segmenter snaps section starts to downbeats already, so this normally
        // finds the target itself; a target further than half a bar from any
        // downbeat is one the two layers disagree about, and a cut is not the
        // gesture to resolve a disagreement with.
        let grid = incoming.downbeats
        guard let index = ScoreCompiler.nearestIndex(grid, to: target.1) else {
            return unaimed("the incoming track has no bar grid")
        }
        let bar = ScoreCompiler.barSeconds(grid, around: index, bpm: incoming.bpm)
        guard abs(grid[index] - target.1) <= bar * 0.5 else {
            return unaimed(String(format: "the %@ at %.2f s is %.2f s from the nearest bar line",
                                  target.0.rawValue, target.1, abs(grid[index] - target.1)))
        }
        let aimTime = grid[index]

        // How much of the incoming track runs before the seam: the swap point,
        // read on the incoming deck's own clock — which under a post-swap glide
        // is the integral of a moving rate, not a product (the c2ec6e6 lesson)
        // — rounded to whole bars so the entry stays a downbeat. A downbeat
        // entry is not cosmetic: the fall-back when no segment arms is a
        // *complete blend*, and a blend entered half a bar out is beat-matched
        // to nothing.
        let geometry = TransitionAutomation.Geometry(plan: .beatMatched(p))
        let glide = TransitionAutomation.incomingGlide(for: .beatMatched(p), geometry: geometry)
        let clock = StemTechniqueLayer.SourceClock(
            rate: Double(max(0.5, min(2, p.incomingRate))), glide: glide)
        // Which instant of the *hand-over* the target is being made to land on:
        // the swap point for a cut (the seam), the end of the overlap for a
        // blend. Read on the incoming deck's own clock either way.
        let landingOffset = landing == .seam ? geometry.swapOffset : geometry.overlapDuration
        let advance = clock.sourceAdvance(to: landingOffset)
        let leadBars = max(1, Int((advance / max(bar, 0.05)).rounded()))
        guard index - leadBars >= 0 else {
            return unaimed(String(format: "the %@ at %.2f s is fewer than %d bars into the track",
                                  target.0.rawValue, aimTime, leadBars))
        }
        let entry = grid[index - leadBars]

        // --- The gates that depend on the entry, re-run. Whatever they say
        // about the aimed geometry is final; there is no aim strong enough to
        // buy its way past one.
        let overlap = p.overlapDuration
        guard entry >= 0, entry + overlap <= incoming.duration else {
            return unaimed(String(format: "entering at %.2f s leaves no room for the %.2f s "
                                  + "overlap on a %.0f s track", entry, overlap,
                                  incoming.duration))
        }
        guard isStable(incoming, incoming.rmsEnvelope, from: entry, length: overlap,
                       cv: config.stableCV, config: config) else {
            return unaimed(String(format: "the incoming window from %.2f s is not steady enough "
                                  + "to enter on", entry))
        }
        guard !vocalsClash(outgoing: outgoing, outPoint: p.outPoint,
                           incoming: incoming, inPoint: entry, overlap: overlap,
                           config: config) else {
            return unaimed(String(format: "entering at %.2f s puts two vocals over each other",
                                  entry))
        }

        return AimOutcome(
            aim: TransitionAim(target: target.0, time: aimTime, leadBars: leadBars,
                               landing: landing),
            inPoint: entry,
            detail: String(format: "%@ at %.2f s lands on %@; the incoming deck is "
                           + "entered %d bars earlier at %.2f s (was %.2f s)",
                           target.0.rawValue, aimTime, landing.label,
                           leadBars, entry, p.inPoint))
    }

    // MARK: - Decision ledger

    /// Record one gate and hand back the very Bool the caller was testing, so a
    /// `guard note(&trace, …, someCondition, …) else { … }` reads and behaves
    /// exactly like the `guard someCondition else { … }` it replaced.
    ///
    /// Everything except `passed` arrives as an autoclosure: while `trace` is
    /// nil — the product path — not one number is formatted and not one string
    /// is built. See `PlanTrace`.
    @inline(__always)
    private static func note(
        _ trace: inout PlanTrace?, _ stage: PlanGate.Stage, _ id: String, _ passed: Bool,
        _ value: @autoclosure () -> Double?, _ threshold: @autoclosure () -> Double?,
        _ detail: @autoclosure () -> String
    ) -> Bool {
        if trace != nil {
            trace!.add(PlanGate(id: id, stage: stage, passed: passed,
                                value: value(), threshold: threshold(), detail: detail()))
        }
        return passed
    }

    // MARK: - Stem layer
    //
    // Two rules, checked in this order, and only ever when the caller says a
    // separator is available. Both start from the same observation: a stem
    // technique acts on the *outgoing vocal*, so it is worth nothing in a
    // window that has none — and the corpus says the planner's own out points
    // are exactly such windows. Fourteen of sixteen tracks have an
    // `outroFadeStart`, which pins the crossfade out point to the fade itself:
    // the track is on its way to silence there, and a separation of that
    // window comes back near-empty (measured vocal-over-mixture energy ≈ 0.005
    // against ~0.33 mid-song). So both rules re-aim the out point at a
    // vocal-carrying phrase boundary *before* the outro, and decline to name a
    // technique when no such boundary exists.
    //
    //   1. vocalExchange — the outgoing window is vocal-active and so is the
    //      incoming opening. Without stems this is the one blend a DJ never
    //      allows, and the planner punishes it: the crossfade is cut to
    //      `vocalClashFadeCap`, and the 8/16-bar beat-matched upgrades are
    //      refused. With stems the punishment becomes a technique. S1 answered
    //      it with a flat duck (`stemDuckDepthDB` for the whole window), which
    //      its blind test liked best of the three gestures — but a duck only
    //      *survives* two vocals, it does not resolve them: over a 12–16 s
    //      overlap it still sounds like two players running at once. So the
    //      planner now asks for the orchestrated hand-off instead, and the
    //      duck is what that degrades to when the outgoing track has no
    //      lyrics to hand over on (see `Audition.VocalExchange`).
    //   2. acapellaOver — the outgoing window is vocal-active and the incoming
    //      opening is instrumental-leaning, at `tier == .compatible` only.
    //      S1: this is the structure the technique was built for, and the one
    //      technique whose separation residue is genuinely exposed, so it stays
    //      on the tier that already licenses a full blend.
    //
    // `instrumentalOut` is deliberately never chosen automatically: it never
    // won a pair in S1's blind test. It remains reachable by hand (`--stem
    // instrumental`, or the console's picker) so it can keep being auditioned.
    //
    // The two rules cannot both apply: `stemAcapellaIncomingVocalMax` (0.90)
    // sits below `vocalClashRatio` (1.10), so an incoming opening is either
    // hot enough to duck against or quiet enough to float over, never both.

    /// What the stem search settled on: where to hand over, and with which
    /// technique.
    private struct StemChoice {
        let outPoint: TimeInterval
        let technique: StemTechnique
    }

    /// Pick a vocal-carrying out point out of `candidates` (tail-window phrase
    /// boundaries that fit `overlap`, best-scored first) and name the technique
    /// its structure implies; nil when nothing here is worth a separation pass.
    /// - Parameter intentVocalRequest: non-nil when the intent layer found both
    ///   edges sung on a `blend` and a separator is ready — the value is the
    ///   layer's own "sung" line (`intentInstrumentalEdgeRatio`), which stands
    ///   in for the two hot-spot thresholds on this path only. Nil (every
    ///   `intentEnabled == false` call, and every other class) leaves the rules
    ///   exactly as they were.
    private static func stemChoice(
        outgoing: TrackAnalysis, incoming: TrackAnalysis,
        candidates: [TimeInterval], inPoint: TimeInterval, overlap: TimeInterval,
        tier: CompatibilityTier, intentVocalRequest: Double? = nil, config: Config
    ) -> StemChoice? {
        guard overlap >= config.stemMinOverlap else { return nil }

        // --- The intent request, checked first and only ever *additive*: if it
        // does not produce an exchange it falls through to the rules below,
        // unchanged, rather than handing the relaxed line to `acapellaOver`.
        // The request is for one technique, so it may only ever grant that one.
        //
        // Both lines move together, and both have to. 1.15 and 1.10 are S1
        // hot-spot numbers — "is this window noticeably more sung than the song
        // is on average" — and the question this path asks is the simpler one
        // the exchange was actually built around: is anyone singing on either
        // side of the seam. The field's confirmed case measured 1.06/1.04 and
        // cleared neither number, which is precisely why it arrived as
        // `stem=none` under a reason sentence promising vocal management.
        //
        // Measured on the real seam windows, not inherited from the intent
        // layer's edge windows: the finding licenses the request, the geometry
        // still has to be there where the hand-over will actually happen.
        if let line = intentVocalRequest,
           let outPoint = candidates.first(where: {
               (vocalScore(outgoing, from: $0, length: overlap) ?? 0) >= line
           }),
           let incomingScore = vocalScore(incoming, from: inPoint, length: overlap),
           incomingScore > line {
            return StemChoice(outPoint: outPoint, technique: .vocalExchange)
        }

        // Best-scored boundary that actually carries the outgoing vocal — the
        // exact opposite of the whole-mix rule below, which prefers a window
        // where the vocals have already finished.
        guard let outPoint = candidates.first(where: {
            (vocalScore(outgoing, from: $0, length: overlap) ?? 0) >= config.stemVocalActiveRatio
        }) else { return nil }

        // A missing incoming contour means an instrumental (or a vocal too
        // weak to measure): not something to duck against, and fine to float
        // over — same reading `vocalsClash` gives it.
        let incomingScore = vocalScore(incoming, from: inPoint, length: overlap)
        if let incomingScore, incomingScore > config.vocalClashRatio {
            // Both sides are singing across a long overlap — the case a flat
            // duck only *survives* and an orchestrated hand-off actually
            // solves. The planner names the template; `Audition.decide`
            // compiles it against the outgoing track's lyrics, and degrades to
            // the duck (visibly) when there is no phrase to hand over on.
            return StemChoice(outPoint: outPoint, technique: .vocalExchange)
        }
        if tier == .compatible,
           (incomingScore ?? 0) <= config.stemAcapellaIncomingVocalMax {
            return StemChoice(outPoint: outPoint, technique: .acapellaOver)
        }
        return nil
    }

    /// Out-point candidates in the outgoing tail that can hold `overlap` and sit
    /// *before* any outro fade — the stem search's candidate list.
    ///
    /// This is the beat-matched out-point window rather than the crossfade's
    /// `crossfadeOutPointShare` one, on purpose: the crossfade window happily
    /// includes the outro fade, and handing over inside a fade is precisely
    /// what leaves a stem technique with nothing to work on.
    private static func stemCandidates(
        _ a: TrackAnalysis, candidates: [TimeInterval], overlap: TimeInterval, config: Config
    ) -> [TimeInterval] {
        let outLimit = a.outroFadeStart ?? a.duration
        let windowStart = max(a.duration * config.tailWindowShare,
                              outLimit - config.tailWindowSeconds)
        return candidates.filter {
            $0 >= windowStart && $0 <= outLimit && $0 + overlap <= a.duration
        }
    }

    /// Which technique sends the outgoing track off, per tier: clashing
    /// pairs exit on an (ideally beat-synced) echo instead of an apologetic
    /// fade; neutral pairs with a hot tail get hollowed out by a filter
    /// sweep; compatible long fades earn the staged EQ hand-over.
    private static func crossfadeStyle(
        tier: CompatibilityTier, outgoing: TrackAnalysis, plan: TransitionPlan,
        config: Config
    ) -> TransitionStyle {
        guard case .crossfade(let duration, _, _) = plan else { return .plain }
        switch tier {
        case .clash:
            guard outgoing.bpmConfidence >= config.bpmConfidenceThreshold, outgoing.bpm > 0
            else { return .plain }
            // Dotted eighth of the outgoing tempo — the classic echo-out tail.
            let delay = min(max(config.echoBeatFraction * 60 / outgoing.bpm,
                                config.echoDelayMin), config.echoDelayMax)
            return TransitionStyle(outroEffect: .echoOut, stagedEQ: false,
                                   echoDelayTime: delay)
        case .neutral:
            // A track already fading itself out doesn't need to be swept out.
            return outgoing.outroFadeStart == nil
                ? TransitionStyle(outroEffect: .filterSweep, stagedEQ: false)
                : .plain
        case .compatible:
            return duration >= config.stagedEQMinOverlap
                ? TransitionStyle(outroEffect: .fade, stagedEQ: true)
                : .plain
        }
    }

    // MARK: - Key gate

    /// Circle-of-fifths distance between two confident keys; nil when either
    /// key is missing or below the confidence gate. Exposed so `Audition` can
    /// report the number the decision actually turned on.
    static func keyDistance(
        _ a: TrackAnalysis, _ b: TrackAnalysis, config: Config = .standard
    ) -> Int? {
        guard let ka = a.keyPitchClass, let kb = b.keyPitchClass,
              a.keyConfidence >= config.keyConfidenceThreshold,
              b.keyConfidence >= config.keyConfidenceThreshold
        else { return nil }
        let majA = a.keyIsMinor ? (ka + 3) % 12 : ka
        let majB = b.keyIsMinor ? (kb + 3) % 12 : kb
        // Position on the circle of fifths, then circular distance.
        let ia = (majA * 7) % 12
        let ib = (majB * 7) % 12
        let d = abs(ia - ib)
        return min(d, 12 - d)
    }

    // MARK: - Vocal gate

    /// Mean vocal activity over [from, from+length), relative to the track's
    /// own mean; nil when the track has no usable vocal contour (analysis
    /// missing, or an instrumental with a near-zero baseline).
    static func vocalScore(
        _ a: TrackAnalysis, from: TimeInterval, length: TimeInterval
    ) -> Double? {
        let env = a.vocalActivity
        guard !env.isEmpty else { return nil }
        let trackMean = Double(env.reduce(0) { $0 + Double($1) }) / Double(env.count)
        guard trackMean > 0.05 else { return nil }
        let start = max(0, min(env.count - 1, Int(from)))
        let end = max(start + 1, min(env.count, Int((from + length).rounded(.up))))
        let slice = env[start..<end]
        let mean = Double(slice.reduce(0) { $0 + Double($1) }) / Double(slice.count)
        return mean / trackMean
    }

    private static func vocalsClash(
        outgoing: TrackAnalysis, outPoint: TimeInterval,
        incoming: TrackAnalysis, inPoint: TimeInterval,
        overlap: TimeInterval, config: Config
    ) -> Bool {
        guard let outScore = vocalScore(outgoing, from: outPoint, length: overlap),
              let inScore = vocalScore(incoming, from: inPoint, length: overlap)
        else { return false }
        return outScore > config.vocalClashRatio && inScore > config.vocalClashRatio
    }

    /// The three raw numbers the tier gate turns on, kept together so
    /// `Audition` can report them (and how close each sits to its threshold)
    /// rather than re-deriving them and drifting from the real decision.
    struct Signals {
        /// |dB| level gap left at the hand-over **as it will be heard**, after
        /// *both* gain stages: the whole-track playback trims and the
        /// transition gain ride. This is the number the tier gate judges — see
        /// the three-stage story on `loudnessGapDB`.
        let loudnessGapDB: Double
        /// Stage two: the gap after the per-track trims but before the ride.
        /// What the gate measured between the trim landing and the ride
        /// landing, kept so the console can narrate the second of three moves.
        let trimmedLoudnessGapDB: Double
        /// Stage one: the gap before any compensation at all — what the gate
        /// measured originally, kept so the console can show the whole move
        /// rather than just the result.
        let rawLoudnessGapDB: Double
        /// The playback trim each deck will run at (dB, 0 when compensation is
        /// off or the loudness is unknown).
        let outgoingTrimDB: Double
        let incomingTrimDB: Double
        /// **Signed** transition gain ride for the *incoming* deck, in dB:
        /// held for the whole overlap and then released back to unity. Negative
        /// = the incoming track enters hotter than the outgoing tail and is
        /// held down; positive = it enters weak and is lifted. 0 when the ride
        /// is off, when there is no overlap to ride over, or when there was no
        /// gap left to close. See `rideDB`.
        let rideDB: Double
        let timbreDistance: Double
        /// Folded (double/half-time) BPM difference as a ratio of the outgoing
        /// tempo; nil when either tempo is below the confidence gate.
        let tempoRatio: Double?
    }

    static func signals(
        outgoing: TrackAnalysis, incoming: TrackAnalysis, config: Config = .standard
    ) -> Signals {
        var tempoRatio: Double?
        if outgoing.bpmConfidence >= config.bpmConfidenceThreshold,
           incoming.bpmConfidence >= config.bpmConfidenceThreshold,
           outgoing.bpm > 0, incoming.bpm > 0 {
            tempoRatio = [0.5, 1.0, 2.0]
                .map { abs(incoming.bpm * $0 - outgoing.bpm) / outgoing.bpm }
                .min()!
        }
        let raw = rawLoudnessGapDB(outgoing: outgoing, incoming: incoming, config: config)
        let outTrim = LoudnessCompensation.trimDB(
            for: outgoing, enabled: config.loudnessCompensation,
            config: config.loudnessConfig)
        let inTrim = LoudnessCompensation.trimDB(
            for: incoming, enabled: config.loudnessCompensation,
            config: config.loudnessConfig)
        // Stage two: what the two constant trims left behind, still signed
        // (positive = the outgoing tail is the louder side).
        let trimmed = raw + outTrim - inTrim
        let ride = rideDB(forTrimmedGapDB: trimmed, incoming: incoming,
                          incomingTrimDB: inTrim, config: config)
        return Signals(
            loudnessGapDB: abs(trimmed - ride),
            trimmedLoudnessGapDB: abs(trimmed),
            rawLoudnessGapDB: abs(raw),
            outgoingTrimDB: outTrim,
            incomingTrimDB: inTrim,
            rideDB: ride,
            timbreDistance: timbreDistance(outgoing.melProfile, incoming.melProfile),
            tempoRatio: tempoRatio)
    }

    /// **Transition gain ride**: the temporary gain offset the *incoming* deck
    /// is held at for the length of the hand-over, and then released from.
    ///
    /// ### Why a ride at all
    ///
    /// `LoudnessCompensation` aligns two *whole* masters. It cannot align two
    /// *seconds* — a track that ends on a bare piano outro and one that opens
    /// on a full band are 8 dB apart at the seam however well their integrated
    /// loudness matches, and the corpus says this local difference, not the
    /// mastering difference, is what the tier gate keeps demoting pairs for.
    /// A human DJ's answer is not a different fade curve: it is the incoming
    /// deck's trim knob, pulled down before the blend and pushed back up once
    /// the new track owns the room. This is that gesture, automated.
    ///
    /// ### Why only the incoming deck
    ///
    /// The ride is deliberately **one-sided**. Splitting it — half down on the
    /// incoming deck, half up on the outgoing one — is tempting and wrong:
    ///
    ///   - The outgoing deck is mid-song and *already audible at full level*
    ///     when the overlap begins. Any ride on it is a step change in a
    ///     signal the listener is currently hearing, which is precisely the
    ///     artefact this feature exists to remove; making it inaudible would
    ///     need its own pre-ramp, over seconds the plan does not automate.
    ///   - The outgoing deck is never given its level back. It ends. So a ride
    ///     on it permanently recolours a song's last seconds — an arrangement
    ///     decision, not a compensation.
    ///   - The incoming deck enters from a fader at 0, so *any* offset on it
    ///     costs nothing to introduce, and it is released while it is the only
    ///     thing playing, where a slow glide is inaudible.
    ///
    /// One-sided also closes exactly as much of the gap as two-sided would:
    /// only the difference between the decks is audible.
    ///
    /// ### Sign and bounds
    ///
    /// `trimmedGapDB` is signed the way `rawLoudnessGapDB` is (positive = the
    /// outgoing tail is louder), so adding it to the incoming deck is what
    /// closes the gap. The two directions are clipped **asymmetrically**,
    /// because they are not the same operation:
    ///
    ///   - A **cut** (`-rideMaxCutDB`, 4 dB) is applied to a deck whose fader
    ///     is still at 0 when the offset goes on, so there is nothing audible
    ///     for it to step on; it costs no headroom and introduces no artefact.
    ///     What it does cost is *time*: it is let go of at a fixed dB/s while
    ///     that deck is the only thing playing, so the cap is also how long the
    ///     new track sits under its own level. That, and the editorial limit —
    ///     far enough down and the ride stops being a level match and starts
    ///     being a mix decision — is where 4 dB sits.
    ///   - A **boost** (`+rideMaxDB`, 4 dB) is the direction that costs
    ///     something. It pushes a real signal towards its own peak ceiling, so
    ///     it is additionally held to whatever headroom the incoming track's
    ///     peak leaves after its trim — the same clip guard
    ///     `LoudnessCompensation` runs — and the old reasoning stands
    ///     unchanged: past ~4 dB a lift is an arrangement choice.
    ///
    /// Whatever the clips refuse is exactly what the tier gate still sees, so
    /// widening the cut side does not hide anything from the gate; it moves
    /// real dB out of the residual and lets the gate judge what is left.
    ///
    /// Zero — and so bit-identical to the pre-ride player — when compensation
    /// is off (this is the same gain-compensation family the user's one switch
    /// governs), when `rideMaxDB` is 0, or when the gap is already closed.
    /// `rideMaxDB` at 0 disables the ride in **both** directions: it is the
    /// feature's off switch, and a config that could still cut would be a
    /// surprising reading of "no ride".
    static func rideDB(
        forTrimmedGapDB trimmedGapDB: Double, incoming: TrackAnalysis?,
        incomingTrimDB: Double, config: Config
    ) -> Double {
        guard config.loudnessCompensation, config.rideMaxDB > 0 else { return 0 }
        guard trimmedGapDB.isFinite else { return 0 }
        if trimmedGapDB < 0 {
            // Hold the incoming deck down; a cut is always safe, and gets the
            // deeper of the two caps.
            return max(trimmedGapDB, -config.rideMaxCutDB)
        }
        let headroom = LoudnessCompensation.boostHeadroomDB(
            for: incoming, afterTrimDB: incomingTrimDB, config: config.loudnessConfig)
        return min(trimmedGapDB, config.rideMaxDB, headroom)
    }

    static func compatibility(
        outgoing: TrackAnalysis, incoming: TrackAnalysis, config: Config = .standard
    ) -> CompatibilityTier {
        tier(of: signals(outgoing: outgoing, incoming: incoming, config: config),
             config: config)
    }

    static func tier(of s: Signals, config: Config = .standard) -> CompatibilityTier {
        let tempoClash = (s.tempoRatio ?? 0) > config.clashTempoRatio
        if s.loudnessGapDB > config.clashLoudnessDB
            || s.timbreDistance > config.clashTimbreDistance
            || tempoClash {
            return .clash
        }
        if s.loudnessGapDB > config.neutralLoudnessDB
            || s.timbreDistance > config.neutralTimbreDistance {
            return .neutral
        }
        return .compatible
    }

    /// **Signed** gap between the outgoing tail's mean RMS and the incoming
    /// opening's mean RMS (~15 s windows), in dB, before any compensation.
    /// Positive = the outgoing tail is the louder side.
    ///
    /// This is a *local* level comparison (the seconds that actually meet),
    /// which is the right thing to gate a hand-over on — while
    /// `referenceLoudness` is a *whole-track* mastering figure, which is the
    /// right thing to derive a constant playback trim from. `signals` combines
    /// them in **three stages**, and the tier gate only ever judges the last:
    ///
    ///   1. `rawLoudnessGapDB` — this number, the bare local difference.
    ///   2. `trimmedLoudnessGapDB` — after the two decks' whole-track trims.
    ///      Two songs whose masters differ by 6 dB but whose hand-over windows
    ///      are equally loud have always read 0 dB at stage 1 and still do; two
    ///      songs whose 6 dB gap the trims cancel now also read ~0 here,
    ///      instead of being demoted for a difference the player removes.
    ///   3. `loudnessGapDB` — after the transition gain ride (`rideDB`) holds
    ///      the incoming deck off its own level for the length of the overlap.
    ///      This is what the listener hears at the seam, so this is what the
    ///      gate measures: only the part *neither* gain stage could absorb (a
    ///      trim clipped by the +3 dB boost cap or the peak guard, a ride
    ///      clipped by `rideMaxDB` or by the same peak guard, or a track with
    ///      no loudness reading at all).
    private static func rawLoudnessGapDB(
        outgoing: TrackAnalysis, incoming: TrackAnalysis, config: Config
    ) -> Double {
        func mean(_ env: [Float], from: Int, length: Int) -> Double {
            let start = max(0, min(env.count - 1, from))
            let end = max(start + 1, min(env.count, from + length))
            let slice = env[start..<end]
            return Double(slice.reduce(0, +)) / Double(slice.count)
        }
        guard !outgoing.rmsEnvelope.isEmpty, !incoming.rmsEnvelope.isEmpty else { return 0 }
        // Anchor the outgoing window *before* any outro fade: a track that
        // fades itself out reads as near-silence over its literal last
        // seconds, which is the fade — not a level mismatch (audition-loop
        // finding: this misread 12/15 real pairs as 15–31 dB clashes).
        let tailEnd = min(outgoing.rmsEnvelope.count,
                          Int(outgoing.outroFadeStart ?? outgoing.duration))
        let window = max(1, config.loudnessWindow)
        let tail = mean(outgoing.rmsEnvelope, from: tailEnd - window, length: window)
        // Deliberately still `introEnd` and not the structural in point: this is
        // a *gate* input, and the structure layer only ever changes candidates.
        // Re-anchoring it would move the tier line under every pair whose
        // segmentation happens to be good, which is exactly the coupling the
        // "candidates change, gates do not" rule exists to forbid.
        let opening = mean(incoming.rmsEnvelope, from: Int(incoming.introEnd), length: window)
        guard tail > 1e-6, opening > 1e-6 else { return 0 }
        return 20 * log10(tail / opening)
    }

    /// Cosine distance between the (already normalized) mel fingerprints;
    /// 0 when either is missing — absence of evidence is not a clash.
    private static func timbreDistance(_ a: [Float], _ b: [Float]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        let dot = zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        return Double(max(0, 1 - dot))
    }

    // MARK: - Structure layer
    //
    // Everything below produces *candidates*. Not one line of it decides
    // anything: the tier gate, the five signals, the bar-upgrade search and the
    // stem rules run afterwards, unchanged, over whatever this hands them. That
    // is the whole safety argument for the layer — a mislabelled chorus can move
    // a hand-over, it can never authorize one that the gates refuse.
    //
    // Two sources feed it, and both are optional:
    //
    //   * `TrackAnalysis.sections` (v7, `StructureSegmenter`) — empty for every
    //     older sidecar and for everything the segmenter was unsure about.
    //   * the outgoing track's lyric line ends, carried in on `PlanContext`.
    //
    // With neither, `outPointCandidates` hands back `phraseBoundaries` — the
    // same array, in the same order — and `inPointChoice` hands back
    // `introEnd`, so the fallback path is not "equivalent to" the old
    // behaviour, it *is* the old behaviour.

    /// The out-point candidate list, best first, plus what the console needs to
    /// narrate where it came from.
    struct OutPointCandidates {
        /// Ordered candidates. Callers filter these by their own window rules
        /// exactly as they used to filter `phraseBoundaries`.
        var points: [TimeInterval] = []
        /// How many of `points` came from sections rather than the RMS-scored
        /// fallback list.
        var structuralCount = 0
        /// Where a candidate was pulled back to a lyric line end: snapped time →
        /// the time it came from.
        var snaps: [TimeInterval: TimeInterval] = [:]
        /// Start of the final chorus, when there is one — the climax the guard
        /// protects.
        var climaxStart: TimeInterval?
        /// The forbidden window, and how many candidates fell inside it.
        var guardWindow: (start: TimeInterval, end: TimeInterval)?
        var guardRejected = 0
        /// **The climax extension**: the second forbidden window, covering a
        /// unique, vocally dense passage that follows the final chorus
        /// immediately — the song still finishing what it came to say. Open at
        /// the low end, so the final chorus's own end (the best candidate there
        /// is) stays legal and only the passage after it is protected.
        var climaxExtensionWindow: (start: TimeInterval, end: TimeInterval)?
        /// One sentence about why the extension is what it is, for the trace.
        var climaxExtensionDetail: String?
        /// How many candidates were moved up because they sit on a vocal
        /// cliff, and how many were considered.
        var vocalCliffPromoted = 0
        /// Every candidate was inside the guard window, so the guard was
        /// dropped: a transition still has to happen somewhere.
        var guardFellBack = false

        /// Where `point` sat before its lyric snap, if it was snapped.
        func snapOrigin(of point: TimeInterval) -> TimeInterval? {
            snaps.first { abs($0.key - point) < 1e-6 }?.value
        }
    }

    /// A chorus, or the electronic music equivalent. Both are "the part the
    /// listener came for", which is what the candidate ordering and the climax
    /// guard both turn on — so an electronic track whose climax is labelled
    /// `drop` is protected exactly as a pop chorus is, and the guard has no
    /// genre-shaped blind spot. `drop` gets no *other* special treatment here:
    /// aligning the overlap's end to a drop is P4's business.
    private static func isClimax(_ kind: TrackAnalysis.Section.Kind) -> Bool {
        kind == .chorus || kind == .drop
    }

    /// The climax the guard protects: whichever chorus-or-drop **starts last**.
    /// Deliberately by `start` rather than by array position — sections arrive
    /// in time order today, and a guard window derived from the wrong section
    /// would silently protect the wrong eight bars if that ever stopped being
    /// true.
    private static func finalClimax(
        _ sections: [TrackAnalysis.Section]
    ) -> TrackAnalysis.Section? {
        sections.filter { isClimax($0.kind) }.max { $0.start < $1.start }
    }

    /// `a`'s sections, or nil when they are absent or below the planner's own
    /// confidence re-gate (`structureConfidenceGate`).
    private static func usableSections(
        _ a: TrackAnalysis, config: Config
    ) -> [TrackAnalysis.Section]? {
        guard !a.sections.isEmpty,
              a.structureConfidence >= config.structureConfidenceGate
        else { return nil }
        return a.sections
    }

    /// One bar at the track's own tempo, or a flat 4 s when the tempo is not
    /// trustworthy enough to count bars with (≈ one bar at 120 BPM).
    private static func barLength(_ a: TrackAnalysis, config: Config) -> TimeInterval {
        guard a.bpmConfidence >= config.bpmConfidenceThreshold, a.bpm > 0 else { return 4 }
        return 4 * 60 / a.bpm
    }

    /// Out-point candidates for the outgoing track, in preference order:
    ///
    ///   1. the **end of the final chorus** — the moment the song has said
    ///      everything it came to say, and the one cut nobody argues with;
    ///   2. any other chorus end, latest first;
    ///   3. any other section boundary, latest first — later is less of the song
    ///      thrown away, and the tail window has already excluded "too early";
    ///   4. `phraseBoundaries`, untouched and in their own scored order, as the
    ///      tail of the list. They are not deleted, only outranked: on a track
    ///      with three sections they are still what a 16-bar overlap ends up
    ///      landing on.
    ///
    /// Then two adjustments, in this order: candidates within a beat of one
    /// already in the list are dropped (the final chorus's end *is* the outro's
    /// start *is*, often, a phrase boundary — three names for one moment), and
    /// each survivor is pulled back to a lyric line end when one sits within
    /// `lyricSnapMaxSeconds` behind it. Snapping is backward-only on purpose:
    /// forward would cut into a line the singer has already started.
    ///
    /// Finally the climax guard removes anything inside
    /// `[finalChorusStart − climaxGuardBarsBefore, + climaxGuardBarsAfter)`,
    /// unless that would leave nothing at all.
    static func outPointCandidates(
        _ a: TrackAnalysis, context: PlanContext, config: Config
    ) -> OutPointCandidates {
        var result = OutPointCandidates()
        let sections = config.useStructureOutPoints ? usableSections(a, config: config) : nil
        let lineEnds = config.lyricSnapMaxSeconds > 0 ? context.outgoingLyricLineEnds : []
        let tolerance = a.bpmConfidence >= config.bpmConfidenceThreshold && a.bpm > 0
            ? 60 / a.bpm : 1.0
        var candidates: [(time: TimeInterval, structural: Bool)] = []
        // Nothing to add and nothing to move: hand back the exact array the
        // three searches have always filtered, in its exact order.
        //
        // The vocal-cliff pass still runs over it — that is the point of the
        // pass. It is not a structure feature: it reads `vocalActivity`, which
        // every v5 sidecar carries, so a track with no sections and no lyrics
        // is exactly the track that most needs somebody to notice where the
        // singing stops. Nothing is added or removed either way.
        guard sections != nil || !lineEnds.isEmpty else {
            result.points = preferringVocalCliffs(
                a.phraseBoundaries.map { (time: $0, structural: false) },
                of: a, into: &result, config: config).map(\.time)
            return result
        }
        func push(_ t: TimeInterval, structural: Bool) {
            guard t.isFinite, t > 0 else { return }
            guard !candidates.contains(where: { abs($0.time - t) <= tolerance }) else { return }
            candidates.append((t, structural))
        }

        if let sections {
            let climaxes = sections.filter { isClimax($0.kind) }
                .sorted { $0.start < $1.start }
            if let final = finalClimax(sections) {
                result.climaxStart = final.start
                push(final.end, structural: true)
            }
            for section in climaxes.dropLast().reversed() { push(section.end, structural: true) }
            // Every boundary the segmentation drew, latest first. Starts plus
            // the last section's end covers them all exactly once — sections are
            // contiguous, so every other end is the next one's start.
            var boundaries = sections.map(\.start)
            if let last = sections.last { boundaries.append(last.end) }
            for t in boundaries.sorted(by: >) { push(t, structural: true) }
        }
        for t in a.phraseBoundaries { push(t, structural: false) }

        if !lineEnds.isEmpty {
            var snapped: [(time: TimeInterval, structural: Bool)] = []
            for candidate in candidates {
                guard let end = lastLineEnd(lineEnds, atOrBefore: candidate.time),
                      candidate.time - end > 1e-3,
                      candidate.time - end <= config.lyricSnapMaxSeconds
                else {
                    snapped.append(candidate)
                    continue
                }
                // Two candidates can collapse onto the same line end; the
                // better-ranked one is already there.
                guard !snapped.contains(where: { abs($0.time - end) <= tolerance }) else { continue }
                result.snaps[end] = candidate.time
                snapped.append((end, candidate.structural))
            }
            candidates = snapped
        }

        // --- The climax extension. Computed before the guard because the two
        // are filtered together: a hand-over still has to happen, so if the two
        // windows between them leave nothing, both stand down rather than one.
        if config.climaxExtendPostChorus, let sections, let final = finalClimax(sections) {
            let extension_ = climaxExtension(sections, after: final, config: config)
            if let extension_ {
                result.climaxExtensionWindow = (start: final.end, end: extension_.end)
                result.climaxExtensionDetail = extension_.detail
            }
        }

        if let climaxStart = result.climaxStart,
           config.climaxGuardBarsBefore > 0 || config.climaxGuardBarsAfter > 0
               || result.climaxExtensionWindow != nil {
            let bar = barLength(a, config: config)
            let window = (start: climaxStart - Double(config.climaxGuardBarsBefore) * bar,
                          end: climaxStart + Double(config.climaxGuardBarsAfter) * bar)
            result.guardWindow = window
            let tolerance2 = tolerance
            let extended = result.climaxExtensionWindow
            let kept = candidates.filter { candidate in
                let t = candidate.time
                if t >= window.start && t < window.end { return false }
                // Open at the low end: `final.end` itself is the one cut nobody
                // argues with, and the extension exists to protect what comes
                // *after* it, not to take it away.
                if let extended, t > extended.start + tolerance2, t < extended.end - tolerance2 {
                    return false
                }
                return true
            }
            result.guardRejected = candidates.count - kept.count
            // A hand-over has to happen: if the guard would leave the search
            // with nothing, it loses. Traced, because "we cut right before the
            // chorus" then has a reason attached to it.
            if kept.isEmpty {
                result.guardFellBack = result.guardRejected > 0
            } else {
                candidates = kept
            }
        }

        candidates = preferringVocalCliffs(candidates, of: a, into: &result, config: config)

        result.points = candidates.map(\.time)
        result.structuralCount = candidates.filter(\.structural).count
        return result
    }

    /// **Vocal cliff preference.** A *stable partition*, never a filter:
    /// candidates that sit where the voice stops move ahead of ones that do
    /// not, each group keeping its own order. Nothing is removed, so the
    /// fall-back list is intact and no gate can see this layer at all — the
    /// same safety argument the rest of the structure layer makes.
    private static func preferringVocalCliffs(
        _ candidates: [(time: TimeInterval, structural: Bool)], of a: TrackAnalysis,
        into result: inout OutPointCandidates, config: Config
    ) -> [(time: TimeInterval, structural: Bool)] {
        guard config.preferVocalCliffOutPoints, !a.vocalActivity.isEmpty else { return candidates }
        var cliffs: [(time: TimeInterval, structural: Bool)] = []
        var rest: [(time: TimeInterval, structural: Bool)] = []
        for candidate in candidates {
            if vocalCliff(a, at: candidate.time, config: config) != nil {
                cliffs.append(candidate)
            } else {
                rest.append(candidate)
            }
        }
        guard !cliffs.isEmpty, !rest.isEmpty else { return candidates }
        result.vocalCliffPromoted = cliffs.count
        return cliffs + rest
    }

    /// **The climax does not end where the chorus cluster does.**
    ///
    /// Field evidence, one seam: track 476081904 was segmented `chorus
    /// 131.5–174.3`, then a passage 174.3–208.6 that happens exactly once
    /// (`repetition == 1`, so the segmenter files it as a bridge) and whose
    /// `vocalDensity` is 1.03 — the singer is still working, at above the
    /// track's own average — then the outro. The guard protected the sixteen
    /// bars *before* the last chorus and then stood aside, so the hand-over
    /// landed at 204.7 s, four seconds from the end of a phrase nobody had
    /// finished. The listener marked it bad, and was right to.
    ///
    /// So the no-cut zone runs on past the final chorus for as long as unique,
    /// vocally dense sections follow it directly. Three conditions, all
    /// necessary: **unique**, because a repeat-out is the song saying something
    /// it has already said; **vocally dense**, because an instrumental tag is
    /// a fine place to leave; and **immediately after**, because a dense verse
    /// two sections later is a different part of the song.
    ///
    /// Returns nil — no extension — whenever any of the three fails, which is
    /// the ordinary case.
    private static func climaxExtension(
        _ sections: [TrackAnalysis.Section], after final: TrackAnalysis.Section,
        config: Config
    ) -> (end: TimeInterval, detail: String)? {
        let ordered = sections.sorted { $0.start < $1.start }
        guard let index = ordered.firstIndex(where: { abs($0.start - final.start) < 1e-6 })
        else { return nil }
        var end = final.end
        var taken: [TrackAnalysis.Section] = []
        for section in ordered[(index + 1)...] {
            guard abs(section.start - end) < 1e-3 else { break }
            guard section.repetition == 1,
                  Double(section.vocalDensity) >= config.climaxExtendVocalDensity,
                  !isClimax(section.kind), section.kind != .outro
            else { break }
            taken.append(section)
            end = section.end
        }
        guard !taken.isEmpty else { return nil }
        return (end, String(format: "the final %@ ends at %.2f s but %@ follows it — "
                            + "unique, vocal density %.2f against a %.2f line — so the no-cut "
                            + "zone runs to %.2f s",
                            final.kind.rawValue, final.end,
                            taken.map(\.kind.rawValue).joined(separator: "+"),
                            Double(taken.map(\.vocalDensity).max() ?? 0),
                            config.climaxExtendVocalDensity, end))
    }

    /// **A vocal cliff**: how far `vocalActivity` falls across `t`, in units of
    /// the track's own mean, or nil when it does not fall far enough to matter.
    ///
    /// The other half of the same lesson. The right cut on that seam was
    /// 208.6 s — the outro's downbeat, where the voice stops — and nothing in
    /// the candidate ordering could prefer it over 204.7 s, where the voice is
    /// mid-phrase, because the ordering only knows about section boundaries and
    /// RMS jumps. A voice stopping is the most audible full stop a song has.
    static func vocalCliff(
        _ a: TrackAnalysis, at t: TimeInterval, config: Config
    ) -> Double? {
        let window = config.vocalCliffWindowSeconds
        guard window > 0,
              let before = vocalScore(a, from: max(0, t - window), length: window),
              let after = vocalScore(a, from: t, length: window)
        else { return nil }
        let drop = before - after
        return drop >= config.vocalCliffDrop ? drop : nil
    }

    /// The last entry of an ascending array that is at or before `t`.
    private static func lastLineEnd(
        _ ends: [TimeInterval], atOrBefore t: TimeInterval
    ) -> TimeInterval? {
        var low = 0, high = ends.count
        while low < high {
            let mid = (low + high) / 2
            if ends[mid] <= t + 1e-6 { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? ends[low - 1] : nil
    }

    /// Where the incoming track is entered, and where that came from.
    struct InPointChoice {
        let point: TimeInterval
        /// The section it was taken from, nil when the choice is `introEnd`.
        let section: TrackAnalysis.Section?
        let detail: String
    }

    /// In point: the start of the first **core** section — the first section
    /// that is neither intro-kind nor outro-kind — instead of `introEnd`'s
    /// "first second above 25 % of peak".
    ///
    /// The two disagree exactly where `introEnd` is weakest (predev §1.2): an a
    /// cappella opening clears the energy threshold in its first second, and a
    /// slow electronic build never does until it is already over. "The song
    /// proper starts here" is a structural question, and structure answers it.
    /// Section starts are downbeat-snapped by the segmenter, so the downbeat
    /// mechanics the beat-matched search applies on top are unchanged.
    ///
    /// **Core is defined by exclusion, not by a list**, and that is the whole
    /// lesson of the first corpus sweep. `bridge` is the segmenter's catch-all
    /// for a cluster that happens once, so a first verse that never repeats
    /// verbatim — the ordinary case in rap and in through-composed pop — comes
    /// back labelled `bridge`. Asking for "the first verse or chorus" then
    /// walked straight past it to the *second* chorus and entered the song
    /// fifty seconds in. Anything that is not the intro and not the outro is the
    /// song, whatever the label on it says.
    ///
    /// Falls back to `introEnd` when there are no usable sections, when every
    /// section is intro- or outro-kind, or when the answer lands outside a
    /// sanity window around `introEnd`.
    static func inPointChoice(_ a: TrackAnalysis, config: Config) -> InPointChoice {
        func introEnd(_ why: String) -> InPointChoice {
            InPointChoice(point: a.introEnd, section: nil,
                          detail: String(format: "intro end %.2f s — %@", a.introEnd, why))
        }
        guard config.useStructureInPoint else { return introEnd("structural in point is off") }
        guard let sections = usableSections(a, config: config) else {
            return introEnd(a.sections.isEmpty
                            ? "the incoming track has no sections"
                            : String(format: "structure confidence %.2f below the %.2f gate",
                                     a.structureConfidence, config.structureConfidenceGate))
        }
        guard let core = sections.first(where: { $0.kind != .intro && $0.kind != .outro })
        else { return introEnd("every section is an intro or an outro") }
        let low = a.introEnd - config.structureInPointSlackSeconds
        let high = a.introEnd + config.structureInPointMaxLeadSeconds
        guard core.start >= low, core.start <= high else {
            return introEnd(String(format: "the first %@ starts at %.2f s, outside "
                                   + "[%.2f s, %.2f s] around the intro end",
                                   core.kind.rawValue, core.start, low, high))
        }
        return InPointChoice(
            point: core.start, section: core,
            detail: String(format: "first %@ starts at %.2f s (intro end %.2f s)",
                           core.kind.rawValue, core.start, a.introEnd))
    }

    // MARK: - Making room for the vocal exchange

    /// Where deck B should be entered — and how long the overlap should be — so
    /// that the incoming singer's first line lands *on* the hand-over instead
    /// of under a mute.
    ///
    /// The compile (`Audition.VocalExchange`) reads both lyric clocks and picks
    /// the instant; it cannot pick the material. If the planner enters an
    /// incoming track on top of a verse, deck B's first lines are inside the
    /// overlap and before the hand-over, and the only thing the compile can do
    /// with them is hold them at −40 dB. That is the field complaint — an
    /// in-point 0.012 s into a track that sings from the top, hand-over at
    /// 16.9 s of a 28.9 s overlap, seventeen seconds of the new singer gone.
    ///
    /// So when the pair is a sung/sung blend that asked for a `.vocalExchange`
    /// and the incoming track's lyric clock is known, the entry moves back into
    /// the incoming song's own **pre-vocal gap** (its intro, or the space
    /// before a verse — the largest gap near the structural choice), far enough
    /// back that the first line arrives about `vocalEntryLeadBeats` past the
    /// floor swap, and the overlap ladder prefers 8 and 4 bars over 16: a short
    /// window is what keeps that arithmetic inside the gap the song actually
    /// has.
    ///
    /// Nil — no timing, no gap, or nothing to gain — leaves the plan exactly as
    /// it was.
    static func vocalEntryAim(
        incoming: TrackAnalysis, timing: PlanContext.LyricTiming,
        structuralInPoint: TimeInterval, beat: TimeInterval, rate: Double,
        config: Config
    ) -> (inPoint: TimeInterval, ladder: [Int], detail: String)? {
        let starts = timing.lineStarts.sorted()
        let ends = timing.lineEnds.sorted()
        let move = config.vocalEntryMaxMoveSeconds
        guard !starts.isEmpty, beat > 0, rate > 0, move > 0 else { return nil }

        // The ladder this rule works in: shorter overlaps, because the entry
        // has to fit inside a gap the incoming song actually has, and a 16-bar
        // window would need one no pop track offers.
        let ladder = [8, 4]

        // Does deck B sing from where the planner would enter it? If its first
        // line is already most of an overlap away, entering there costs the
        // listener nothing and this rule has no business moving anything.
        guard let firstLine = starts.first(where: { $0 >= structuralInPoint - 0.05 }),
              (firstLine - structuralInPoint) / rate
                  < Double(ladder[0]) * 4 * beat / 2
        else { return nil }

        // The gaps this song offers: from the previous line's end to the next
        // line's start, plus the intro (from 0 to the first line). Only gaps
        // near the structural in-point are candidates — a gap a minute away is
        // not this hand-over's entry, whatever its length.
        var gaps: [(start: TimeInterval, entry: TimeInterval)] = []
        for (index, line) in starts.enumerated() {
            let from = index == 0 ? 0 : (index - 1 < ends.count ? ends[index - 1] : line)
            if line > from { gaps.append((from, line)) }
        }
        let near = gaps.filter {
            $0.entry >= structuralInPoint - move && $0.start <= structuralInPoint + move
        }
        guard let gap = near.max(by: { ($0.entry - $0.start) < ($1.entry - $1.start) })
        else { return nil }
        let floor = Swift.max(0, gap.start, structuralInPoint - move)

        for bars in ladder {
            let overlap = Double(bars) * 4 * beat
            // Aim: the first line lands `vocalEntryLeadBeats` past the floor
            // swap, which a beat-matched plan puts at half the overlap.
            let lead = rate * (overlap / 2 + config.vocalEntryLeadBeats * beat)
            let target = gap.entry - lead
            guard target >= floor - 0.05 else { continue }
            // Only ever *earlier*: entering later would throw away more of the
            // incoming track's opening, which is the thing being rescued. And
            // if the aim does not actually move the entry, today's plan already
            // lands the line where this rule wants it.
            guard target < structuralInPoint - 0.05 else { return nil }
            // Land on a downbeat *at or before* the target, and hand that
            // downbeat over as the anchor: the search's own snap walks
            // **forward** to the first downbeat past its anchor, so aiming at
            // the raw target would give back up to a bar of the lead and drop
            // the incoming line in front of the floor swap. The bar grid is the
            // granularity this rule has; picking the downbeat here is what
            // keeps the line on the late side of the swap.
            guard let entry = incoming.downbeats.last(where: {
                $0 <= Swift.min(target, structuralInPoint) + 0.05 && $0 >= floor - 0.05
            }) else { continue }
            let landing = (gap.entry - entry) / rate
            return (entry, bars == 4 ? [4] : [bars, 4], String(
                format: "vocal entry: incoming sings from %.2f s (pre-vocal gap "
                    + "%.2f–%.2f s), so the in point moves %.2f s earlier to %.2f s "
                    + "and the overlap takes at most %d bars — its first line then lands "
                    + "%.2f s into the overlap, %.2f s past the floor swap",
                gap.entry, gap.start, gap.entry, structuralInPoint - entry, entry, bars,
                landing, landing - overlap / 2))
        }
        return nil
    }

    // MARK: - Rule 1: beat-matched

    /// - Parameters:
    ///   - candidates: the ordered out-point candidate list
    ///     (`outPointCandidates`); `phraseBoundaries` verbatim when the
    ///     structure layer had nothing to say.
    ///   - inAnchor: where the incoming track is entered before the downbeat
    ///     snap below — the first core section's start, or `introEnd`.
    private static func beatMatchedPlan(
        outgoing: TrackAnalysis, incoming: TrackAnalysis,
        candidates: [TimeInterval], inAnchor: TimeInterval,
        stems: StemAvailability, intentVocalRequest: Double? = nil,
        incomingLyrics: PlanContext.LyricTiming? = nil, config: Config,
        trace: inout PlanTrace?
    ) -> (plan: BeatMatchedPlan, stem: StemTechnique?, vocalEntry: String?)? {
        guard note(&trace, .beatMatch, "bpmConfidence",
                   outgoing.bpmConfidence >= config.bpmConfidenceThreshold
                       && incoming.bpmConfidence >= config.bpmConfidenceThreshold
                       && outgoing.bpm > 0 && incoming.bpm > 0,
                   Swift.min(outgoing.bpmConfidence, incoming.bpmConfidence),
                   config.bpmConfidenceThreshold,
                   String(format: "tempo confidence %.2f / %.2f against a %.2f gate",
                          outgoing.bpmConfidence, incoming.bpmConfidence,
                          config.bpmConfidenceThreshold))
        else { return nil }

        // Fold the incoming tempo to the closest double/half-time candidate.
        let foldedBPM = [0.5, 1.0, 2.0]
            .map { incoming.bpm * $0 }
            .min { abs($0 - outgoing.bpm) < abs($1 - outgoing.bpm) }!
        let bpmDelta = abs(foldedBPM - outgoing.bpm) / outgoing.bpm
        // Which regime this seam is being judged under — the glide's wider caps
        // or the step's — said out loud in both gates below, because "why was
        // this pair beat-matched" and "why was that one not" is otherwise a
        // question about a config field nobody was looking at.
        let bpmCap = config.beatMatchBPMDeltaCap
        let rateCap = config.beatMatchRateCap
        let bendShare = config.beatMatchBendShareOutgoing
        let regime = config.tempoRampEnabled
            ? String(format: "ramped (%.1f s glide, %.0f/%.0f split)",
                     config.rampLeadSeconds, bendShare * 100, (1 - bendShare) * 100)
            : "stepped"
        guard note(&trace, .beatMatch, "bpmDelta", bpmDelta <= bpmCap,
                   bpmDelta, bpmCap,
                   String(format: "%.1f → %.1f BPM (folded %.1f), %.1f %% apart "
                          + "against a %.1f %% beat-match window (%@)",
                          outgoing.bpm, incoming.bpm, foldedBPM,
                          bpmDelta * 100, bpmCap * 100, regime))
        else { return nil }

        // Where the two decks meet, and how far each may bend to get there.
        //
        // An even split is written as the midpoint it always was rather than as
        // `o + 0.5·(f − o)`: the two are the same number in exact arithmetic but
        // not in `Double`, and "a plan made with the ramp off is what it was" is
        // a promise about the bits, not about the algebra. The share path is
        // therefore only taken when the share is actually asymmetric — which is
        // also the only case that can need the clamp below.
        var targetBPM = (outgoing.bpm + foldedBPM) / 2
        if bendShare != 0.5 {
            // The outgoing deck takes `bendShare` of the gap; the incoming one
            // takes what is left. Clamped to the regime's cap, which is what
            // spills the excess onto the other deck: `targetBPM` held at the
            // cap *is* the remainder landing on the incoming side, and it is
            // what makes the effective split degrade toward 50/50 for pairs at
            // the edge of `beatMatchBPMDeltaCap` (see `rampBendShareOutgoing`).
            // Whatever is left over after that spill is what the rate gate
            // below refuses, exactly as it always did.
            let bend = outgoing.bpm * rateCap
            targetBPM = Swift.min(Swift.max(outgoing.bpm + bendShare * (foldedBPM - outgoing.bpm),
                                            outgoing.bpm - bend),
                                  outgoing.bpm + bend)
        }
        let outgoingRate = targetBPM / outgoing.bpm
        let incomingRate = targetBPM / foldedBPM
        guard note(&trace, .beatMatch, "rateDeviation",
                   abs(outgoingRate - 1) <= rateCap + 1e-9
                       && abs(incomingRate - 1) <= rateCap + 1e-9,
                   Swift.max(abs(outgoingRate - 1), abs(incomingRate - 1)),
                   rateCap,
                   String(format: "decks bend %.2f %% / %.2f %% against a ±%.1f %% limit (%@)",
                          (outgoingRate - 1) * 100, (incomingRate - 1) * 100,
                          rateCap * 100, regime))
        else { return nil }

        // Making room for the vocal exchange, before the snap rather than
        // after it: when this pair is a sung/sung blend that asked for one and
        // the incoming track's lyric clock is known, the entry may move back
        // into deck B's own pre-vocal gap so its first line lands on the
        // hand-over. `nil` lyrics — every path that does not read a `.lrc` —
        // leaves `anchor` and both ladders exactly as they were.
        var anchor = inAnchor
        var barLadder = [16, 8]
        var stemLadder = [16, 8, 4]
        var vocalEntry: String?
        if let incomingLyrics, intentVocalRequest != nil,
           let aim = vocalEntryAim(incoming: incoming, timing: incomingLyrics,
                                   structuralInPoint: inAnchor,
                                   beat: 60.0 / targetBPM, rate: incomingRate,
                                   config: config) {
            anchor = aim.inPoint
            barLadder = aim.ladder
            stemLadder = aim.ladder
            vocalEntry = aim.detail
        }

        // In point: the downbeat aligned with the incoming track's entry — the
        // first core section's start when structure named one, `introEnd`
        // otherwise. The snap itself is unchanged either way.
        guard let inPoint = incoming.downbeats.first(where: { $0 >= anchor - 0.05 })
                ?? incoming.downbeats.first
        else {
            _ = note(&trace, .beatMatch, "inPoint", false, nil, nil,
                     String(format: "the incoming track has no downbeat at all "
                            + "(entry anchored at %.2f s)", inAnchor))
            return nil
        }
        _ = note(&trace, .beatMatch, "inPoint", true, inPoint, nil,
                 String(format: "first downbeat past the %.2f s entry sits at %.2f s",
                        anchor, inPoint)
                     + (vocalEntry.map { " (\($0))" } ?? ""))

        let beatDuration = 60.0 / targetBPM
        func overlapDuration(bars: Int) -> TimeInterval { Double(bars) * 4 * beatDuration }
        let overlapCeiling = min(
            config.maxOverlap,
            config.maxOverlapShare * min(outgoing.duration, incoming.duration))

        // Out point: best candidate before any outro fade that still leaves
        // room for the overlap. The list is ordered by preference, not by time,
        // so restrict it to a tail window first — the best-ranked entry may sit
        // mid-song, and cutting there would skip half the track.
        let outLimit = outgoing.outroFadeStart ?? outgoing.duration
        let tailWindowStart = max(outgoing.duration * config.tailWindowShare,
                                  outLimit - config.tailWindowSeconds)
        func outPoint(forOverlap overlap: TimeInterval) -> TimeInterval? {
            candidates.first {
                $0 >= tailWindowStart && $0 <= outLimit && $0 + overlap <= outgoing.duration
            }
        }

        // Longest steady overlap wins, under the shared ceiling: 16 or 8
        // bars when both regions hold steady, 4 bars as the floor.
        var bars = 4
        var chosenOutPoint: TimeInterval?
        for candidate in barLadder {
            let overlap = overlapDuration(bars: candidate)
            guard note(&trace, .barUpgrade, "bars\(candidate).ceiling",
                       overlap <= overlapCeiling, overlap, overlapCeiling,
                       String(format: "%d bars = %.2f s against a %.2f s ceiling",
                              candidate, overlap, overlapCeiling))
            else { continue }
            guard let op = outPoint(forOverlap: overlap) else {
                _ = note(&trace, .barUpgrade, "bars\(candidate).outPoint", false, nil, nil,
                         String(format: "no candidate in [%.1f s, %.1f s] leaves room "
                                + "for a %.2f s overlap",
                                tailWindowStart, outLimit, overlap))
                continue
            }
            _ = note(&trace, .barUpgrade, "bars\(candidate).outPoint", true, op, nil,
                     String(format: "out point %.2f s", op))
            guard note(&trace, .barUpgrade, "bars\(candidate).incomingRoom",
                       inPoint + overlap <= incoming.duration,
                       inPoint + overlap, incoming.duration,
                       String(format: "in point %.2f s + %.2f s against a %.0f s track",
                              inPoint, overlap, incoming.duration))
            else { continue }
            guard note(&trace, .barUpgrade, "bars\(candidate).stableOut",
                       isStable(outgoing, outgoing.rmsEnvelope, from: op, length: overlap,
                                cv: config.stableCV, config: config),
                       energyCV(outgoing.rmsEnvelope, from: op, length: overlap),
                       steadyBar(outgoing, from: op, length: overlap,
                                 base: config.stableCV, config: config),
                       "outgoing " + steadyText(outgoing, from: op, length: overlap,
                                                base: config.stableCV, config: config))
            else { continue }
            guard note(&trace, .barUpgrade, "bars\(candidate).stableIn",
                       isStable(incoming, incoming.rmsEnvelope, from: inPoint,
                                length: overlap, cv: config.stableCV, config: config),
                       energyCV(incoming.rmsEnvelope, from: inPoint, length: overlap),
                       steadyBar(incoming, from: inPoint, length: overlap,
                                 base: config.stableCV, config: config),
                       "incoming " + steadyText(incoming, from: inPoint, length: overlap,
                                                base: config.stableCV, config: config))
            else { continue }
            guard note(&trace, .barUpgrade, "bars\(candidate).vocals",
                       !vocalsClash(outgoing: outgoing, outPoint: op,
                                    incoming: incoming, inPoint: inPoint, overlap: overlap,
                                    config: config),
                       nil, config.vocalClashRatio,
                       String(format: "vocal density %@ / %@ against a %.2f clash line",
                              scoreText(vocalScore(outgoing, from: op, length: overlap)),
                              scoreText(vocalScore(incoming, from: inPoint, length: overlap)),
                              config.vocalClashRatio))
            else { continue }
            bars = candidate
            chosenOutPoint = op
            break
        }
        if chosenOutPoint == nil {
            let overlap4 = overlapDuration(bars: 4)
            guard note(&trace, .beatMatch, "overlapCeiling", overlap4 <= overlapCeiling,
                       overlap4, overlapCeiling,
                       String(format: "the 4-bar floor is %.2f s against a %.2f s ceiling",
                              overlap4, overlapCeiling))
            else { return nil }
            guard let op4 = outPoint(forOverlap: overlap4) else {
                _ = note(&trace, .beatMatch, "outPoint", false, nil, nil,
                         String(format: "no candidate in [%.1f s, %.1f s] leaves room "
                                + "for the %.2f s floor (the track offers %d)",
                                tailWindowStart, outLimit, overlap4, candidates.count))
                return nil
            }
            _ = note(&trace, .beatMatch, "outPoint", true, op4, nil,
                     String(format: "out point %.2f s", op4))
            guard note(&trace, .beatMatch, "incomingRoom",
                       inPoint + overlap4 <= incoming.duration,
                       inPoint + overlap4, incoming.duration,
                       String(format: "in point %.2f s + %.2f s against a %.0f s track",
                              inPoint, overlap4, incoming.duration))
            else { return nil }
            chosenOutPoint = op4
        } else if trace != nil {
            // The upgrade search already cleared these three for a longer
            // overlap, so record them passed rather than leaving a hole in the
            // ledger where the histogram expects a row.
            let overlap = overlapDuration(bars: bars)
            _ = note(&trace, .beatMatch, "overlapCeiling", true, overlap, overlapCeiling,
                     String(format: "%d bars = %.2f s against a %.2f s ceiling",
                            bars, overlap, overlapCeiling))
            _ = note(&trace, .beatMatch, "outPoint", true, chosenOutPoint, nil,
                     String(format: "out point %.2f s", chosenOutPoint ?? 0))
            _ = note(&trace, .beatMatch, "incomingRoom", true,
                     inPoint + overlap, incoming.duration,
                     String(format: "in point %.2f s + %.2f s against a %.0f s track",
                            inPoint, overlap, incoming.duration))
        }
        guard let outPoint = chosenOutPoint else { return nil }

        func made(bars: Int, outPoint: TimeInterval) -> BeatMatchedPlan {
            let overlap = overlapDuration(bars: bars)
            return BeatMatchedPlan(
                outPoint: outPoint,
                inPoint: inPoint,
                overlapBars: bars,
                outgoingRate: Float(outgoingRate),
                incomingRate: Float(incomingRate),
                bassSwapOffset: overlap / 2,
                overlapDuration: overlap,
                // Carried on the plan rather than looked up from a config by
                // the engine: the plan is the one thing that survives the
                // plan → engine → offline-render path and the armed-plan
                // re-plan comparison, so this is where "was this seam planned
                // to glide, and how far ahead" has to live. Zero — a plan made
                // with the knob off — is read everywhere as the old step.
                rampLeadSeconds: config.tempoRampEnabled ? config.rampLeadSeconds : 0,
                rampReleaseSeconds: config.tempoRampEnabled ? config.rampReleaseSeconds : 0,
                rampGlideBackFromSwap: config.tempoRampEnabled
                    && config.rampGlideBackFromSwap)
        }
        let plain = made(bars: bars, outPoint: outPoint)
        guard stems == .ready else { return (plain, nil, vocalEntry) }

        // Stem variant: the same longest-first bar search, but the vocal gate
        // that blocked the 8/16-bar upgrades above is replaced by "a stem
        // technique must apply here". So a pair the whole-mix planner cut back
        // to four bars for a vocal clash gets its long overlap back — with the
        // clash ducked rather than avoided. Everything the search still
        // insists on (the ceiling, both sides' steadiness, room on the
        // incoming deck) is unchanged: a technique cannot make a lurching
        // window sit still.
        for candidate in stemLadder {
            let overlap = overlapDuration(bars: candidate)
            guard overlap <= overlapCeiling, inPoint + overlap <= incoming.duration,
                  let choice = stemChoice(
                    outgoing: outgoing, incoming: incoming,
                    candidates: stemCandidates(outgoing, candidates: candidates,
                                               overlap: overlap, config: config),
                    inPoint: inPoint, overlap: overlap, tier: .compatible,
                    intentVocalRequest: intentVocalRequest, config: config)
            else { continue }
            if candidate > 4 {
                guard isStable(outgoing, outgoing.rmsEnvelope, from: choice.outPoint,
                               length: overlap, cv: config.stableCV, config: config),
                      isStable(incoming, incoming.rmsEnvelope, from: inPoint,
                               length: overlap, cv: config.stableCV, config: config)
                else { continue }
            }
            return (made(bars: candidate, outPoint: choice.outPoint), choice.technique,
                    vocalEntry)
        }
        return (plain, nil, vocalEntry)
    }

    /// The steadiness bar that applies to one window of one track: the looser
    /// `sectionSteadyCV` when the window sits wholly inside a single labelled
    /// section, `base` otherwise.
    ///
    /// Nil `a` — every caller that judges a window with no analysis to hand —
    /// and every track without usable sections take `base`, so the whole
    /// section rule is unreachable for them and their decisions are what they
    /// were before it existed.
    private static func steadyBar(
        _ a: TrackAnalysis?, from: TimeInterval, length: TimeInterval,
        base: Double, config: Config
    ) -> Double {
        guard let a, let sections = usableSections(a, config: config) else { return base }
        // A hair of slack at each end: section bounds are snapped to downbeats
        // and the window is derived from a bar count, so a window that fills a
        // section exactly can miss by a rounding error.
        let inside = sections.contains {
            from >= $0.start - 0.05 && from + length <= $0.end + 0.05
        }
        return inside ? Swift.max(base, config.sectionSteadyCV) : base
    }

    /// Whether a window is steady, at whichever bar `steadyBar` says applies.
    /// The trace-facing companion is `steadyText`, which quotes both numbers.
    private static func isStable(
        _ a: TrackAnalysis?, _ envelope: [Float], from: TimeInterval,
        length: TimeInterval, cv: Double, config: Config
    ) -> Bool {
        isStable(envelope, from: from, length: length,
                 cv: steadyBar(a, from: from, length: length, base: cv, config: config))
    }

    /// Whether the 1s RMS envelope is steady over [from, from+length).
    private static func isStable(
        _ envelope: [Float], from: TimeInterval, length: TimeInterval, cv: Double
    ) -> Bool {
        let start = max(0, Int(from))
        let end = min(envelope.count, Int((from + length).rounded(.up)))
        guard end - start >= 3 else { return false }
        let slice = envelope[start..<end]
        let mean = slice.reduce(0, +) / Float(slice.count)
        guard mean > 1e-4 else { return false }
        let variance = slice.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) }
            / Float(slice.count)
        return Double(variance.squareRoot() / mean) < cv
    }

    /// The number `isStable` compares against `cv` — the coefficient of
    /// variation of the 1 s RMS over the window, or nil when the window is too
    /// short or too quiet to judge. Trace-only: nothing decides on it.
    private static func energyCV(
        _ envelope: [Float], from: TimeInterval, length: TimeInterval
    ) -> Double? {
        let start = max(0, Int(from))
        let end = min(envelope.count, Int((from + length).rounded(.up)))
        guard end - start >= 3 else { return nil }
        let slice = envelope[start..<end]
        let mean = slice.reduce(0, +) / Float(slice.count)
        guard mean > 1e-4 else { return nil }
        let variance = slice.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) }
            / Float(slice.count)
        return Double(variance.squareRoot() / mean)
    }

    private static func cvText(
        _ envelope: [Float], from: TimeInterval, length: TimeInterval
    ) -> String {
        energyCV(envelope, from: from, length: length)
            .map { String(format: "%.3f", $0) } ?? "unmeasurable (window too short or silent)"
    }

    private static func scoreText(_ v: Double?) -> String {
        v.map { String(format: "%.2f", $0) } ?? "—"
    }

    /// The steadiness comparison in words, naming the bar that actually
    /// applied and — when it is the looser one — why. Without the "why" a
    /// reader of the ledger sees two different numbers on two different seams
    /// and no way to tell which rule they are looking at.
    private static func steadyText(
        _ a: TrackAnalysis?, from: TimeInterval, length: TimeInterval,
        base: Double, config: Config
    ) -> String {
        let bar = steadyBar(a, from: from, length: length, base: base, config: config)
        let envelope = a?.rmsEnvelope ?? []
        return String(format: "energy CV %@ against a %.2f steadiness bar%@",
                      cvText(envelope, from: from, length: length), bar,
                      bar > base ? " (single-section window)" : "")
    }

    /// How many tail seconds of the outgoing track can sit under a fade:
    /// the whole outro when the track fades itself out, otherwise the
    /// longest energy-steady window ending at the tail.
    static func tailCapacity(_ a: TrackAnalysis, config: Config) -> TimeInterval {
        if let outro = a.outroFadeStart {
            return a.duration - max(outro, a.duration * config.tailWindowShare)
        }
        let env = a.rmsEnvelope
        for len in stride(from: Int(config.maxOverlap), through: 3, by: -1) {
            let start = env.count - len
            guard start >= 0 else { continue }
            if isStable(a, env, from: TimeInterval(start), length: TimeInterval(len),
                        cv: config.tailStableCV, config: config) {
                return TimeInterval(len)
            }
        }
        // The track ends hot and jagged — keep the fade short.
        return config.tailCapacityFallback
    }

    /// How long the incoming opening can sit under the fade: its energy
    /// climb after the in point (a slow build hides nicely under the
    /// outgoing tail; a hot open should surface fast), plus a little body.
    static func intakeCapacity(
        _ a: TrackAnalysis, inPoint: TimeInterval, config: Config
    ) -> TimeInterval {
        let env = a.rmsEnvelope
        guard let peak = env.max(), peak > 0, !env.isEmpty else { return 6 }
        var i = min(env.count - 1, max(0, Int(inPoint)))
        var climb: TimeInterval = 0
        while i < env.count, env[i] < peak * Float(config.intakePeakShare) {
            climb += 1
            i += 1
        }
        return climb + config.intakeBodySeconds
    }

    // MARK: - Rule 2: crossfade

    private static func crossfadePlan(
        outgoing: TrackAnalysis, incoming: TrackAnalysis,
        candidates: [TimeInterval], inPoint: TimeInterval,
        tierCap: TimeInterval, tier: CompatibilityTier,
        stems: StemAvailability, intentVocalRequest: Double? = nil, config: Config
    ) -> (plan: TransitionPlan, stem: StemTechnique?) {
        // `inPoint` is the structure layer's answer (`inPointChoice`), which is
        // `introEnd` whenever there is no structure to read — and it is the same
        // value `intakeCapacity` measures the incoming climb from below, so the
        // fade length follows the in point rather than drifting from it.
        // Computed, not fixed: the shorter of what the outgoing tail can
        // carry and what the incoming opening can absorb, bounded by the
        // shared ceiling and the compatibility tier's cap.
        let ceiling = min(config.maxOverlap, tierCap,
                          config.maxOverlapShare * min(outgoing.duration, incoming.duration))
        var fade = max(config.minOverlap,
                       min(tailCapacity(outgoing, config: config),
                           intakeCapacity(incoming, inPoint: inPoint, config: config),
                           ceiling))

        let outPoint: TimeInterval
        if let outro = outgoing.outroFadeStart {
            // Trim the limp outro: hand over where the fade begins instead
            // of riding it down to silence and cutting at the last moment.
            outPoint = max(outro, outgoing.duration * config.tailWindowShare)
        } else {
            // Same tail-window restriction as the beat-matched out point;
            // among the candidates, prefer one where the outgoing vocals
            // have already finished.
            let inWindow = candidates.filter {
                $0 >= outgoing.duration * config.crossfadeOutPointShare
                    && $0 + fade <= outgoing.duration
            }
            outPoint = inWindow.first {
                (vocalScore(outgoing, from: $0, length: fade) ?? 0) <= config.vocalClashRatio
            } ?? inWindow.first ?? max(0, outgoing.duration - fade)
        }
        // Stem layer, before the vocal cap: a technique that can hold the
        // outgoing vocal down does not need the overlap shortened, and it
        // needs a *vocal-carrying* out point rather than the outro fade this
        // search would otherwise settle on.
        if stems == .ready,
           let choice = stemChoice(
            outgoing: outgoing, incoming: incoming,
            candidates: stemCandidates(outgoing, candidates: candidates,
                                       overlap: fade, config: config),
            inPoint: inPoint, overlap: fade, tier: tier,
            intentVocalRequest: intentVocalRequest, config: config) {
            return (.crossfade(duration: fade, outPoint: choice.outPoint, inPoint: inPoint),
                    choice.technique)
        }

        // Two lead vocals over each other is the one unforgivable blend —
        // when no vocal-free window exists, keep the overlap brief instead.
        if vocalsClash(outgoing: outgoing, outPoint: outPoint,
                       incoming: incoming, inPoint: inPoint, overlap: fade,
                       config: config) {
            fade = min(fade, config.vocalClashFadeCap)
        }
        return (.crossfade(duration: fade, outPoint: outPoint, inPoint: inPoint), nil)
    }
}
#endif
