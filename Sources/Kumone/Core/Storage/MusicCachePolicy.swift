import Foundation

enum MusicCachePolicy: String, CaseIterable, Identifiable, Codable {
    case automatic, disabled
    case gb1, gb2, gb5, gb10, gb20, gb30, gb50
    var id: String { rawValue }
    var fixedBytes: Int64? {
        let sizes: [Self: Int64] = [.gb1: 1, .gb2: 2, .gb5: 5, .gb10: 10, .gb20: 20, .gb30: 30, .gb50: 50]
        return sizes[self].map { $0 * 1_000_000_000 }
    }
    var title: String {
        switch self {
        case .automatic: return String(localized: "自动")
        case .disabled: return String(localized: "不缓存")
        default: return ByteCountFormatter.string(fromByteCount: fixedBytes ?? 0, countStyle: .file)
        }
    }
    /// Offline listening is a phone use case (commutes, flights). A Mac is
    /// nearly always online, so it only keeps a small replay cache, the same
    /// 1 GB the official desktop client ships with.
    static var `default`: Self {
        #if os(macOS)
        .gb1
        #else
        .automatic
        #endif
    }
    static var options: [Self] {
        #if os(macOS)
        allCases
        #else
        allCases.filter { $0 != .gb50 }
        #endif
    }

    func limit(free: Int64, cacheBytes: Int64, downloadReservations: Int64, floor: Int64, isMac: Bool) -> Int64 {
        guard self != .disabled else { return 0 }
        // Add cache usage back so filling this cache does not shrink its own
        // allowance. Pending downloads consume space outside this allowance.
        let recoverable = max(0, free - downloadReservations) + cacheBytes
        let safe = max(0, recoverable - floor)
        if let fixedBytes { return min(fixedBytes, safe) }
        let ordinaryMinimum: Int64 = isMac ? 5_000_000_000 : 2_000_000_000
        let maximum: Int64 = isMac ? 50_000_000_000 : 30_000_000_000
        return min(safe, min(maximum, max(ordinaryMinimum, recoverable / 10)))
    }
}

struct MusicCacheContext: Equatable {
    var policy: MusicCachePolicy
    var protectedAssetIDs: Set<String> = []
    var protectedTracks: [String: Set<Int>] = [:]
    // Unknown accounts get the same retention priority as liked tracks.
    var likedTracks: [String: Set<Int>] = [:]
    var isPrefetch = false
}

struct MusicCacheCapacity {
    let limit: Int64
    let used: Int64
}

extension Notification.Name {
    static let musicCachePolicyChanged = Notification.Name("Kumone.musicCachePolicyChanged")
    static let playbackQualityChanged = Notification.Name("Kumone.playbackQualityChanged")
}
