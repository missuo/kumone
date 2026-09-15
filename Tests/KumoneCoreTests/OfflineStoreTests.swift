import Foundation
import Testing
@testable import KumoneCore

@Suite("Offline storage")
struct OfflineStoreTests {
    @Test func sparseFileIsNotOfflinePlayable() async throws {
        let fixture = try OfflineAudioFixture()
        let store = fixture.store(), writer = UUID(), id = fixture.descriptor.identity.id
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try await store.begin(fixture.descriptor, writer: writer)
        try await store.write(fixture.data.suffix(20), at: fixture.descriptor.byteCount - 20, id: id, writer: writer)
        #expect(try await store.read(id: id, at: 0, maximum: 20) == nil)
        await #expect(throws: OfflineAudioError.incomplete) { try await store.finalize(id: id, writer: writer) }
        #expect(try await store.acquire(accountScope: "test-account", trackID: 1, preferredQuality: "exhigh") == nil)
    }

    @Test(arguments: OfflineAudioFormat.allCases)
    func completeFileSurvivesReopening(_ format: OfflineAudioFormat) async throws {
        let fixture = try OfflineAudioFixture(format)
        let store = fixture.store(), writer = UUID(), id = fixture.descriptor.identity.id
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try await store.begin(fixture.descriptor, writer: writer)
        let middle = fixture.data.count / 2
        try await store.write(fixture.data.suffix(from: middle), at: Int64(middle), id: id, writer: writer)
        try await store.write(fixture.data.prefix(middle), at: 0, id: id, writer: writer)
        try await store.finalize(id: id, writer: writer)
        let reopened = OfflineStore(directory: store.directory, minimumFreeBytes: 0)
        let lease = try #require(try await reopened.acquire(accountScope: "test-account", trackID: 1, preferredQuality: "exhigh"))
        #expect(try Data(contentsOf: lease.url) == fixture.data)
        #expect(try lease.url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(try await reopened.acquire(accountScope: "another-account", trackID: 1, preferredQuality: "exhigh") == nil)
        try await reopened.release(lease)
    }

    @Test func checksumFailureNeverBecomesComplete() async throws {
        let fixture = try OfflineAudioFixture(), store = fixture.store()
        let writer = UUID(), id = fixture.descriptor.identity.id
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try await store.begin(fixture.descriptor, writer: writer)
        var corrupt = fixture.data
        corrupt[100] ^= 0xff
        try await store.write(corrupt, at: 0, id: id, writer: writer)
        await #expect(throws: OfflineAudioError.checksumMismatch) { try await store.finalize(id: id, writer: writer) }
        #expect(try await store.record(id: id) == nil)
    }

    @Test func sharedRetentionAndPlaybackProtectFile() async throws {
        let fixture = try OfflineAudioFixture(), store = fixture.store()
        let writer = UUID(), id = fixture.descriptor.identity.id
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try await store.begin(fixture.descriptor, writer: writer)
        try await store.write(fixture.data, at: 0, id: id, writer: writer)
        try await store.finalize(id: id, writer: writer)
        try await store.retain(id: id, owner: "playlist:1")
        try await store.retain(id: id, owner: "playlist:2")
        try await store.removeRetention(id: id, owner: "playlist:1")
        await #expect(throws: OfflineAudioError.retained) { try await store.remove(id: id) }
        let lease = try #require(try await store.acquire(accountScope: "test-account", trackID: 1, preferredQuality: "exhigh"))
        try await store.removeRetention(id: id, owner: "playlist:2")
        try await store.remove(id: id)
        #expect(FileManager.default.fileExists(atPath: lease.url.path))
        #expect(try await store.acquire(accountScope: "test-account", trackID: 1, preferredQuality: "exhigh") == nil)
        try await store.release(lease)
        #expect(!FileManager.default.fileExists(atPath: lease.url.path))
    }

    @Test func rejectsCompetingAndLateWriters() async throws {
        let fixture = try OfflineAudioFixture(), store = fixture.store()
        let writer = UUID(), id = fixture.descriptor.identity.id
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try await store.begin(fixture.descriptor, writer: writer)
        await #expect(throws: OfflineAudioError.busy) { try await store.begin(fixture.descriptor, writer: UUID()) }
        try await store.remove(id: id)
        await #expect(throws: OfflineAudioError.unavailable) { try await store.write(fixture.data, at: 0, id: id, writer: writer) }
        #expect(try await store.record(id: id) == nil)
    }

    @Test func recoversInterruptedCommit() async throws {
        let fixture = try OfflineAudioFixture(), store = fixture.store()
        let writer = UUID(), id = fixture.descriptor.identity.id
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try await store.begin(fixture.descriptor, writer: writer)
        try await store.write(fixture.data, at: 0, id: id, writer: writer)
        // Simulate death after writing the commit intent but before file rename.
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
        let writer = UUID(), id = fixture.descriptor.identity.id
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try await store.begin(fixture.descriptor, writer: writer)
        try await store.write(fixture.data, at: 0, id: id, writer: writer)
        try await store.finalize(id: id, writer: writer)
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
        await store.releaseWriter(id: id, writer: writer)
        let repair = UUID()
        try await store.begin(fixture.descriptor, writer: repair)
        try await store.write(fixture.data, at: 0, id: id, writer: repair)
        try await store.finalize(id: id, writer: repair)
        #expect(try await store.record(id: id)?.retainedBy == ["manual"])
    }

    @Test func insufficientSpaceDoesNotPublishWrittenRanges() async throws {
        let fixture = try OfflineAudioFixture()
        let directory = fixture.store().directory
        let store = OfflineStore(directory: directory, minimumFreeBytes: Int64.max)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = UUID(), id = fixture.descriptor.identity.id
        try await store.begin(fixture.descriptor, writer: writer)
        await #expect(throws: OfflineAudioError.insufficientSpace) {
            try await store.write(fixture.data, at: 0, id: id, writer: writer)
        }
        #expect(try await store.record(id: id)?.ranges.byteCount == 0)
    }

    @Test func cleansOrphansAndRecoversCommitAfterRename() async throws {
        let fixture = try OfflineAudioFixture(), store = fixture.store()
        let writer = UUID(), id = fixture.descriptor.identity.id
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try await store.begin(fixture.descriptor, writer: writer)
        try await store.write(fixture.data, at: 0, id: id, writer: writer)
        try await store.finalize(id: id, writer: writer)
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
}
