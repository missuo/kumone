import Combine
import CryptoKit
import Foundation
import Security
import Synchronization
import Testing
@testable import KumoneCore

private final class CountingSyncDefaults: UserDefaults, @unchecked Sendable {
    let writeCountsByKey = Mutex<[String: Int]>([:])

    override func set(_ value: Any?, forKey key: String) {
        super.set(value, forKey: key)
        writeCountsByKey.withLock { $0[key, default: 0] += 1 }
    }
}

@MainActor
private final class SyncPeriodicClock {
    let waits = AsyncStream<CheckedContinuation<Void, Never>>.makeStream()
    private(set) var sleepCount = 0

    // Deliberately wake cancelled waits too, to exercise stale-loop protection.
    func sleep() async {
        sleepCount += 1
        await withCheckedContinuation { waits.continuation.yield($0) }
    }
}

private let fixtureLoginKey = LoginKey(id: UUID(), secret: SymmetricKey(size: .bits256))

extension SyncedLogin {
    /// Sealed under the fixture key. Cookies without `MUSIC_U` cannot be
    /// sealed and stand in for an invalid offer.
    init(accountID: Int, nickname: String, cookies: [String: String]) {
        if let sealed = try? fixtureLoginKey.seal(accountID: accountID, nickname: nickname, cookies: cookies) {
            self = sealed
        } else {
            self.init(accountID: accountID, nickname: nickname, keyID: fixtureLoginKey.id, sealedCookies: Data())
        }
    }

    var cookies: [String: String] { (try? fixtureLoginKey.open(self)) ?? [:] }
}

/// Offers are only listed under the folder's current key.
private func writeFixtureLoginKey(to repository: SyncRepository, connectionID: UUID) async throws {
    let file = LoginKeyFile(schemaVersion: 1, id: fixtureLoginKey.id, salt: Data(count: 16), rounds: 1,
                            verifier: fixtureLoginKey.verifier)
    try await repository.writeLoginKey(file, connectionID: connectionID)
}

// Preference tests temporarily edit the shared SettingsManager.
@Suite("Cross-device sync", .serialized)
struct SyncTests {
    @Test @MainActor func preferencesRestoreWithoutEchoAndPersistEditsBeforeCloudFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-preference-commit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "kumone-preference-commit-defaults-\(UUID())"
        let defaults = try #require(CountingSyncDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager.shared
        let originalTranslation = settings.showLyricsTranslation
        let originalVerbatim = settings.verbatimLyrics
        defer {
            settings.showLyricsTranslation = originalTranslation
            settings.verbatimLyrics = originalVerbatim
        }
        settings.showLyricsTranslation = false
        settings.verbatimLyrics = false
        let device = UUID()
        let remote = UUID()
        let connection = UUID()
        let repository = SyncRepository()
        _ = try await repository.connect(to: root, connectionID: connection)
        let incoming = SyncedPreferences(fields: [
            SettingsManager.Keys.showTranslation: .init(value: .boolean(true), revision: .init(counter: 100, deviceID: remote)),
            SettingsManager.Keys.verbatimLyrics: .init(value: .boolean(true), revision: .init(counter: 101, deviceID: remote))
        ])
        try await repository.write(SyncRecord(revision: .init(counter: 102, deviceID: remote), deviceName: "Remote", payload: incoming),
                                   domain: .preferences, connectionID: connection)
        let initialPreferencesSync = PreferencesSync(defaults: defaults, settings: settings)
        let clock = SyncRevisionClock(defaults: defaults, deviceID: device, deviceName: "Local")
        try await initialPreferencesSync.synchronize(reading: true, repository: repository, connectionID: connection, clock: clock)
        #expect(settings.showLyricsTranslation && settings.verbatimLyrics)
        let localPreferencesFile = root.appendingPathComponent("Kumone/Devices/\(device.uuidString)/preferences.json")
        let publishedData = try Data(contentsOf: localPreferencesFile)
        defaults.writeCountsByKey.withLock { $0.removeAll() }
        let restoredPreferencesSync = PreferencesSync(defaults: defaults, settings: settings)
        try restoredPreferencesSync.restore()
        let nextClock = SyncRevisionClock(defaults: defaults, deviceID: device, deviceName: "Local")
        try await restoredPreferencesSync.synchronize(reading: true, repository: repository, connectionID: connection, clock: nextClock)
        #expect(try Data(contentsOf: localPreferencesFile) == publishedData)
        #expect(defaults.writeCountsByKey.withLock { $0.isEmpty })

