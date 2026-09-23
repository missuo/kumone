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
        // "Why is the player holding 1.1 GB?" has, until now, been answerable
        // only by attaching `vmmap` to a running app. The MLX buffer pool is
        // half of that number and it is now dropped after every window, so the
        // journal says so — one line per trim, with the megabytes.
        StemSeparator.onCacheTrim = { StemSeparation.note($0) }
        // The four-lane separator is installed only when its checkpoint is
        // already on disk. It is not auto-downloaded (upstream ships a PyTorch
        // pickle; see `Scripts/fetch-4stem-checkpoint.sh`), so the common case
        // is nil and every four-lane gesture plays its two-lane form.
        let full: KumoneCore.FullStemProvider? = ResidentStemSeparator.hasFourStem()
            ? VocalStemCache.cachingFull { request in
                var lanes: [KumoneCore.StemLane: [[Float]]] = [:]
                for (lane, channels) in try ResidentStemSeparator.shared.stems(
                    samples: request.samples, sampleRate: request.sampleRate) {
                    lanes[KumoneCore.StemLane(rawValue: lane.rawValue)!] = channels
                }
                return lanes
            }
            : nil

        StemSeparation.install(VocalStemCache.caching { request in
            try ResidentStemSeparator.shared.vocals(samples: request.samples,
                                                    sampleRate: request.sampleRate)
        }, full: full)
    }
}
#endif
