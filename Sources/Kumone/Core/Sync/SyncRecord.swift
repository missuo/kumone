import Foundation

/// Logical revisions make concurrent edits deterministic without trusting device clocks.
struct SyncRevision: Codable, Comparable, Hashable {
    let counter: UInt64
    let deviceID: UUID

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.counter == rhs.counter
            ? lhs.deviceID.uuidString < rhs.deviceID.uuidString
            : lhs.counter < rhs.counter
    }
}

/// Transport metadata is shared; validation and merge policies belong to each domain.
struct SyncRecord<Payload: Codable>: Codable, Identifiable {
    let schemaVersion: Int
    let revision: SyncRevision
    let deviceName: String
    let updatedAt: Date
    let payload: Payload?

    var id: UUID { revision.deviceID }

    init(revision: SyncRevision, deviceName: String, updatedAt: Date = Date(), payload: Payload?) {
        schemaVersion = 1
        self.revision = revision
        self.deviceName = deviceName
        self.updatedAt = updatedAt
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, revision, deviceName, updatedAt, payload
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == 1 else { throw SyncError.newerVersion }
        revision = try c.decode(SyncRevision.self, forKey: .revision)
        deviceName = try c.decode(String.self, forKey: .deviceName)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        payload = try c.decodeIfPresent(Payload.self, forKey: .payload)
    }
}

enum SyncError: LocalizedError {
    case unavailable, downloading, identityChanged, invalidRecord, newerVersion, accountMismatch
    case loginLocked, wrongPassphrase, weakPassphrase, passphraseMismatch

    var errorDescription: String? {
        switch self {
        case .unavailable: return String(localized: "同步目录不可用")
        case .downloading: return String(localized: "等待 iCloud 下载")
        case .identityChanged: return String(localized: "iCloud 账号已更改")
        case .invalidRecord: return String(localized: "同步数据损坏")
        case .newerVersion: return String(localized: "同步数据需要更新版本的 Kumone")
        case .accountMismatch: return String(localized: "接续需要登录同一账号")
        case .loginLocked: return String(localized: "需要输入同步密码")
        case .wrongPassphrase: return String(localized: "同步密码不正确")
        case .weakPassphrase: return String(localized: "同步密码至少需要 8 个字符")
        case .passphraseMismatch: return String(localized: "两次输入的同步密码不一致")
        }
    }
}
