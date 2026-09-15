import Foundation

actor OfflineStore {
    static let shared = OfflineStore(directory: KumonePaths.applicationSupport.appendingPathComponent("Offline", isDirectory: true))

    nonisolated let directory: URL
    private let minimumFreeBytes: Int64
    private var database: OfflineAudioDatabase?
    private var writers: [String: UUID] = [:]
    private var leases: [UUID: String] = [:]
    private var validating: Set<String> = []
    private var downloadReservations: [String: Int64] = [:]

    init(directory: URL, minimumFreeBytes: Int64? = nil) {
        self.directory = directory
        #if os(macOS)
        self.minimumFreeBytes = minimumFreeBytes ?? 2_000_000_000
        #else
        self.minimumFreeBytes = minimumFreeBytes ?? 1_000_000_000
        #endif
    }

    func begin(_ descriptor: OfflineAudioDescriptor, writer: UUID) throws {
        try descriptor.validate()
        let db = try preparedDatabase()
        let id = descriptor.identity.id
        guard writers[id] == nil || writers[id] == writer else { throw OfflineAudioError.busy }
        if var existing = try db.record(id: id) {
            guard existing.descriptor == descriptor, existing.state != .deleting else { throw OfflineAudioError.changedResource }
            guard existing.state != .verifying else { throw OfflineAudioError.busy }
            let extent = existing.ranges.ranges.last?.upperBound ?? 0
            let stagingSize = (try? stagingURL(existing).resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            if existing.state == .missing || (existing.state == .partial && stagingSize < extent) {
                guard !leases.values.contains(id) else { throw OfflineAudioError.busy }
                try removeFiles(existing)
                guard FileManager.default.createFile(atPath: stagingURL(existing).path, contents: nil) else { throw OfflineAudioError.unavailable }
                existing.state = .partial
                existing.ranges = AudioByteRanges()
                try db.save(existing)
            }
        } else {
            let record = OfflineAudioRecord(descriptor: descriptor)
            try makeDirectory(stagingURL(record).deletingLastPathComponent())
            try makeDirectory(audioURL(record).deletingLastPathComponent())
            guard FileManager.default.createFile(atPath: stagingURL(record).path, contents: nil) else { throw OfflineAudioError.unavailable }
            try db.save(record)
        }
        writers[id] = writer
    }

    func releaseWriter(id: String, writer: UUID) {
        if writers[id] == writer { writers[id] = nil }
    }

    func write(_ data: Data, at offset: Int64, id: String, writer: UUID) throws {
        let db = try preparedDatabase()
        guard writers[id] == writer, var record = try db.record(id: id), record.state == .partial else { throw OfflineAudioError.unavailable }
        guard offset >= 0, offset <= record.descriptor.byteCount,
              Int64(data.count) <= record.descriptor.byteCount - offset else { throw OfflineAudioError.invalidResponse }
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
        guard let free = attributes[.systemFreeSize] as? NSNumber,
              free.int64Value - Int64(data.count) >= minimumFreeBytes else { throw OfflineAudioError.insufficientSpace }
        let file = try FileHandle(forWritingTo: stagingURL(record))
        defer { try? file.close() }
        try file.seek(toOffset: UInt64(offset))
        try file.write(contentsOf: data)
        try file.synchronize()
        record.ranges.insert(offset..<(offset + Int64(data.count)))
        try db.save(record)
    }

    func read(id: String, at offset: Int64, maximum: Int) throws -> Data? {
        guard maximum > 0, offset >= 0,
              let record = try preparedDatabase().record(id: id), [.partial, .verifying, .complete].contains(record.state) else { return nil }
        let count = record.ranges.availableLength(at: offset, maximum: maximum)
        guard count > 0 else { return nil }
        let url = record.state == .complete ? audioURL(record) : stagingURL(record)
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        try file.seek(toOffset: UInt64(offset))
        let data = try file.read(upToCount: count)
        guard let data, data.count == count else { throw OfflineAudioError.incomplete }
        return data
    }

    func record(id: String) throws -> OfflineAudioRecord? { try preparedDatabase().record(id: id) }

    func storageFiles() throws -> [AudioStorageFile] {
        try preparedDatabase().allRecords().flatMap { record in
            let inUse = writers[record.id] != nil || validating.contains(record.id) || leases.values.contains(record.id)
            return [audioURL(record), stagingURL(record)].map { url in
                AudioStorageFile(url: url, assetID: record.id, accountScope: record.descriptor.identity.accountScope,
                    trackID: record.descriptor.identity.trackID, retained: !record.retainedBy.isEmpty,
                    complete: record.state == .complete, inUse: inUse)
            }
        }
    }

    func clearMusicCache(excluding downloadAssetIDs: Set<String> = []) throws -> MusicCacheClearResult {
        var result = MusicCacheClearResult()
        for record in try preparedDatabase().allRecords() where record.retainedBy.isEmpty && !downloadAssetIDs.contains(record.id) {
            if writers[record.id] != nil || validating.contains(record.id) || leases.values.contains(record.id) {
                result.inUse += 1
                continue
            }
            do { try remove(id: record.id); result.removed += 1 }
            catch { result.failed += 1 }
        }
        return result
    }

    func reserveDownload(token: String, bytes: Int64) throws {
        _ = try preparedDatabase()
        let values = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
        let others = downloadReservations.filter { $0.key != token }.values.reduce(0, +)
        guard bytes >= 0, let free = values[.systemFreeSize] as? NSNumber,
              free.int64Value - others - bytes >= minimumFreeBytes else { throw OfflineAudioError.insufficientSpace }
        downloadReservations[token] = bytes
    }

    func updateDownloadReservation(token: String, remainingBytes: Int64) {
        if let existing = downloadReservations[token] { downloadReservations[token] = min(existing, max(0, remainingBytes)) }
    }

    func releaseDownloadReservation(token: String) { downloadReservations[token] = nil }

    func availableRecords(accountScope: String) throws -> [OfflineAudioRecord] {
        let db = try preparedDatabase()
        return try db.allRecords().filter { $0.descriptor.identity.accountScope == accountScope && $0.state == .complete }
            .compactMap { try availableRecord($0, database: db) }
    }

    func reusableDescriptor(accountScope: String, trackID: Int, quality: String, retainingFor owner: String? = nil) throws -> OfflineAudioDescriptor? {
        let db = try preparedDatabase()
        let rank = ["standard", "higher", "exhigh", "lossless", "hires"]
        guard let requested = rank.firstIndex(of: quality) else { return nil }
        for record in try db.records(scope: accountScope, trackID: trackID) where record.state == .complete {
            guard record.descriptor.identity.source == "netease",
                  (rank.firstIndex(of: record.descriptor.identity.quality) ?? -1) >= requested else { continue }
            if var available = try availableRecord(record, database: db) {
                if let owner { available.retainedBy.insert(owner); try db.save(available) }
                return available.descriptor
            }
        }
        return nil
    }

    /// Background URLSession already owns a whole temporary file. Import it on
    /// the same volume, then use the same integrity gate as streamed audio.
    func importDownload(at url: URL, descriptor: OfflineAudioDescriptor) async throws {
        let writer = UUID(), id = descriptor.identity.id
        try begin(descriptor, writer: writer)
        defer { if writers[id] == writer { writers[id] = nil } }
        let db = try preparedDatabase()
        guard var record = try db.record(id: id) else { throw OfflineAudioError.unavailable }
        if record.state == .complete { return }
        guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) == descriptor.byteCount else {
            throw OfflineAudioError.incomplete
        }
        record.ranges = AudioByteRanges()
        try db.save(record)
        let staging = stagingURL(record)
        if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) }
        try FileManager.default.moveItem(at: url, to: staging)
        record.ranges.insert(0..<descriptor.byteCount)
        try db.save(record)
        try await finalize(id: id, writer: writer)
    }

    func finalize(id: String, writer: UUID) async throws {
        let db = try preparedDatabase()
        guard writers[id] == writer, var record = try db.record(id: id) else { throw OfflineAudioError.unavailable }
        if record.state == .complete { return }
        guard record.state == .partial, !validating.contains(id), record.ranges.covers(record.descriptor.byteCount) else {
            throw OfflineAudioError.incomplete
        }
        record.state = .verifying
        try db.save(record)
        validating.insert(id)
        defer { validating.remove(id) }
        let staging = stagingURL(record)
        let descriptor = record.descriptor
        do {
            try await Task.detached(priority: .utility) { try OfflineAudioValidator.validate(url: staging, descriptor: descriptor) }.value
            guard let current = try db.record(id: id), current.state == .verifying else { throw CancellationError() }
            try FileManager.default.moveItem(at: staging, to: audioURL(record))
            try protect(audioURL(record))
            record.state = .complete
            record.verifiedModificationDate = try audioURL(record).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            try db.save(record)
        } catch {
            try removeFiles(record)
            let wasDeleted = try db.record(id: id)?.state == .deleting
            if record.retainedBy.isEmpty || wasDeleted {
                try db.remove(id: id)
            } else {
                record.state = .missing
                record.ranges = AudioByteRanges()
                try db.save(record)
            }
            throw error
        }
    }

    func acquire(accountScope: String, trackID: Int, preferredQuality: String) throws -> OfflinePlaybackLease? {
        let db = try preparedDatabase()
        let records = try db.records(scope: accountScope, trackID: trackID)
            .filter { $0.state == .complete && $0.descriptor.identity.source == "netease" }
            .sorted {
                let qualities = ["standard", "higher", "exhigh", "lossless", "hires"]
                let lhs = $0.descriptor.identity.quality, rhs = $1.descriptor.identity.quality
                if (lhs == preferredQuality) != (rhs == preferredQuality) { return lhs == preferredQuality }
                return (qualities.firstIndex(of: lhs) ?? -1) > (qualities.firstIndex(of: rhs) ?? -1)
            }
        for candidate in records {
            guard var record = try availableRecord(candidate, database: db) else { continue }
            let url = audioURL(record)
            record.lastPlayed = Date()
            try db.save(record)
            let token = UUID()
            leases[token] = record.id
            return OfflinePlaybackLease(token: token, descriptor: record.descriptor, url: url)
        }
        return nil
    }

    private func availableRecord(_ candidate: OfflineAudioRecord, database db: OfflineAudioDatabase) throws -> OfflineAudioRecord? {
        var record = candidate
        let url = audioURL(record)
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        do {
            guard values?.fileSize.map(Int64.init) == record.descriptor.byteCount else { throw OfflineAudioError.incomplete }
            if record.verifiedModificationDate == nil || values?.contentModificationDate != record.verifiedModificationDate {
                try OfflineAudioValidator.validate(url: url, descriptor: record.descriptor)
                record.verifiedModificationDate = values?.contentModificationDate
                try db.save(record)
            }
            return record
        } catch {
            record.state = .missing
            record.ranges = AudioByteRanges()
            try db.save(record)
            if !leases.values.contains(record.id) { try removeFiles(record) }
            return nil
        }
    }

    func release(_ lease: OfflinePlaybackLease) throws {
        guard let id = leases.removeValue(forKey: lease.token), !leases.values.contains(id),
              let record = try preparedDatabase().record(id: id), record.state == .deleting else { return }
        try removeFiles(record)
        try preparedDatabase().remove(id: id)
    }

    func retain(id: String, owner: String) throws {
        let db = try preparedDatabase()
        guard !owner.isEmpty, var record = try db.record(id: id), record.state == .complete else { throw OfflineAudioError.unavailable }
        record.retainedBy.insert(owner)
        try db.save(record)
    }

    func removeRetention(id: String, owner: String) throws {
        let db = try preparedDatabase()
        guard var record = try db.record(id: id) else { return }
        record.retainedBy.remove(owner)
        try db.save(record)
    }

    /// Deletion intent is durable. A late writer cannot resurrect the entry.
    func remove(id: String) throws {
        let db = try preparedDatabase()
        guard var record = try db.record(id: id) else { return }
        guard record.retainedBy.isEmpty else { throw OfflineAudioError.retained }
        record.state = .deleting
        try db.save(record)
        writers[id] = nil
        guard !leases.values.contains(id), !validating.contains(id) else { return }
        try removeFiles(record)
        try db.remove(id: id)
    }

    private func preparedDatabase() throws -> OfflineAudioDatabase {
        if let database { return database }
        try makeDirectory(directory)
        let db = try OfflineAudioDatabase(url: directory.appendingPathComponent("index.sqlite"))
        // Recover interrupted commits and discard deletion tombstones. Completed
        // assets are checked lazily on acquire, avoiding a full library rehash.
        for var record in try db.allRecords() {
            if record.state == .deleting {
                try removeFiles(record)
                try db.remove(id: record.id)
            } else if record.state == .verifying {
                let final = audioURL(record)
                let candidate = FileManager.default.fileExists(atPath: final.path) ? final : stagingURL(record)
                do {
                    try OfflineAudioValidator.validate(url: candidate, descriptor: record.descriptor)
                    if candidate != final { try FileManager.default.moveItem(at: candidate, to: final) }
                    try protect(final)
                    record.state = .complete
                    record.verifiedModificationDate = try final.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                    try db.save(record)
                } catch {
                    try removeFiles(record)
                    if record.retainedBy.isEmpty { try db.remove(id: record.id) }
                    else {
                        record.state = .missing
                        record.ranges = AudioByteRanges()
                        try db.save(record)
                    }
                }
            } else if record.state == .partial, !FileManager.default.fileExists(atPath: stagingURL(record).path) {
                record.state = .missing
                record.ranges = AudioByteRanges()
                try db.save(record)
            }
        }
        try removeOrphans(database: db)
        database = db
        return db
    }

    private func removeOrphans(database: OfflineAudioDatabase) throws {
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey],
                                                         options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in files {
            guard ["audio", "staging"].contains(url.deletingLastPathComponent().lastPathComponent),
                  (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            let id = url.deletingPathExtension().lastPathComponent
            guard id.count == 64, id.allSatisfy({ $0.isASCII && $0.isHexDigit }), try database.record(id: id) == nil else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }

    private func audioURL(_ record: OfflineAudioRecord) -> URL {
        directory.appendingPathComponent(record.descriptor.identity.scopeDirectory)
            .appendingPathComponent("audio/\(record.id).\(record.descriptor.identity.format.rawValue)")
    }

    private func stagingURL(_ record: OfflineAudioRecord) -> URL {
        directory.appendingPathComponent(record.descriptor.identity.scopeDirectory)
            .appendingPathComponent("staging/\(record.id).\(record.descriptor.identity.format.rawValue)")
    }

    private func removeFiles(_ record: OfflineAudioRecord) throws {
        for url in [stagingURL(record), audioURL(record)] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try protect(url)
    }

    private func protect(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
}
