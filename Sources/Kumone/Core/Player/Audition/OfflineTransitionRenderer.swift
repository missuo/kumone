import Accelerate
import AVFoundation
import Foundation

/// Renders a planned transition to a WAV file, offline and faster than real
/// time, through a node graph isomorphic to `PlaybackEngine`'s.
///
/// The point is a tight tuning loop: change a `TransitionPlanner` constant or a
/// `TransitionAutomation` curve, re-render, listen. To be worth trusting, the
/// render has to be the same computation the player performs — so:
///
/// - the graph is `DeckChain`'s, twice (player → timePitch → EQ → delay →
///   mixer), at `DeckChain.format` (44.1 kHz stereo), the same fixed format
///   the live engine wires;
/// - the parameters come from `TransitionAutomation`, the same pure function
///   the live engine's overlap tick applies, stepped at the same 50 Hz;
/// - the post-overlap settling (rate restore, echo-tail decay) mirrors
///   `PlaybackEngine.settleTickLocked` via `TransitionAutomation.settleFrame`.
///
/// What is deliberately NOT modelled: the live engine's seek flush windows,
/// stream/underrun handling and plan re-resolution. Those are transport
/// concerns; none of them shape how a transition sounds.
enum OfflineTransitionRenderer {

    struct Options: Sendable {
        /// Context before the hand-over begins.
        var preRoll: TimeInterval = 12
        /// Context after the overlap (and any settling) has finished.
        var postRoll: TimeInterval = 12
        /// Automation granularity; 50 Hz is the live engine's ramp tick.
        var tickRate: Double = 50
        /// How the renderer gets a vocal stem when the style asks for one.
        /// Nil — the default — means stem techniques degrade to a whole-mix
        /// render, with the reason reported in `Result.stemFallbackReason`.
        var vocalStemProvider: VocalStemProvider? = nil

        /// The compiled audio side of a `TransitionScore`: two whole-mix gain
        /// lanes and, when the score throws one, a delay directive
        /// (`ScoreCompiler`). Nil — the default, and every render that has
        /// never heard of a score — leaves this whole path unread.
        ///
        /// **Nothing here separates anything.** A score-only segment costs one
        /// render pass (~1 s) and never touches `vocalStemProvider`, which is
        /// the entire point: a full-band gesture does not need stems, and
        /// paying 30 s of separation for one silent beat would be absurd.
        var mixLanes: WholeMixLanes? = nil

        /// Per-deck loudness compensation, in dB, exactly as the live player
        /// would apply it (`LoudnessCompensation`). Multiplied into every fader
        /// write, so what the render sounds like is what the product does.
        /// 0/0 — the default — is the uncompensated render, bit-identical to
        /// what this renderer produced before compensation existed.
        var outgoingTrimDB: Double = 0
        var incomingTrimDB: Double = 0
        /// The two tracks' sample peaks (`TrackAnalysis.peakDBFS`), used only
        /// to size each deck's bent-rate headroom pad exactly as the player
        /// would (`LoudnessCompensation.timePitchPadDB`). Nil — the default —
        /// means no pad, which is what a deck with no analysis gets live.
        var outgoingPeakDBFS: Double? = nil
        var incomingPeakDBFS: Double? = nil

        /// The hand-over's gain ride for the incoming deck, in dB
        /// (`PlannedTransition.rideDB`), applied exactly as the live engine
        /// applies it: full value for the whole overlap, then released at
        /// `TransitionAutomation.rideReleaseDBPerSecond(for:)`. 0 — the default
        /// — is the un-ridden render, bit-identical to what this produced
        /// before.
        ///
        /// The post-roll is stretched when needed so the release finishes
        /// inside the rendered file: the whole point of auditioning a ride is
        /// hearing that you cannot hear it being let go of.
        var rideDB: Double = 0

        /// Whether the post-roll is stretched so a gain ride finishes unwinding
        /// inside the render (see `rideDB`).
        ///
        /// True — the default — is what auditioning wants: the file has to
        /// contain the whole release for the release to be judged. The live
        /// pre-render path sets it false, because there the release is *handed
        /// back to the deck* at the splice (`Mix.rideDBAtEnd`) and continues on
        /// the engine's own glide timer; rendering another 13 s of the incoming
        /// track just to finish it would be 13 s of separation budget spent on
        /// audio the deck can play itself.
        var stretchPostRollForRideRelease = true

        /// Release slope for the ride, in dB per second, overriding the shipped
        /// `TransitionAutomation.rideReleaseDBPerSecond(for:)`.
        ///
        /// **Audition-only, and the reason it exists is A/B.** The slope is a
        /// constant rather than a planner knob because the live engine reaches
        /// it without a `Config` in hand — which is right, and which also means
        /// "render this seam at the old slope and at the new one" cannot be
        /// said with `--set`. Nil, the default, is the shipped constant, so
        /// every path that does not ask for this is unchanged.
        var rideReleaseDBPerSecond: Double? = nil

        /// Whether the pre-roll is stretched so a plan's **tempo ramp** starts
        /// inside the render (`TransitionAutomation.tempoRamp`).
        ///
        /// True — the default — is what auditioning wants, for the same reason
        /// as the ride: the glide is the thing being judged, so the file has to
        /// contain it. `TransitionSegmentRenderer` sets it false, because its
        /// pre-roll is deliberately the ramp's flat tail and nothing else; see
        /// `TransitionSegmentRenderer.handoff`.
        var extendPreRollForTempoRamp = true

