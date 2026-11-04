import CryptoKit
import Foundation

/// Device records supply publication comparisons. Withdrawal responsibility
/// survives a later read that skips this device's temporarily unreadable file.
@MainActor
final class LoginSync {
    enum KeyState: Equatable {
        /// No device has set a sync passphrase for this folder yet.
        case unset
        /// The folder has a key this device has not unlocked.
        case locked
        case unlocked
    }

    private let keyStore: LoginKeyStore
    private var cachedLoginRecords: [SyncRecord<SyncedLogin>] = []
    private var hasPublishedLogin = false
    private var keyFile: LoginKeyFile?
    private var key: LoginKey?

    init(keyStore: LoginKeyStore = .keychain) {
        self.keyStore = keyStore
    }

    var keyState: KeyState {
        guard keyFile != nil else { return .unset }
        return key == nil ? .locked : .unlocked
    }

    func resetConnection() {
        cachedLoginRecords = []
        hasPublishedLogin = false
        keyFile = nil
        key = nil
    }

    /// Another device still offers this account, so its session may be in use
    /// there. The last device to sign out finds none and revokes it.
    func isAccountSharedElsewhere(accountID: Int, deviceID: UUID) -> Bool {
        Dictionary(grouping: cachedLoginRecords, by: \.id).contains { device, records in
            device != deviceID && records.max { $0.revision < $1.revision }?.payload?.accountID == accountID
        }
    }

    func open(_ login: SyncedLogin) throws -> [String: String] {
        guard let key else { throw SyncError.loginLocked }
        return try key.open(login)
    }

    func unlock(passphrase: String) async throws {
        guard let keyFile else { throw SyncError.loginLocked }
        // Key derivation is deliberately slow; keep it off the main actor.
        let unlocked = try await Task.detached(priority: .userInitiated) {
            try keyFile.unlock(passphrase: passphrase)
        }.value
        guard self.keyFile == keyFile else { throw CancellationError() }
        try keyStore.save(unlocked.secret, unlocked.id)
        key = unlocked
    }

    func createKey(passphrase: String, repository: SyncRepository, connectionID: UUID) async throws {
        let (newFile, newKey) = try await Task.detached(priority: .userInitiated) {
            try LoginKeyFile.make(passphrase: passphrase)
        }.value
        try await repository.writeLoginKey(newFile, connectionID: connectionID)
        try keyStore.save(newKey.secret, newKey.id)
        keyFile = newFile
        key = newKey
    }

    func read(repository: SyncRepository, connectionID: UUID, clock: SyncRevisionClock) async throws {
        try Task.checkCancellation()
        let currentKeyFile = try await repository.readLoginKey(connectionID: connectionID)
        let records = try await repository.read(.login, as: SyncedLogin.self, connectionID: connectionID)
        try Task.checkCancellation()
        if currentKeyFile != keyFile {
            keyFile = currentKeyFile
            key = currentKeyFile.flatMap { file in
                keyStore.load(file.id).map { LoginKey(id: file.id, secret: $0) }
                    .flatMap { $0.verifier == file.verifier ? $0 : nil }
            }
        }
        cachedLoginRecords = records
        for record in records { clock.observe(record.revision.counter) }
        if let latestLocalRecord = records.lazy.filter({ $0.id == clock.deviceID }).max(by: { $0.revision < $1.revision }) {
            hasPublishedLogin = latestLocalRecord.payload != nil
        }
    }

    func publish(
        enabled isLoginSyncEnabled: Bool, repository: SyncRepository, connectionID: UUID,
        clock: SyncRevisionClock
    ) async throws -> [SyncRecord<SyncedLogin>] {
        try Task.checkCancellation()
        let previousLocalRecord = cachedLoginRecords.lazy.filter { $0.id == clock.deviceID }.max { $0.revision < $1.revision }
        let accountStore = AccountStore.shared
        let outgoingLogin: SyncedLogin?
        if isLoginSyncEnabled, let key, let profile = accountStore.profile,
           accountStore.authenticatedAccountID == profile.userId {
            let cookies = MusicClient.shared.authenticationCookies()
            // Sealing is randomized; compare what the previous offer carries.
            if let previous = previousLocalRecord?.payload, previous.keyID == key.id,
               previous.accountID == profile.userId, previous.nickname == profile.nickname,
               (try? key.open(previous)) == cookies {
                outgoingLogin = previous
            } else {
                outgoingLogin = try key.seal(accountID: profile.userId, nickname: profile.nickname, cookies: cookies)
            }
        } else if !isLoginSyncEnabled || key == nil || !accountStore.hasAuthCookie {
            // Without the key there is nothing safe to offer; an offer under
            // a replaced key is withdrawn rather than left unopenable.
            outgoingLogin = nil
        } else {
            // Bootstrap has not verified the local cookie's account yet. Keep
            // the published offer until authentication becomes authoritative.
            return availableAccounts(excluding: clock.deviceID)
        }
        if previousLocalRecord?.payload != outgoingLogin || (outgoingLogin == nil && hasPublishedLogin) {
            let record = try clock.makeRecord(outgoingLogin)
            try await repository.write(record, domain: .login, connectionID: connectionID)
            try Task.checkCancellation()
            cachedLoginRecords.removeAll { $0.id == clock.deviceID }
            cachedLoginRecords.append(record)
            hasPublishedLogin = outgoingLogin != nil
        }
        clock.persistCounter()
        return availableAccounts(excluding: clock.deviceID)
    }

    /// Only offers sealed under the folder's current key can ever be opened.
    private func availableAccounts(excluding deviceID: UUID) -> [SyncRecord<SyncedLogin>] {
        guard let keyFile else { return [] }
        return SyncedLogin.availableAccounts(in: cachedLoginRecords, excluding: deviceID, keyID: keyFile.id)
    }
}
