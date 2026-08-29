#if os(macOS)
import Foundation
import KumoneCore
import StemKit

// The app's half of the stem wiring. KumoneCore stays MLX-free: it asks for a
// vocal stem through a closure, and this is where that closure comes from.
//
// Installing one is what turns AutoMix's stem techniques from an EQ
// approximation into real separated audio (`TransitionSegmentRenderer`). Not
// installing one — no checkpoint on disk, no `mlx.metallib`, not macOS — is the
// shipping default and leaves every playback path exactly as it was.
enum StemSetup {

    static func install() {
        guard ResidentStemSeparator.isRunnable() else { return }
        StemSeparation.install(VocalStemCache.caching { request in
            try ResidentStemSeparator.shared.vocals(samples: request.samples,
                                                    sampleRate: request.sampleRate)
        })
    }
}
#endif