        settings.showLyricsTranslation = false
        settings.verbatimLyrics = false
        try await restoredPreferencesSync.synchronize(reading: false, repository: repository, connectionID: connection, clock: nextClock)
        #expect(defaults.writeCountsByKey.withLock { $0["sync.preferences"] } == 1)
        #expect(defaults.writeCountsByKey.withLock { $0["sync.counter"] } == 2)
        let beforeFailure = try Data(contentsOf: localPreferencesFile)
        await repository.disconnect(connectionID: connection)
        settings.showLyricsTranslation = true
        await #expect(throws: CancellationError.self) {
            try await restoredPreferencesSync.synchronize(reading: false, repository: repository, connectionID: connection, clock: nextClock)
        }
        #expect(try Data(contentsOf: localPreferencesFile) == beforeFailure)
        // A process restart must recover the edit that could not reach the cloud.
        let restartedPreferencesSync = PreferencesSync(defaults: defaults, settings: settings)
        try restartedPreferencesSync.restore()
        let restartedClock = SyncRevisionClock(defaults: defaults, deviceID: device, deviceName: "Local")
        _ = try await repository.connect(to: root, connectionID: connection)
        try await restartedPreferencesSync.synchronize(reading: true, repository: repository, connectionID: connection, clock: restartedClock)
        let records = try await repository.read(.preferences, as: SyncedPreferences.self, connectionID: connection)
        let localRecord = try #require(records.first { $0.id == device })
        #expect(localRecord.payload?.fields[SettingsManager.Keys.showTranslation]?.value == .boolean(true))
        #expect(localRecord.payload?.fields[SettingsManager.Keys.verbatimLyrics]?.value == .boolean(false))
        await repository.disconnect(connectionID: connection)
    }
    @Test(arguments: ["invalid-bookmark", "deleted-folder", "invalid-manifest"])
    @MainActor func failedRestoreCanReconnectWithoutDiscardingTheOldAuthorization(failure: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-restore-error-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "kumone-restore-error-defaults-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = SyncRepository()
        let connection = UUID()
        let bookmark = try await repository.connect(to: root, connectionID: connection)
        await repository.disconnect(connectionID: connection)
        let folder = root.appendingPathComponent("Kumone")
        var saved = bookmark
        switch failure {
        case "invalid-bookmark": saved = Data("invalid bookmark".utf8)
        case "deleted-folder": try FileManager.default.removeItem(at: folder)
        default: try Data("invalid JSON".utf8).write(to: folder.appendingPathComponent("repository.json"))
        }
        defaults.set(saved, forKey: "sync.directoryBookmark")
        let service = SyncService(defaults: defaults, deviceIdentity: { UUID() }, playbackContext: { (nil, nil) })
        await #expect(throws: SyncError.self) { try await service.enable() }
        #expect(!service.connected && !service.enabled)
        #expect(defaults.data(forKey: "sync.directoryBookmark") == saved)
        if failure == "deleted-folder" { #expect(!FileManager.default.fileExists(atPath: folder.path)) }
        // Explicitly choosing a new location replaces the unusable grant, without
        // resetting the app or deleting the rejected repository's contents.
        let replacement = root.appendingPathComponent("Replacement")
        await service.connect(to: replacement)
        #expect(service.connected && service.enabled && service.errorMessage == nil)
        #expect(defaults.data(forKey: "sync.directoryBookmark") != saved)
        #expect(FileManager.default.fileExists(atPath: replacement.appendingPathComponent("Kumone/repository.json").path))
        await service.disable()
    }

    @Test(arguments: [false, true])
    @MainActor func removedRepositoryRevokesOffersAndRequiresExplicitReconnect(replacedWithFile: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-directory-loss-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "kumone-directory-loss-defaults-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = SyncRepository()
        let connection = UUID()
        _ = try await repository.connect(to: root, connectionID: connection)
        let remote = UUID()
        let track = try JSONDecoder().decode(Track.self, from: Data("{\"id\":1}".utf8))
        let session = PlaybackSession(accountID: 42, queue: [track], orderedQueue: [track],
                                      currentIndex: 0, currentTrack: track, playNext: [], source: .none,
                                      repeatMode: "off", shuffled: false, automaticOrder: false, isFM: false, progress: 20)
        try await repository.writePlayback(SyncRecord(revision: .init(counter: 1, deviceID: remote),
                                                       deviceName: "Fixture", payload: session), connectionID: connection)
        let login = SyncedLogin(accountID: 42, nickname: "Fixture", cookies: ["MUSIC_U": "synthetic-session"])
        try await repository.write(SyncRecord(revision: .init(counter: 2, deviceID: remote), deviceName: "Fixture", payload: login),
                                   domain: .login, connectionID: connection)
        try await writeFixtureLoginKey(to: repository, connectionID: connection)
        await repository.disconnect(connectionID: connection)
        let service = SyncService(defaults: defaults, deviceIdentity: { UUID() }, playbackContext: { (session, 42) })
        await service.connect(to: root)
        #expect(service.sessions.count == 1 && service.logins.count == 1)
        let bookmark = defaults.data(forKey: "sync.directoryBookmark")
        let folder = root.appendingPathComponent("Kumone")
        try FileManager.default.removeItem(at: folder)
        if replacedWithFile { try Data("not a directory".utf8).write(to: folder) }
        await service.synchronizeNow()
        #expect(service.enabled && !service.connected)
        #expect(service.sessions.isEmpty && service.logins.isEmpty)
        #expect(service.errorMessage == SyncError.unavailable.localizedDescription)
        #expect(defaults.data(forKey: "sync.directoryBookmark") == bookmark)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("Devices").path))
        // Further player events must not recreate or overwrite the removed folder.
        await service.synchronizeNow(refreshing: [])
        if replacedWithFile { #expect(try Data(contentsOf: folder) == Data("not a directory".utf8)) }
        else { #expect(!FileManager.default.fileExists(atPath: folder.path)) }
        await service.connect(to: root.appendingPathComponent("Replacement"))
        #expect(service.connected && service.errorMessage == nil)
        await service.disable()
    }

    @Test(arguments: [Int?(42), Int?(99), nil], [Int?(42), Int?(99), Int?(0), nil])
    @MainActor func playbackPublicationRequiresMatchingAccountsAndWithdrawsAfterSignOut(
        sessionAccountID: Int?, accountID: Int?
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-playback-consent-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "kumone-playback-consent-defaults-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let device = UUID()
        let track = try JSONDecoder().decode(Track.self, from: Data("{\"id\":1}".utf8))
        var session = PlaybackSession(accountID: sessionAccountID, queue: [track], orderedQueue: [track],
                                      currentIndex: 0, currentTrack: track, playNext: [], source: .none,
                                      repeatMode: "off", shuffled: false, automaticOrder: false, isFM: false, progress: 20)
        var currentAccount = accountID
        let service = SyncService(defaults: defaults, deviceIdentity: { device }, playbackContext: { (session, currentAccount) })
        await service.connect(to: root)
        #expect(service.connected)
        let file = root.appendingPathComponent("Kumone/Devices/\(device.uuidString)/playback.json")
        if let accountID, accountID > 0, sessionAccountID == accountID {
            #expect(FileManager.default.fileExists(atPath: file.path))
        } else {
            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(!FileManager.default.fileExists(atPath: file.deletingLastPathComponent().appendingPathComponent("Queues").path))
        }
        currentAccount = 42
        session = PlaybackSession(accountID: 42, queue: [track], orderedQueue: [track],
                                  currentIndex: 0, currentTrack: track, playNext: [], source: .none,
                                  repeatMode: "off", shuffled: false, automaticOrder: false, isFM: false, progress: 30)
        await service.synchronizeNow(refreshing: [])
        let published = try JSONDecoder().decode(SyncRecord<PlaybackCheckpoint>.self, from: Data(contentsOf: file))
        #expect(published.payload?.progress == 30)
        // A stationary player must repair an externally removed pointer too.
        try FileManager.default.removeItem(at: file)
        await service.synchronizeNow(refreshing: [.playback], publishing: [.playback])
        let repaired = try JSONDecoder().decode(SyncRecord<PlaybackCheckpoint>.self, from: Data(contentsOf: file))
        #expect(repaired.payload?.progress == 30 && repaired.revision > published.revision)
        // Keep the old queue's account provenance; losing authentication must
        // withdraw the offer without changing the player's local session.
        currentAccount = nil
        await service.synchronizeNow(refreshing: [])
        let bytes = try Data(contentsOf: file)
        let withdrawn = try JSONDecoder().decode(SyncRecord<PlaybackCheckpoint>.self, from: bytes)
        #expect(withdrawn.payload == nil && withdrawn.revision > published.revision)
        await service.synchronizeNow()
        #expect(try Data(contentsOf: file) == bytes)
        await service.disable()
    }

    @Test @MainActor func loginWithdrawalSurvivesAnUnreadableOwnRecordAndDoesNotEchoAfterReset() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-login-withdrawal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "kumone-login-withdrawal-defaults-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = SyncRepository()
        let connection = UUID()
        _ = try await repository.connect(to: root, connectionID: connection)
        let device = UUID()
        let login = SyncedLogin(accountID: 42, nickname: "Fixture", cookies: ["MUSIC_U": "synthetic-session"])
        try await repository.write(SyncRecord(revision: .init(counter: 100, deviceID: device), deviceName: "Local", payload: login),
                                   domain: .login, connectionID: connection)
        let loginSync = LoginSync()
        let clock = SyncRevisionClock(defaults: defaults, deviceID: device, deviceName: "Local")
        try await loginSync.read(repository: repository, connectionID: connection, clock: clock)
        let loginFile = root.appendingPathComponent("Kumone/Devices/\(device.uuidString)/login.json")
        try Data("broken".utf8).write(to: loginFile, options: .atomic)
        try await loginSync.read(repository: repository, connectionID: connection, clock: clock)
        _ = try await loginSync.publish(enabled: false, repository: repository, connectionID: connection, clock: clock)
        let writtenBytes = try Data(contentsOf: loginFile)
        let withdrawnRecord = try JSONDecoder().decode(SyncRecord<SyncedLogin>.self, from: writtenBytes)
        #expect(withdrawnRecord.payload == nil && withdrawnRecord.revision.counter > 100)
        loginSync.resetConnection()
        try await loginSync.read(repository: repository, connectionID: connection, clock: clock)
        _ = try await loginSync.publish(enabled: false, repository: repository, connectionID: connection, clock: clock)
        #expect(try Data(contentsOf: loginFile) == writtenBytes)
        await repository.disconnect(connectionID: connection)
    }

    @Test @MainActor func onlyAnotherDevicesOfferKeepsASessionAlive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-login-revocation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "kumone-login-revocation-defaults-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let device = UUID()
        let remote = UUID()
        let connection = UUID()
        let repository = SyncRepository()
        _ = try await repository.connect(to: root, connectionID: connection)
        let loginSync = LoginSync(keyStore: .memory())
        let clock = SyncRevisionClock(defaults: defaults, deviceID: device, deviceName: "Local")
        let login = SyncedLogin(accountID: 42, nickname: "Fixture", cookies: ["MUSIC_U": "synthetic-shared"])
        #expect(!loginSync.isAccountSharedElsewhere(accountID: 42, deviceID: device))
        // This device's own offer is no reason to keep its session alive.
        try await repository.write(SyncRecord(revision: .init(counter: 1, deviceID: device), deviceName: "Local", payload: login),
                                   domain: .login, connectionID: connection)
        try await loginSync.read(repository: repository, connectionID: connection, clock: clock)
        #expect(!loginSync.isAccountSharedElsewhere(accountID: 42, deviceID: device))
        try await repository.write(SyncRecord(revision: .init(counter: 2, deviceID: remote), deviceName: "Remote", payload: login),
                                   domain: .login, connectionID: connection)
        try await loginSync.read(repository: repository, connectionID: connection, clock: clock)
        #expect(loginSync.isAccountSharedElsewhere(accountID: 42, deviceID: device))
        #expect(!loginSync.isAccountSharedElsewhere(accountID: 7, deviceID: device))
        loginSync.resetConnection()
        #expect(!loginSync.isAccountSharedElsewhere(accountID: 42, deviceID: device))
        try await loginSync.read(repository: repository, connectionID: connection, clock: clock)
        #expect(loginSync.isAccountSharedElsewhere(accountID: 42, deviceID: device))
        // Once the other device signs out, the last one out revokes.
        let withdrawn = SyncRecord<SyncedLogin>(revision: .init(counter: 3, deviceID: remote), deviceName: "Remote", payload: nil)
        try await repository.write(withdrawn, domain: .login, connectionID: connection)
        try await loginSync.read(repository: repository, connectionID: connection, clock: clock)
        #expect(!loginSync.isAccountSharedElsewhere(accountID: 42, deviceID: device))
        await repository.disconnect(connectionID: connection)
    }

    @Test func sealedLoginsKeepTheSessionOutOfTheFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-login-sealed-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SyncRepository()
        let connection = UUID()
        _ = try await repository.connect(to: root, connectionID: connection)
        let cookies = ["MUSIC_U": "synthetic-secret-session", "__csrf": "synthetic-csrf"]
        let login = try fixtureLoginKey.seal(accountID: 42, nickname: "Fixture", cookies: cookies)
        let record = SyncRecord(revision: .init(counter: 1, deviceID: UUID()), deviceName: "Mac", payload: login)
        try await repository.write(record, domain: .login, connectionID: connection)
        let bytes = try Data(contentsOf: root.appendingPathComponent("Kumone/Devices/\(record.id.uuidString)/login.json"))
        let text = try #require(String(data: bytes, encoding: .utf8))
        #expect(!text.contains("synthetic-secret-session") && !text.contains("synthetic-csrf"))
        #expect(try fixtureLoginKey.open(login) == cookies)

        // The account is authenticated with the cookies; it cannot be swapped.
        let relabeled = SyncedLogin(accountID: 7, nickname: "Fixture", keyID: login.keyID, sealedCookies: login.sealedCookies)
        #expect(throws: SyncError.self) { try fixtureLoginKey.open(relabeled) }
        let otherKey = LoginKey(id: fixtureLoginKey.id, secret: SymmetricKey(size: .bits256))
        #expect(throws: SyncError.self) { try otherKey.open(login) }
        let replacedKey = LoginKey(id: UUID(), secret: fixtureLoginKey.secret)
        #expect(throws: SyncError.loginLocked) { try replacedKey.open(login) }
        await repository.disconnect(connectionID: connection)
    }

    @Test func loginKeyUnlocksOnlyWithItsPassphrase() throws {
        #expect(throws: SyncError.weakPassphrase) { try LoginKeyFile.make(passphrase: "short", rounds: 1_000) }
        let (file, key) = try LoginKeyFile.make(passphrase: "correct horse battery", rounds: 1_000)
        let unlocked = try file.unlock(passphrase: "correct horse battery")
        #expect(unlocked.id == key.id && unlocked.verifier == key.verifier)
        #expect(throws: SyncError.wrongPassphrase) { try file.unlock(passphrase: "correct horse battery!") }
        let decoded = try JSONDecoder().decode(LoginKeyFile.self, from: JSONEncoder().encode(file))
        #expect(decoded == file)
        // A shared folder must not be able to stall a device with its round count.
        let hostile = LoginKeyFile(schemaVersion: 1, id: file.id, salt: file.salt, rounds: Int.max, verifier: file.verifier)
        #expect(throws: SyncError.invalidRecord) { try hostile.unlock(passphrase: "correct horse battery") }
    }

    @Test @MainActor func lockedDevicesOfferNothingUntilTheyEnterThePassphrase() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-login-key-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "kumone-login-key-defaults-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = SyncRepository()
        let connection = UUID()
        _ = try await repository.connect(to: root, connectionID: connection)
        let mac = LoginSync(keyStore: .memory())
        let phoneStore = LoginKeyStore.memory()
        let phone = LoginSync(keyStore: phoneStore)
        let phoneClock = SyncRevisionClock(defaults: defaults, deviceID: UUID(), deviceName: "iPhone")
        try await phone.read(repository: repository, connectionID: connection, clock: phoneClock)
        #expect(phone.keyState == .unset)

        try await mac.createKey(passphrase: "correct horse battery", repository: repository, connectionID: connection)
        #expect(mac.keyState == .unlocked)
        // An offer sealed under any other key is never listed.
        let stale = SyncedLogin(accountID: 42, nickname: "Fixture", cookies: ["MUSIC_U": "synthetic-session"])
        try await repository.write(SyncRecord(revision: .init(counter: 1, deviceID: UUID()), deviceName: "Mac", payload: stale),
                                   domain: .login, connectionID: connection)
        try await phone.read(repository: repository, connectionID: connection, clock: phoneClock)
        #expect(phone.keyState == .locked)
        #expect(try await phone.publish(enabled: true, repository: repository, connectionID: connection, clock: phoneClock).isEmpty)
        #expect(throws: SyncError.loginLocked) { try phone.open(stale) }
        await #expect(throws: SyncError.wrongPassphrase) { try await phone.unlock(passphrase: "wrong horse battery") }
        #expect(phone.keyState == .locked)
        try await phone.unlock(passphrase: "correct horse battery")
        #expect(phone.keyState == .unlocked)

        // A reconnect reloads the key from this device's own store.
        phone.resetConnection()
        try await phone.read(repository: repository, connectionID: connection, clock: phoneClock)
        #expect(phone.keyState == .unlocked)
        // Replacing the passphrase elsewhere locks this device again.
        try await mac.createKey(passphrase: "another horse battery", repository: repository, connectionID: connection)
        try await phone.read(repository: repository, connectionID: connection, clock: phoneClock)
        #expect(phone.keyState == .locked)
        await repository.disconnect(connectionID: connection)
    }

    @Test(arguments: [false, true], [false, true])
    @MainActor func loginConsentWithoutPublicationStillRequiresServerRevocation(syncEnabled: Bool, loginEnabled: Bool) throws {
        let suite = "kumone-login-revocation-consent-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(syncEnabled, forKey: "sync.enabled")
        defaults.set(loginEnabled, forKey: "sync.publishLogin")
        let service = SyncService(defaults: defaults)
        #expect(service.shouldRevokeLoginSession(accountID: 42))
    }

    @Test @MainActor func reconnectWithdrawsAnOldOfferEvenWhenItsQueueIsMissing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-withdraw-missing-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "kumone-withdraw-missing-defaults-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = SyncRepository()
        let connection = UUID()
        _ = try await repository.connect(to: root, connectionID: connection)
        let local = UUID()
        let remote = UUID()
        let track = try JSONDecoder().decode(Track.self, from: Data("{\"id\":1}".utf8))
        let session = PlaybackSession(accountID: 42, queue: [track], orderedQueue: [track],
                                      currentIndex: 0, currentTrack: track, playNext: [], source: .none,
                                      repeatMode: "off", shuffled: false, automaticOrder: false, isFM: false, progress: 10)
        for device in [local, remote] {
            try await repository.writePlayback(SyncRecord(revision: .init(counter: 50, deviceID: device),
                                                           deviceName: "Fixture", payload: session), connectionID: connection)
        }
        let folder = root.appendingPathComponent("Kumone/Devices/\(local.uuidString)/Queues")
        let queue = try #require(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        try FileManager.default.removeItem(at: queue)
        let remoteFile = root.appendingPathComponent("Kumone/Devices/\(remote.uuidString)/playback.json")
        let remoteBytes = try Data(contentsOf: remoteFile)
        let service = SyncService(defaults: defaults, deviceIdentity: { local }, playbackContext: { (nil, nil) })
        await service.connect(to: root)
        let records = try await repository.read(.playback, as: PlaybackCheckpoint.self, connectionID: connection)
        let withdrawn = try #require(records.first { $0.id == local })
        #expect(withdrawn.payload == nil && withdrawn.revision.counter > 50)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        #expect(try Data(contentsOf: remoteFile) == remoteBytes)
        await service.synchronizeNow()
        #expect(service.errorMessage == nil)
        await service.disable()
        await repository.disconnect(connectionID: connection)
    }

    @Test func deviceIdentityPersistsAcrossConcurrentAndSubsequentLoads() async throws {
        let keychainService = "kumone-sync-identity-test-\(UUID())"
        defer {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                      kSecAttrService as String: keychainService,
                                      kSecAttrAccount as String: "device-id"]
            SecItemDelete(query as CFDictionary)
        }
        async let first = SyncDeviceIdentity.load(service: keychainService)
        async let concurrent = SyncDeviceIdentity.load(service: keychainService)
        let (identity, other) = try await (first, concurrent)
        #expect(identity == other)
        #expect(try await SyncDeviceIdentity.load(service: keychainService) == identity)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: keychainService,
                                  kSecAttrAccount as String: "device-id"]
        #expect(SecItemDelete(query as CFDictionary) == errSecSuccess)
        // The process keeps its resolved identity without another Keychain read.
        #expect(try await SyncDeviceIdentity.load(service: keychainService) == identity)
    }

    @Test(arguments: ["malformed", "newer", "invalid-payload"])
    func oneInvalidLoginFileDoesNotHideOtherAccounts(failure: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-partial-login-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SyncRepository()
        let connection = UUID()
        _ = try await repository.connect(to: root, connectionID: connection)
        let login = SyncedLogin(accountID: 42, nickname: "Fixture", cookies: ["MUSIC_U": "synthetic-session"])
        let good = SyncRecord(revision: .init(counter: 1, deviceID: UUID()), deviceName: "Mac", payload: login)
        let badLogin = SyncedLogin(accountID: 99, nickname: "Invalid", cookies: [:])
        let bad = SyncRecord(revision: .init(counter: 2, deviceID: UUID()), deviceName: "iPhone", payload: badLogin)
        for record in [good, bad] {
            try await repository.write(record, domain: .login, connectionID: connection)
        }
        let file = root.appendingPathComponent("Kumone/Devices/\(bad.id.uuidString)/login.json")
        if failure == "malformed" {
            try Data("invalid JSON".utf8).write(to: file)
        } else if failure == "newer" {
            var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(bad)) as? [String: Any])
            object["schemaVersion"] = 2
            try JSONSerialization.data(withJSONObject: object).write(to: file)
        }
        let records = try await repository.read(.login, as: SyncedLogin.self, connectionID: connection)
        #expect(SyncedLogin.availableAccounts(in: records, excluding: UUID()).map(\.id) == [good.id])
        await repository.disconnect(connectionID: connection)
    }

    @Test func invalidLatestLoginDoesNotResurrectItsOlderCredential() {
        let device = UUID()
        let login = SyncedLogin(accountID: 42, nickname: "Fixture", cookies: ["MUSIC_U": "synthetic-session"])
        let old = SyncRecord(revision: .init(counter: 1, deviceID: device), deviceName: "Mac", payload: login)
        let invalid = SyncRecord(revision: .init(counter: 2, deviceID: device), deviceName: "Mac",
                                 payload: SyncedLogin(accountID: 42, nickname: "Invalid", cookies: [:]))
        #expect(SyncedLogin.availableAccounts(in: [old, invalid], excluding: UUID()).isEmpty)
    }

    @Test @MainActor func reinstallReusesItsDeviceAndExcludesItsOwnPlayback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-reinstall-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SyncRepository()
        let connection = UUID()
        _ = try await repository.connect(to: root, connectionID: connection)
        let identity = UUID()
        let remote = UUID()
        let track = try JSONDecoder().decode(Track.self, from: Data("{\"id\":1,\"name\":\"Fixture\"}".utf8))
        let session = PlaybackSession(accountID: 42, queue: [track], orderedQueue: [track],
                                      currentIndex: 0, currentTrack: track, playNext: [], source: .none,
                                      repeatMode: "off", shuffled: false, automaticOrder: false, isFM: false, progress: 0)
        for device in [identity, remote] {
            try await repository.writePlayback(SyncRecord(revision: .init(counter: 9, deviceID: device),
                                                           deviceName: "iPhone", payload: session), connectionID: connection)
        }
        // A fresh defaults domain models reinstall; names deliberately match.
        let suite = "kumone-reinstall-defaults-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = SyncService(defaults: defaults, deviceIdentity: { identity })
        await service.connect(to: root)
        #expect(service.connected)
        #expect(service.sessions.map(\.id) == [remote])
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Kumone/Devices").path)
        #expect(Set(files) == Set([identity.uuidString, remote.uuidString]))
        await service.disable()
        await repository.disconnect(connectionID: connection)
    }

    @Test @MainActor func inaccessibleDeviceIdentityCannotConnectOrPublish() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-identity-error-\(UUID())")
        let suite = "kumone-identity-error-defaults-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = SyncService(defaults: defaults, deviceIdentity: { throw SyncError.unavailable })
        await service.connect(to: root)
        #expect(!service.connected)
        #expect(service.errorMessage != nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        await #expect(throws: SyncError.self) { try await service.enable() }
        #expect(!service.connected)
    }

    @Test @MainActor func disabledSyncDoesNotCapturePreferenceChanges() async throws {
        let suite = "kumone-disabled-sync-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = SettingsManager.shared
        let original = settings.showLyricsTranslation
        defer {
            settings.showLyricsTranslation = original
            defaults.removePersistentDomain(forName: suite)
        }
        let service = SyncService(defaults: defaults)
        await service.start()
        settings.showLyricsTranslation.toggle()
        await service.setForeground(false)
        try await Task.sleep(for: .milliseconds(750))
        #expect(defaults.data(forKey: "sync.preferences") == nil)
        #expect(defaults.object(forKey: "sync.counter") == nil)
    }

    @Test @MainActor func supersededEnableIsCancelledRatherThanRequestingAuthorization() async throws {
        let suite = "kumone-cancel-enable-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ready = AsyncStream<Void>.makeStream()
        let identities = AsyncStream<UUID>.makeStream()
        let service = SyncService(defaults: defaults, deviceIdentity: {
            ready.continuation.yield(())
            for await identity in identities.stream { return identity }
            throw CancellationError()
        })
        let enabling = Task { try await service.enable() }
        for await _ in ready.stream { break }
        await service.disable()
        identities.continuation.yield(UUID())
        identities.continuation.finish()
        ready.continuation.finish()
        await #expect(throws: CancellationError.self) { try await enabling.value }
        #expect(!service.enabled && !service.connected)
    }

    @Test(arguments: [SyncRepository.Domain.preferences, .playback])
    @MainActor func failedDomainDoesNotBlockLoginWithdrawalOrOtherDomains(domain: SyncRepository.Domain) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-domain-failure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "kumone-domain-failure-defaults-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = SyncRepository()
        let connection = UUID()
        _ = try await repository.connect(to: root, connectionID: connection)
        let local = UUID()
        let remote = UUID()
        let revision = SyncRevision(counter: 30, deviceID: remote)
        let track = try JSONDecoder().decode(Track.self, from: Data("{\"id\":1}".utf8))
        let session = PlaybackSession(accountID: 42, queue: [track], orderedQueue: [track],
                                      currentIndex: 0, currentTrack: track, playNext: [], source: .none,
                                      repeatMode: "off", shuffled: false, automaticOrder: false, isFM: false, progress: 10)
        let preferences = SyncedPreferences(fields: ["future-option": .init(value: .boolean(true), revision: revision)])
        let preferenceRecord = SyncRecord(revision: revision, deviceName: "Remote", payload: preferences)
        let playbackRecord = SyncRecord(revision: revision, deviceName: "Remote", payload: session)
        try await repository.write(preferenceRecord, domain: .preferences, connectionID: connection)
        try await repository.writePlayback(playbackRecord, connectionID: connection)
        let login = SyncedLogin(accountID: 42, nickname: "Fixture", cookies: ["MUSIC_U": "synthetic-session"])
        for device in [local, remote] {
            try await repository.write(SyncRecord(revision: .init(counter: 31, deviceID: device),
                                                   deviceName: "Fixture", payload: login), domain: .login, connectionID: connection)
        }
        try await writeFixtureLoginKey(to: repository, connectionID: connection)
        let brokenFile = root.appendingPathComponent("Kumone/Devices/\(remote.uuidString)/\(domain.rawValue).json")
        try Data("invalid JSON".utf8).write(to: brokenFile, options: .atomic)
        let service = SyncService(defaults: defaults, deviceIdentity: { local })
        await service.connect(to: root)
        #expect(service.connected)
        #expect(service.errorMessage != nil)
        #expect(service.logins.map(\.id) == [remote])
        if domain == .preferences { #expect(service.sessions.map(\.id) == [remote]) }
        else {
            let records = try await repository.read(.preferences, as: SyncedPreferences.self, connectionID: connection)
            #expect(records.first { $0.id == local }?.payload?.fields["future-option"] != nil)
        }
        let loginRecords = try await repository.read(.login, as: SyncedLogin.self, connectionID: connection)
        #expect(try #require(loginRecords.first { $0.id == local }).payload == nil)
        if domain == .preferences {
            try await repository.write(preferenceRecord, domain: .preferences, connectionID: connection)
        } else {
            try await repository.writePlayback(playbackRecord, connectionID: connection)
        }
        // A local-only round still retries a domain whose preceding read failed.
        await service.synchronizeNow(refreshing: [], publishing: [])
        #expect(service.errorMessage == nil)
        #expect(service.sessions.map(\.id) == [remote])
        await service.disable()
        await repository.disconnect(connectionID: connection)
    }

    @Test @MainActor func directedPreferenceSyncSkipsPlaybackAndUnrelatedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-directed-sync-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "kumone-directed-sync-defaults-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let device = UUID()
        var playbackReads = 0
        let service = SyncService(defaults: defaults, deviceIdentity: { device }, playbackContext: {
            playbackReads += 1
            return (nil, nil)
        })
        await service.connect(to: root)
        await service.setForeground(false)
        playbackReads = 0
        let folder = root.appendingPathComponent("Kumone/Devices/\(device.uuidString)")
        try Data("broken".utf8).write(to: folder.appendingPathComponent("playback.json"), options: .atomic)
        let saved = defaults.data(forKey: "sync.preferences")
        var notifications = 0
        let observer = service.objectWillChange.sink { notifications += 1 }
        await service.synchronizeNow(refreshing: [.preferences], publishing: [.preferences])
        #expect(playbackReads == 0)
        #expect(service.errorMessage == nil)
        #expect(defaults.data(forKey: "sync.preferences") == saved)
        #expect(notifications == 0)
        observer.cancel()
        await service.disable()
    }

    @Test @MainActor func overlappingConnectionsKeepOnlyTheLatestDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-connect-race-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "kumone-connect-race-defaults-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let identities = AsyncStream<CheckedContinuation<UUID, Error>>.makeStream()
        let service = SyncService(defaults: defaults, deviceIdentity: {
            try await withCheckedThrowingContinuation { identities.continuation.yield($0) }
        }, playbackContext: { (nil, nil) })
        var iterator = identities.stream.makeAsyncIterator()
        let oldFolder = root.appendingPathComponent("Old")
        let newFolder = root.appendingPathComponent("New")
        let firstConnectTask = Task { await service.connect(to: oldFolder) }
        let oldIdentity = try #require(await iterator.next())
        let secondConnectTask = Task { await service.connect(to: newFolder) }
        let newIdentity = try #require(await iterator.next())
        let device = UUID()
        newIdentity.resume(returning: device)
        await secondConnectTask.value
        oldIdentity.resume(returning: device)
        await firstConnectTask.value
        identities.continuation.finish()
        #expect(service.connected && service.errorMessage == nil)
        #expect(!FileManager.default.fileExists(atPath: oldFolder.path))
        #expect(FileManager.default.fileExists(atPath: newFolder.appendingPathComponent("Kumone/Devices/\(device.uuidString)/preferences.json").path))
        await service.disable()
    }

    @Test @MainActor func overlappingDomainRequestsDrainWithoutPublishingTwice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-request-drain-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "kumone-request-drain-defaults-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let device = UUID()
        let track = try JSONDecoder().decode(Track.self, from: Data("{\"id\":1}".utf8))
        let session = PlaybackSession(accountID: 42, queue: [track], orderedQueue: [track], currentIndex: 0,
                                      currentTrack: track, playNext: [], source: .none, repeatMode: "off",
                                      shuffled: false, automaticOrder: false, isFM: false, progress: 20)
        var playbackReads = 0
        let service = SyncService(defaults: defaults, deviceIdentity: { device }, playbackContext: {
            playbackReads += 1
            return (session, 42)
        })
        await service.connect(to: root)
        await service.setForeground(false)
        playbackReads = 0
        async let preferencesSyncTask: Void = service.synchronizeNow(refreshing: [.preferences], publishing: [.preferences])
        async let playbackSyncTask: Void = service.synchronizeNow(refreshing: [], publishing: [.playback])
        await preferencesSyncTask
        await playbackSyncTask
        #expect(playbackReads == 1)
        #expect(service.errorMessage == nil)
        await service.disable()
    }

    @Test @MainActor func periodicRefreshFollowsActivityAndRejectsOldConnectionWakeups() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-periodic-sync-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "kumone-periodic-sync-defaults-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = SyncPeriodicClock()
        defer { clock.waits.continuation.finish() }
        var waits = clock.waits.stream.makeAsyncIterator()
        var playbackReads = 0
        let service = SyncService(defaults: defaults, deviceIdentity: { UUID() }, playbackContext: {
            playbackReads += 1
            return (nil, nil)
        }, periodicRefreshSleep: { await clock.sleep() })

        await service.connect(to: root.appendingPathComponent("First"))
        let firstWait = try #require(await waits.next())
        for _ in 0..<3 { await service.synchronizeNow() }
        #expect(clock.sleepCount == 1)

        await service.setForeground(false)
        firstWait.resume()
        await service.synchronizeNow()
        #expect(clock.sleepCount == 1)

        service.updatePeriodicRefreshTask(isPlaying: true)
        let playbackWait = try #require(await waits.next())
        service.updatePeriodicRefreshTask(isPlaying: true)
        #expect(clock.sleepCount == 2)
        service.updatePeriodicRefreshTask(isPlaying: false)
        playbackWait.resume()

        await service.setForeground(true)
        let oldConnectionWait = try #require(await waits.next())
        await service.disable()
        await service.connect(to: root.appendingPathComponent("Second"))
        let currentWait = try #require(await waits.next())
        oldConnectionWait.resume()
        await service.synchronizeNow()
        #expect(clock.sleepCount == 4)

        playbackReads = 0
        currentWait.resume()
        let nextWait = try #require(await waits.next())
        #expect(playbackReads == 1)
        #expect(clock.sleepCount == 5)
        #expect(service.connected && service.errorMessage == nil)
        await service.disable()
        nextWait.resume()
    }

    @Test @MainActor func sleepingPeriodicRefreshDoesNotRetainTheService() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-periodic-release-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "kumone-periodic-release-defaults-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = SyncPeriodicClock()
        defer { clock.waits.continuation.finish() }
        var waits = clock.waits.stream.makeAsyncIterator()
        var service: SyncService? = SyncService(defaults: defaults, deviceIdentity: { UUID() },
                                               playbackContext: { (nil, nil) },
                                               periodicRefreshSleep: { await clock.sleep() })
        await service?.connect(to: root)
        let sleeping = try #require(await waits.next())
        weak var releasedService = service
        service = nil
        #expect(releasedService == nil)
        sleeping.resume()
    }

    @Test func concurrentPreferencesMergePerFieldAndConvergeInEitherOrder() throws {
        let deviceA = UUID()
        let deviceB = UUID()
        let a = PreferenceEdit(value: .string("dark"), revision: .init(counter: 3, deviceID: deviceA))
        let b = PreferenceEdit(value: .string("lossless"), revision: .init(counter: 3, deviceID: deviceB))
        let left = SyncedPreferences(fields: ["appearance": a])
        let right = SyncedPreferences(fields: ["quality": b])
        var forward = left
        forward.merge(right)
        var backward = right
        backward.merge(left)
        #expect(forward == backward)
        #expect(forward.fields["appearance"] == a)
        #expect(forward.fields["quality"] == b)
        let concurrent = SyncedPreferences(fields: ["appearance": .init(value: .string("light"), revision: b.revision)])
        forward.merge(concurrent)
        var reversed = concurrent
        reversed.merge(backward)
        #expect(forward == reversed)
        forward.merge(SyncedPreferences(fields: ["future-setting": b]))
        #expect(forward.fields["future-setting"] == b)
    }

    @Test func directoryLoginsCollapseAccountsAfterResolvingDeviceDeletions() throws {
        let login = SyncedLogin(accountID: 42, nickname: "Fixture", cookies: ["MUSIC_U": "synthetic-session"])
        let mac = UUID()
        let phone = UUID()
        let receiver = UUID()
        let first = SyncRecord(revision: .init(counter: 1, deviceID: mac), deviceName: "Mac", payload: login)
        let duplicate = SyncRecord(revision: .init(counter: 2, deviceID: phone), deviceName: "iPhone", payload: login)
        let withdrawn = SyncRecord<SyncedLogin>(revision: .init(counter: 3, deviceID: phone), deviceName: "iPhone", payload: nil)
        let accounts = SyncedLogin.availableAccounts(in: [first, duplicate], excluding: receiver)
        #expect(accounts.map(\.id) == [phone])
        let remaining = SyncedLogin.availableAccounts(in: [duplicate, withdrawn, first], excluding: receiver)
        #expect(remaining.map(\.id) == [mac])
        #expect(SyncedLogin.availableAccounts(in: [duplicate, withdrawn, first], excluding: mac).isEmpty)

        #expect(throws: SyncError.self) { try SyncedLogin(accountID: 42, nickname: "Fixture", cookies: [:]).validate() }
        #expect(throws: SyncError.self) { try SyncedLogin(accountID: 0, nickname: "Fixture", cookies: login.cookies).validate() }
    }

    @Test @MainActor func loginPublicationRequiresExplicitConsent() throws {
        let suite = "kumone-sync-consent-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!SyncService(defaults: defaults).loginEnabled)
        defaults.set(true, forKey: "sync.publishLogin")
        #expect(SyncService(defaults: defaults).loginEnabled)
    }

    @Test func loginUsesOneFileAndSupportsWithdrawal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-login-format-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SyncRepository()
        let connection = UUID()
        _ = try await repository.connect(to: root, connectionID: connection)
        let login = SyncedLogin(accountID: 42, nickname: "Fixture", cookies: ["MUSIC_U": "synthetic-session"])
        let record = SyncRecord(revision: .init(counter: 1, deviceID: UUID()), deviceName: "Mac", payload: login)
        try await repository.write(record, domain: .login, connectionID: connection)
        let device = root.appendingPathComponent("Kumone/Devices/\(record.id.uuidString)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: device.path) == ["login.json"])
        let received = try await repository.read(.login, as: SyncedLogin.self, connectionID: connection)
        let imported = SyncedLogin.availableAccounts(in: received, excluding: UUID())
        #expect(imported.count == 1)
        #expect(imported.first?.payload == login)
        let tombstone = SyncRecord<SyncedLogin>(revision: .init(counter: 2, deviceID: record.id), deviceName: "Mac", payload: nil)
        try await repository.write(tombstone, domain: .login, connectionID: connection)
        let withdrawn = try await repository.read(.login, as: SyncedLogin.self, connectionID: connection)
        #expect(SyncedLogin.availableAccounts(in: withdrawn, excluding: UUID()).isEmpty)
        await repository.disconnect(connectionID: connection)
    }

    @Test @MainActor func failedDirectoryChangeRevokesPreviouslyOfferedLogins() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-login-reconnect-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "kumone-sync-reconnect-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = SyncRepository()
        let connection = UUID()
        _ = try await repository.connect(to: root, connectionID: connection)
        let record = SyncRecord(revision: .init(counter: 1, deviceID: UUID()), deviceName: "Mac", payload: SyncedLogin(accountID: 42, nickname: "Fixture", cookies: ["MUSIC_U": "synthetic-session"]))
        try await repository.write(record, domain: .login, connectionID: connection)
        try await writeFixtureLoginKey(to: repository, connectionID: connection)
        let identity = UUID()
        let service = SyncService(defaults: defaults, deviceIdentity: { identity })
        await service.connect(to: root)
        #expect(service.connected)
        #expect(service.logins.map(\.id) == [record.id])
        #expect(!service.loginEnabled)

        let invalidDirectory = root.appendingPathComponent("not-a-directory")
        try Data().write(to: invalidDirectory)
        await service.connect(to: invalidDirectory)
        #expect(!service.connected && service.logins.isEmpty)
        #expect(service.errorMessage != nil)
        await #expect(throws: CancellationError.self) { try await service.importLogin(record) }
        #expect(!service.loginEnabled)
        await service.connect(to: root)
        #expect(service.connected)
        await service.disable()
        #expect(!service.connected)
        #expect(try await service.enable())
        #expect(service.connected)
        await service.disable()
        await repository.disconnect(connectionID: connection)
    }

    @Test func localSignOutKeepsTheOtherDevicesSharedLoginAvailableForReturn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-return-login-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SyncRepository()
        let connection = UUID()
        _ = try await repository.connect(to: root, connectionID: connection)
        let mac = UUID()
        let phone = UUID()
        let macClient = MusicClient(cookieDirectory: root.appendingPathComponent("mac"))
        let phoneClient = MusicClient(cookieDirectory: root.appendingPathComponent("phone"))
        macClient.setCookies(["MUSIC_U": "synthetic-shared-session"])
        let login = SyncedLogin(accountID: 42, nickname: "Fixture", cookies: macClient.authenticationCookies())
        try await repository.write(SyncRecord(revision: .init(counter: 1, deviceID: mac), deviceName: "Mac",
                                              payload: login), domain: .login, connectionID: connection)

        try phoneClient.replaceAuthentication(with: login.cookies)
        let received = SyncedLogin(accountID: 42, nickname: "Fixture", cookies: phoneClient.authenticationCookies())
        try await repository.write(SyncRecord(revision: .init(counter: 2, deviceID: phone), deviceName: "iPhone",
                                              payload: received), domain: .login, connectionID: connection)
        try macClient.clearAuthCookies()
        let signedOut = SyncRecord<SyncedLogin>(revision: .init(counter: 3, deviceID: mac), deviceName: "Mac",
                                                payload: nil)
        try await repository.write(signedOut, domain: .login, connectionID: connection)

        #expect(!macClient.isLoggedIn)
        #expect(phoneClient.isLoggedIn)
        let records = try await repository.read(.login, as: SyncedLogin.self, connectionID: connection)
        let accounts = SyncedLogin.availableAccounts(in: records, excluding: mac)
        #expect(accounts.map(\.id) == [phone])
        let returnLogin = try #require(accounts.first?.payload)
        try macClient.replaceAuthentication(with: returnLogin.cookies)
        #expect(macClient.isLoggedIn)
        #expect(MusicClient(cookieDirectory: root.appendingPathComponent("phone")).isLoggedIn)
        await repository.disconnect(connectionID: connection)
    }

    @Test func repeatedSongsPreserveTheirCursorAndPlayNextTrack() throws {
        let track = try JSONDecoder().decode(Track.self, from: Data("{\"id\":1,\"name\":\"Fixture\",\"dt\":200000}".utf8))
        let next = try JSONDecoder().decode(Track.self, from: Data("{\"id\":2,\"name\":\"Next\"}".utf8))
        let session = PlaybackSession(accountID: 42, queue: [track, track], orderedQueue: [track, track],
                                      currentIndex: 1, currentTrack: next, playNext: [next], source: .playlist(7),
                                      repeatMode: "all", shuffled: true, automaticOrder: false, isFM: false, progress: 95)
        try session.validate()
        let restored = try JSONDecoder().decode(PlaybackSession.self, from: JSONEncoder().encode(session))
        #expect(restored == session)
        #expect(restored.currentIndex == 1)
    }

    @Test func compactPlaybackSnapshotKeepsMetadataVariantsAndQueueOccurrences() throws {
        let first = try JSONDecoder().decode(Track.self, from: Data("{\"id\":1,\"name\":\"Original\"}".utf8))
        let variant = try JSONDecoder().decode(Track.self, from: Data("{\"id\":1,\"name\":\"Updated\"}".utf8))
        let outside = try JSONDecoder().decode(Track.self, from: Data("{\"id\":2,\"name\":\"FM\"}".utf8))
        let session = PlaybackSession(accountID: 42, queue: [first, first, variant],
                                      orderedQueue: [variant, first, first], currentIndex: 2,
                                      currentTrack: outside, playNext: [outside, first, outside], source: .none,
                                      repeatMode: "off", shuffled: true, automaticOrder: false, isFM: true, progress: 32)
        let data = try JSONEncoder().encode(session)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((object["tracks"] as? [[String: Any]])?.count == 3)
        #expect(object["queue"] as? [Int] == [0, 0, 1])
        #expect(object["orderedQueue"] as? [Int] == [1, 0, 0])
        #expect(object["currentTrack"] as? Int == 2)
        #expect(try JSONDecoder().decode(PlaybackSession.self, from: data) == session)
        let record = SyncRecord(revision: .init(counter: 1, deviceID: UUID()), deviceName: "Fixture", payload: session)
        let envelope = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        #expect(envelope["accountID"] == nil)
    }

    @Test(arguments: ["queue", "orderedQueue", "currentTrack", "playNext"])
    func compactPlaybackSnapshotRejectsInvalidReferences(field: String) throws {
        let track = try JSONDecoder().decode(Track.self, from: Data("{\"id\":1}".utf8))
        let session = PlaybackSession(accountID: 42, queue: [track], orderedQueue: [track],
                                      currentIndex: 0, currentTrack: track, playNext: [], source: .none,
                                      repeatMode: "off", shuffled: false, automaticOrder: false, isFM: false, progress: 0)
        let encoded = try JSONEncoder().encode(session)
        for reference in [-1, 1] {
            var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            object[field] = field == "currentTrack" ? reference : [reference]
            let invalid = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: SyncError.self) { try JSONDecoder().decode(PlaybackSession.self, from: invalid) }
        }
    }

    @Test func repositoryRetainsIndependentDevicesAndRejectsAnOldConnection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-sync-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SyncRepository()
        let connection = UUID()
        _ = try await repository.connect(to: root, connectionID: connection)
        let first = SyncRecord(revision: .init(counter: 1, deviceID: UUID()), deviceName: "Mac", payload: SyncedPreferences())
        let second = SyncRecord(revision: .init(counter: 1, deviceID: UUID()), deviceName: "iPhone", payload: SyncedPreferences(fields: ["new-key": .init(value: .boolean(true), revision: first.revision)]))
        try await repository.write(first, domain: .preferences, connectionID: connection)
        try await repository.write(second, domain: .preferences, connectionID: connection)
        let records = try await repository.read(.preferences, as: SyncedPreferences.self, connectionID: connection)
        #expect(Set(records.map(\.id)) == [first.id, second.id])
        await repository.disconnect(connectionID: connection)
        await #expect(throws: CancellationError.self) {
            try await repository.write(first, domain: .preferences, connectionID: connection)
        }
    }

    @Test func validationClientCannotPersistReceivedCredentials() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-auth-sync-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = MusicClient(cookieDirectory: directory, configuration: .ephemeral, persistsCookies: false)
        client.setCookies(["MUSIC_U": "synthetic-received-session"])
        #expect(client.isLoggedIn)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test(arguments: [Int?(42), Int?(99), nil])
    func handoffRequiresTheSameSignedInAccount(accountID: Int?) throws {
        let publicTrack = try JSONDecoder().decode(Track.self, from: Data("{\"id\":1,\"name\":\"Public\"}".utf8))
        let privateTrack = try JSONDecoder().decode(Track.self, from: Data("{\"id\":2,\"name\":\"Private\",\"pc\":{}}".utf8))
        let publicSession = PlaybackSession(accountID: 42, queue: [publicTrack], orderedQueue: [publicTrack],
                                            currentIndex: 0, currentTrack: publicTrack, playNext: [], source: .none,
                                            repeatMode: "off", shuffled: false, automaticOrder: false, isFM: false, progress: 0)
        let privateSession = PlaybackSession(accountID: 42, queue: [publicTrack], orderedQueue: [publicTrack],
                                             currentIndex: 0, currentTrack: privateTrack, playNext: [], source: .cloud,
                                             repeatMode: "off", shuffled: false, automaticOrder: false, isFM: false, progress: 0)
        for session in [publicSession, privateSession] {
            if accountID == 42 { try session.validateAccess(accountID: accountID) }
            else { #expect(throws: SyncError.self) { try session.validateAccess(accountID: accountID) } }
        }
        let guestSession = PlaybackSession(accountID: nil, queue: [publicTrack], orderedQueue: [publicTrack],
                                           currentIndex: 0, currentTrack: publicTrack, playNext: [], source: .none,
                                           repeatMode: "off", shuffled: false, automaticOrder: false, isFM: false, progress: 0)
        #expect(throws: SyncError.self) { try guestSession.validateAccess(accountID: nil) }
    }

    @Test func authenticationReplacementPreservesDeviceCookiesAndDropsOldCSRF() throws {
        let client = MusicClient(configuration: .ephemeral, persistsCookies: false)
        client.setCookies(["MUSIC_U": "synthetic-old", "__csrf": "synthetic-old-csrf", "device": "local-device"])
        let before = client.authenticationFingerprint
        try client.replaceAuthentication(with: ["MUSIC_U": "synthetic-new"])
        #expect(client.cookie(named: "MUSIC_U") == "synthetic-new")
        #expect(client.cookie(named: "__csrf") == nil)
        #expect(client.cookie(named: "device") == "local-device")
        #expect(client.authenticationFingerprint != before)
    }

    @Test(arguments: [false, true])
    func failedAuthenticationPersistenceLeavesTheLiveLoginIntact(signingOut: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-sync-auth-failure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = MusicClient(cookieDirectory: root)
        client.setCookies(["MUSIC_U": "synthetic-current"])
        let binding = client.authenticationFingerprint
        let file = root.appendingPathComponent("cookies.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            if signingOut { try client.clearAuthCookies() }
            else { try client.replaceAuthentication(with: ["MUSIC_U": "synthetic-received"]) }
        }
        #expect(client.cookie(named: "MUSIC_U") == "synthetic-current")
        #expect(client.authenticationFingerprint == binding)
    }

    @Test func renamedRepositoryIsReusedAndNewerDataIsNotOverwritten() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-sync-rename-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SyncRepository()
        let firstConnection = UUID()
        _ = try await repository.connect(to: root, connectionID: firstConnection)
        let record = SyncRecord(revision: .init(counter: 5, deviceID: UUID()), deviceName: "Mac", payload: SyncedPreferences())
        try await repository.write(record, domain: .preferences, connectionID: firstConnection)
        await repository.disconnect(connectionID: firstConnection)
        let original = root.appendingPathComponent("Kumone")
        let renamed = root.appendingPathComponent("Renamed")
        try FileManager.default.moveItem(at: original, to: renamed)
        let connection = UUID()
        _ = try await repository.connect(to: renamed, connectionID: connection)
        let records = try await repository.read(.preferences, as: SyncedPreferences.self, connectionID: connection)
        #expect(records.map(\.id) == [record.id])
        #expect(!FileManager.default.fileExists(atPath: renamed.appendingPathComponent("Kumone").path))

        let file = renamed.appendingPathComponent("Devices").appendingPathComponent(record.id.uuidString)
            .appendingPathComponent("preferences.json")
        let encoded = try JSONEncoder().encode(record)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["schemaVersion"] = 99
        object["payload"] = ["future-shape": true]
        let newer = try JSONSerialization.data(withJSONObject: object)
        try newer.write(to: file, options: .atomic)
        await #expect(throws: SyncError.self) {
            try await repository.read(.preferences, as: SyncedPreferences.self, connectionID: connection)
        }
        #expect(try Data(contentsOf: file) == newer)
        await repository.disconnect(connectionID: connection)
    }
}
