import Foundation
import Testing
@testable import KumoneCore

private actor AudioValidationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }

    func waitUntilEntered() async throws {
        for _ in 0..<200 {
            if entered { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(entered)
    }
}

@Suite("Offline storage")
struct OfflineStoreTests {
    private func gatedStore(_ gate: AudioValidationGate, fails: Bool = false) -> OfflineStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-offline-test-\(UUID())")
        return OfflineStore(directory: root, minimumFreeBytes: 0, validateAudio: { url, descriptor in
            await gate.wait()
            if fails { throw OfflineAudioError.checksumMismatch }
            try OfflineAudioValidator.validate(url: url, descriptor: descriptor)
        })
    }

    @Test(arguments: [false, true])
    func removingTheLastOwnerDuringVerificationDiscardsTheFile(fails: Bool) async throws {
        let fixture = try OfflineAudioFixture(.flac), gate = AudioValidationGate()
        let store = gatedStore(gate, fails: fails), id = fixture.descriptor.identity.id
        defer { try? FileManager.default.removeItem(at: store.directory) }
        // A download whose file went missing keeps its record; the import repairs it.
        #expect(try await store.record(id: id) == nil)
        let database = try OfflineAudioDatabase(url: store.directory.appendingPathComponent("index.sqlite"))
        var seed = OfflineAudioRecord(descriptor: fixture.descriptor)
        seed.state = .missing
        seed.retainedBy = ["download:old"]
        try database.save(seed)
        let validation = Task { try await store.importFixture(fixture.data, descriptor: fixture.descriptor) }
        try await gate.waitUntilEntered()
        try await store.removeRetention(id: id, owner: "download:old")
        await gate.open()
        if fails {
            await #expect(throws: OfflineAudioError.checksumMismatch) { try await validation.value }
        } else {
            await #expect(throws: CancellationError.self) { try await validation.value }
        }
        #expect(try await store.record(id: id) == nil)
        #expect(try await store.acquire(accountScope: "test-account", trackID: 1, preferredQuality: "exhigh") == nil)
    }

    @Test func preferredQualityCanExcludeLowerQuality() async throws {
        let low = try OfflineAudioFixture(), store = low.store()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try await store.importFixture(low.data, descriptor: low.descriptor)
        #expect(try await store.acquire(accountScope: "test-account", trackID: 1,
                                       preferredQuality: "lossless", allowLowerQuality: false) == nil)
        let offline = try #require(try await store.acquire(accountScope: "test-account", trackID: 1, preferredQuality: "lossless"))
        #expect(offline.descriptor.identity.quality == "exhigh")
        #expect(try Data(contentsOf: offline.url) == low.data)
        try await store.release(offline)

        let high = try OfflineAudioFixture(.flac)
        let descriptor = OfflineAudioDescriptor(identity: .init(accountScope: "test-account", trackID: 1, source: "netease", quality: "lossless",
                                                               format: .flac, contentMD5: high.descriptor.identity.contentMD5),
                                                byteCount: high.descriptor.byteCount, duration: 3)
        try await store.importFixture(high.data, descriptor: descriptor)
        let preferred = try #require(try await store.acquire(accountScope: "test-account", trackID: 1,
                                                            preferredQuality: "lossless", allowLowerQuality: false))
        #expect(preferred.descriptor.identity.quality == "lossless")
        try await store.release(preferred)
        try await store.remove(id: low.descriptor.identity.id)
        let better = try #require(try await store.acquire(accountScope: "test-account", trackID: 1,
                                                         preferredQuality: "exhigh", allowLowerQuality: false))
        #expect(better.descriptor.identity.quality == "lossless")
        try await store.release(better)
    }

    @Test(arguments: OfflineAudioFormat.allCases)
    func completeFileSurvivesReopening(_ format: OfflineAudioFormat) async throws {
        let fixture = try OfflineAudioFixture(format), store = fixture.store()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try await store.importFixture(fixture.data, descriptor: fixture.descriptor)
        let reopened = OfflineStore(directory: store.directory, minimumFreeBytes: 0)
        let lease = try #require(try await reopened.acquire(accountScope: "test-account", trackID: 1, preferredQuality: "exhigh"))
        #expect(try Data(contentsOf: lease.url) == fixture.data)
        #expect(try lease.url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(try await reopened.acquire(accountScope: "another-account", trackID: 1, preferredQuality: "exhigh") == nil)
        try await reopened.release(lease)
    }

    @Test func checksumFailureNeverBecomesComplete() async throws {
        let fixture = try OfflineAudioFixture(), store = fixture.store()
        let id = fixture.descriptor.identity.id
        defer { try? FileManager.default.removeItem(at: store.directory) }
        var corrupt = fixture.data
        corrupt[100] ^= 0xff
        await #expect(throws: OfflineAudioError.checksumMismatch) {
            try await store.importFixture(corrupt, descriptor: fixture.descriptor)
        }
        #expect(try await store.record(id: id) == nil)
    }

    @Test func wrongSizedFileIsRejectedBeforeItIsMoved() async throws {
        let fixture = try OfflineAudioFixture(), store = fixture.store()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let input = store.directory.appendingPathComponent("input.mp3")
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try (fixture.data + Data([0])).write(to: input)
        await #expect(throws: OfflineAudioError.incomplete) {
            try await store.importDownload(at: input, descriptor: fixture.descriptor)
        }
        #expect(try await store.record(id: fixture.descriptor.identity.id) == nil)
        #expect(FileManager.default.fileExists(atPath: input.path))
    }

    @Test func sharedRetentionAndPlaybackProtectFile() async throws {
        let fixture = try OfflineAudioFixture(), store = fixture.store()
        let id = fixture.descriptor.identity.id
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try await store.importFixture(fixture.data, descriptor: fixture.descriptor)
        try await store.retain(id: id, owner: "playlist:1")
        try await store.retain(id: id, owner: "playlist:2")
        try await store.removeRetention(id: id, owner: "playlist:1")
        #expect(try await store.record(id: id)?.retainedBy == ["playlist:2"])
        await #expect(throws: OfflineAudioError.retained) { try await store.remove(id: id) }
        let lease = try #require(try await store.acquire(accountScope: "test-account", trackID: 1, preferredQuality: "exhigh"))
        // The last owner leaving deletes the file, but not under a playing song.
        try await store.removeRetention(id: id, owner: "playlist:2")
        #expect(FileManager.default.fileExists(atPath: lease.url.path))
        #expect(try await store.acquire(accountScope: "test-account", trackID: 1, preferredQuality: "exhigh") == nil)
        try await store.release(lease)
        #expect(!FileManager.default.fileExists(atPath: lease.url.path))
        #expect(try await store.record(id: id) == nil)
    }

    @Test func rejectsACompetingImportOfTheSameAsset() async throws {
        let fixture = try OfflineAudioFixture(), gate = AudioValidationGate()
        let store = gatedStore(gate), id = fixture.descriptor.identity.id
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let first = Task { try await store.importFixture(fixture.data, descriptor: fixture.descriptor) }
        try await gate.waitUntilEntered()
        await #expect(throws: OfflineAudioError.busy) { try await store.importFixture(fixture.data, descriptor: fixture.descriptor) }
        await gate.open()
        try await first.value
        #expect(try await store.record(id: id)?.state == .complete)
        // A second copy of a complete asset is a no-op, not a busy error.
        try await store.importFixture(fixture.data, descriptor: fixture.descriptor)
        try await store.remove(id: id)
        #expect(try await store.record(id: id) == nil)
    }

    @Test func recoversInterruptedVerification() async throws {
        let fixture = try OfflineAudioFixture(), store = fixture.store()
        let id = fixture.descriptor.identity.id
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try await store.importFixture(fixture.data, descriptor: fixture.descriptor)
        // Simulate death after the file was renamed but before its record was published.
        let db = try OfflineAudioDatabase(url: store.directory.appendingPathComponent("index.sqlite"))
        var record = try #require(try db.record(id: id))
        record.state = .verifying
        try db.save(record)
        let reopened = OfflineStore(directory: store.directory, minimumFreeBytes: 0)
        let lease = try #require(try await reopened.acquire(accountScope: "test-account", trackID: 1, preferredQuality: "exhigh"))
        #expect(try Data(contentsOf: lease.url) == fixture.data)
        try await reopened.release(lease)
    }

    @Test func changedFileLosesAvailabilityButKeepsDownloadIntent() async throws {
        let fixture = try OfflineAudioFixture(), store = fixture.store()
        let id = fixture.descriptor.identity.id
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try await store.importFixture(fixture.data, descriptor: fixture.descriptor)
        try await store.retain(id: id, owner: "manual")
        let lease = try #require(try await store.acquire(accountScope: "test-account", trackID: 1, preferredQuality: "exhigh"))
        try await store.release(lease)
        var corrupt = fixture.data
        corrupt[100] ^= 0xff
        try corrupt.write(to: lease.url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: lease.url.path)
        #expect(try await store.acquire(accountScope: "test-account", trackID: 1, preferredQuality: "exhigh") == nil)
        let missing = try #require(try await store.record(id: id))
        #expect(missing.state == .missing)
        #expect(missing.retainedBy == ["manual"])
        try await store.importFixture(fixture.data, descriptor: fixture.descriptor)
        #expect(try await store.record(id: id)?.state == .complete)
        #expect(try await store.record(id: id)?.retainedBy == ["manual"])
    }

    @Test func cleansOrphansAndRecoversCommitAfterRename() async throws {
        let fixture = try OfflineAudioFixture(), store = fixture.store()
        let id = fixture.descriptor.identity.id
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try await store.importFixture(fixture.data, descriptor: fixture.descriptor)
        let db = try OfflineAudioDatabase(url: store.directory.appendingPathComponent("index.sqlite"))
        var record = try #require(try db.record(id: id))
        record.state = .verifying
        try db.save(record)
        let orphan = store.directory.appendingPathComponent(fixture.descriptor.identity.scopeDirectory)
            .appendingPathComponent("staging/\(String(repeating: "a", count: 64)).mp3")
        try Data([1, 2, 3]).write(to: orphan)
        let reopened = OfflineStore(directory: store.directory, minimumFreeBytes: 0)
        let lease = try #require(try await reopened.acquire(accountScope: "test-account", trackID: 1, preferredQuality: "exhigh"))
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        try await reopened.release(lease)
    }

    @Test func removingUnownedAudioKeepsDownloadsAndPlayingSongs() async throws {
        let store = try OfflineAudioFixture().store()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        func descriptor(_ trackID: Int, _ fixture: OfflineAudioFixture) -> OfflineAudioDescriptor {
            .init(identity: .init(accountScope: "test-account", trackID: trackID, source: "netease", quality: "exhigh",
                                  format: fixture.descriptor.identity.format, contentMD5: fixture.descriptor.identity.contentMD5),
                  byteCount: fixture.descriptor.byteCount, duration: 3)
        }
        let fixture = try OfflineAudioFixture()
        let unowned = descriptor(1, fixture), owned = descriptor(2, fixture), playing = descriptor(3, fixture)
        for entry in [unowned, owned, playing] { try await store.importFixture(fixture.data, descriptor: entry) }
        try await store.retain(id: owned.identity.id, owner: "download:2")
        let lease = try #require(try await store.acquire(accountScope: "test-account", trackID: 3, preferredQuality: "exhigh"))
        try await store.removeUnretained()
        #expect(try await store.record(id: unowned.identity.id) == nil)
        #expect(try await store.record(id: owned.identity.id)?.state == .complete)
        #expect(FileManager.default.fileExists(atPath: lease.url.path))
        try await store.release(lease)
        #expect(try await store.record(id: playing.identity.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: lease.url.path))
    }

    @Test func legacyStreamedEntriesAreRetiredOnOpen() async throws {
        let fixture = try OfflineAudioFixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-offline-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = try OfflineAudioDatabase(url: root.appendingPathComponent("index.sqlite"))
        // Earlier builds streamed audio into staging and indexed it as `partial`.
        var cached = OfflineAudioRecord(descriptor: fixture.descriptor)
        cached.state = .partial
        try db.save(cached)
        let ownedDescriptor = OfflineAudioDescriptor(identity: .init(accountScope: "test-account", trackID: 2, source: "netease",
            quality: "exhigh", format: .mp3, contentMD5: fixture.descriptor.identity.contentMD5), byteCount: fixture.descriptor.byteCount, duration: 3)
        var owned = OfflineAudioRecord(descriptor: ownedDescriptor)
        owned.state = .partial
        owned.retainedBy = ["download:2"]
        try db.save(owned)
        let staging = root.appendingPathComponent(fixture.descriptor.identity.scopeDirectory).appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for record in [cached, owned] { try fixture.data.prefix(1_000).write(to: staging.appendingPathComponent("\(record.id).mp3")) }

        let store = OfflineStore(directory: root, minimumFreeBytes: 0)
        #expect(try await store.record(id: cached.id) == nil)
        #expect(try await store.record(id: owned.id)?.state == .missing)
        #expect(try await store.record(id: owned.id)?.retainedBy == ["download:2"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }
}