        /// Loudness the finished file is normalized to before it is written, or
        /// nil to write it at its natural level.
        ///
        /// This is a **blind-listening fairness device and nothing else**: it
        /// has no counterpart in the player, is applied to the mix after both
        /// decks have been summed, and cancels out of any A/B comparison of two
        /// renders of the same pair. Loudness bias is the strongest confound in
        /// listening tests — the louder of two takes just sounds better — and
        /// several of our techniques (`vocalDuck` above all) change level by
        /// construction, so every result gathered without it is suspect
        /// (docs/automix-research-notes.md §2.4). Sony's listening test used
        /// −23 dBFS; −16 LUFS is the same idea on the same scale the rest of
        /// this feature speaks, and leaves comfortable headroom.
        var normalizeToLUFS: Double? = -16
        /// The normalization never lets the file's peak past this.
        var normalizePeakCeilingDBFS: Double = -1
        init() {}
    }

    struct Result: Sendable {
        let outputURL: URL
        /// Length of the rendered file.
        let duration: TimeInterval
        /// Where in the rendered file the overlap starts / how long it lasts.
        /// (For `.gapless`, the splice point with a zero-length overlap.)
        let overlapStart: TimeInterval
        let overlapDuration: TimeInterval
        /// Wall-clock seconds spent rendering, and the resulting speed-up.
        let renderSeconds: Double
        /// The trims the two decks played at (dB), mirroring the product.
        var outgoingTrimDB: Double = 0
        var incomingTrimDB: Double = 0
        /// The gain ride the incoming deck was held at across the overlap, and
        /// how long its release took to unwind inside this file.
        var rideDB: Double = 0
        var rideReleaseSeconds: TimeInterval = 0
        /// Blind-test normalization: what the summed mix measured before it was
        /// written, and the constant gain applied to land it on the target.
        /// Nil/0 when normalization was off or the mix could not be measured.
        var measuredLUFS: Double? = nil
        var normalizationGainDB: Double = 0
        var normalizationTargetLUFS: Double? = nil
        /// The stem technique that actually shaped this render, if any.
        var stemTechnique: String? = nil
        /// Wall-clock seconds the stem provider took (separation, or a cache
        /// read), and how much outgoing audio it was asked for.
        var stemSeconds: Double? = nil
        var stemSeparatedSeconds: TimeInterval? = nil
        /// Source seconds of the *incoming* track that were separated. Only a
        /// `.custom` envelope with a live incoming lane pays for this second
        /// pass; nil means the render split one deck, as every technique
        /// before envelopes did.
        var stemIncomingSeparatedSeconds: TimeInterval? = nil
        /// Which decks were split ("出曲" / "入曲").
        var stemSeparatedSides: [String] = []
        /// Vocal energy in the separated window, relative to the mixture.
        /// Near zero means an instrumental outro — the technique ran and had
        /// nothing to work on.
        var stemVocalEnergyRatio: Double? = nil
        /// The provider served the window from its own cache.
        var stemCacheHit = false
        /// Why a requested stem technique was *not* applied. Non-nil means the
        /// render is a plain whole-mix one and says so out loud, rather than
        /// silently sounding like something the caller did not ask for.
        var stemFallbackReason: String? = nil
        /// The render performed a score's whole-mix lanes.
        var scoreLanesApplied = false
        /// Why it did not, when it was asked to. Non-nil means the file holds
        /// the plain blend — never a half-performed score.
        var scoreFallbackReason: String? = nil

        var realtimeFactor: Double { renderSeconds > 0 ? duration / renderSeconds : .infinity }
    }

    enum RenderError: LocalizedError {
        case emptySegment(URL)
        case converterUnavailable(URL)
        case manualRenderingFailed

        var errorDescription: String? {
            switch self {
            case .emptySegment(let url):
                return "no audio to read at the requested offset in \(url.lastPathComponent)"
            case .converterUnavailable(let url):
                return "cannot convert \(url.lastPathComponent) to 44.1 kHz stereo"
            case .manualRenderingFailed:
                return "offline rendering stopped early"
            }
        }
    }

    // MARK: - The rendered mix

    /// Where one deck's source track is at one instant of the rendered mix.
    ///
    /// The pair of lists a `Mix` carries is the only description of how render
    /// time maps onto the two songs' own clocks: a beat-matched deck consumes
    /// `rate` source seconds per rendered second, and a deck that is not
    /// playing yet (or has stopped) consumes none. The live splice reads its
    /// cue points off these, and reports playback position through them.
    struct TimelinePoint: Sendable, Equatable {
        /// Seconds from the start of the rendered mix.
        var offset: TimeInterval
        /// Position in that deck's source track at `offset`.
        var source: TimeInterval
    }

    /// The finished mix, before normalization and before anything is written.
    /// `render` turns one of these into a WAV; the live pre-render path plays
    /// it straight out of memory.
    struct Mix: Sendable {
        var channels: [[Float]]
        var sampleRate: Double
        var duration: TimeInterval
        /// Where in the mix the overlap starts / how long it lasts.
        var overlapStart: TimeInterval
        var overlapDuration: TimeInterval
        var outgoing: [TimelinePoint]
        var incoming: [TimelinePoint]
        /// The ride the render actually applied, and where its release had got
        /// to when the mix ended — non-zero whenever the post-roll was shorter
        /// than the release, which is the normal case for a live segment.
        var rideDB: Double
        var rideDBAtEnd: Double
        var rideReleaseSeconds: TimeInterval
        var stemApplied: StemTechniqueLayer.Applied?
        var stemFallbackReason: String?
        /// The whole-mix lanes this render performed, when it was handed any.
        /// Nil means the score did not play — the mix is the plain blend, and
        /// `scoreFallbackReason` says why.
        var lanesApplied: WholeMixLaneLayer.Applied?
        var scoreFallbackReason: String?

