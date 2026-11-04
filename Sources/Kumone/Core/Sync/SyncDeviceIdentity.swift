import Foundation
import Security

/// A local, non-migrating identity survives reinstall while Keychain access remains
/// available. It is never synchronized to other devices or inferred from their names.
enum SyncDeviceIdentity {
    private static let cache = Cache()

    static func load(service: String = "sb.moe.kumone.sync-device") async throws -> UUID {
        try await cache.load(service: service)
    }

    private actor Cache {
        private var identities: [String: UUID] = [:]

        func load(service: String) async throws -> UUID {
            if let identity = identities[service] { return identity }
            let identity = try await SyncDeviceIdentity.readOrCreate(service: service)
            identities[service] = identity
            return identity
        }
    }

    private static func readOrCreate(service: String) async throws -> UUID {
        try await Task.detached(priority: .utility) {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: "device-id",
                kSecAttrSynchronizable as String: false
            ]
            if let existing = try read(query) { return existing }

            let identity = UUID()
            var item = query
            item[kSecValueData as String] = Data(identity.uuidString.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(item as CFDictionary, nil)
            // Concurrent connections can both observe an absent item. Keep the winner.
            if status == errSecDuplicateItem {
                guard let existing = try read(query) else { throw SyncError.unavailable }
                return existing
            }
            guard status == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
            return identity
        }.value
    }

    private static func read(_ query: [String: Any]) throws -> UUID? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8),
              let identity = UUID(uuidString: value) else { throw SyncError.invalidRecord }
        return identity
    }
}
