import Foundation

enum DownloadStatus: String, Codable {
    case queued, resolving, downloading, waitingNetwork, paused, waitingAccount
    case verifying, complete, failed, unavailable, cancelled

    var label: String {
        switch self {
        case .queued: return String(localized: "排队中")
        case .resolving: return String(localized: "获取下载地址")
        case .downloading: return String(localized: "下载中")
        case .waitingNetwork: return String(localized: "等待可用网络")
        case .paused: return String(localized: "已暂停")
        case .waitingAccount: return String(localized: "等待登录原账号")
        case .verifying: return String(localized: "校验中")
        case .complete: return String(localized: "已下载")
        case .failed: return String(localized: "下载失败")
        case .unavailable: return String(localized: "暂不可下载")
        case .cancelled: return String(localized: "已取消")
        }
    }

    var isWorking: Bool { [.resolving, .downloading, .verifying].contains(self) }
    var canResume: Bool { [.paused, .failed, .unavailable, .cancelled, .waitingNetwork].contains(self) }
}

struct DownloadJob: Codable, Identifiable {
    let id: UUID
    let accountScope: String
    let track: Track
    let quality: String
    var owners: Set<String>
    var status: DownloadStatus = .queued
    var allowsMetered = false
    var attempt: UUID?
    var descriptor: OfflineAudioDescriptor?
    var assetID: String?
    var receivedBytes: Int64 = 0
    var expectedBytes: Int64 = 0
    var errorMessage: String?
    var metadataPending = true
    var retries = 0
    let createdAt: Date

    init(scope: String, track: Track, quality: String, owner: String, allowsMetered: Bool) {
        id = UUID()
        accountScope = scope
        self.track = track
        self.quality = quality
        owners = [owner]
        self.allowsMetered = allowsMetered
        createdAt = Date()
    }

    var token: String? { attempt.map { "\(id.uuidString).\($0.uuidString)" } }
    var retentionOwner: String { "download:\(id.uuidString)" }
    var progress: Double? {
        guard expectedBytes > 0 else { return nil }
        return min(1, max(0, Double(receivedBytes) / Double(expectedBytes)))
    }
}

struct DownloadCollection: Codable, Identifiable {
    let id: String
    let accountScope: String
    let name: String
    let tracks: [Track]
    let savedAt: Date
}

struct OfflineLibraryTrack: Identifiable {
    let track: Track
    let assets: [OfflineAudioRecord]
    var id: Int { track.id }
    var isDownloaded: Bool { assets.contains { !$0.retainedBy.isEmpty } }
    var byteCount: Int64 { assets.reduce(0) { $0 + $1.descriptor.byteCount } }
}

struct DownloadCatalog: Codable {
    var version = 1
    var revision: UInt64 = 0
    var jobs: [DownloadJob] = []
    var collections: [DownloadCollection] = []
}

struct DownloadNetworkState: Equatable {
    var connected: Bool
    var expensive: Bool
    var constrained: Bool
    func permits(_ job: DownloadJob) -> Bool { connected && (job.allowsMetered || (!expensive && !constrained)) }
    static let unknown = Self(connected: false, expensive: false, constrained: false)
}

/// Monotonic revisions prevent slower, older saves overwriting a newer pause,
/// cancellation or account switch. Writes are serialized off the main actor.
actor DownloadCatalogStore {
    nonisolated let directory: URL
    private var lastRevision: UInt64 = 0
    init(directory: URL) { self.directory = directory }

    func load() throws -> DownloadCatalog {
        let url = directory.appendingPathComponent("downloads.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return DownloadCatalog() }
        let catalog = try JSONDecoder().decode(DownloadCatalog.self, from: Data(contentsOf: url))
        guard catalog.version == 1 else { throw OfflineAudioError.database("Unsupported download catalog") }
        lastRevision = catalog.revision
        return catalog
    }

    func save(_ catalog: DownloadCatalog) throws {
        guard catalog.revision >= lastRevision else { return }
        try DownloadFileProtection.prepareDirectory(directory)
        try JSONEncoder().encode(catalog).write(to: directory.appendingPathComponent("downloads.json"), options: .atomic)
        lastRevision = catalog.revision
    }

    func resumeData(jobID: UUID) -> Data? { try? Data(contentsOf: resumeURL(jobID)) }
    func saveResumeData(_ data: Data?, jobID: UUID) throws {
        if let data {
            try DownloadFileProtection.prepareDirectory(directory)
            try data.write(to: resumeURL(jobID), options: .atomic)
            try DownloadFileProtection.protect(resumeURL(jobID))
        } else if FileManager.default.fileExists(atPath: resumeURL(jobID).path) {
            try FileManager.default.removeItem(at: resumeURL(jobID))
        }
    }
    private func resumeURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).resume") }
}
