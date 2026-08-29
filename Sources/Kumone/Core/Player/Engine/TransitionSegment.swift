import AVFoundation
import Foundation

/// A hand-over that has already been rendered, waiting to be spliced into
/// playback in place of the live two-deck overlap.
///
/// Stem techniques cannot be performed by the live graph: separating a vocal
/// costs seconds per window and the deck chain has nowhere to put the result.
/// So a hand-over that asks for one is rendered ahead of time by the very code
/// the audition renderer uses (`OfflineTransitionRenderer.renderMix`, stem
/// layer included), and the engine plays *that* instead — the outgoing deck
/// stops at the segment's head, the incoming deck resumes at its tail, and in
/// between there is one pre-mixed buffer carrying both tracks.
///
/// Everything the splice needs is here and nothing else: the buffer, where its
/// two ends sit on the two songs' own clocks, and the two short windows at
/// either end where the segment duplicates a deck so the swap can be
/// crossfaded rather than cut.
struct TransitionSegment: @unchecked Sendable {

    /// Which hand-over this segment was rendered for.
    ///
    /// A plan can be re-resolved between the pre-render starting and the splice
    /// (a seek degrades it, a late analysis upgrades it), and a segment
    /// rendered for the old geometry would splice audio from the wrong place.
    /// So the engine checks identity before it plays one.
    struct Signature: Equatable, Sendable {
        var outPoint: TimeInterval
        var inPoint: TimeInterval
        var overlapDuration: TimeInterval

        /// Nil for `.gapless`, which has no overlap and therefore no segment.
        init?(plan: TransitionPlan) {
            switch plan {
            case .beatMatched(let p):
                outPoint = p.outPoint
                inPoint = p.inPoint
                overlapDuration = p.overlapDuration
            case .crossfade(let duration, let out, let point):
                outPoint = out
                inPoint = point
                overlapDuration = duration
            case .gapless:
                return nil
            }
        }

        /// Plans are compared with a millisecond of slack: they are carried
        /// around as seconds and rebuilt by value, not by identity.
        static func == (lhs: Signature, rhs: Signature) -> Bool {
            abs(lhs.outPoint - rhs.outPoint) < 0.001
                && abs(lhs.inPoint - rhs.inPoint) < 0.001
                && abs(lhs.overlapDuration - rhs.overlapDuration) < 0.001
        }
    }

    /// The rendered audio, at `DeckChain.format`. Immutable from construction:
    /// it is built on the pre-render task and only ever read afterwards, which
    /// is what makes the `@unchecked Sendable` above honest.
    let buffer: AVAudioPCMBuffer
    let signature: Signature
    let duration: TimeInterval

    /// Outgoing-track position of the segment's first sample.
    let outgoingStart: TimeInterval
    /// Head window: the segment opens with this many seconds of the outgoing
    /// track exactly as the deck is playing it, so the deck can be crossfaded
    /// out over identical material instead of cut.
    let handoffIn: TimeInterval
    /// The same head window measured on the **outgoing track's own clock**
    /// rather than the segment's.
    ///
    /// The two are the same number whenever the deck plays that window at rate
    /// 1 — every plan without a tempo ramp, which is why one field used to do
    /// both jobs. Under a ramp the deck is already bent to `outgoingRate`
    /// there, so the same audio is a *shorter* stretch of the song than it is
    /// of the segment, and `spliceStart` — a position on the song — has to be
    /// measured in these. Nil, the default, means "the same", which is what
    /// every unramped segment is.
    var handoffInSource: TimeInterval? = nil
    /// Tail window: the segment closes with this many seconds of the incoming
    /// track exactly as the deck will play it, for the same reason.
    let handoffOut: TimeInterval
    /// Seconds into the segment where the audible hand-over lands — where the
    /// live engine would have emitted `transitionMidpoint`.
    let midpointOffset: TimeInterval
    /// The incoming deck's gain ride, in dB, where the segment hands over. The
    /// release is still running there; the deck picks it up and finishes it.
    let incomingRideDB: Double

    /// Rendered-time → source-time maps for the two decks, from the render.
    let outgoing: [OfflineTransitionRenderer.TimelinePoint]
    let incoming: [OfflineTransitionRenderer.TimelinePoint]

    /// Head window measured on the outgoing song, which is what every position
    /// comparison against a deck's playhead needs.
    var headSourceSpan: TimeInterval { handoffInSource ?? handoffIn }

    /// Outgoing-track position where the segment takes over from the deck —
    /// one head window before the plan's out point, by construction.
    var spliceStart: TimeInterval { signature.outPoint - headSourceSpan }

    /// Seconds into the segment where the incoming deck takes over.
    var handoffOutStart: TimeInterval { max(0, duration - handoffOut) }

    /// Outgoing-track position the segment is playing at `offset`.
    func outgoingTime(at offset: TimeInterval) -> TimeInterval {
        OfflineTransitionRenderer.Mix.source(of: outgoing, at: offset)
    }

    /// Incoming-track position the segment is playing at `offset`.
    func incomingTime(at offset: TimeInterval) -> TimeInterval {
        OfflineTransitionRenderer.Mix.source(of: incoming, at: offset)
    }

    /// Where the incoming deck is cued to when it takes over.
    var incomingResume: TimeInterval { incomingTime(at: handoffOutStart) }
}
