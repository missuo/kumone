import Foundation

/// Downloaded audio on disk plus the SQLite index that describes it. Every
/// file arrives whole from a finished transfer, is verified in a staging
/// directory and only then becomes playable.
actor OfflineStore {
    static let shared = OfflineStore(directory: KumonePaths.applicationSupport.appendingPathComponent("Offline", isDirectory: true))

    nonisolated let directory: URL
    private let minimumFreeBytes: Int64
    private var database: OfflineAudioDatabase?
    /// Assets whose file is being moved into place, so two transfers of the
    /// same asset cannot race each other.
    private var importing: Set<String> = []
    private var leases: [UUID: String] = [:]
    private var validating: Set<String> = []
    private var downloadReservations: [String: Int64] = [:]
    private let validateAudio: @Sendable (URL, OfflineAudioDescriptor) async throws -> Void
    private let freeSpace: @Sendable (URL) throws -> Int64

    init(directory: URL, minimumFreeBytes: Int64? = nil,
         validateAudio: @escaping @Sendable (URL, OfflineAudioDescriptor) async throws -> Void = { url, descriptor in
             try await Task.detached(priority: .utility) { try OfflineAudioValidator.validate(url: url, descriptor: descriptor) }.value
         },
         freeSpace: @escaping @Sendable (URL) throws -> Int64 = { url in
             let values = try FileManager.default.attributesOfFileSystem(forPath: url.path)
             guard let free = values[.systemFreeSize] as? NSNumber else { throw OfflineAudioError.insufficientSpace }
             return free.int64Value
         }) {
        self.directory = directory
        self.validateAudio = validateAudio
        self.freeSpace = freeSpace
        #if os(macOS)
        self.minimumFreeBytes = minimumFreeBytes ?? 2_000_000_000
        #else
        self.minimumFreeBytes = minimumFreeBytes ?? 1_000_000_000
        #endif
    }

    func record(id: String) throws -> OfflineAudioRecord? { try preparedDatabase().record(id: id) }

    /// Every song that still has audio here, or is about to; their metadata
    /// stays on disk while everything else is pruned.
    func metadataTrackIDs() throws -> [String: Set<Int>] {
        var result: [String: Set<Int>] = [:]
        for record in try preparedDatabase().allRecords() where record.state != .deleting {
            result[record.descriptor.identity.accountScope, default: []].insert(record.descriptor.identity.trackID)
        }
        return result
    }

    func storageFiles() throws -> [AudioStorageFile] {
        try preparedDatabase().allRecords().flatMap { record in
            [audioURL(record), stagingURL(record)].map { AudioStorageFile(url: $0, accountScope: record.descriptor.identity.accountScope) }
        }
    }

    /// Reserve disk for a transfer that has not landed yet, alongside every
    /// other transfer still in flight.
    func reserveDownload(token: String, bytes: Int64) throws {
        guard bytes >= 0 else { throw OfflineAudioError.insufficientSpace }
        let others = downloadReservations.filter { $0.key != token }.values.reduce(0, +)
        guard try freeSpace(directory) - others - bytes >= minimumFreeBytes else { throw OfflineAudioError.insufficientSpace }
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

    /// Same filtering as the whole-library scan, for one song only.
    func availableRecords(accountScope: String, trackID: Int) throws -> [OfflineAudioRecord] {
        let db = try preparedDatabase()
        return try db.records(scope: accountScope, trackID: trackID).filter { $0.state == .complete }
            .compactMap { try availableRecord($0, database: db) }
    }

    func reusableDescriptor(accountScope: String, trackID: Int, quality: String, retainingFor owner: String? = nil) throws -> OfflineAudioDescriptor? {
        let db = try preparedDatabase()
        let rank = AudioQuality.allCases.map(\.rawValue)
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

    /// Background URLSession already owns a whole temporary file. Move it onto
    /// this volume, verify it, then publish it.
    func importDownload(at url: URL, descriptor: OfflineAudioDescriptor) async throws {
        try descriptor.validate()
        let db = try preparedDatabase()
        let id = descriptor.identity.id
        guard !importing.contains(id), !validating.contains(id) else { throw OfflineAudioError.busy }
        importing.insert(id)
        defer { importing.remove(id) }
        var record: OfflineAudioRecord
        if let existing = try db.record(id: id) {
            guard existing.descriptor == descriptor else { throw OfflineAudioError.changedResource }
            // Removed while it plays: the file goes when playback lets go of it,
            // and this copy has to wait for that.
            guard existing.state != .deleting else { throw OfflineAudioError.busy }
            if existing.state == .complete { return }
            record = existing
        } else {
            record = OfflineAudioRecord(descriptor: descriptor)
        }
        try makeDirectory(stagingURL(record).deletingLastPathComponent())
        try makeDirectory(audioURL(record).deletingLastPathComponent())
        guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) == descriptor.byteCount else {
            throw OfflineAudioError.incomplete
        }
        // Whatever an earlier attempt left behind is replaced by this file.
        try removeFiles(record)
        try FileManager.default.moveItem(at: url, to: stagingURL(record))
        record.state = .verifying
        try db.save(record)
        try await verify(record, database: db)
    }

    private func verify(_ candidate: OfflineAudioRecord, database db: OfflineAudioDatabase) async throws {
        var record = candidate
        let id = record.id
        validating.insert(id)
        defer { validating.remove(id) }
        let staging = stagingURL(record)
        do {
            try await validateAudio(staging, record.descriptor)
            // Removal while verifying wins: the file is deleted, not published.
            guard let current = try db.record(id: id), current.state == .verifying else { throw CancellationError() }
            record = current
            try FileManager.default.moveItem(at: staging, to: audioURL(record))
            try protect(audioURL(record))
            record.state = .complete
            record.verifiedModificationDate = try audioURL(record).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            try db.save(record)
        } catch {
            try removeFiles(record)
            guard let current = try db.record(id: id) else { throw error }
            record = current
            if record.retainedBy.isEmpty || record.state == .deleting {
                try db.remove(id: id)
            } else {
                // The download still wants this song; only its file is gone.
                record.state = .missing
                try db.save(record)
            }
            throw error
        }
    }

    func acquire(accountScope: String, trackID: Int, preferredQuality: String,
                 allowLowerQuality: Bool = true) throws -> OfflinePlaybackLease? {
        let db = try preparedDatabase()
        let records = try playbackRecords(accountScope: accountScope, trackID: trackID, preferredQuality: preferredQuality)
        let qualities = AudioQuality.allCases.map(\.rawValue)
        for candidate in records {
            if !allowLowerQuality {
                guard let requested = qualities.firstIndex(of: preferredQuality),
                      let stored = qualities.firstIndex(of: candidate.descriptor.identity.quality), stored >= requested else { continue }
            }
            guard var record = try availableRecord(candidate, database: db) else { continue }
            record.lastPlayed = Date()
            try db.save(record)
            let token = UUID()
            leases[token] = record.id
            return OfflinePlaybackLease(token: token, descriptor: record.descriptor, url: audioURL(record))
        }
        return nil
    }

    func availableDescriptor(accountScope: String, trackID: Int, preferredQuality: String) throws -> OfflineAudioDescriptor? {
        let db = try preparedDatabase()
        for candidate in try playbackRecords(accountScope: accountScope, trackID: trackID, preferredQuality: preferredQuality) {
            if let record = try availableRecord(candidate, database: db) { return record.descriptor }
        }
        return nil
    }

    private func playbackRecords(accountScope: String, trackID: Int, preferredQuality: String) throws -> [OfflineAudioRecord] {
        try preparedDatabase().records(scope: accountScope, trackID: trackID)
            .filter { $0.state == .complete && $0.descriptor.identity.source == "netease" }
            .sorted {
                let qualities = AudioQuality.allCases.map(\.rawValue)
                let lhs = $0.descriptor.identity.quality, rhs = $1.descriptor.identity.quality
                if (lhs == preferredQuality) != (rhs == preferredQuality) { return lhs == preferredQuality }
                return (qualities.firstIndex(of: lhs) ?? -1) > (qualities.firstIndex(of: rhs) ?? -1)
            }
    }

    /// Completed assets are checked lazily here, so a file edited or truncated
    /// behind the app's back never plays; a full library rehash is unnecessary.
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
            try db.save(record)
            if !leases.values.contains(record.id) { try removeFiles(record) }
            return nil
        }
    }

    /// A file removed while it was playing is deleted once its last lease ends.
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

    /// Dropping the last owner deletes the file: nothing keeps audio that no
    /// download refers to any more.
    func removeRetention(id: String, owner: String) throws {
        let db = try preparedDatabase()
        guard var record = try db.record(id: id) else { return }
        record.retainedBy.remove(owner)
        try db.save(record)
        if record.retainedBy.isEmpty { try remove(id: id) }
    }

    /// Deletion intent is durable. A verification still running cannot
    /// resurrect the entry.
    func remove(id: String) throws {
        let db = try preparedDatabase()
        guard var record = try db.record(id: id) else { return }
        guard record.retainedBy.isEmpty else { throw OfflineAudioError.retained }
        record.state = .deleting
        try db.save(record)
        guard !leases.values.contains(id), !validating.contains(id), !importing.contains(id) else { return }
        try removeFiles(record)
        try db.remove(id: id)
    }

    /// Explicit removal from the device clears all download owners for the
    /// selected songs. Commit deletion intent once before touching their files.
    func removeDownloads(trackIDs: Set<Int>, accountScope: String) throws {
        let db = try preparedDatabase()
        var records = try db.allRecords().filter {
            $0.descriptor.identity.accountScope == accountScope && trackIDs.contains($0.descriptor.identity.trackID)
        }
        try db.transaction {
            for i in records.indices {
                records[i].retainedBy.removeAll()
                records[i].state = .deleting
                try db.save(records[i])
            }
        }
        var removed: [String] = []
        var failure: Error?
        for record in records {
            guard !leases.values.contains(record.id), !validating.contains(record.id), !importing.contains(record.id) else { continue }
            do { try removeFiles(record); removed.append(record.id) }
            catch { failure = error }
        }
        try db.transaction { for id in removed { try db.remove(id: id) } }
        if let failure { throw failure }
    }

    /// Audio no download owns. Earlier builds kept such files as a playback
    /// cache; they go once the download catalog has claimed what it recognises.
    /// `keeping` names assets a job still refers to, retained or not.
    func removeUnretained(keeping: Set<String> = []) throws {
        for record in try preparedDatabase().allRecords()
        where record.retainedBy.isEmpty && record.state != .deleting && !keeping.contains(record.id) {
            guard !importing.contains(record.id), !validating.contains(record.id) else { continue }
            try remove(id: record.id)
        }
    }

    private func preparedDatabase() throws -> OfflineAudioDatabase {
        if let database { return database }
        try makeDirectory(directory)
        let db = try OfflineAudioDatabase(url: directory.appendingPathComponent("index.sqlite"))
        // Recover interrupted verifications and discard deletion tombstones.
        for var record in try db.allRecords() {
            switch record.state {
            case .deleting:
                try removeFiles(record)
                try db.remove(id: record.id)
            case .verifying:
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
                        try db.save(record)
                    }
                }
            case .partial:
                // Streamed partial files from earlier builds are never resumed.
                try removeFiles(record)
                if record.retainedBy.isEmpty { try db.remove(id: record.id) }
                else {
                    record.state = .missing
                    try db.save(record)
                }
            case .complete, .missing:
                break
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