        /// Source position of one deck at `offset`, linearly interpolated
        /// between breakpoints and clamped to the ends.
        static func source(of timeline: [TimelinePoint], at offset: TimeInterval) -> TimeInterval {
            guard let first = timeline.first, let last = timeline.last else { return 0 }
            if offset <= first.offset { return first.source }
            if offset >= last.offset { return last.source }
            var low = 0, high = timeline.count - 1
            while high - low > 1 {
                let mid = (low + high) / 2
                if timeline[mid].offset <= offset { low = mid } else { high = mid }
            }
            let a = timeline[low], b = timeline[high]
            let span = b.offset - a.offset
            guard span > 1e-12 else { return b.source }
            return a.source + (b.source - a.source) * ((offset - a.offset) / span)
        }
    }

    // MARK: - Entry point

    static func render(_ planned: PlannedTransition,
                       outgoing outgoingURL: URL, incoming incomingURL: URL,
                       to outputURL: URL, options: Options = Options()) throws -> Result {
        let started = Date()
        var mix = try renderMix(planned, outgoing: outgoingURL, incoming: incomingURL,
                                options: options)

        // --- Blind-test normalization, then the one and only file write.
        let normalization = normalize(&mix.channels, options: options)
        try write(mix.channels, to: outputURL, format: DeckChain.format,
                  sampleRate: mix.sampleRate)

        return Result(outputURL: outputURL, duration: mix.duration,
                      overlapStart: mix.overlapStart, overlapDuration: mix.overlapDuration,
                      renderSeconds: Date().timeIntervalSince(started),
                      outgoingTrimDB: options.outgoingTrimDB,
                      incomingTrimDB: options.incomingTrimDB,
                      rideDB: mix.rideDB,
                      rideReleaseSeconds: mix.rideReleaseSeconds,
                      measuredLUFS: normalization.measuredLUFS,
                      normalizationGainDB: normalization.gainDB,
                      normalizationTargetLUFS: options.normalizeToLUFS,
                      stemTechnique: mix.stemApplied?.technique.label,
                      stemSeconds: mix.stemApplied?.seconds,
                      stemSeparatedSeconds: mix.stemApplied?.separatedSeconds,
                      stemIncomingSeparatedSeconds: mix.stemApplied?.incomingSeparatedSeconds,
                      stemSeparatedSides: mix.stemApplied?.separatedSides ?? [],
                      stemVocalEnergyRatio: mix.stemApplied?.vocalEnergyRatio,
                      stemCacheHit: mix.stemApplied?.cacheHit ?? false,
                      stemFallbackReason: mix.stemFallbackReason,
                      scoreLanesApplied: mix.lanesApplied != nil,
                      scoreFallbackReason: mix.scoreFallbackReason)
    }

    /// Render a transition into memory. This is the whole computation — the
    /// deck graph, the stem layer, the automation, the settling and the ride —
    /// with nothing done to the result: `render` normalizes and writes it, the
    /// live pre-render path splices it into playback.
    static func renderMix(_ planned: PlannedTransition,
                          outgoing outgoingURL: URL, incoming incomingURL: URL,
                          options: Options = Options()) throws -> Mix {
        let format = DeckChain.format
        let sampleRate = format.sampleRate
        let geometry = TransitionAutomation.Geometry(plan: planned.plan)

        // How long the post-overlap settling phase runs, if at all.
        var settleDuration: TimeInterval = 0
        if case .beatMatched(let p) = planned.plan, abs(p.incomingRate - 1) > 0.001 {
            // Zero under a post-swap glide that finished inside the overlap:
            // the deck is already at unity, so the settle loop below runs no
            // ticks — but its epilogue (the outgoing deck neutralized, the
            // bent-rate pad let go of) still has to run, which is why
            // `restoringRate` stays keyed off the bend and not off this.
            settleDuration = TransitionAutomation.rateReleaseDuration(
                planned.plan, geometry: geometry)
        }
        if planned.style.outroEffect == .echoOut, geometry.overlapDuration > 0 {
            settleDuration = max(settleDuration, TransitionAutomation.echoTailDuration)
        }
        // A score's echo throw rings past the seam exactly as `.echoOut`'s does
        // — the outgoing deck is cut, the tail is not — so it needs the same
        // settling window to decay in.
        if options.mixLanes?.echoThrow != nil, geometry.overlapDuration > 0 {
            settleDuration = max(settleDuration, TransitionAutomation.echoTailDuration)
        }

        // Source windows. The outgoing deck may be sped up by up to ±4 % during
        // a beat-matched overlap, so give it a little more material than the
        // render time asks for.
        let rateHeadroom = 1.1
        let outPoint = planned.plan.outPoint
        let overlap = geometry.overlapDuration

        // Gain ride: only over an overlap, exactly like the planner and the
        // live engine. Stretch the post-roll so the release — up to ~13 s at
        // 0.3 dB/s — finishes inside the file, plus a second of the track at
        // its own level to land on.
        var rideDB: Double = 0
        if case .gapless = planned.plan {} else { rideDB = options.rideDB }
        // One local pair of closures rather than the statics, so an audition
        // A/B can move the slope without any of it leaking into the player.
        let rideSlope = options.rideReleaseDBPerSecond
            ?? TransitionAutomation.rideReleaseDBPerSecond(for: rideDB)
        func rideAt(_ elapsed: TimeInterval) -> Double {
            guard rideDB != 0, rideDB.isFinite, rideSlope > 0 else { return 0 }
            let released = rideSlope * max(0, elapsed)
            return rideDB > 0 ? max(0, rideDB - released) : min(0, rideDB + released)
        }
        let rideRelease = (rideDB != 0 && rideSlope > 0) ? abs(rideDB) / rideSlope : 0
        let postRoll = (rideRelease > 0 && options.stretchPostRollForRideRelease)
            ? max(options.postRoll, rideRelease + 1)
            : options.postRoll

        let engine = AVAudioEngine()
        let decks = (0..<2).map { _ -> OfflineDeck in OfflineDeck(engine: engine, format: format) }
        let from = decks[0], to = decks[1]
        // Same trim the live decks would carry, in the same place: a multiplier
        // on the fader, never on the mixer.
        from.trim = LoudnessCompensation.gain(fromDB: options.outgoingTrimDB)
        to.trim = LoudnessCompensation.gain(fromDB: options.incomingTrimDB)
        // Sized here, engaged where each deck actually bends — the same two
        // decisions the engine makes, in the same order.
        from.padCeilingDB = LoudnessCompensation.timePitchPadDB(
            forPeakDBFS: options.outgoingPeakDBFS, afterTrimDB: options.outgoingTrimDB)
        to.padCeilingDB = LoudnessCompensation.timePitchPadDB(
            forPeakDBFS: options.incomingPeakDBFS, afterTrimDB: options.incomingTrimDB)
        engine.mainMixerNode.outputVolume = 1
        for deck in decks { deck.connect(engine: engine, format: format) }

        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()
        defer { engine.stop() }

        let scratch = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                       frameCapacity: engine.manualRenderingMaximumFrameCount)!
        let tickFrames = AVAudioFrameCount((sampleRate / options.tickRate).rounded())

