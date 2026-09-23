#if os(macOS)
import AVFoundation
import Foundation

// The stem layer of a rendered transition.
//
// KumoneCore deliberately does not depend on StemKit (and therefore not on
// mlx-swift): separation is a macOS-only, model-backed, 60-seconds-of-budget
// concern, while this module is the shared playback core. So the renderer asks
// for a vocal stem through an injected closure and the host — the app's
// launcher, which does link StemKit — supplies one. Nothing here knows what a model is.

/// One window of one track, handed to a stem provider.
///
/// `samples` is the audio the renderer already decoded, deinterleaved and
/// converted to the deck graph's format; a provider must separate *those*
/// samples, not re-decode the file, so the stem lines up sample-for-sample.
/// `source`/`start`/`duration` are there purely as a cache key.
public struct VocalStemRequest: Sendable {
    public let source: URL
    /// Seconds into `source` where `samples` begins.
    public let start: TimeInterval
    public let duration: TimeInterval
    public let sampleRate: Double
    public let samples: [[Float]]
}

/// What a provider hands back: the vocal stem, per channel, the same shape as
/// the request's samples. The accompaniment is the residual `mixture - vocals`,
/// which the renderer computes itself.
public struct VocalStem: Sendable {
    public let channels: [[Float]]
    /// The provider served this from its own cache rather than separating.
    public let cached: Bool

    public init(channels: [[Float]], cached: Bool = false) {
        self.channels = channels
        self.cached = cached
    }
}

/// Separates the vocal out of a window of audio. Throwing is a normal outcome —
/// no model, no network, a cancelled run — and the renderer degrades to a
/// whole-mix transition, reporting why.
public typealias VocalStemProvider = @Sendable (VocalStemRequest) throws -> VocalStem

// MARK: - Four-lane separation

/// One separable part of a mix.
///
/// Named after the four-stem convention every separation model and evaluation
/// corpus agrees on, so that "what is in lane 2" has one answer everywhere.
public enum StemLane: String, Sendable, Hashable, CaseIterable, Codable {
    case vocals
    case drums
    case bass
    /// Everything else — guitars, keys, pads, strings: the harmonic furniture,
    /// and the part of a track that can actually clash in key with another one.
    ///
    /// **Defined as the residual `mixture − vocals − drums − bass`**, not as
    /// whatever the model's fourth head estimated. Every consumer here rebuilds
    /// a buffer as `Σ laneᵢ · gainᵢ(t)`, and the whole stem layer rests on that
    /// sum being the untouched mixture when the gains are unity — that is what
    /// lets an envelope compose with the fader, the EQ hand-over and the outro
    /// effect rather than compete with them. Four independent mask estimates do
    /// not partition their input; this does, sample for sample. Measured on the
    /// shipping checkpoint, the difference between the two definitions is
    /// −27 dB relative to the mixture, so the residual "other" is the model's
    /// "other" plus a quiet crumb of what the masks missed.
    case other
}

/// One window of one track, handed to a four-lane stem provider.
///
/// The same contract as ``VocalStemRequest`` — separate *these* samples, do not
/// re-decode the file — plus which lanes the caller is actually going to use.
public struct StemRequest: Sendable {
    public let source: URL
    /// Seconds into `source` where `samples` begins.
    public let start: TimeInterval
    public let duration: TimeInterval
    public let sampleRate: Double
    public let samples: [[Float]]
    /// Lanes the caller needs. A provider may return more; it must not return
    /// fewer.
    public let wanted: Set<StemLane>

    public init(source: URL, start: TimeInterval, duration: TimeInterval,
                sampleRate: Double, samples: [[Float]],
                wanted: Set<StemLane> = Set(StemLane.allCases)) {
        self.source = source
        self.start = start
        self.duration = duration
        self.sampleRate = sampleRate
        self.samples = samples
        self.wanted = wanted
    }
}

/// What a four-lane provider hands back: a partition of the request's samples.
public struct Stems: Sendable {
    public let lanes: [StemLane: [[Float]]]
    /// Every lane consulted came from the provider's cache rather than the model.
    public let cached: Bool

