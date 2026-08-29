#if os(macOS)
import AVFoundation
import Foundation
import KumoneCore
import StemKit

// The `audition` side of the stem layer: hold one warm separator, cache what it
// produces next to the corpus, and hand `OfflineTransitionRenderer` a plain
// closure. KumoneCore never learns that MLX exists.
//
// Two costs shape this file:
//   - loading + warming the 64 MiB checkpoint is a one-off several seconds, so
//     the separator is process-resident and prepared at most once;
//   - separating a 12-second overlap window is ~6 s on an M4, so the result is
//     written to a sidecar and a re-render of the same window is instant.
final class StemService: @unchecked Sendable {

    static let shared = StemService()

    /// The sidecar cache itself lives in KumoneCore (`VocalStemCache`), so the
    /// app's pre-render path and this console share both the file layout and
    /// the files: a window either has separated for is instant for the other.
    static let cacheVersion = VocalStemCache.version
    static let cacheMarker = VocalStemCache.marker

    static func isStemSidecar(_ url: URL) -> Bool { VocalStemCache.isSidecar(url) }

    /// What the renderer takes: `(window) throws -> vocal stem`.
    var provider: VocalStemProvider {
        VocalStemCache.caching { request in
            try ResidentStemSeparator.shared.vocals(samples: request.samples,
                                                    sampleRate: request.sampleRate)
        }
    }

    /// Report a stage change (`"separating"` / `"rendering"`) — the console
    /// wires its polling progress line to this.
    static func stageReporting(_ base: @escaping VocalStemProvider,
                               onSeparating: @escaping @Sendable (Bool) -> Void)
        -> VocalStemProvider {
        { request in
            onSeparating(true)
            defer { onSeparating(false) }
            return try base(request)
        }
    }
}
#endif