        // The mix is accumulated rather than streamed straight to disk: the
        // blind-test normalization needs the whole file's loudness before a
        // single sample is written, and a ~40 s stereo render is a few MB.
        let channelCount = Int(engine.manualRenderingFormat.channelCount)
        var mix = [[Float]](repeating: [], count: channelCount)

        /// Pull `frames` frames through the graph and append them to the mix.
        func pump(_ frames: AVAudioFrameCount) throws {
            var remaining = frames
            while remaining > 0 {
                let chunk = min(remaining, scratch.frameCapacity)
                let status = try engine.renderOffline(chunk, to: scratch)
                switch status {
                case .success:
                    if let data = scratch.floatChannelData {
                        for channel in 0..<channelCount {
                            mix[channel].append(contentsOf: UnsafeBufferPointer(
                                start: data[channel], count: Int(scratch.frameLength)))
                        }
                    }
                    remaining -= scratch.frameLength
                case .insufficientDataFromInputNode:
                    // No input node in this graph; treat as end of material.
                    return
                case .cannotDoInCurrentContext, .error:
                    throw RenderError.manualRenderingFailed
                @unknown default:
                    throw RenderError.manualRenderingFailed
                }
            }
        }

        var overlapStart = options.preRoll
        var written: AVAudioFrameCount = 0
        var stemApplied: StemTechniqueLayer.Applied?
        var stemFallback: String?
        var lanesApplied: WholeMixLaneLayer.Applied?
        var scoreFallback: String?
        var endRideDB: Double = 0

        // Where the two source tracks are as the mix plays. A deck consumes
        // `rate` source seconds per rendered second while it is playing and
        // none at all before it starts or after it stops, so the map is built
        // alongside the render rather than reconstructed from the plan.
        var rendered: TimeInterval = 0
        var outgoingSource: TimeInterval = 0
        var incomingSource: TimeInterval = 0
        var outgoingTimeline: [TimelinePoint] = []
        var incomingTimeline: [TimelinePoint] = []
        func mark() {
            outgoingTimeline.append(TimelinePoint(offset: rendered, source: outgoingSource))
            incomingTimeline.append(TimelinePoint(offset: rendered, source: incomingSource))
        }
        /// Advance the clocks by one pumped chunk, at the rates the decks ran
        /// it at (0 = that deck was not playing).
        func advance(_ frames: AVAudioFrameCount, outgoingRate: Double, incomingRate: Double) {
            let seconds = Double(frames) / sampleRate
            rendered += seconds
            outgoingSource += seconds * outgoingRate
            incomingSource += seconds * incomingRate
            mark()
        }

