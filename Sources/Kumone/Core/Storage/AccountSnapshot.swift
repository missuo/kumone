import Foundation

struct AccountSnapshot: Codable {
    let authenticationFingerprint: String
    let profile: UserProfile
    let likedTrackIDs: Set<Int>
    let playlists: [PlaylistSummary]
    let savedAt: Date

    func matches(fingerprint: String?) -> Bool { fingerprint != nil && fingerprint == authenticationFingerprint }
}

struct AccountSnapshotStorage {
    static let shared = AccountSnapshotStorage(url: KumonePaths.applicationSupport.appendingPathComponent("account-snapshot.json"))
    let url: URL

    func load(fingerprint: String?) -> AccountSnapshot? {
        guard let data = try? Data(contentsOf: url), let snapshot = try? JSONDecoder().decode(AccountSnapshot.self, from: data),
              snapshot.matches(fingerprint: fingerprint) else { return nil }
        return snapshot
    }

    func save(_ snapshot: AccountSnapshot) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }

    func clear() { try? FileManager.default.removeItem(at: url) }
}