    public init(lanes: [StemLane: [[Float]]], cached: Bool = false) {
        self.lanes = lanes
        self.cached = cached
    }

    public subscript(lane: StemLane) -> [[Float]]? { lanes[lane] }
}

/// Splits a window into drums / bass / other / vocals.
///
/// **Deliberately a second provider rather than a generalisation of
/// ``VocalStemProvider``.** The two-stem path is the shipping one: it is four
/// times cheaper, its checkpoint downloads itself, and every technique in the
/// library except one runs on it. Widening the existing closure would have
/// meant touching every call site and every test to express "the same thing as
/// before", and would have left the fallback — no four-stem model, keep the
/// vocals model — as an emptier and emptier `Set<StemLane>` rather than as the
/// absence of a thing. So this sits beside it, nil is a supported state, and a
/// gesture that wants four lanes asks for them and degrades when the answer is
/// nil.
public typealias FullStemProvider = @Sendable (StemRequest) throws -> Stems

/// Applies a `StemTechnique` to the outgoing deck's source buffer.
///
/// The transformation is entirely *before* the deck chain: the buffer that goes
/// into the player is rebuilt as `accompaniment × gᵢ(t) + vocal × g᷎ᵥ(t)`, and
/// the fader / EQ / outro automation then plays over it unchanged. That is what
/// makes the techniques composable with `outroEffect` and `stagedEQ` instead of
/// competing with them.
///
/// The gain curves are the ones S1's Python prototype blind-tested
/// (`Scripts/stems-prototype/separate_and_mix.py`, `render_variants`), with the
/// prototype's crossfade factored out — there, `fo` was multiplied in by hand;
/// here it *is* the deck fader.
enum StemTechniqueLayer {

    struct Applied: Sendable {
        let technique: StemTechnique
        /// Wall-clock seconds the provider took (separation, or a cache read),
        /// summed over every side that was separated.
        let seconds: Double
        /// Every side that was consulted came back from the provider's cache.
        let cacheHit: Bool
        /// Source seconds of the outgoing track that were separated.
        let separatedSeconds: TimeInterval
        /// Vocal stem RMS over mixture RMS in the separated window — S1's
        /// `vocal_energy_ratio`. Near zero means the outgoing track's outro is
        /// instrumental, and every one of these techniques is then a no-op
        /// however correctly it ran. Worth saying out loud rather than
        /// leaving the listener to wonder why nothing changed.
        let vocalEnergyRatio: Double
        /// Source seconds of the *incoming* track that were separated — only a
        /// `.custom` envelope with a live incoming lane ever pays for this.
        var incomingSeparatedSeconds: TimeInterval? = nil
        /// Which decks were split, for the console's cost line.
        var separatedSides: [String] = ["出曲"]
        /// A gesture that was asked for and quietly came out smaller — today,
        /// only "the bed was not split because there is no four-stem model".
        /// Never silent: a listening note has to be able to say which of two
        /// gestures was actually heard.
        var degradation: String? = nil
    }

    enum StemError: LocalizedError {
        case noProvider
        case noOverlap
        case emptyWindow
        case uncompiledExchange
        case shapeMismatch(expectedChannels: Int, expectedFrames: Int,
                           gotChannels: Int, gotFrames: Int)

        var errorDescription: String? {
            switch self {
            case .noProvider:
                return "this renderer has no stem separator wired up"
            case .noOverlap:
                return "a stem technique needs an overlap; this plan has none"
            case .emptyWindow:
                return "the overlap window has no audio to separate"
            case .uncompiledExchange:
                return "vocalExchange 是一个模板标记，要先由 Audition.decide 读歌词编译成"
                    + " stemEnvelope 才能渲染"
            case .shapeMismatch(let ec, let ef, let gc, let gf):
                return "stem provider returned \(gc)×\(gf) samples, expected \(ec)×\(ef)"
            }
        }
    }

