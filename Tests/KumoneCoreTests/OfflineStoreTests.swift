import Foundation
import Testing
@testable import KumoneCore

private actor AudioValidationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}

@Suite("Offline storage")
struct OfflineStoreTests {
    @Test(arguments: [false, true])
    func validationCannotRestoreARemovedRetention(fails: Bool) async throws {
        let fixture = try OfflineAudioFixture(.flac), gate = AudioValidationGate()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OfflineStore(directory: root, minimumFreeBytes: 0, validateAudio: { url, descriptor in
            await gate.wait()
            if fails { throw OfflineAudioError.checksumMismatch }
            try OfflineAudioValidator.validate(url: url, descriptor: descriptor)
        })
        let writer = UUID(), id = fixture.descriptor.identity.id
        try await store.begin(fixture.descriptor, writer: writer)
        try await store.write(fixture.data, at: 0, id: id, writer: writer)
        // A retained resource can be partial while recovering its missing file.
        let database = try OfflineAudioDatabase(url: root.appendingPathComponent("index.sqlite"))
        var record = try #require(try database.record(id: id))
        record.retainedBy = ["download:old"]
        try database.save(record)
        let validation = Task { try await store.finalize(id: id, writer: writer) }
        for _ in 0..<200 {
            if await gate.entered { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await gate.entered)
        try await store.removeRetention(id: id, owner: "download:old")
        await gate.open()
        if fails {
            await #expect(throws: OfflineAudioError.checksumMismatch) { try await validation.value }
            #expect(try await store.record(id: id) == nil)
        } else {
            try await validation.value
            #expect(try await store.record(id: id)?.retainedBy.isEmpty == true)
            await store.releaseWriter(id: id, writer: writer)
            try await store.remove(id: id)
            #expect(try await store.record(id: id) == nil)
        }
    }

    @Test func preferredQualityCanExcludeLowerCacheWithoutMarkingItPlayed() async throws {
        let low = try OfflineAudioFixture(), store = low.store()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let writer = UUID()
        try await store.begin(low.descriptor, writer: writer)
        try await store.write(low.data, at: 0, id: low.descriptor.identity.id, writer: writer)
        try await store.finalize(id: low.descriptor.identity.id, writer: writer)
        await store.releaseWriter(id: low.descriptor.identity.id, writer: writer)
        #expect(try await store.acquire(accountScope: "test-account", trackID: 1,
                                       preferredQuality: "lossless", allowLowerQuality: false) == nil)
        #expect(try await store.record(id: low.descriptor.identity.id)?.lastPlayed == nil)
        let offline = try #require(try await store.acquire(accountScope: "test-account", trackID: 1, preferredQuality: "lossless"))
        #expect(offline.descriptor.identity.quality == "exhigh")
        #expect(try Data(contentsOf: offline.url) == low.data)
        try await store.release(offline)

        let high = try OfflineAudioFixture(.flac)
        let descriptor = OfflineAudioDescriptor(identity: .init(accountScope: "test-account", trackID: 1, source: "netease", quality: "lossless",
                                                               format: .flac, contentMD5: high.descriptor.identity.contentMD5),
                                                byteCount: high.descriptor.byteCount, duration: 3)
        let highWriter = UUID()
        try await store.begin(descriptor, writer: highWriter)
        try await store.write(high.data, at: 0, id: descriptor.identity.id, writer: highWriter)
        try await store.finalize(id: descriptor.identity.id, writer: highWriter)
        await store.releaseWriter(id: descriptor.identity.id, writer: highWriter)
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

