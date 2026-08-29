import AVFoundation
import Foundation

/// Renders a `TransitionSegment` ahead of the hand-over it belongs to.
///
/// This is glue, not DSP: the audio comes out of
/// `OfflineTransitionRenderer.renderMix` — the same graph, the same automation
/// curves and the same `StemTechniqueLayer` the audition console renders
/// through — and everything here does is choose the window, compile a
/// `.vocalExchange` marker into curves, and note where the two ends of the
/// result sit on the two songs' clocks.
///
/// Cost, on an M4: ~15 s of separation per side plus ~1 s of rendering for a
/// 15 s overlap. That is why the caller starts it a minute ahead and gives up
/// on it rather than waiting.
enum TransitionSegmentRenderer {

    /// How much of the outgoing track the segment duplicates before the out
    /// point, and how much of the incoming track it duplicates after the
    /// overlap has finished settling.
    ///
    /// Both exist for the same reason: the moment a deck is swapped for the
    /// segment (or back) cannot be made sample-exact by a timer, but *can* be
    /// made inaudible by having both sides carry the same audio at the same
    /// level for a moment and crossfading between them. Half a second is long
    /// enough to hide the engine's tick granularity and short enough that the
    /// extra material costs nothing to render.
    ///
    /// **Segments never carry a tempo ramp, by construction.** The head window
    /// is exactly the outgoing source span `[outPoint − handoff, outPoint]`,
    /// and `TransitionAutomation.tempoRamp` anchors every glide to *finish* at
    /// `outPoint − segmentHandoff` — the same instant. So the segment's whole
    /// pre-roll sits in the flat, fully-bent stretch, is rendered at a constant
    /// `outgoingRate`, and is byte-identical to what the deck is playing there.
    static let handoff: TimeInterval = TransitionAutomation.segmentHandoff

    /// Longest hand-over worth pre-rendering. Separation is ~1× realtime per
    /// side; an overlap beyond this would not finish inside the lead time the
    /// player gives it, and the live path is the better answer.
    static let maxOverlap: TimeInterval = 30

    struct Request: Sendable {
        var planned: PlannedTransition
        var outgoingURL: URL
        var incomingURL: URL
        /// The trims the two decks are (or will be) loaded at, so the segment
        /// is at exactly the level the decks it replaces would have played.
        var outgoingTrimDB: Double = 0
        var incomingTrimDB: Double = 0
        /// The outgoing track's analysis, needed only to compile a
        /// `.vocalExchange` marker. Without it the marker degrades to a duck.
        var outgoingAnalysis: TrackAnalysis?
        /// The incoming track's analysis. Only a `TransitionScore` needs it —
        /// the bar grid the score's non-negative bars are addressed on is the
        /// incoming track's. Without it a score cannot compile and the seam
        /// takes the live blend.
        var incomingAnalysis: TrackAnalysis?
        var config: TransitionPlanner.Config = .standard
    }

    enum SegmentError: LocalizedError {
        case noOverlap
        case overlapTooLong(TimeInterval)
        case nothingToRender
        case stemsNotApplied(String?)
        case scoreNotCompiled(String?)
        case scoreNotApplied(String?)
        case emptyRender

        var errorDescription: String? {
            switch self {
            case .noOverlap:
                return "a pre-rendered segment needs an overlap; this plan has none"
            case .overlapTooLong(let seconds):
                return String(format: "overlap of %.1fs is longer than the pre-render budget",
                              seconds)
            case .nothingToRender:
                return "this hand-over asks for neither a stem technique nor a score"
            case .stemsNotApplied(let reason):
                return reason ?? "the stem layer did not run"
            case .scoreNotCompiled(let reason):
                return reason ?? "the score could not be placed on the beat grid"
            case .scoreNotApplied(let reason):
                return reason ?? "the score's whole-mix lanes did not run"
            case .emptyRender:
                return "the pre-render produced no audio"
            }
        }
    }