    /// One deck's overlap-time → source-time map, with no audio attached.
    ///
    /// Split out of `Side` because two callers need the arithmetic without
    /// having a buffer to hand: the score compiler places a grid position on
    /// the overlap clock before anything is loaded, and its inverse is how a
    /// downbeat in the incoming song's own timeline becomes "+7.31 s into the
    /// overlap". One copy of the map, so the compiler and the renderer cannot
    /// disagree about where a cut lands.
    struct SourceClock: Sendable, Equatable {
        /// Playback rate this deck runs at during the overlap.
        var rate: Double
        /// The deck's post-swap walk back to unity, when it has one.
        var glide: TransitionAutomation.IncomingGlide?

        /// Source seconds consumed in the first `elapsed` seconds of the overlap.
        func sourceAdvance(to elapsed: TimeInterval) -> TimeInterval {
            glide?.sourceAdvance(to: elapsed) ?? elapsed * rate
        }

        /// The inverse: the overlap-relative instant at which the deck is
        /// `source` seconds into its window.
        func overlapElapsed(atSource source: TimeInterval,
                            within limit: TimeInterval) -> TimeInterval {
            guard let glide else { return rate > 0 ? source / rate : 0 }
            return glide.overlapElapsed(atSource: source, within: limit)
        }
    }

    /// One deck's window, as the envelope path needs to see it.
    ///
    /// `overlapStartFrame` differs between the two by construction: the
    /// outgoing buffer carries the render's pre-roll ahead of the hand-over,
    /// while the incoming one is loaded *at* its in point and starts playing
    /// when the overlap does.
    struct Side {
        let buffer: AVAudioPCMBuffer
        let source: URL
        let windowStart: TimeInterval
        let overlapStartFrame: Int
        /// Playback rate this deck runs at during the overlap.
        let rate: Double
        /// The deck's post-swap walk back to unity, when it has one.
        ///
        /// **Why a scalar `rate` is not enough for the incoming deck any more.**
        /// Everything here maps overlap-relative time onto source frames, and
        /// under `TransitionAutomation.incomingGlide` that map is no longer
        /// `t × rate`: the deck holds the bend to the swap and then walks home.
        /// Treating the glide as a constant rate misplaces the far end of the
        /// window by the glide's integral — for a 15 s post-swap stretch at a
        /// 4 % bend, about 300 ms, which for a compiled `.vocalExchange` is the
        /// difference between the incoming voice entering on the line and
        /// entering over the end of the outgoing one. Nil — the default, and
        /// every unramped plan and every outgoing side — keeps the constant-rate
        /// arithmetic exactly as it was.
        var glide: TransitionAutomation.IncomingGlide? = nil

        /// This deck's overlap↔source map, without the audio.
        var clock: SourceClock { SourceClock(rate: rate, glide: glide) }

        /// Source seconds this deck consumes in the first `elapsed` seconds of
        /// the overlap.
        func sourceAdvance(to elapsed: TimeInterval) -> TimeInterval {
            clock.sourceAdvance(to: elapsed)
        }
    }

    /// S1's `highpass(x, 100.0)` on the acapella: keeps the floated vocal out
    /// of the incoming track's low end.
    static let acapellaHighPassHz: Double = 100

    /// How long the ducked / wiped vocal takes to reach its new level at the
    /// very top of the overlap. The prototype stepped straight to it; the deck
    /// here is fed one continuous buffer whose pre-roll is the untouched mix,
    /// so a short ramp keeps that seam a level move rather than a step.
    static let entryRampSeconds: TimeInterval = 0.04

    /// Ceiling on the acapella's fader compensation (see `envelopes`).
    static let acapellaGainCeiling: Float = 6

    // MARK: - Entry point