        if case .gapless = planned.plan {
            if planned.style.stemTechnique != nil {
                stemFallback = StemTechniqueLayer.StemError.noOverlap.errorDescription
            }
            if options.mixLanes != nil {
                scoreFallback = WholeMixLaneLayer.LaneError.noOverlap.errorDescription
            }
            // Tail-to-head: play out the end of the outgoing track, then start
            // the incoming one on the very next sample.
            let outDuration = try duration(of: outgoingURL)
            let tail = min(options.preRoll, outDuration)
            let outBuffer = try loadSegment(outgoingURL, from: outDuration - tail,
                                            seconds: tail, format: format)
            outgoingSource = outDuration - tail
            mark()
            from.schedule(outBuffer)
            from.setFader(1)
            from.player.play()
            let tailFrames = outBuffer.frameLength
            try pump(tailFrames)
            written += tailFrames
            advance(tailFrames, outgoingRate: 1, incomingRate: 0)
            overlapStart = Double(tailFrames) / sampleRate

            from.player.stop()
            let inBuffer = try loadSegment(incomingURL, from: 0,
                                           seconds: options.postRoll, format: format)
            to.schedule(inBuffer)
            to.setFader(1)
            to.player.play()
            try pump(inBuffer.frameLength)
            written += inBuffer.frameLength
            advance(inBuffer.frameLength, outgoingRate: 0, incomingRate: 1)
        } else {
            // A plan with a tempo ramp needs the whole glide inside the render,
            // or the file opens on an outgoing deck already halfway bent —
            // which is the one thing the audition is there to listen to.
            let tempoRamp = TransitionAutomation.tempoRamp(for: planned.plan)
            var preRollRequest = options.preRoll
            if let tempoRamp, options.extendPreRollForTempoRamp {
                // Room for the glide *and* for the headroom pad's own lead-in
                // ahead of it, or the render would open on a deck already
                // part-padded — and, worse, would clip in the stretch the pad
                // is supposed to have covered before the bend began.
                let padLead = TransitionAutomation.ratePadLeadSeconds(from.padCeilingDB)
                preRollRequest = max(preRollRequest,
                                     (outPoint ?? 0) - tempoRamp.start + padLead + 1)
            }
            let outStart = max(0, (outPoint ?? 0) - preRollRequest)
            // Pre-roll is measured on the *outgoing song's* clock — the deck
            // plays from `outStart` until it reaches the out point, however
            // long the glide makes that take in rendered time.
            let preRoll = (outPoint ?? 0) - outStart
            let inPoint: TimeInterval
            switch planned.plan {
            case .crossfade(_, _, let point): inPoint = point
            case .beatMatched(let p): inPoint = p.inPoint
            case .gapless: inPoint = 0
            }

            let outBuffer = try loadSegment(
                outgoingURL, from: outStart,
                seconds: (preRoll + overlap) * rateHeadroom + 1, format: format)
            let inBuffer = try loadSegment(
                incomingURL, from: inPoint,
                seconds: (overlap + settleDuration + postRoll) * rateHeadroom + 1,
                format: format)

            // --- Stem layer: rewrite the outgoing deck's overlap window
            // before a single sample is pulled through the graph, so the
            // automation below plays over stems without knowing it.
            if let technique = planned.style.stemTechnique {
                var outgoingRate = 1.0
                var incomingRate = 1.0
                if case .beatMatched(let p) = planned.plan {
                    outgoingRate = Double(p.outgoingRate)
                    incomingRate = Double(p.incomingRate)
                }
                do {
                    guard let provider = options.vocalStemProvider else {
                        throw StemTechniqueLayer.StemError.noProvider
                    }
                    if case .custom(let envelope) = technique {
                        // The incoming buffer is loaded *at* its in point and
                        // starts playing when the overlap does, so its overlap
                        // begins at frame zero — unlike the outgoing one, which
                        // carries the render's pre-roll first.
                        stemApplied = try StemTechniqueLayer.apply(
                            envelope: envelope,
                            outgoing: StemTechniqueLayer.Side(
                                buffer: outBuffer, source: outgoingURL,
                                windowStart: outStart,
                                overlapStartFrame: Int((preRoll * sampleRate).rounded()),
                                rate: outgoingRate),
                            incoming: StemTechniqueLayer.Side(
                                buffer: inBuffer, source: incomingURL,
                                windowStart: inPoint, overlapStartFrame: 0,
                                rate: incomingRate,
                                // The incoming deck may walk back to unity
                                // partway through the overlap, in which case
                                // `incomingRate` alone no longer says where it
                                // is in its own song; see `Side.glide`.
                                glide: TransitionAutomation.incomingGlide(
                                    for: planned.plan, geometry: geometry)),
                            geometry: geometry, provider: provider)
                    } else {
                        stemApplied = try StemTechniqueLayer.apply(
                            technique, to: outBuffer,
                            source: outgoingURL, windowStart: outStart,
                            overlapStartFrame: Int((preRoll * sampleRate).rounded()),
                            plan: planned.plan, style: planned.style, geometry: geometry,
                            outgoingRate: outgoingRate, provider: provider)
                    }
                } catch {
                    stemFallback = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                }
            }

            // --- Score layer: two whole-mix gain lanes, applied to the same
            // source buffers and in the same place, but per sample and without
            // separating anything. A cut edge has to land on the frame the
            // compiler named; 50 Hz control points would put it within 20 ms of
            // it, which is the flam the score model exists to avoid.
            if let lanes = options.mixLanes, !lanes.isPassThrough {
                var outgoingRate = 1.0
                var incomingRate = 1.0
                if case .beatMatched(let p) = planned.plan {
                    outgoingRate = Double(p.outgoingRate)
                    incomingRate = Double(p.incomingRate)
                }
                do {
                    lanesApplied = try WholeMixLaneLayer.apply(
                        lanes,
                        outgoing: StemTechniqueLayer.Side(
                            buffer: outBuffer, source: outgoingURL, windowStart: outStart,
                            overlapStartFrame: Int((preRoll * sampleRate).rounded()),
                            rate: outgoingRate),
                        incoming: StemTechniqueLayer.Side(
                            buffer: inBuffer, source: incomingURL,
                            windowStart: inPoint, overlapStartFrame: 0,
                            rate: incomingRate,
                            glide: TransitionAutomation.incomingGlide(
                                for: planned.plan, geometry: geometry)),
                        overlap: overlap)
                } catch {
                    scoreFallback = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                }
            }

            // --- Pre-roll: the outgoing track alone, chain transparent.
            outgoingSource = outStart
            incomingSource = inPoint
            mark()
            from.schedule(outBuffer)
            from.setFader(1)
            from.player.play()
            if let tempoRamp {
                // The engine's wait tick, offline: the deck's rate is a
                // function of where it is in its own song, and the pre-roll
                // runs until that position reaches the out point. So the
                // *source* span is fixed at `preRoll` and the rendered span is
                // whatever ∫ ds/r(s) works out to — longer when the deck is
                // being slowed down, shorter when it is being sped up. One
                // copy of the curve, one arrival point, no forked geometry.
                var pumped: AVAudioFrameCount = 0
                let target = outPoint ?? 0
                let tickSeconds = Double(tickFrames) / sampleRate
                let padLead = TransitionAutomation.ratePadLeadSeconds(from.padCeilingDB)
                let padStart = tempoRamp.start - padLead
                while outgoingSource < target - 1e-9 {
                    let rate = tempoRamp.rate(at: outgoingSource)
                    // The pad lands exactly where the bend begins — the same
                    // lead-in the engine's wait tick gives it.
                    from.setRatePad(db: from.padCeilingDB * Double(
                        TransitionAutomation.ramp(outgoingSource, from: padStart,
                                                  to: tempoRamp.start)))
                    from.timePitch.rate = rate
                    // Clamp the last chunk so the pre-roll lands *on* the out
                    // point rather than a tick past it.
                    let seconds = min(tickSeconds,
                                      (target - outgoingSource) / Double(rate))
                    let frames = AVAudioFrameCount(max(1, (seconds * sampleRate).rounded()))
                    try pump(frames)
                    written += frames
                    pumped += frames
                    advance(frames, outgoingRate: Double(rate), incomingRate: 0)
                    mark()
                }
                from.timePitch.rate = tempoRamp.target
                overlapStart = Double(pumped) / sampleRate
            } else {
                let preRollFrames = AVAudioFrameCount((preRoll * sampleRate).rounded())
                try pump(preRollFrames)
                written += preRollFrames
                advance(preRollFrames, outgoingRate: 1, incomingRate: 0)
                overlapStart = preRoll
            }

            // --- Overlap: `beginOverlapLocked`'s priming, then the ramps.
            to.schedule(inBuffer)
            if case .beatMatched(let p) = planned.plan {
                to.timePitch.rate = p.incomingRate
                // Full value at once, under a fader still at 0 — the engine's
                // `beginOverlapLocked` makes the same move for the same reason.
                to.setRatePad(db: to.padCeilingDB)
                if !planned.style.stagedEQ {
                    to.eq.bands[DeckChain.Band.low.rawValue].gain = TransitionAutomation.bassCutDB
                }
            }
            if planned.style.stagedEQ {
                to.eq.bands[DeckChain.Band.low.rawValue].gain = TransitionAutomation.bassCutDB
                to.eq.bands[DeckChain.Band.mid.rawValue].gain = TransitionAutomation.midCutDB
                to.eq.bands[DeckChain.Band.high.rawValue].gain = TransitionAutomation.highCutDB
            }
            // `beginOverlapLocked`: the ride goes on at full value while the
            // incoming fader is still 0, so it never steps anything audible.
            to.setRide(db: rideDB)
            to.setFader(0)
            to.player.play()

            var elapsed: TimeInterval = 0
            var echoThrown = false
            let tickSeconds = Double(tickFrames) / sampleRate
            // A score that owns the gain law replaces the blend rather than
            // decorating it: the cut *is* the hand-over, and cutting a deck the
            // staged EQ has already stripped of its highs and mids would cut
            // something that was barely there. So both decks' faders and EQ go
            // neutral and the lanes — already burnt into the source buffers —
            // say everything. The rates still come from the plan: a cut on the
            // one is only on the one if the two grids are still matched.
            let scoreOwnsGain = lanesApplied != nil && (options.mixLanes?.ownsGainLaw ?? false)
            let throwDirective = lanesApplied != nil ? options.mixLanes?.echoThrow : nil
            while elapsed < overlap {
                var frame = TransitionAutomation.frame(
                    plan: planned.plan, style: planned.style,
                    elapsed: elapsed, geometry: geometry,
                    // The stem layer has already rewritten the source buffers,
                    // so the live stand-in for it must not run as well.
                    approximateStems: stemApplied == nil)
                if scoreOwnsGain {
                    let rates = (outgoing: frame.outgoing.rate, incoming: frame.incoming.rate)
                    frame.outgoing = TransitionAutomation.DeckParameters()
                    frame.incoming = TransitionAutomation.DeckParameters()
                    frame.outgoing.rate = rates.outgoing
                    frame.incoming.rate = rates.incoming
                    if let throwDirective, elapsed >= throwDirective.throwAt {
                        // The lane cuts the *source*, upstream of this delay, so
                        // the tail outlives the track it came from — the same
                        // reason `.echoOut` never cuts with the fader.
                        frame.outgoing.delayTime = throwDirective.delayTime
                        frame.outgoing.delayWetDryMix = throwDirective.wetDryMix
                        frame.outgoing.delayFeedback = throwDirective.feedback
                        frame.echoThrown = true
                    }
                }
                from.apply(frame.outgoing)
                to.apply(frame.incoming)
                if frame.echoThrown { echoThrown = true }
                try pump(tickFrames)
                written += tickFrames
                advance(tickFrames, outgoingRate: Double(frame.outgoing.rate),
                        incomingRate: Double(frame.incoming.rate))
                elapsed += tickSeconds
            }

            // --- `finishOverlapLocked`: the outgoing deck is spent; a thrown
            // echo tail outlives it (player stopped, delay left wet).
            let tailRinging = echoThrown
            from.player.stop()
            from.timePitch.rate = 1
            for band in [DeckChain.Band.low, .mid, .high] { from.eq.bands[band.rawValue].gain = 0 }
            from.eq.bands[DeckChain.Band.highPass.rawValue].bypass = true
            if !tailRinging {
                from.setFader(0)
                from.eq.globalGain = 0
                from.delay.wetDryMix = 0
                from.delay.feedback = 0
            }
            to.setFader(1)
            for band in [DeckChain.Band.low, .mid, .high] { to.eq.bands[band.rawValue].gain = 0 }
            to.eq.bands[DeckChain.Band.highPass.rawValue].bypass = true

            var restoringRate = false
            if case .beatMatched(let p) = planned.plan, abs(p.incomingRate - 1) > 0.001 {
                restoringRate = true
            } else {
                to.timePitch.rate = 1
            }

            // --- Settling, and the start of the ride release.
            //
            // `releaseRideLocked` fires the moment the overlap ends, so the
            // release clock starts here and keeps running *through* settling
            // and into the post-roll — in the live engine it is a deck-level
            // glide that outlives the transition entirely, and this is that
            // same envelope, stepped at the same 50 Hz.
            var sinceOverlap: TimeInterval = 0
            func rideStep() {
                guard rideDB != 0 else { return }
                to.setRide(db: rideAt(sinceOverlap))
            }

            if restoringRate || tailRinging {
                var settled: TimeInterval = 0
                while settled < settleDuration {
                    let s = TransitionAutomation.settleFrame(
                        plan: planned.plan, restoringRate: restoringRate,
                        echoTailRinging: tailRinging, elapsed: settled,
                        geometry: geometry)
                    if restoringRate { to.timePitch.rate = s.incomingRate }
                    if tailRinging {
                        from.delay.wetDryMix = s.outgoingDelayWetDryMix
                        from.delay.feedback = s.outgoingDelayFeedback
                    }
                    rideStep()
                    try pump(tickFrames)
                    written += tickFrames
                    advance(tickFrames, outgoingRate: 0,
                            incomingRate: Double(restoringRate ? s.incomingRate : 1))
                    settled += tickSeconds
                    sinceOverlap += tickSeconds
                }
                from.setFader(0)
                DeckChain.neutralize(timePitch: from.timePitch, eq: from.eq, delay: from.delay)
                to.timePitch.rate = 1
                // Rate home, so the pad it was covering for goes too — the
                // same order `settleTickLocked` releases them in.
                to.setRatePad(db: 0)
            }

            // --- Post-roll: the incoming track alone, still letting go of the
            // ride for as long as the release has left to run.
            var post: TimeInterval = 0
            while rideDB != 0, post < postRoll, sinceOverlap < rideRelease {
                rideStep()
                try pump(tickFrames)
                written += tickFrames
                advance(tickFrames, outgoingRate: 0, incomingRate: 1)
                post += tickSeconds
                sinceOverlap += tickSeconds
            }
            // Whatever is left of the ride when the mix ends is handed back to
            // the caller rather than snapped away: the live splice puts it on
            // the incoming deck and lets the engine's own glide finish it. The
            // write below is therefore only ever reached with the release
            // already spent (`postFrames > 0` implies `post < postRoll`, which
            // implies the loop stopped because `sinceOverlap >= rideRelease`).
            let rideDBAtEnd = rideAt(sinceOverlap)
            if rideDB != 0 { to.setRide(db: 0) }
            let postFrames = AVAudioFrameCount(
                (max(0, postRoll - post) * sampleRate).rounded())
            if postFrames > 0 {
                try pump(postFrames)
                written += postFrames
                advance(postFrames, outgoingRate: 0, incomingRate: 1)
            }
            endRideDB = rideDBAtEnd
        }

