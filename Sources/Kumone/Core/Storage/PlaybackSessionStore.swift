import Foundation

struct PlaybackSessionSnapshot: Codable {
    var version = 1
    let sessionID: UUID
    let accountScope: String
    let queue: [Track]
    let shuffledQueue: [Track]
    let playNextList: [Track]
    let fmUpcoming: [Track]
    let currentIndex: Int
    let currentTrack: Track?
    var progress: TimeInterval
    let source: PlaySource
    let repeatMode: String
    let shuffle: Bool
    let isFM: Bool
    let recentContexts: [PlayContext]
}

struct PlaybackPositionSnapshot: Codable {
    let sessionID: UUID
    let trackID: Int
    let progress: TimeInterval
}

actor PlaybackSessionStore {
    static let shared = PlaybackSessionStore(directory: KumonePaths.applicationSupport.appendingPathComponent("playback-sessions"))
    nonisolated let directory: URL
    private var sessionRevisions: [String: UInt64] = [:]
    private var positionRevisions: [String: UInt64] = [:]

    init(directory: URL) { self.directory = directory }

    nonisolated func load(scope: String) -> PlaybackSessionSnapshot? {
        guard let data = try? Data(contentsOf: url(scope: scope, position: false)),
              var snapshot = try? JSONDecoder().decode(PlaybackSessionSnapshot.self, from: data),
              snapshot.version == 1, snapshot.accountScope == scope else { return nil }
        if let data = try? Data(contentsOf: url(scope: scope, position: true)),
           let position = try? JSONDecoder().decode(PlaybackPositionSnapshot.self, from: data),
           position.sessionID == snapshot.sessionID, position.trackID == snapshot.currentTrack?.id {
            snapshot.progress = position.progress
        }
        if !snapshot.progress.isFinite || snapshot.progress < 0 { snapshot.progress = 0 }
        return snapshot
    }

    func save(_ snapshot: PlaybackSessionSnapshot, revision: UInt64) throws {
        guard revision >= sessionRevisions[snapshot.accountScope] ?? 0 else { return }
        try write(JSONEncoder().encode(snapshot), scope: snapshot.accountScope, position: false)
        sessionRevisions[snapshot.accountScope] = revision
    }

    func savePosition(_ position: PlaybackPositionSnapshot, scope: String, revision: UInt64) throws {
        guard revision >= positionRevisions[scope] ?? 0 else { return }
        try write(JSONEncoder().encode(position), scope: scope, position: true)
        positionRevisions[scope] = revision
    }

    private func write(_ data: Data, scope: String, position: Bool) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url(scope: scope, position: position), options: .atomic)
    }

    private nonisolated func url(scope: String, position: Bool) -> URL {
        directory.appendingPathComponent("\(OfflineMetadataStore.key(scope))\(position ? ".position" : "").json")
    }
}