    /// Rewrite `buffer`'s overlap window in place.
    ///
    /// - Parameters:
    ///   - buffer: The outgoing deck's source buffer (pre-roll + overlap).
    ///   - source / windowStart: Where `buffer` came from, for the cache key.
    ///   - overlapStartFrame: Frame in `buffer` where the overlap begins.
    ///   - outgoingRate: Playback rate the outgoing deck runs at during the
    ///     overlap, so overlap time can be mapped onto source frames.
    static func apply(_ technique: StemTechnique,
                      to buffer: AVAudioPCMBuffer,
                      source: URL, windowStart: TimeInterval,
                      overlapStartFrame: Int,
                      plan: TransitionPlan, style: TransitionStyle,
                      geometry: TransitionAutomation.Geometry,
                      outgoingRate: Double,
                      provider: VocalStemProvider) throws -> Applied {
        let overlap = geometry.overlapDuration
        guard overlap > 0 else { throw StemError.noOverlap }
        switch technique {
        case .vocalExchange: throw StemError.uncompiledExchange
        case .custom: throw StemError.uncompiledExchange
        case .acapellaOver, .instrumentalOut, .vocalDuck: break
        }
        let side = Side(buffer: buffer, source: source, windowStart: windowStart,
                        overlapStartFrame: overlapStartFrame, rate: outgoingRate)
        let split = try separate(side, overlap: overlap, provider: provider)
        let sampleRate = buffer.format.sampleRate
        let channelCount = Int(buffer.format.channelCount)
        let data = buffer.floatChannelData!

        let gains = envelopes(technique, frames: split.count, sampleRate: sampleRate,
                              rate: split.rate,
                              plan: plan, style: style, geometry: geometry)

        for channel in 0..<channelCount {
            var vocal = split.vocal[channel]
            if case .acapellaOver = technique {
                vocal = zeroPhaseHighPass(vocal, cutoff: acapellaHighPassHz,
                                          sampleRate: sampleRate)
            }
            let pointer = data[channel] + split.start
            for i in 0..<split.count {
                // accompaniment = mixture − vocals, by construction.
                let accompaniment = pointer[i] - split.vocal[channel][i]
                pointer[i] = accompaniment * gains.accompaniment[i] + vocal[i] * gains.vocal[i]
            }
        }

        return Applied(technique: technique, seconds: split.seconds, cacheHit: split.cached,
                       separatedSeconds: Double(split.count) / sampleRate,
                       vocalEnergyRatio: split.vocalEnergyRatio)
    }

    // MARK: - Envelope entry point

