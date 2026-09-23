import Foundation

enum AudioCacheSource: Codable, Equatable, Sendable {
    case netease
    case unblock(String)

    var requiresUnblockEnabled: Bool {
        if case .unblock = self {
            return true
        }
        return false
    }
}

struct AudioCacheMetadata: Codable, Equatable, Sendable {
    let trackID: Int
    let requestedQuality: String
    let servedQuality: String?
    let source: AudioCacheSource
    let contentType: String?
    let fileName: String
    let byteCount: Int64
    let completedAt: Date
}

struct AudioCacheEntry: Sendable {
    let fileURL: URL
    let metadata: AudioCacheMetadata
}

struct AudioCacheWriteSession: Sendable {
    let id: UUID
    let partialFileURL: URL
    let finalFileURL: URL
    let trackID: Int
    let requestedQuality: String
    let servedQuality: String?
    let source: AudioCacheSource
}

enum AudioCacheCommitResult: Sendable {
    case retained(entry: AudioCacheEntry, leaseID: UUID)
    /// The cache must not retain this entry, but its partial file remains
    /// available until the resource loader switches to direct streaming.
    case deferredDiscard
    /// The latest cache limit rejects this entry, but its partial file remains
    /// available until the resource loader switches to direct streaming.
    case rejectedForCurrentLimit
}

enum AudioCacheError: LocalizedError {
    case emptyFile
    case invalidFileName
    case missingWriteSession
    case writeFileCreationFailed(URL)

    var errorDescription: String? {
        switch self {
        case .emptyFile:
            return "Audio cache rejected an empty response."
        case .invalidFileName:
            return "Audio cache metadata contains an invalid file name."
        case .missingWriteSession:
            return "Audio cache write session is no longer active."
        case .writeFileCreationFailed(let url):
            return "Audio cache could not create \(url.lastPathComponent)."
        }
    }
}