        return Mix(channels: mix, sampleRate: sampleRate,
                   duration: Double(written) / sampleRate,
                   overlapStart: overlapStart, overlapDuration: overlap,
                   outgoing: outgoingTimeline, incoming: incomingTimeline,
                   rideDB: rideDB, rideDBAtEnd: endRideDB,
                   rideReleaseSeconds: rideRelease,
                   stemApplied: stemApplied, stemFallbackReason: stemFallback,
                   lanesApplied: lanesApplied, scoreFallbackReason: scoreFallback)
    }

    // MARK: - Output normalization and write-out

    /// Scale the finished mix to `options.normalizeToLUFS`, peak-guarded.
    ///
    /// Product-irrelevant by construction: this happens after both decks are
    /// summed, so it cannot change the *shape* of a transition, only how loud
    /// the resulting file plays. It exists so two renders put side by side in a
    /// blind test are compared on their hand-over rather than on their level
    /// (§2.4 of the research notes; Sony normalized their stimuli to −23 dBFS
    /// for exactly this reason). The live player does none of this.
    private static func normalize(
        _ mix: inout [[Float]], options: Options
    ) -> (measuredLUFS: Double?, gainDB: Double) {
        guard let target = options.normalizeToLUFS, !mix.isEmpty, !mix[0].isEmpty else {
            return (nil, 0)
        }
        // Measure on the mono downmix, matching how `referenceLoudness` is
        // measured (LoudnessMeter counts a mono signal as a centred pair).
        var mono = mix[0]
        if mix.count > 1 {
            for channel in 1..<mix.count {
                for i in 0..<mono.count { mono[i] += mix[channel][i] }
            }
            let scale = Float(mix.count)
            for i in 0..<mono.count { mono[i] /= scale }
        }
        guard let measured = LoudnessMeter.integratedLUFS(mono, sampleRate: DeckChain.format.sampleRate)
        else { return (nil, 0) }

        var gainDB = target - measured
        // Sony's clip guard (`utils_data_normalization.py:79-80`), here as a
        // cap on the gain rather than a rescale after the fact — same result,
        // one pass.
        if let peak = LoudnessMeter.peakDBFS(mix.flatMap { $0 }) {
            gainDB = min(gainDB, options.normalizePeakCeilingDBFS - peak)
        }
        let gain = LoudnessCompensation.gain(fromDB: gainDB)
        guard abs(gain - 1) > 1e-6 else { return (measured, 0) }
        for channel in 0..<mix.count {
            var scale = gain
            vDSP_vsmul(mix[channel], 1, &scale, &mix[channel], 1, vDSP_Length(mix[channel].count))
        }
        return (measured, gainDB)
    }

    /// Write the accumulated mix out as the 16-bit WAV callers expect.
    private static func write(_ mix: [[Float]], to outputURL: URL,
                              format: AVAudioFormat, sampleRate: Double) throws {
        let writer = try AVAudioFile(forWriting: outputURL,
                                     settings: wavSettings(sampleRate: sampleRate),
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let frames = mix.first?.count, frames > 0 else { return }
        let chunkSize = 4096
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(chunkSize))
        else { throw RenderError.manualRenderingFailed }
        var offset = 0
        while offset < frames {
            let count = min(chunkSize, frames - offset)
            buffer.frameLength = AVAudioFrameCount(count)
            if let data = buffer.floatChannelData {
                for channel in 0..<Int(format.channelCount) {
                    let source = mix[min(channel, mix.count - 1)]
                    source.withUnsafeBufferPointer {
                        data[channel].update(from: $0.baseAddress! + offset, count: count)
                    }
                }
            }
            try writer.write(from: buffer)
            offset += count
        }
    }

    // MARK: - Offline deck

    /// One deck of the offline graph: the same nodes, in the same order, with
    /// the same neutral pose as a live `PlaybackEngine` deck.
    private final class OfflineDeck {
        let player = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        let eq = AVAudioUnitEQ(numberOfBands: DeckChain.bandCount)
        let delay = AVAudioUnitDelay()

        init(engine: AVAudioEngine, format: AVAudioFormat) {
            DeckChain.configureBands(eq)
            DeckChain.configureDelay(delay)
            engine.attach(player)
            engine.attach(timePitch)
            engine.attach(eq)
            engine.attach(delay)
        }

        func connect(engine: AVAudioEngine, format: AVAudioFormat) {
            engine.connect(player, to: timePitch, format: format)
            engine.connect(timePitch, to: eq, format: format)
            engine.connect(eq, to: delay, format: format)
            engine.connect(delay, to: engine.mainMixerNode, format: format)
        }

        func schedule(_ buffer: AVAudioPCMBuffer) {
            player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        }

        /// Loudness-compensation multiplier; see `PlaybackEngine.DeckState.trim`.
        var trim: Float = 1
        /// Transition gain ride multiplier, and the last level a caller asked
        /// the fader for — the same pair `PlaybackEngine.DeckState` keeps, so
        /// changing the ride between automation ticks re-writes the fader
        /// through the current curve value rather than clobbering it.
        var ride: Float = 1
        var faderRequest: Float = 1
        /// Bent-rate headroom pad; see `PlaybackEngine.DeckState.ratePad`. The
        /// third multiplier, and the render has to carry it or the audition
        /// A/B is a different signal path from the player.
        var ratePad: Float = 1
        /// How far this deck comes down while bent, in dB (≤ 0).
        var padCeilingDB: Double = 0

        /// The single fader writer, mirroring `PlaybackEngine.setFaderLocked`:
        /// callers speak in 0–1 and all three gains are folded in here.
        func setFader(_ value: Float) {
            faderRequest = value
            player.volume = value * trim * ride * ratePad
        }

        /// Move the ride and re-apply the fader through it.
        func setRide(db: Double) {
            ride = LoudnessCompensation.gain(fromDB: db)
            setFader(faderRequest)
        }

        /// Move the bent-rate pad and re-apply the fader through it.
        func setRatePad(db: Double) {
            ratePad = LoudnessCompensation.gain(fromDB: db)
            setFader(faderRequest)
        }

        func apply(_ p: TransitionAutomation.DeckParameters) {
            setFader(p.fader)
            DeckChain.apply(p, timePitch: timePitch, eq: eq, delay: delay)
        }
    }

    // MARK: - Source loading

    static func duration(of url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// Read `seconds` of `url` starting at `from` and hand it back in the deck
    /// graph's format — the offline equivalent of the live engine's FileFeeder
    /// (hi-res and mono files are converted, the graph is never reconfigured).
    private static func loadSegment(_ url: URL, from: TimeInterval, seconds: TimeInterval,
                                    format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        let startFrame = max(0, min(file.length,
                                    AVAudioFramePosition((from * source.sampleRate).rounded())))
        let available = file.length - startFrame
        let wanted = AVAudioFrameCount(max(0, min(Double(available),
                                                  (seconds * source.sampleRate).rounded())))
        guard wanted > 0 else { throw RenderError.emptySegment(url) }
        file.framePosition = startFrame
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: wanted) else {
            throw RenderError.emptySegment(url)
        }
        try file.read(into: input, frameCount: wanted)

        if source.sampleRate == format.sampleRate, source.channelCount == format.channelCount {
            return input
        }
        guard let converter = AVAudioConverter(from: source, to: format) else {
            throw RenderError.converterUnavailable(url)
        }
        let ratio = format.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw RenderError.converterUnavailable(url)
        }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed {
                status.pointee = .endOfStream
                return nil
            }
            fed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        guard output.frameLength > 0 else { throw RenderError.emptySegment(url) }
        return output
    }

    private static func wavSettings(sampleRate: Double) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }
}