    /// Apply a four-lane `StemEnvelope` across both decks' overlap windows.
    ///
    /// This is the general form the one-shot techniques above are special cases
    /// of, and the only path that ever splits the *incoming* track. A side
    /// whose two lanes are both pass-through is never separated at all — which
    /// is what keeps a one-sided orchestration as cheap as it always was
    /// (a separation pass is ~15 s of wall clock per side on an M4).
    static func apply(envelope: StemEnvelope,
                      outgoing: Side, incoming: Side,
                      geometry: TransitionAutomation.Geometry,
                      provider: VocalStemProvider,
                      fullProvider: FullStemProvider? = nil) throws -> Applied {
        let overlap = geometry.overlapDuration
        guard overlap > 0 else { throw StemError.noOverlap }
        try envelope.validate(overlap: overlap)

        var seconds = 0.0
        var cacheHits: [Bool] = []
        var sides: [String] = []
        var outgoingSeparated: TimeInterval = 0
        var incomingSeparated: TimeInterval?
        var ratio = 0.0
        var bedSplitNote: String?

        for (side, label, vocalLane, bedLane) in [
            (outgoing, "出曲", StemEnvelope.Lane.outgoingVocal, StemEnvelope.Lane.outgoingBed),
            (incoming, "入曲", StemEnvelope.Lane.incomingVocal, StemEnvelope.Lane.incomingBed),
        ] {
            let wantsBedSplit = label == "入曲" && envelope.hasIncomingBedSplit
            guard !envelope.isPassThrough(vocalLane) || !envelope.isPassThrough(bedLane)
                    || wantsBedSplit
            else { continue }
            // Four lanes only where a gesture asked for them *and* this machine
            // can produce them. Without the four-stem checkpoint the bed stays
            // one thing, the gesture still plays, and the note below says which
            // of the two was heard — a silently downgraded gesture is worse
            // than a refused one.
            let bedSplit = wantsBedSplit ? envelope.incomingBedSplit : nil
            let full = bedSplit != nil ? fullProvider : nil
            if wantsBedSplit {
                if full == nil {
                    bedSplitNote = "入曲伴奏没有拆成鼓/贝斯/其他：这台机器没有四轨模型，垫子整块进。"
                    PlaybackJournal.note("stem bed split unavailable, incoming bed plays whole")
                } else {
                    PlaybackJournal.note("stem bed split drums/bass/other on the incoming deck")
                }
            }
            let split = try separate(side, overlap: overlap, provider: provider,
                                     fullProvider: full)
            let sampleRate = side.buffer.format.sampleRate
            let channelCount = Int(side.buffer.format.channelCount)
            let data = side.buffer.floatChannelData!
            let gains = laneGains(envelope, vocal: vocalLane, bed: bedLane,
                                  frames: split.count, sampleRate: sampleRate,
                                  rate: split.rate, overlap: overlap, glide: split.glide,
                                  bedSplit: split.lanes == nil ? nil : bedSplit)
            for channel in 0..<channelCount {
                let pointer = data[channel] + split.start
                let vocal = split.vocal[channel]
                if let lanes = split.lanes, let sub = gains.bedSplit {
                    // The bed, three ways. `drums + bass + other` is the bed by
                    // construction, so at unity sub-gains this is the line
                    // below, arithmetic order included.
                    let drums = lanes[.drums]?[channel] ?? []
                    let bass = lanes[.bass]?[channel] ?? []
                    let other = lanes[.other]?[channel] ?? []
                    for i in 0..<split.count {
                        let bed = drums[i] * sub.drums[i] + bass[i] * sub.bass[i]
                            + other[i] * sub.other[i]
                        pointer[i] = bed * gains.bed[i] + vocal[i] * gains.vocal[i]
                    }
                } else {
                    for i in 0..<split.count {
                        let bed = pointer[i] - vocal[i]
                        pointer[i] = bed * gains.bed[i] + vocal[i] * gains.vocal[i]
                    }
                }
            }
            seconds += split.seconds
            cacheHits.append(split.cached)
            sides.append(label)
            let separated = Double(split.count) / sampleRate
            if label == "出曲" {
                outgoingSeparated = separated
                ratio = split.vocalEnergyRatio
            } else {
                incomingSeparated = separated
                if sides.count == 1 { ratio = split.vocalEnergyRatio }
            }
        }

        return Applied(technique: .custom(envelope), seconds: seconds,
                       cacheHit: !cacheHits.isEmpty && cacheHits.allSatisfy { $0 },
                       separatedSeconds: outgoingSeparated,
                       vocalEnergyRatio: ratio,
                       incomingSeparatedSeconds: incomingSeparated,
                       separatedSides: sides,
                       degradation: bedSplitNote)
    }

    // MARK: - Separation

    /// One side's overlap window, split into mixture and vocal.
    private struct Separated {
        let vocal: [[Float]]
        /// The full partition, when a four-lane provider was consulted. Nil is
        /// the two-stem case, where the bed is `mixture − vocal` and never
        /// materialised.
        var lanes: [StemLane: [[Float]]]? = nil
        let start: Int
        let count: Int
        let rate: Double
        let glide: TransitionAutomation.IncomingGlide?
        let seconds: Double
        let cached: Bool
        let vocalEnergyRatio: Double
    }

