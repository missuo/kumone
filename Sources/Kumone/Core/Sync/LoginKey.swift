import CommonCrypto
import CryptoKit
import Foundation
import Security

/// The folder holds only a salt and a verifier. The key is derived from the
/// user's sync passphrase and kept in each device's own Keychain, so reading
/// the sync folder alone never yields a usable session.
struct LoginKeyFile: Codable, Equatable {
    let schemaVersion: Int
    let id: UUID
    let salt: Data
    let rounds: Int
    let verifier: Data

    static let defaultRounds = 600_000
    static let minimumPassphraseLength = 8

    /// A new key replaces every earlier one: offers sealed under it can no
    /// longer be opened, and other devices must enter the new passphrase.
    static func make(passphrase: String, rounds: Int = defaultRounds) throws -> (Self, LoginKey) {
        guard passphrase.count >= minimumPassphraseLength else { throw SyncError.weakPassphrase }
        let salt = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        let id = UUID()
        let key = LoginKey(id: id, secret: try LoginKey.secret(passphrase: passphrase, salt: salt, rounds: rounds))
        return (Self(schemaVersion: 1, id: id, salt: salt, rounds: rounds, verifier: key.verifier), key)
    }

    func validate() throws {
        guard schemaVersion == 1 else { throw SyncError.newerVersion }
        // The round count comes from a shared folder; never let it stall a device.
        guard (1...10_000_000).contains(rounds), salt.count >= 16, verifier.count == 32 else {
            throw SyncError.invalidRecord
        }
    }

    func unlock(passphrase: String) throws -> LoginKey {
        try validate()
        let key = LoginKey(id: id, secret: try LoginKey.secret(passphrase: passphrase, salt: salt, rounds: rounds))
        guard key.verifier == verifier else { throw SyncError.wrongPassphrase }
        return key
    }
}

struct LoginKey {
    let id: UUID
    let secret: SymmetricKey
    private let sealing: SymmetricKey
    let verifier: Data

    init(id: UUID, secret: SymmetricKey) {
        self.id = id
        self.secret = secret
        sealing = HKDF<SHA256>.deriveKey(inputKeyMaterial: secret, info: Data("kumone.login.seal".utf8),
                                         outputByteCount: 32)
        let verifying = HKDF<SHA256>.deriveKey(inputKeyMaterial: secret, info: Data("kumone.login.verify".utf8),
                                               outputByteCount: 32)
        verifier = Data(HMAC<SHA256>.authenticationCode(for: Data(id.uuidString.utf8), using: verifying))
    }

    static func secret(passphrase: String, salt: Data, rounds: Int) throws -> SymmetricKey {
        let password = passphrase.precomposedStringWithCanonicalMapping
        var derived = [UInt8](repeating: 0, count: 32)
        let status = password.withCString { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes, password.utf8.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds), &derived, derived.count)
            }
        }
        guard status == kCCSuccess else { throw SyncError.invalidRecord }
        return SymmetricKey(data: derived)
    }

    /// The account and key are authenticated with the cookies, so a sealed
    /// session cannot be passed off under another record's account.
    func seal(accountID: Int, nickname: String, cookies: [String: String]) throws -> SyncedLogin {
        guard accountID > 0, cookies["MUSIC_U"]?.isEmpty == false else { throw SyncError.invalidRecord }
        let box = try AES.GCM.seal(JSONEncoder().encode(cookies), using: sealing,
                                   authenticating: Self.context(accountID: accountID, keyID: id))
        guard let sealed = box.combined else { throw SyncError.invalidRecord }
        return SyncedLogin(accountID: accountID, nickname: nickname, keyID: id, sealedCookies: sealed)
    }

    func open(_ login: SyncedLogin) throws -> [String: String] {
        guard login.keyID == id else { throw SyncError.loginLocked }
        do {
            let box = try AES.GCM.SealedBox(combined: login.sealedCookies)
            let data = try AES.GCM.open(box, using: sealing,
                                        authenticating: Self.context(accountID: login.accountID, keyID: id))
            let cookies = try JSONDecoder().decode([String: String].self, from: data)
            guard cookies["MUSIC_U"]?.isEmpty == false else { throw SyncError.invalidRecord }
            return cookies
        } catch { throw SyncError.invalidRecord }
    }

    private static func context(accountID: Int, keyID: UUID) -> Data {
        Data("kumone.login|\(accountID)|\(keyID.uuidString)".utf8)
    }
}

/// Where this device keeps the derived key. Never synchronized: each device
/// unlocks with the passphrase itself.
struct LoginKeyStore {
    let load: (UUID) -> SymmetricKey?
    let save: (SymmetricKey, UUID) throws -> Void

    static var keychain: Self {
        let service = "sb.moe.kumone.sync-login-key"
        return Self(
            load: { id in
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: id.uuidString,
                    kSecAttrSynchronizable as String: false,
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                ]
                var result: CFTypeRef?
                guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                      let data = result as? Data, data.count == 32 else { return nil }
                return SymmetricKey(data: data)
            },
            save: { secret, id in
                // One key at a time: a replaced key is useless and should not linger.
                SecItemDelete([
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrSynchronizable as String: false,
                ] as CFDictionary)
                let item: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: id.uuidString,
                    kSecAttrSynchronizable as String: false,
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                    kSecValueData as String: secret.withUnsafeBytes { Data($0) },
                ]
                let status = SecItemAdd(item as CFDictionary, nil)
                guard status == errSecSuccess else {
                    throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
                }
            })
    }

    static func memory() -> Self {
        final class Box { var keys: [UUID: SymmetricKey] = [:] }
        let box = Box()
        return Self(load: { box.keys[$0] }, save: { secret, id in box.keys = [id: secret] })
    }
}
