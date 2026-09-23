import Foundation

/// One separable part of a mix.
///
/// The names are the four-stem convention every separation model and every
/// evaluation corpus (MUSDB18 and everything trained on it) agrees on, so a
/// checkpoint's output order can be written down as `[StemLane]` and nothing
/// else has to know what the model called its channels.
///
/// ``other`` is deliberately *last* and deliberately special: for Kumone it is
/// never read out of the model, it is the residual `mixture − vocals − drums −
/// bass`. See ``SeparatedStems`` for why.
public enum StemLane: String, Sendable, Hashable, CaseIterable, Codable {
    case vocals
    case drums
    case bass
    /// Everything else: guitars, keys, pads, synths, strings — the harmonic
    /// furniture of the track.
    case other
}

extension Array where Element == StemLane {
    /// A single-stem vocals checkpoint's output order.
    public static var vocalsOnly: [StemLane] { [.vocals] }

    /// The four-stem order used by every Mel-Band RoFormer / BS-RoFormer
    /// multi-stem checkpoint trained on MUSDB18, and by Demucs before them.
    public static var fourStem: [StemLane] { [.vocals, .drums, .bass, .other] }
}