    private static func separate(_ side: Side, overlap: TimeInterval,
                                 provider: VocalStemProvider,
                                 fullProvider: FullStemProvider? = nil) throws -> Separated {
        guard let data = side.buffer.floatChannelData else { throw StemError.emptyWindow }
        let sampleRate = side.buffer.format.sampleRate
        let channelCount = Int(side.buffer.format.channelCount)
        let rate = max(0.5, min(2, side.rate))
        let start = max(0, min(Int(side.buffer.frameLength), side.overlapStartFrame))
        // How many source seconds the overlap consumes: `overlap × rate` at a
        // constant rate, the glide's integral when the deck walks back to unity
        // partway through. Anything the buffer is short by simply is not
        // separated (it is past the file end).
        // (`rate` is the clamped local, so the no-glide arithmetic is exactly
        // what it was.)
        let wanted = Int(((side.glide?.sourceAdvance(to: overlap) ?? overlap * rate)
                          * sampleRate).rounded())
        let count = min(wanted, Int(side.buffer.frameLength) - start)
        guard count > 0 else { throw StemError.emptyWindow }

        let window = (0..<channelCount).map { channel in
            Array(UnsafeBufferPointer(start: data[channel] + start, count: count))
        }

        let began = Date()
        let windowStart = side.windowStart + Double(start) / sampleRate
        let duration = Double(count) / sampleRate
        var lanes: [StemLane: [[Float]]]?
        let stem: VocalStem
        if let fullProvider {
            let stems = try fullProvider(StemRequest(
                source: side.source, start: windowStart, duration: duration,
                sampleRate: sampleRate, samples: window))
            for lane in StemLane.allCases {
                guard let channels = stems[lane], channels.count == channelCount,
                      channels.allSatisfy({ $0.count == count }) else {
                    throw StemError.shapeMismatch(
                        expectedChannels: channelCount, expectedFrames: count,
                        gotChannels: stems[lane]?.count ?? 0,
                        gotFrames: stems[lane]?.first?.count ?? 0)
                }
            }
            lanes = stems.lanes
            stem = VocalStem(channels: stems[.vocals]!, cached: stems.cached)
        } else {
            stem = try provider(VocalStemRequest(
                source: side.source, start: windowStart, duration: duration,
                sampleRate: sampleRate, samples: window))
        }
        let seconds = Date().timeIntervalSince(began)

        guard stem.channels.count == channelCount,
              stem.channels.allSatisfy({ $0.count == count }) else {
            throw StemError.shapeMismatch(
                expectedChannels: channelCount, expectedFrames: count,
                gotChannels: stem.channels.count,
                gotFrames: stem.channels.first?.count ?? 0)
        }

        func rootMeanSquare(_ channels: [[Float]]) -> Double {
            var total = 0.0, n = 0
            for channel in channels {
                for sample in channel { total += Double(sample) * Double(sample) }
                n += channel.count
            }
            return n > 0 ? (total / Double(n)).squareRoot() : 0
        }
        let mixtureRMS = rootMeanSquare(window)
        let ratio = mixtureRMS > 0 ? rootMeanSquare(stem.channels) / mixtureRMS : 0

        return Separated(vocal: stem.channels, lanes: lanes,
                         start: start, count: count, rate: rate,
                         glide: side.glide,
                         seconds: seconds, cached: stem.cached, vocalEnergyRatio: ratio)
    }

