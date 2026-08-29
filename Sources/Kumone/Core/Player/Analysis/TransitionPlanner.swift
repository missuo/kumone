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
    /// constants; `audition serve` swaps in a modified copy to explore what
    /// a different calibration would have decided.
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

        // --- Transition score (docs/automix-score-predev.md). P1 ships dark:
        // the knob is **off**, so the planner writes no `TransitionStyle.score`
        // and every decision, curve and rendered sample is field-for-field what
        // it was before the score model existed. The debug panel's A/B toggle
        // and the audition console are how it gets heard.

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
        _ = note(&trace, .structure, "inPointSource", true, inChoice.point, nil,
                 (inChoice.section == nil ? "introEnd: " : "section: ") + inChoice.detail)

        var matched: (plan: BeatMatchedPlan, stem: StemTechnique?)?
        if tier == .compatible {
            matched = beatMatchedPlan(outgoing: outgoing, incoming: incoming,
                                      candidates: candidates.points, inAnchor: inChoice.point,
                                      stems: stems, config: config, trace: &trace)
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
                                stems: stems, config: config, trace: &shadow)
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
            // …and a score layers over *that*, as an alternative the segment
            // path may perform. Off by default, so this is nil on every
            // shipped decision and the style is field-for-field what it was.
            style.score = score(outgoing: outgoing, incoming: incoming,
                                context: context, config: config)
            // Deliberately *not* a `PlanTrace` gate: the trace's stages are the
            // chain that decides whether a pair hands over at all, and a score
            // decides nothing — it is offered on top of a plan already made.
            // Where it went is reported by the compile (`Audition.describe`),
            // which is the only place that knows whether it was performed.
            return finish(PlannedTransition(plan: .beatMatched(matched.plan), style: style,
                                            rideDB: s.rideDB))
        }
        let cap: TimeInterval
        switch tier {
        case .compatible: cap = config.maxOverlap
        case .neutral: cap = config.neutralOverlapCap
        case .clash: cap = config.clashOverlapCap
        }
        let crossfade = crossfadePlan(outgoing: outgoing, incoming: incoming,
                                      candidates: candidates.points, inPoint: inChoice.point,
                                      tierCap: cap, tier: tier, stems: stems, config: config)
        // Same composition rule as above: the stem technique never replaces
        // the outro effect or the staged-EQ decision, it sits beneath them.
        // So a ducked vocal under a filter sweep is a swept exit whose vocal
        // is 9 dB down, not a different exit.
        var style = crossfadeStyle(tier: tier, outgoing: outgoing,
                                   plan: crossfade.plan, config: config)
        style.stemTechnique = crossfade.stem
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
    /// P1 keeps the selection rule deliberately thin: gates only, no material
    /// semantics. The gesture budget the predev's §2.4 describes is P3's, and
    /// inventing half of it here would be a rule nobody has listened to yet.
    static func score(outgoing: TrackAnalysis, incoming: TrackAnalysis,
                      context: PlanContext, config: Config) -> TransitionScore? {
        guard config.scoreEnabled else { return nil }
        // Both grids confident enough to cut on, and long enough to address:
        // a cut half a beat out is the one error the gesture cannot survive.
        guard outgoing.bpmConfidence >= config.scoreMinBPMConfidence,
              incoming.bpmConfidence >= config.scoreMinBPMConfidence,
              outgoing.downbeats.count > TransitionScore.maxPreBars,
              incoming.downbeats.count > TransitionScore.maxPostBars
        else { return nil }
        // An echo throw needs a last line to throw; with no `.lrc` the score is
        // the plain cut, which is the same gesture without the tail.
        return .cutOnOne(throwingEcho: !context.outgoingLyricLineEnds.isEmpty)
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
    private static func stemChoice(
        outgoing: TrackAnalysis, incoming: TrackAnalysis,
        candidates: [TimeInterval], inPoint: TimeInterval, overlap: TimeInterval,
        tier: CompatibilityTier, config: Config
    ) -> StemChoice? {
        guard overlap >= config.stemMinOverlap else { return nil }
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

    /// Both keys confident and ≥ `clashKeyDistance` apart on the circle of
    /// fifths. Minors fold to their relative major first, so Am → C is
    /// distance 0 (Camelot-style adjacency).
    private static func keysClash(
        _ a: TrackAnalysis, _ b: TrackAnalysis, _ config: Config
    ) -> Bool {
        guard let distance = keyDistance(a, b, config: config) else { return false }
        return distance >= config.clashKeyDistance
    }

    /// Circle-of-fifths distance between two confident keys; nil when either
    /// key is missing or below the confidence gate. Exposed so `audition` can
    /// print the number the decision actually turned on.
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
    /// `audition` can print them (and how close each sits to its threshold)
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
            for: outgoing, enabled: config.loudnessCompensation)
        let inTrim = LoudnessCompensation.trimDB(
            for: incoming, enabled: config.loudnessCompensation)
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
            for: incoming, afterTrimDB: incomingTrimDB)
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
        // Nothing to add and nothing to move: hand back the exact array the
        // three searches have always filtered, in its exact order.
        guard sections != nil || !lineEnds.isEmpty else {
            result.points = a.phraseBoundaries
            return result
        }

        let tolerance = a.bpmConfidence >= config.bpmConfidenceThreshold && a.bpm > 0
            ? 60 / a.bpm : 1.0
        var candidates: [(time: TimeInterval, structural: Bool)] = []
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

        if let climaxStart = result.climaxStart,
           config.climaxGuardBarsBefore > 0 || config.climaxGuardBarsAfter > 0 {
            let bar = barLength(a, config: config)
            let window = (start: climaxStart - Double(config.climaxGuardBarsBefore) * bar,
                          end: climaxStart + Double(config.climaxGuardBarsAfter) * bar)
            result.guardWindow = window
            let kept = candidates.filter { !($0.time >= window.start && $0.time < window.end) }
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

        result.points = candidates.map(\.time)
        result.structuralCount = candidates.filter(\.structural).count
        return result
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
        stems: StemAvailability, config: Config,
        trace: inout PlanTrace?
    ) -> (plan: BeatMatchedPlan, stem: StemTechnique?)? {
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

        // In point: the downbeat aligned with the incoming track's entry — the
        // first core section's start when structure named one, `introEnd`
        // otherwise. The snap itself is unchanged either way.
        guard let inPoint = incoming.downbeats.first(where: { $0 >= inAnchor - 0.05 })
                ?? incoming.downbeats.first
        else {
            _ = note(&trace, .beatMatch, "inPoint", false, nil, nil,
                     String(format: "the incoming track has no downbeat at all "
                            + "(entry anchored at %.2f s)", inAnchor))
            return nil
        }
        _ = note(&trace, .beatMatch, "inPoint", true, inPoint, nil,
                 String(format: "first downbeat past the %.2f s entry sits at %.2f s",
                        inAnchor, inPoint))

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
        for candidate in [16, 8] {
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
        guard stems == .ready else { return (plain, nil) }

        // Stem variant: the same longest-first bar search, but the vocal gate
        // that blocked the 8/16-bar upgrades above is replaced by "a stem
        // technique must apply here". So a pair the whole-mix planner cut back
        // to four bars for a vocal clash gets its long overlap back — with the
        // clash ducked rather than avoided. Everything the search still
        // insists on (the ceiling, both sides' steadiness, room on the
        // incoming deck) is unchanged: a technique cannot make a lurching
        // window sit still.
        for candidate in [16, 8, 4] {
            let overlap = overlapDuration(bars: candidate)
            guard overlap <= overlapCeiling, inPoint + overlap <= incoming.duration,
                  let choice = stemChoice(
                    outgoing: outgoing, incoming: incoming,
                    candidates: stemCandidates(outgoing, candidates: candidates,
                                               overlap: overlap, config: config),
                    inPoint: inPoint, overlap: overlap, tier: .compatible, config: config)
            else { continue }
            if candidate > 4 {
                guard isStable(outgoing, outgoing.rmsEnvelope, from: choice.outPoint,
                               length: overlap, cv: config.stableCV, config: config),
                      isStable(incoming, incoming.rmsEnvelope, from: inPoint,
                               length: overlap, cv: config.stableCV, config: config)
                else { continue }
            }
            return (made(bars: candidate, outPoint: choice.outPoint), choice.technique)
        }
        return (plain, nil)
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
        stems: StemAvailability, config: Config
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
            inPoint: inPoint, overlap: fade, tier: tier, config: config) {
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
