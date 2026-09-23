#if os(macOS)
import Foundation

// Two things the analysis and planning code kept re-spelling, in one place.

/// Clamp to 0...1. A non-finite input lands at 0, which is what
/// `min(1, max(0, v))` has always produced for a NaN and what every caller
/// here was written against.
func clamp01(_ v: Double) -> Double { Swift.min(1, Swift.max(0, v)) }

/// Where an FNV-1a digest starts, for a caller that folds its bytes in by
/// parts rather than handing over one sequence.
let fnv1aOffsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325

/// FNV-1a over a byte sequence, resumable.
///
/// Deliberately *not* `Hashable`'s seeded hash: that value changes from one
/// process to the next, so a render cache or a feedback corpus keyed on it
/// could never be joined across runs. The constants are the published 64-bit
/// FNV-1a ones and must not be touched — every render filename and every
/// fingerprint already written to disk depends on them.
///
/// - Parameters:
///   - bytes: The bytes to fold in, in order.
///   - hash: The running value to continue from. Omit it to start fresh.
func fnv1a<Bytes: Sequence>(_ bytes: Bytes, from hash: UInt64 = fnv1aOffsetBasis) -> UInt64
where Bytes.Element == UInt8 {
    var hash = hash
    for byte in bytes {
        hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
    }
    return hash
}

/// One byte's worth of the above — the separator a structured digest folds in
/// between its parts.
func fnv1a(_ byte: UInt8, from hash: UInt64) -> UInt64 {
    (hash ^ UInt64(byte)) &* 0x100_0000_01b3
}

/// The eight bytes of `value`, least-significant first, folded in — the byte
/// order the shift-and-mask loop this replaced produced.
func fnv1a(littleEndian value: UInt64, from hash: UInt64) -> UInt64 {
    withUnsafeBytes(of: value.littleEndian) { fnv1a($0, from: hash) }
}
#endif
