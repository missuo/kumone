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
    private var cacheReservations: [String: Int64] = [:]
    private let freeSpace: @Sendable (URL) throws -> Int64

    init(directory: URL, minimumFreeBytes: Int64? = nil,
         freeSpace: @escaping @Sendable (URL) throws -> Int64 = { url in
             let values = try FileManager.default.attributesOfFileSystem(forPath: url.path)
             guard let free = values[.systemFreeSize] as? NSNumber else { throw OfflineAudioError.insufficientSpace }
             return free.int64Value
         }) {
        self.directory = directory
        self.freeSpace = freeSpace
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
        if writers[id] == writer { writers[id] = nil; cacheReservations[id] = nil }
    }

    func write(_ data: Data, at offset: Int64, id: String, writer: UUID) throws {
        let db = try preparedDatabase()
        guard writers[id] == writer, var record = try db.record(id: id), record.state == .partial else { throw OfflineAudioError.unavailable }
        guard offset >= 0, offset <= record.descriptor.byteCount,
              Int64(data.count) <= record.descriptor.byteCount - offset else { throw OfflineAudioError.invalidResponse }
        let reserved = cacheReservations[id] == nil ? 0 : downloadReservations.values.reduce(0, +)
        guard try freeSpace(directory) - reserved - Int64(data.count) >= minimumFreeBytes else { throw OfflineAudioError.insufficientSpace }
        let file = try FileHandle(forWritingTo: stagingURL(record))
        defer { try? file.close() }
        try file.seek(toOffset: UInt64(offset))
        try file.write(contentsOf: data)
        try file.synchronize()
        record.ranges.insert(offset..<(offset + Int64(data.count)))
        try db.save(record)
        if cacheReservations[id] != nil {
            cacheReservations[id] = max(0, record.descriptor.byteCount - record.ranges.byteCount)
        }
    }

    func read(id: String, at offset: Int64, maximum: Int) throws -> Data? {
        guard maximum > 0, offset >= 0,
              let record = try preparedDatabase().record(id: id),
              [.partial, .verifying, .complete].contains(record.state)
                || (record.state == .deleting && leases.values.contains(id)) else { return nil }
        let count = record.ranges.availableLength(at: offset, maximum: maximum)
        guard count > 0 else { return nil }
        let url = record.state == .complete || (record.state == .deleting && FileManager.default.fileExists(atPath: audioURL(record).path))
            ? audioURL(record) : stagingURL(record)
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        try file.seek(toOffset: UInt64(offset))
        let data = try file.read(upToCount: count)
        guard let data, data.count == count else { throw OfflineAudioError.incomplete }
        return data
    }

    func record(id: String) throws -> OfflineAudioRecord? { try preparedDatabase().record(id: id) }

    func metadataTrackIDs() throws -> [String: Set<Int>] {
        var result: [String: Set<Int>] = [:]
        for record in try preparedDatabase().allRecords() {
            let inUse = writers[record.id] != nil || validating.contains(record.id) || leases.values.contains(record.id)
            if !record.retainedBy.isEmpty || inUse || ([.partial, .complete, .verifying].contains(record.state) && record.ranges.byteCount > 0) {
                result[record.descriptor.identity.accountScope, default: []].insert(record.descriptor.identity.trackID)
            }
        }
        return result
    }

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

    func reserveDownload(token: String, bytes: Int64, context: MusicCacheContext = .init(policy: .automatic)) throws {
        let db = try preparedDatabase()
        let others = downloadReservations.filter { $0.key != token }.values.reduce(0, +) + cacheReservations.values.reduce(0, +)
        guard bytes >= 0 else { throw OfflineAudioError.insufficientSpace }
        if try freeSpace(directory) - others - bytes < minimumFreeBytes {
            let records = try db.allRecords().filter { $0.retainedBy.isEmpty && !context.protectedAssetIDs.contains($0.id) }
            let candidates = evictionCandidates(records, context: context)
            let reclaimable = candidates.reduce(Int64(0)) { $0 + cacheFileBytes($1) }
            // Do not discard useful cache if even removing it cannot fit this download.
            guard try freeSpace(directory) + reclaimable - others - bytes >= minimumFreeBytes else {
                throw OfflineAudioError.insufficientSpace
            }
            for record in candidates {
                if try freeSpace(directory) - others - bytes >= minimumFreeBytes { break }
                try remove(id: record.id)
            }
        }
        guard try freeSpace(directory) - others - bytes >= minimumFreeBytes else { throw OfflineAudioError.insufficientSpace }
        downloadReservations[token] = bytes
    }

    func updateDownloadReservation(token: String, remainingBytes: Int64) {
        if let existing = downloadReservations[token] { downloadReservations[token] = min(existing, max(0, remainingBytes)) }
    }

    func releaseDownloadReservation(token: String) { downloadReservations[token] = nil }

    /// Admit a whole current-track cache before it starts, accounting for
    /// partial files and all outstanding writes. No files are preallocated.
    func beginCaching(_ descriptor: OfflineAudioDescriptor, writer: UUID, context: MusicCacheContext) throws {
        try descriptor.validate()
        guard context.policy != .disabled else { throw OfflineAudioError.unavailable }
        let db = try preparedDatabase(), id = descriptor.identity.id
        guard writers[id] == nil, !context.protectedAssetIDs.contains(id) else { throw OfflineAudioError.busy }
        let existing = try db.record(id: id)
        guard existing?.retainedBy.isEmpty != false else { throw OfflineAudioError.retained }
        let stagingSize = existing.flatMap { try? stagingURL($0).resourceValues(forKeys: [.fileSizeKey]).fileSize }.map(Int64.init) ?? 0
        let received = existing.map { stagingSize >= ($0.ranges.ranges.last?.upperBound ?? 0) ? $0.ranges.byteCount : 0 } ?? 0
        let remaining = max(0, descriptor.byteCount - received) + 4096
        // Reject a file that cannot fit even on its own before evicting useful
        // songs. Disk-space failure should not empty the existing cache.
        #if os(macOS)
        let isMac = true
        #else
        let isMac = false
        #endif
        let used = try db.allRecords().filter { $0.retainedBy.isEmpty && !context.protectedAssetIDs.contains($0.id) }
            .reduce(0) { $0 + cacheFileBytes($1) }
        let possible = context.policy.limit(free: try freeSpace(directory), cacheBytes: used,
            downloadReservations: downloadReservations.values.reduce(0, +), floor: minimumFreeBytes, isMac: isMac)
        guard descriptor.byteCount + 4096 <= possible else { throw OfflineAudioError.insufficientSpace }
        let result = try reconcileCache(context, additionalBytes: remaining, protecting: id)
        guard result.used + cacheReservations.values.reduce(0, +) + remaining <= result.limit,
              try freeSpace(directory) - downloadReservations.values.reduce(0, +)
                - cacheReservations.values.reduce(0, +) - remaining >= minimumFreeBytes else {
            throw OfflineAudioError.insufficientSpace
        }
        try begin(descriptor, writer: writer)
        cacheReservations[id] = remaining
        if !context.isPrefetch, var record = try db.record(id: id) {
            record.lastPlayed = Date()
            try db.save(record)
        }
    }

    @discardableResult
    func reconcileCache(_ context: MusicCacheContext, additionalBytes: Int64 = 0, protecting: String? = nil) throws -> MusicCacheCapacity {
        let db = try preparedDatabase()
        let records = try db.allRecords().filter { $0.retainedBy.isEmpty && !context.protectedAssetIDs.contains($0.id) }
        var sizes = Dictionary(uniqueKeysWithValues: records.map { ($0.id, cacheFileBytes($0)) })
        var used = sizes.values.reduce(0, +)
        #if os(macOS)
        let isMac = true
        #else
        let isMac = false
        #endif
        let pending = downloadReservations.values.reduce(0, +)
        let limit = context.policy.limit(free: try freeSpace(directory), cacheBytes: used,
            downloadReservations: pending, floor: minimumFreeBytes, isMac: isMac)
        guard context.policy != .disabled else { return .init(limit: 0, used: used) }
        let reserved = cacheReservations.values.reduce(0, +) + additionalBytes
        let target = used + reserved > limit ? limit * 9 / 10 : limit
        for record in evictionCandidates(records, context: context, protecting: protecting) {
            let enoughDisk = try freeSpace(directory) - pending - reserved >= minimumFreeBytes
            if used + reserved <= target && enoughDisk { break }
            try remove(id: record.id)
            used -= sizes.removeValue(forKey: record.id) ?? 0
        }
        return .init(limit: limit, used: used)
    }

    private func evictionCandidates(_ records: [OfflineAudioRecord], context: MusicCacheContext,
                                    protecting: String? = nil) -> [OfflineAudioRecord] {
        func priority(_ record: OfflineAudioRecord) -> Int {
            if record.state != .complete { return 0 }
            let liked = context.likedTracks[record.descriptor.identity.accountScope]?
                .contains(record.descriptor.identity.trackID) ?? true
            return liked ? 2 : 1
        }
        return records.filter {
            $0.id != protecting && writers[$0.id] == nil && !validating.contains($0.id) && !leases.values.contains($0.id)
                && context.protectedTracks[$0.descriptor.identity.accountScope]?.contains($0.descriptor.identity.trackID) != true
        }.sorted {
            if priority($0) != priority($1) { return priority($0) < priority($1) }
            if ($0.lastPlayed == nil) != ($1.lastPlayed == nil) { return $0.lastPlayed == nil }
            return ($0.lastPlayed ?? $0.verifiedModificationDate ?? .distantPast)
                < ($1.lastPlayed ?? $1.verifiedModificationDate ?? .distantPast)
        }
    }

    private func cacheFileBytes(_ record: OfflineAudioRecord) -> Int64 {
        [audioURL(record), stagingURL(record)].reduce(0) { total, url in
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            return total + Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
    }

    func availableRecords(accountScope: String) throws -> [OfflineAudioRecord] {
        let db = try preparedDatabase()
        return try db.allRecords().filter { $0.descriptor.identity.accountScope == accountScope && $0.state == .complete }
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

    func acquire(accountScope: String, trackID: Int, preferredQuality: String,
                 allowLowerQuality: Bool = true) throws -> OfflinePlaybackLease? {
        let db = try preparedDatabase()
        let records = try playbackRecords(accountScope: accountScope, trackID: trackID, preferredQuality: preferredQuality)
        let qualities = AudioQuality.allCases.map(\.rawValue)
        for candidate in records {
            if !allowLowerQuality {
                guard let requested = qualities.firstIndex(of: preferredQuality),
                      let cached = qualities.firstIndex(of: candidate.descriptor.identity.quality), cached >= requested else { continue }
            }
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
        try releasePlaybackRead(token: lease.token)
    }

    func protectPlaybackRead(id: String, token: UUID) throws {
        guard let record = try preparedDatabase().record(id: id), record.state != .deleting else { throw OfflineAudioError.unavailable }
        leases[token] = id
    }

    func releasePlaybackRead(token: UUID) throws {
        guard let id = leases.removeValue(forKey: token), !leases.values.contains(id),
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
        cacheReservations[id] = nil
        guard !leases.values.contains(id), !validating.contains(id) else { return }
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
            writers[record.id] = nil
            cacheReservations[record.id] = nil
            guard !leases.values.contains(record.id), !validating.contains(record.id) else { continue }
            do { try removeFiles(record); removed.append(record.id) }
            catch { failure = error }
        }
        try db.transaction { for id in removed { try db.remove(id: id) } }
        if let failure { throw failure }
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