    /// Render one hand-over into a segment. Blocking and slow — call it off the
    /// main thread, on a task the caller is willing to throw away.
    static func render(_ request: Request,
                       provider: @escaping VocalStemProvider) throws -> TransitionSegment {
        let planned = try compilingExchange(request)
        guard let signature = TransitionSegment.Signature(plan: planned.plan) else {
            throw SegmentError.noOverlap
        }
        let geometry = TransitionAutomation.Geometry(plan: planned.plan)
        guard geometry.overlapDuration > 0 else { throw SegmentError.noOverlap }
        guard geometry.overlapDuration <= maxOverlap else {
            throw SegmentError.overlapTooLong(geometry.overlapDuration)
        }
        // Admission, one notch wider than S3's: a segment is worth rendering for
        // a stem technique **or** for a score. A score-only segment separates
        // nothing at all — it is ~1 s of rendering and no Metal time — which is
        // why the runway it asks `PlayerService` for collapses to the margin.
        guard planned.style.stemTechnique != nil || planned.style.score != nil else {
            throw SegmentError.nothingToRender
        }

        var options = OfflineTransitionRenderer.Options()
        options.preRoll = handoff
        options.postRoll = handoff
        // The head window *is* the ramp's flat tail (see `handoff`), so the
        // renderer must not stretch the pre-roll back over the glide: that
        // would put audio the deck never plays into the identity crossfade.
        options.extendPreRollForTempoRamp = false
        options.outgoingTrimDB = request.outgoingTrimDB
        options.incomingTrimDB = request.incomingTrimDB
        options.rideDB = planned.rideDB
        // The two audition-only devices are off: nothing normalizes the live
        // signal path, and the ride's release is handed to the deck instead of
        // being rendered out in full (`Mix.rideDBAtEnd`).
        options.normalizeToLUFS = nil
        options.stretchPostRollForRideRelease = false
        options.vocalStemProvider = provider

        // `.score` is a marker too, and compiling it is the same job the
        // exchange's compile is: turn an intent into the curves the final
        // geometry actually implies. A score that will not place is refused
        // *here*, before a sample is rendered, so the seam takes the live blend
        // rather than a segment carrying half a gesture.
        if let score = planned.style.score {
            guard let outgoingAnalysis = request.outgoingAnalysis,
                  let incomingAnalysis = request.incomingAnalysis else {
                throw SegmentError.scoreNotCompiled(
                    "乐谱要按两侧的小节网格落点，这次转场手里没有分析。")
            }
            let compiled = ScoreCompiler.compile(
                score, planned: planned,
                outgoing: outgoingAnalysis, incoming: incomingAnalysis,
                outgoingURL: request.outgoingURL)
            guard let lanes = compiled.lanes else {
                throw SegmentError.scoreNotCompiled(compiled.refusalReason)
            }
            options.mixLanes = lanes
        }

        let mix = try OfflineTransitionRenderer.renderMix(
            planned, outgoing: request.outgoingURL, incoming: request.incomingURL,
            options: options)
        // A segment that fell back to a whole-mix render is not worth splicing:
        // it is the live path with extra steps, and the live path can also be
        // seeked, paused and re-planned.
        if planned.style.stemTechnique != nil {
            guard mix.stemApplied != nil else {
                throw SegmentError.stemsNotApplied(mix.stemFallbackReason)
            }
        }
        if planned.style.score != nil {
            guard mix.lanesApplied != nil else {
                throw SegmentError.scoreNotApplied(mix.scoreFallbackReason)
            }
        }
        guard let buffer = makeBuffer(mix) else { throw SegmentError.emptyRender }

        let duration = Double(buffer.frameLength) / mix.sampleRate
        // The engine's own midpoint rule, evaluated on the rendered timeline:
        // the overlap starts one handoff window in.
        let midpoint = mix.overlapStart + midpointOffset(planned: planned, geometry: geometry)
        return TransitionSegment(
            buffer: buffer, signature: signature, duration: duration,
            outgoingStart: mix.outgoing.first?.source ?? 0,
            handoffIn: mix.overlapStart,
            // The head window on the *song's* clock: the render started the
            // outgoing deck here and pumped until it reached the out point.
            handoffInSource: signature.outPoint - (mix.outgoing.first?.source ?? 0),
            handoffOut: handoff,
            midpointOffset: min(midpoint, duration),
            incomingRideDB: mix.rideDBAtEnd,
            outgoing: mix.outgoing, incoming: mix.incoming)
    }

    /// Seconds into the *overlap* where the audible hand-over lands — the same
    /// rule `TransitionAutomation.frame` latches `midpointReached` on.
    static func midpointOffset(planned: PlannedTransition,
                               geometry: TransitionAutomation.Geometry) -> TimeInterval {
        guard case .beatMatched(let p) = planned.plan else {
            return geometry.overlapDuration * 0.5
        }
        return planned.style.stagedEQ
            ? geometry.swapOffset
            : min(max(p.bassSwapOffset, 0.8), geometry.overlapDuration)
    }

    /// `.vocalExchange` is a marker, not a curve: it has to be compiled against
    /// the final geometry before anything can render it. This is the same call
    /// `Audition.decide` makes for the console, so the player and the tuning
    /// loop compile the same hand-over the same way.
    private static func compilingExchange(_ request: Request) throws -> PlannedTransition {
        let planned = request.planned
        guard planned.style.stemTechnique == .vocalExchange else { return planned }
        guard let analysis = request.outgoingAnalysis else {
            // No analysis, no contour and no lyric timing to aim at. The
            // planner's own degradation is a plain duck.
            var style = planned.style
            style.stemTechnique = .vocalDuck(
                depthDB: Float(-abs(request.config.stemDuckDepthDB)))
            return PlannedTransition(plan: planned.plan, style: style, rideDB: planned.rideDB)
        }
        let compiled = Audition.VocalExchange.compile(
            outgoingURL: request.outgoingURL, outgoing: analysis,
            planned: planned, config: request.config)
        var style = planned.style
        style.stemTechnique = compiled.technique
        return PlannedTransition(plan: planned.plan, style: style, rideDB: planned.rideDB)
    }

    private static func makeBuffer(_ mix: OfflineTransitionRenderer.Mix) -> AVAudioPCMBuffer? {
        let format = DeckChain.format
        guard let frames = mix.channels.first?.count, frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames)),
              let data = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<Int(format.channelCount) {
            let source = mix.channels[min(channel, mix.channels.count - 1)]
            source.withUnsafeBufferPointer {
                data[channel].update(from: $0.baseAddress!, count: min(frames, source.count))
            }
        }
        return buffer
    }
}