/// Disk-backed, size-bounded audio cache. Completed entries are keyed by track
/// id, while their metadata preserves the requested quality and source so a
/// third-party file is never used after the unblock setting is disabled.
actor AudioCache {
    static let shared = AudioCache()
    static let defaultMaximumSizeMB = 500

    private let fileManager: FileManager
    private let cacheDirectory: URL
    private let partialDirectory: URL
    private var activeWrites: [UUID: AudioCacheWriteSession] = [:]
    private var clearAfterWrite: Set<UUID> = []
    private var leases: [UUID: URL] = [:]
    private var clearAfterRelease: Set<URL> = []
    private var maximumSizeMB = AudioCache.defaultMaximumSizeMB

    /// Where the cache lives, for storage accounting.
    nonisolated var directory: URL { cacheDirectory }

    init(cacheDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.cacheDirectory = cacheDirectory ?? fileManager.urls(
            for: .cachesDirectory, in: .userDomainMask
        )[0].appendingPathComponent("im.missuo.Kumone/audio", isDirectory: true)
        partialDirectory = self.cacheDirectory.appendingPathComponent("partial", isDirectory: true)
    }

    func entry(
        for trackID: Int,
        requestedQuality: String,
        allowsUnblock: Bool
    ) throws -> AudioCacheEntry? {
        guard let entry = try loadEntry(trackID: trackID) else { return nil }
        guard entry.metadata.requestedQuality == requestedQuality else { return nil }
        guard allowsUnblock || !entry.metadata.source.requiresUnblockEnabled else { return nil }
        try touch(entry.fileURL)
        return entry
    }

    func fallbackEntry(for trackID: Int, allowsUnblock: Bool) throws -> AudioCacheEntry? {
        guard let entry = try loadEntry(trackID: trackID) else { return nil }
        guard allowsUnblock || !entry.metadata.source.requiresUnblockEnabled else { return nil }
        try touch(entry.fileURL)
        return entry
    }

    /// Tracks with a complete cached copy, for offline availability.
    func cachedTrackIDs() throws -> Set<Int> {
        Set(try completedEntries().map(\.metadata.trackID))
    }

    func retain(_ entry: AudioCacheEntry) -> UUID {
        let leaseID = UUID()
        leases[leaseID] = entry.fileURL
        return leaseID
    }

    func release(_ leaseID: UUID) throws {
        guard let fileURL = leases.removeValue(forKey: leaseID) else { return }
        if !leases.values.contains(fileURL), clearAfterRelease.remove(fileURL) != nil {
            try removeCompletedFile(at: fileURL)
        }
        try enforce(maximumBytes: Int64(maximumSizeMB) * 1_000_000)
    }

    func beginWrite(
        trackID: Int,
        requestedQuality: String,
        servedQuality: String?,
        source: AudioCacheSource,
        fileExtension: String,
        maximumSizeMB: Int
    ) throws -> AudioCacheWriteSession {
        self.maximumSizeMB = max(maximumSizeMB, 0)
        try ensureDirectories()
        try removeInactivePartialFiles()
        let id = UUID()
        let normalizedFileExtension = try sanitizedFileExtension(fileExtension)
        let partialFileURL = partialDirectory.appendingPathComponent("\(id.uuidString).part")
        guard fileManager.createFile(atPath: partialFileURL.path, contents: nil) else {
            throw AudioCacheError.writeFileCreationFailed(partialFileURL)
        }
        let session = AudioCacheWriteSession(
            id: id,
            partialFileURL: partialFileURL,
            finalFileURL: cacheDirectory.appendingPathComponent(
                "\(trackID)-\(id.uuidString).\(normalizedFileExtension)"
            ),
            trackID: trackID,
            requestedQuality: requestedQuality,
            servedQuality: servedQuality,
            source: source
        )
        activeWrites[id] = session
        return session
    }

    func commitAndRetain(
        _ session: AudioCacheWriteSession,
        byteCount: Int64,
        contentType: String?
    ) throws -> AudioCacheCommitResult {
        guard activeWrites[session.id] != nil else {
            throw AudioCacheError.missingWriteSession
        }
        guard byteCount > 0 else {
            activeWrites.removeValue(forKey: session.id)
            clearAfterWrite.remove(session.id)
            try removePartialFile(at: session.partialFileURL)
            throw AudioCacheError.emptyFile
        }
        guard !clearAfterWrite.contains(session.id) else {
            return .deferredDiscard
        }
        guard byteCount <= Int64(maximumSizeMB) * 1_000_000 else {
            return .rejectedForCurrentLimit
        }
        activeWrites.removeValue(forKey: session.id)
        clearAfterWrite.remove(session.id)

        try ensureDirectories()
        let fileName = session.finalFileURL.lastPathComponent
        let finalFileURL = session.finalFileURL
        let previousEntry = try loadEntry(trackID: session.trackID)

        try fileManager.moveItem(at: session.partialFileURL, to: finalFileURL)
        let metadata = AudioCacheMetadata(
            trackID: session.trackID,
            requestedQuality: session.requestedQuality,
            servedQuality: session.servedQuality,
            source: session.source,
            contentType: contentType,
            fileName: fileName,
            byteCount: byteCount,
            completedAt: .now
        )
        do {
            try JSONEncoder().encode(metadata).write(
                to: metadataURL(for: session.trackID), options: .atomic
            )
        } catch {
            do {
                try fileManager.removeItem(at: finalFileURL)
            } catch {
                print("Audio cache could not remove incomplete entry: \(error)")
            }
            throw error
        }

        if let previousEntry, previousEntry.fileURL != finalFileURL {
            if leases.values.contains(previousEntry.fileURL) {
                clearAfterRelease.insert(previousEntry.fileURL)
            } else {
                try removeFileIfPresent(at: previousEntry.fileURL)
            }
        }
        let entry = AudioCacheEntry(fileURL: finalFileURL, metadata: metadata)
        let leaseID = retain(entry)
        do {
            try enforce(maximumBytes: Int64(maximumSizeMB) * 1_000_000)
        } catch {
            print("Audio cache committed a track but could not enforce its size limit: \(error)")
        }
        return .retained(entry: entry, leaseID: leaseID)
    }

    func discard(_ session: AudioCacheWriteSession) throws {
        activeWrites.removeValue(forKey: session.id)
        clearAfterWrite.remove(session.id)
        try removePartialFile(at: session.partialFileURL)
    }

    func enforce(maximumSizeMB: Int) throws {
        self.maximumSizeMB = max(maximumSizeMB, 0)
        try enforce(maximumBytes: Int64(self.maximumSizeMB) * 1_000_000)
    }

    func usage() throws -> CacheUsage {
        try removeInactivePartialFiles()
        let entries = try completedEntries()
        return CacheUsage(bytes: try entries.reduce(into: Int64(0)) { total, entry in
            total += try allocatedSize(of: entry.fileURL)
        })
    }

    func clear() throws {
        let entries = try completedEntries()
        for entry in entries {
            if leases.values.contains(entry.fileURL) {
                clearAfterRelease.insert(entry.fileURL)
            } else {
                try removeEntry(entry)
            }
        }

        clearAfterWrite.formUnion(activeWrites.keys)
        let partialFiles = try fileManager.contentsOfDirectory(
            at: partialDirectory,
            includingPropertiesForKeys: nil
        )
        let activePartialFilePaths = activePartialFilePaths()
        for partialFile in partialFiles
        where !activePartialFilePaths.contains(partialFile.resolvingSymlinksInPath().path) {
            try fileManager.removeItem(at: partialFile)
        }
    }

    private func enforce(maximumBytes: Int64) throws {
        let entries = try completedEntries().map { entry in
            (entry, try allocatedSize(of: entry.fileURL), try modificationDate(of: entry.fileURL))
        }
        var bytes = entries.reduce(into: Int64(0)) { $0 += $1.1 }
        for (entry, entryBytes, _) in entries.sorted(by: { $0.2 < $1.2 }) where bytes > maximumBytes {
            guard !leases.values.contains(entry.fileURL) else { continue }
            try removeEntry(entry)
            bytes -= entryBytes
        }
    }

    private func ensureDirectories() throws {
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: partialDirectory, withIntermediateDirectories: true)
    }

    private func loadEntry(trackID: Int) throws -> AudioCacheEntry? {
        try ensureDirectories()
        let metadataURL = metadataURL(for: trackID)
        guard fileManager.fileExists(atPath: metadataURL.path) else { return nil }
        let metadata: AudioCacheMetadata
        do {
            metadata = try JSONDecoder().decode(
                AudioCacheMetadata.self,
                from: Data(contentsOf: metadataURL)
            )
        } catch {
            try fileManager.removeItem(at: metadataURL)
            print("Audio cache removed invalid metadata for track \(trackID): \(error)")
            return nil
        }
        guard metadata.trackID == trackID else {
            try fileManager.removeItem(at: metadataURL)
            print("Audio cache removed metadata stored under the wrong track id: \(trackID)")
            return nil
        }
        let fileURL: URL
        do {
            fileURL = try completedFileURL(for: metadata)
        } catch {
            try fileManager.removeItem(at: metadataURL)
            print("Audio cache removed invalid metadata for track \(trackID): \(error)")
            return nil
        }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            try fileManager.removeItem(at: metadataURL)
            return nil
        }
        let entry = AudioCacheEntry(fileURL: fileURL, metadata: metadata)
        guard try fileSize(of: fileURL) == metadata.byteCount else {
            try removeEntry(entry)
            print("Audio cache removed an incomplete file for track \(trackID).")
            return nil
        }
        return entry
    }

    private func completedEntries() throws -> [AudioCacheEntry] {
        try ensureDirectories()
        let cacheContents = try fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        let metadataFiles = cacheContents.filter { $0.pathExtension == "json" }
        var entries: [AudioCacheEntry] = []
        for metadataFile in metadataFiles {
            do {
                let metadata = try JSONDecoder().decode(
                    AudioCacheMetadata.self,
                    from: Data(contentsOf: metadataFile)
                )
                guard metadataFile.lastPathComponent == "\(metadata.trackID).json" else {
                    throw AudioCacheError.invalidFileName
                }
                let fileURL = try completedFileURL(for: metadata)
                guard fileManager.fileExists(atPath: fileURL.path) else {
                    try fileManager.removeItem(at: metadataFile)
                    continue
                }
                let entry = AudioCacheEntry(fileURL: fileURL, metadata: metadata)
                let hasExpectedSize = leases.values.contains(fileURL)
                    ? true
                    : try fileSize(of: fileURL) == metadata.byteCount
                guard hasExpectedSize else {
                    try removeEntry(entry)
                    print("Audio cache removed an incomplete file for track \(metadata.trackID).")
                    continue
                }
                entries.append(entry)
            } catch {
                try removeFileIfPresent(at: metadataFile)
                print("Audio cache removed invalid metadata \(metadataFile.lastPathComponent): \(error)")
            }
        }

        let protectedFilePaths = Set(
            entries.map { $0.fileURL.resolvingSymlinksInPath().path }
                + leases.values.map { $0.resolvingSymlinksInPath().path }
        )
        for fileURL in cacheContents where fileURL.pathExtension != "json" {
            let values = try fileURL.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory != true,
                  !protectedFilePaths.contains(fileURL.resolvingSymlinksInPath().path) else { continue }
            try fileManager.removeItem(at: fileURL)
            print("Audio cache removed orphaned file \(fileURL.lastPathComponent).")
        }
        return entries
    }

    private func metadataURL(for trackID: Int) -> URL {
        cacheDirectory.appendingPathComponent("\(trackID).json")
    }

    private func completedFileURL(for metadata: AudioCacheMetadata) throws -> URL {
        guard metadata.fileName == URL(fileURLWithPath: metadata.fileName).lastPathComponent,
              !metadata.fileName.isEmpty else {
            throw AudioCacheError.invalidFileName
        }
        return cacheDirectory.appendingPathComponent(metadata.fileName)
    }

    private func sanitizedFileExtension(_ value: String) throws -> String {
        let allowed = CharacterSet.alphanumerics
        guard !value.isEmpty,
              value.count <= 10,
              value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw AudioCacheError.invalidFileName
        }
        return value.lowercased()
    }

    private func touch(_ fileURL: URL) throws {
        try fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
    }

    private func modificationDate(of fileURL: URL) throws -> Date {
        let values = try fileURL.resourceValues(forKeys: [.contentModificationDateKey])
        return values.contentModificationDate ?? .distantPast
    }

    private func allocatedSize(of fileURL: URL) throws -> Int64 {
        let values = try fileURL.resourceValues(forKeys: [.fileAllocatedSizeKey, .fileSizeKey])
        return Int64(values.fileAllocatedSize ?? values.fileSize ?? 0)
    }

    private func fileSize(of fileURL: URL) throws -> Int64 {
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    private func removeEntry(_ entry: AudioCacheEntry) throws {
        try removeFileIfPresent(at: entry.fileURL)
        let metadataURL = metadataURL(for: entry.metadata.trackID)
        if fileManager.fileExists(atPath: metadataURL.path) {
            try fileManager.removeItem(at: metadataURL)
        }
    }

    private func removeCompletedFile(at fileURL: URL) throws {
        try removeFileIfPresent(at: fileURL)
        let metadataFiles = try fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        for metadataFile in metadataFiles {
            let metadata = try JSONDecoder().decode(AudioCacheMetadata.self, from: Data(contentsOf: metadataFile))
            if try completedFileURL(for: metadata) == fileURL {
                try fileManager.removeItem(at: metadataFile)
                return
            }
        }
    }

    private func removePartialFile(at fileURL: URL) throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }

    private func removeInactivePartialFiles() throws {
        try ensureDirectories()
        let activePartialFilePaths = activePartialFilePaths()
        let partialFiles = try fileManager.contentsOfDirectory(
            at: partialDirectory,
            includingPropertiesForKeys: nil
        )
        for partialFile in partialFiles
        where !activePartialFilePaths.contains(partialFile.resolvingSymlinksInPath().path) {
            try fileManager.removeItem(at: partialFile)
        }
    }

    private func activePartialFilePaths() -> Set<String> {
        Set(activeWrites.values.map { $0.partialFileURL.resolvingSymlinksInPath().path })
    }

    private func removeFileIfPresent(at fileURL: URL) throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }
}