    /// Streaming must not pay an fsync plus an index write per 64 KiB chunk,
    /// and the index must never claim bytes the file does not hold.
    @Test func streamedChunksCommitInBatches() async throws {
        let descriptor = OfflineAudioDescriptor(
            identity: .init(accountScope: "test-account", trackID: 7, source: "netease", quality: "exhigh",
                            format: .mp3, contentMD5: String(repeating: "a", count: 32)),
            byteCount: 4 * 1024 * 1024, duration: 3)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = OfflineStore(directory: root, minimumFreeBytes: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = UUID(), id = descriptor.identity.id, chunk = 64 * 1024
        func persistedRanges() throws -> AudioByteRanges {
            try OfflineAudioDatabase(url: root.appendingPathComponent("index.sqlite")).record(id: id)?.ranges ?? .init()
        }
        try await store.begin(descriptor, writer: writer)
        var written = Data()
        func stream(_ count: Int) async throws {
            for _ in 0..<count {
                let data = Data((0..<chunk).map { UInt8(truncatingIfNeeded: written.count &+ $0) })
                try await store.write(data, at: Int64(written.count), id: id, writer: writer)
                written.append(data)
            }
        }
        try await stream(8)
        // Below one batch: nothing is published yet, but the session serves reads.
        #expect(try persistedRanges().byteCount == 0)
        #expect(try await store.record(id: id)?.ranges.byteCount == Int64(written.count))
        #expect(try await store.read(id: id, at: 0, maximum: 4_096) == Data(written.prefix(4_096)))
        #expect(try await store.read(id: id, at: Int64(written.count) - 8, maximum: 64) == Data(written.suffix(8)))
        try await stream(25)
        let batched = try persistedRanges().byteCount
        #expect(batched >= OfflineStore.commitInterval && batched < Int64(written.count))
        await store.releaseWriter(id: id, writer: writer)
        #expect(try persistedRanges().ranges == [0..<Int64(written.count)])

        // A fresh store on the same directory never claims more than the file
        // holds, and every claimed byte reads back exactly as written.
        let reopened = OfflineStore(directory: root, minimumFreeBytes: 0)
        let record = try #require(try await reopened.record(id: id))
        let staging = root.appendingPathComponent(descriptor.identity.scopeDirectory)
            .appendingPathComponent("staging/\(id).mp3")
        let onDisk = try Data(contentsOf: staging)
        #expect(record.state == .partial)
        #expect(record.ranges.byteCount <= Int64(onDisk.count))
        for range in record.ranges.ranges {
            #expect(onDisk[Int(range.lowerBound)..<Int(range.upperBound)] == written[Int(range.lowerBound)..<Int(range.upperBound)])
        }
    }

    @Test func chunkedWritesStillVerifyAndPromote() async throws {
        let fixture = try OfflineAudioFixture(.flac), store = fixture.store()
        let writer = UUID(), id = fixture.descriptor.identity.id
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try await store.begin(fixture.descriptor, writer: writer)
        var offset = 0
        while offset < fixture.data.count {
            let end = min(fixture.data.count, offset + 64 * 1024)
            try await store.write(fixture.data[offset..<end], at: Int64(offset), id: id, writer: writer)
            offset = end
        }
        try await store.finalize(id: id, writer: writer)
        await store.releaseWriter(id: id, writer: writer)
        let lease = try #require(try await store.acquire(accountScope: "test-account", trackID: 1, preferredQuality: "exhigh"))
        #expect(try Data(contentsOf: lease.url) == fixture.data)
        try await store.release(lease)
    }

    @Test func removalDuringAnOpenSessionClosesTheStagingFile() async throws {
        let fixture = try OfflineAudioFixture(), store = fixture.store()
        let writer = UUID(), id = fixture.descriptor.identity.id
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try await store.begin(fixture.descriptor, writer: writer)
        try await store.write(fixture.data.prefix(4_096), at: 0, id: id, writer: writer)
        let staging = store.directory.appendingPathComponent(fixture.descriptor.identity.scopeDirectory)
            .appendingPathComponent("staging/\(id).mp3")
        #expect(FileManager.default.fileExists(atPath: staging.path))
        try await store.remove(id: id)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(try await store.record(id: id) == nil)
        await #expect(throws: OfflineAudioError.unavailable) {
            try await store.write(fixture.data.prefix(4_096), at: 0, id: id, writer: writer)
        }
        #expect(try await store.read(id: id, at: 0, maximum: 16) == nil)
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
