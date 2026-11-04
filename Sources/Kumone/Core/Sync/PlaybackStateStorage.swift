import Foundation
import os

/// Keep the newest pending snapshot per file. A short coalescing window avoids
/// encoding intermediate seeks; the serial writer preserves in-flight ordering.
enum PlaybackStateStorage {
    private static let queue = DispatchQueue(label: "sb.moe.kumone.playback-state", qos: .utility)
    private static let log = Logger(subsystem: "sb.moe.kumone", category: "playback-state")
    private struct Pending {
        var snapshots: [URL: () throws -> Data] = [:]
        var scheduled = false
    }
    private static let pending = OSAllocatedUnfairLock(initialState: Pending())

    static func save<T: Encodable>(_ state: T, to url: URL) {
        let schedule = pending.withLock {
            $0.snapshots[url] = { try JSONEncoder().encode(state) }
            guard !$0.scheduled else { return false }
            $0.scheduled = true
            return true
        }
        if schedule {
            queue.asyncAfter(deadline: .now() + .milliseconds(150)) { writePending() }
        }
    }

    private static func writePending() {
        let snapshots = pending.withLock {
            let snapshots = $0.snapshots
            $0.snapshots.removeAll(keepingCapacity: true)
            $0.scheduled = false
            return snapshots
        }
        for (url, encode) in snapshots {
            do {
                try encode().write(to: url, options: .atomic)
            } catch {
                log.error("Playback checkpoint write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Finish queued local writes before normal application termination.
    static func flush() {
        queue.sync { writePending() }
    }
}