    /// Per-sample gains for one side's two lanes, evaluated on the automation's
    /// own 50 Hz control grid and interpolated — the same shape (and the same
    /// cost) as `envelopes` above.
    ///
    /// `glide` is the deck's post-swap walk back to unity, when it has one: the
    /// lanes are written in overlap-relative seconds and applied to source
    /// frames, and under a glide that map is the integral of a moving rate
    /// rather than a straight line. Nil is the constant-rate arithmetic this
    /// always did, unchanged down to the arithmetic order.
    static func laneGains(_ envelope: StemEnvelope,
                          vocal vocalLane: StemEnvelope.Lane,
                          bed bedLane: StemEnvelope.Lane,
                          frames: Int, sampleRate: Double, rate: Double,
                          overlap: TimeInterval,
                          glide: TransitionAutomation.IncomingGlide? = nil,
                          bedSplit: StemEnvelope.BedSplit? = nil)
        -> (vocal: [Float], bed: [Float],
            bedSplit: (drums: [Float], bass: [Float], other: [Float])?) {
        let controlHz = 50.0
        let elapsedPerFrame = 1 / (sampleRate * rate)
        let points = max(2, Int((overlap * controlHz).rounded()) + 2)
        var controlVocal = [Float](repeating: 1, count: points)
        var controlBed = [Float](repeating: 1, count: points)
        // Three more control curves when the bed is orchestrated as drums /
        // bass / other, on the same grid so they interpolate identically.
        var controlSub: [StemLane: [Float]] = [:]
        if let bedSplit {
            for lane in StemEnvelope.BedSplit.lanes {
                controlSub[lane] = (0..<points).map {
                    bedSplit.gain(lane, at: min(overlap, Double($0) / controlHz))
                }
            }
        }
        for k in 0..<points {
            let elapsed = min(overlap, Double(k) / controlHz)
            controlVocal[k] = envelope.gain(vocalLane, at: elapsed)
            controlBed[k] = envelope.gain(bedLane, at: elapsed)
        }

        // Where each control point sits on the *source* clock, when the source
        // clock is not linear in overlap time. Inverted by a monotone cursor
        // walk rather than per-frame bisection: both sequences increase, so one
        // pass over the frames costs what the straight-line version did.
        var controlSource: [Double] = []
        if let glide {
            controlSource = (0..<points).map {
                glide.sourceAdvance(to: Double($0) / controlHz)
            }
        }
        var cursor = 0

        var vocal = [Float](repeating: 1, count: frames)
        var bed = [Float](repeating: 1, count: frames)
        var sub: [StemLane: [Float]] = controlSub.isEmpty ? [:] : Dictionary(
            uniqueKeysWithValues: StemEnvelope.BedSplit.lanes.map {
                ($0, [Float](repeating: 1, count: frames))
            })
        for i in 0..<frames {
            let position: Double
            if glide != nil {
                let source = Double(i) / sampleRate
                while cursor + 1 < points, controlSource[cursor + 1] <= source { cursor += 1 }
                let span = cursor + 1 < points
                    ? controlSource[cursor + 1] - controlSource[cursor] : 0
                position = Double(cursor) + (span > 0
                                             ? (source - controlSource[cursor]) / span : 0)
            } else {
                position = Double(i) * elapsedPerFrame * controlHz
            }
            let lower = min(points - 1, Int(position))
            let upper = min(points - 1, lower + 1)
            let fraction = Float(position - Double(lower))
            vocal[i] = controlVocal[lower]
                + (controlVocal[upper] - controlVocal[lower]) * fraction
            bed[i] = controlBed[lower] + (controlBed[upper] - controlBed[lower]) * fraction
            for lane in StemEnvelope.BedSplit.lanes where !controlSub.isEmpty {
                let curve = controlSub[lane]!
                sub[lane]![i] = curve[lower] + (curve[upper] - curve[lower]) * fraction
            }
        }
        guard !sub.isEmpty else { return (vocal, bed, nil) }
        return (vocal, bed, (drums: sub[.drums]!, bass: sub[.bass]!, other: sub[.other]!))
    }

    // MARK: - Gain curves

