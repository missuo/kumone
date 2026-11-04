import Foundation
import os

/// A shared sign-in as it sits in the sync folder. The account and nickname
/// label the offer; the cookies are sealed with the sync passphrase's key
/// (`LoginKey`), so folder access alone cannot sign anyone in.
struct SyncedLogin: Codable, Equatable {
    let accountID: Int
    let nickname: String
    let keyID: UUID
    let sealedCookies: Data

    func validate() throws {
        guard accountID > 0, !sealedCookies.isEmpty else { throw SyncError.invalidRecord }
    }

    private static let log = Logger(subsystem: "sb.moe.kumone", category: "login-sync")

    /// With `keyID`, offers sealed under any other key are left out: they can
    /// never be opened here.
    static func availableAccounts(
        in records: [SyncRecord<Self>], excluding deviceID: UUID, keyID: UUID? = nil
    ) -> [SyncRecord<Self>] {
        // Resolve each device's deletion marker before collapsing duplicate accounts.
        let latest = Dictionary(grouping: records, by: \.id).values.compactMap {
            $0.max { $0.revision < $1.revision }
        }.filter { record in
            guard record.id != deviceID else { return false }
            do {
                guard let login = record.payload else { return false }
                try login.validate()
                return keyID.map { login.keyID == $0 } ?? true
            } catch {
                // Never resurrect an older login when the latest record is invalid.
                log.error("Rejected login record for device \(record.id.uuidString, privacy: .public)")
                return false
            }
        }
        return Dictionary(grouping: latest, by: { $0.payload?.accountID }).values.compactMap {
            $0.max { $0.revision < $1.revision }
        }.sorted { $0.revision > $1.revision }
    }
}
