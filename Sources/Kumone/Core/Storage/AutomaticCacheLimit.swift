import Foundation

/// The song cache limit when the listener leaves sizing to the app: a tenth
/// of what the volume could hold for it, between two and thirty gigabytes,
/// so a phone with plenty of room caches generously and a full one does not.
enum AutomaticCacheLimit {
    static let minimumMB = 2_000
    static let maximumMB = 30_000

    static func megabytes(freeBytes: Int64, cacheBytes: Int64) -> Int {
        // Cache usage is added back so filling the cache never shrinks its own allowance.
        let recoverable = max(0, freeBytes) + max(0, cacheBytes)
        return Int(min(Int64(maximumMB), max(Int64(minimumMB), recoverable / 10 / 1_000_000)))
    }

    static func freeBytes() -> Int64 {
        let volume = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let values = try? volume.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? Int64(values?.volumeAvailableCapacity ?? 0)
    }
}

extension SettingsManager {
    /// The limit the song cache is held to right now.
    func effectiveAudioCacheSizeMB() async -> Int {
        guard audioCacheAutomatic else { return audioCacheSizeMB }
        let used = (try? await AudioCache.shared.usage().bytes) ?? 0
        return AutomaticCacheLimit.megabytes(freeBytes: AutomaticCacheLimit.freeBytes(), cacheBytes: used)
    }
}