    /// Per-sample gains for the two stems across the overlap window.
    ///
    /// Evaluated on the automation's own 50 Hz control grid and interpolated,
    /// so a 12-second overlap costs ~600 curve evaluations rather than 600 000
    /// — and so the `.acapellaOver` compensation reads the *actual* outgoing
    /// fader rather than assuming a fade law.
    static func envelopes(_ technique: StemTechnique, frames: Int,
                          sampleRate: Double, rate: Double,
                          plan: TransitionPlan, style: TransitionStyle,
                          geometry: TransitionAutomation.Geometry)
        -> (vocal: [Float], accompaniment: [Float]) {
        let overlap = geometry.overlapDuration
        let controlHz = 50.0
        // Source frames → overlap-elapsed seconds: the deck plays this window
        // at `rate`, so one source second lasts 1/rate overlap seconds.
        let elapsedPerFrame = 1 / (sampleRate * rate)
        let points = max(2, Int((overlap * controlHz).rounded()) + 2)
        var controlVocal = [Float](repeating: 1, count: points)
        var controlAccompaniment = [Float](repeating: 1, count: points)

        for k in 0..<points {
            let elapsed = min(overlap, Double(k) / controlHz)
            let t = overlap > 0 ? min(1, elapsed / overlap) : 1
            // A short entry ramp measured in real overlap seconds, expressed as
            // a fraction so it composes with the fraction-based curves below.
            let entry = min(0.5, entryRampSeconds / max(overlap, 1e-6))

            switch technique {
            case .vocalDuck(let depthDB):
                let target = LoudnessCompensation.linearGain(depthDB)
                controlVocal[k] = raisedCosine(t, 0, entry, 1, target)
                controlAccompaniment[k] = 1

            case .instrumentalOut:
                // S1: `o_ov_voc * ramp(n, 0.0, 0.12, 1.0, 0.0)`.
                controlVocal[k] = raisedCosine(t, 0, 0.12, 1, 0)
                controlAccompaniment[k] = 1

            case .acapellaOver:
                // S1: instrumental gone by 28 % of the overlap, the vocal held
                // at unity until 72 % and retired by 96 %.
                controlAccompaniment[k] = raisedCosine(t, 0, 0.28, 1, 0)
                let hold = raisedCosine(t, 0.72, 0.96, 1, 0)
                // The prototype exempted the acapella from the outgoing
                // crossfade — that exemption *is* the technique, and it is the
                // one thing the stem layer cannot express by leaving the
                // automation alone. So divide the fader back out, capped, and
                // let everything else (EQ hand-over, outro effect) still apply.
                let fader = TransitionAutomation.frame(
                    plan: plan, style: style, elapsed: elapsed, geometry: geometry).outgoing.fader
                let compensation = min(acapellaGainCeiling, 1 / max(fader, 1e-3))
                controlVocal[k] = hold * compensation

            case .vocalExchange, .custom:
                // Not gestures: `.vocalExchange` is a marker `Audition.decide`
                // compiles away, and `.custom` runs through `laneGains`. The
                // `apply` above refuses both before reaching here; leaving the
                // lanes at unity keeps this switch total without inventing a
                // curve nobody asked for.
                break
            }
        }

        var vocal = [Float](repeating: 1, count: frames)
        var accompaniment = [Float](repeating: 1, count: frames)
        for i in 0..<frames {
            let position = Double(i) * elapsedPerFrame * controlHz
            let lower = min(points - 1, Int(position))
            let upper = min(points - 1, lower + 1)
            let fraction = Float(position - Double(lower))
            vocal[i] = controlVocal[lower]
                + (controlVocal[upper] - controlVocal[lower]) * fraction
            accompaniment[i] = controlAccompaniment[lower]
                + (controlAccompaniment[upper] - controlAccompaniment[lower]) * fraction
        }
        return (vocal, accompaniment)
    }

    /// S1's `ramp()`: `v0` up to `t0`, raised-cosine to `v1` by `t1`.
    static func raisedCosine(_ t: Double, _ t0: Double, _ t1: Double,
                             _ v0: Float, _ v1: Float) -> Float {
        let u = min(1, max(0, (t - t0) / max(t1 - t0, 1e-9)))
        let s = Float(0.5 - 0.5 * cos(.pi * u))
        return v0 + (v1 - v0) * s
    }

    // MARK: - Filtering

    /// Zero-phase 2nd-order Butterworth high-pass — the Swift counterpart of
    /// the prototype's `sosfiltfilt`. Running the biquad forwards and then
    /// backwards cancels its phase response, which matters here because the
    /// filtered vocal is summed back against an unfiltered accompaniment.
    static func zeroPhaseHighPass(_ input: [Float], cutoff: Double,
                                  sampleRate: Double) -> [Float] {
        guard input.count > 4, cutoff > 0, cutoff < sampleRate / 2 else { return input }
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let cosW0 = cos(w0)
        let alpha = sin(w0) / (2 * (1 / 2.0.squareRoot()))  // Butterworth Q = 1/√2
        let a0 = 1 + alpha
        let b0 = Float((1 + cosW0) / 2 / a0)
        let b1 = Float(-(1 + cosW0) / a0)
        let b2 = b0
        let a1 = Float(-2 * cosW0 / a0)
        let a2 = Float((1 - alpha) / a0)

        func biquad(_ x: [Float]) -> [Float] {
            var y = [Float](repeating: 0, count: x.count)
            // Seed the state with the first sample so the filter does not
            // start from a step at the window edge.
            var x1 = x[0], x2 = x[0], y1: Float = 0, y2: Float = 0
            for i in 0..<x.count {
                let out = b0 * x[i] + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                x2 = x1; x1 = x[i]
                y2 = y1; y1 = out
                y[i] = out
            }
            return y
        }
        return biquad(biquad(input).reversed().map { $0 }).reversed().map { $0 }
    }
}
#endif
