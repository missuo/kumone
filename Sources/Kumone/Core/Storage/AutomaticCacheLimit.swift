import Foundation

/// The song cache limit when the listener leaves sizing to the app: a tenth
/// of what the volume could hold for it, between two and thirty gigabytes,
/// and never into the last gigabyte of the disk.
enum AutomaticCacheLimit {
    static let minimumMB = 2_000
    static let maximumMB = 30_000
    /// Space the cache never eats into, so the device keeps working.
    static let reserveBytes: Int64 = 1_000_000_000
    /// How long a computed limit is trusted before free space is read again.
    static let refreshInterval: TimeInterval = 600

    static func megabytes(freeBytes: Int64, cacheBytes: Int64) -> Int {
        // Cache usage is added back so filling the cache never shrinks its own allowance.
        let recoverable = max(0, freeBytes) + max(0, cacheBytes)
        let allowance = max(0, recoverable - reserveBytes) / 1_000_000
        let wanted = min(Int64(maximumMB), max(Int64(minimumMB), recoverable / 10 / 1_000_000))
        return Int(min(wanted, allowance))
    }

    static func freeBytes() -> Int64 {
        let volume = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let values = try? volume.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? Int64(values?.volumeAvailableCapacity ?? 0)
    }
}

extension SettingsManager {
    /// The automatic limit last computed, so starting a song does not scan
    /// the cache every time.
    @MainActor private static var automaticLimit: (megabytes: Int, at: Date)?

    /// The limit the song cache is held to right now.
    func effectiveAudioCacheSizeMB(refresh: Bool = false) async -> Int {
        guard audioCacheAutomatic else { return audioCacheSizeMB }
        if !refresh, let known = Self.automaticLimit,
           Date().timeIntervalSince(known.at) < AutomaticCacheLimit.refreshInterval {
            return known.megabytes
        }
        let used = (try? await AudioCache.shared.usage().bytes) ?? 0
        let megabytes = AutomaticCacheLimit.megabytes(freeBytes: AutomaticCacheLimit.freeBytes(), cacheBytes: used)
        Self.automaticLimit = (megabytes, Date())
        return megabytes
    }
}
