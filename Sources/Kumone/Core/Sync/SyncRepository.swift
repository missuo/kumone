import Foundation
import os

/// Each installation writes only its own directory. File coordination protects
/// access through both iCloud containers and user-authorized File Provider folders.
actor SyncRepository {
    enum Domain: String, CaseIterable {
        case playback, preferences, login
    }

    private var directory: URL?
    private var scopedURL: URL?
    private var connectionID: UUID?
    private var conflicts: [String: [NSFileVersion]] = [:]
    private var presenter: SyncDirectoryPresenter?
    private let log = Logger(subsystem: "sb.moe.kumone", category: "sync-repository")
    private struct FileStamp: Equatable {
        let identity: any NSObjectProtocol
        let generation: any NSObjectProtocol

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.identity.isEqual(rhs.identity) && lhs.generation.isEqual(rhs.generation)
        }
    }
    private struct CachedRecord {
        let stamp: FileStamp?
        let data: Data
        // Type erasure stays inside the generic repository cache. A different
        // requested payload type must decode and validate its own record.
        let record: Any
    }
    private var decodedFiles: [String: CachedRecord] = [:]
    private var playbackStore: PlaybackSyncStore
    private struct Manifest: Codable {
        let application: String
        let schemaVersion: Int
    }

    init(now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        playbackStore = PlaybackSyncStore(now: now)
    }

    func connect(to selectedURL: URL, connectionID: UUID) throws -> Data {
        disconnect()
        if selectedURL.startAccessingSecurityScopedResource() { scopedURL = selectedURL }
        do {
            let containsRepository = FileManager.default.fileExists(
                atPath: selectedURL.appendingPathComponent("repository.json").path
            )
            let root = containsRepository || selectedURL.lastPathComponent == "Kumone"
                ? selectedURL : selectedURL.appendingPathComponent("Kumone", isDirectory: true)
            try coordinate(root, writing: true) { url in
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
            return try connectAuthorizedDirectory(root, connectionID: connectionID)
        } catch {
            disconnect()
            throw error
        }
    }

    func restore(bookmark: Data, connectionID: UUID) throws -> Data {
        disconnect()
        var stale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
        #else
        let options: URL.BookmarkResolutionOptions = .withoutUI
        #endif
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: bookmark, options: options, bookmarkDataIsStale: &stale)
        } catch {
            let failure = error as NSError
            log.error("Could not restore directory authorization: \(failure.domain, privacy: .public) (\(failure.code)): \(failure.localizedDescription, privacy: .public)")
            throw SyncError.unavailable
        }
        // A deleted authorized folder requires a new grant. Do not recreate it
        // through an old bookmark or publish into a location the user removed.
        if url.startAccessingSecurityScopedResource() { scopedURL = url }
        do {
            try checkDirectory(url)
            return try connectAuthorizedDirectory(url, connectionID: connectionID)
        } catch {
            disconnect()
            throw error
        }
    }

    /// The caller owns directory authorization until failure or disconnect.
    private func connectAuthorizedDirectory(_ root: URL, connectionID: UUID) throws -> Data {
        try validateRepository(at: root)
        let bookmark: Data
        do {
            #if os(macOS)
            bookmark = try root.bookmarkData(options: .withSecurityScope)
            #else
            bookmark = try root.bookmarkData(options: .minimalBookmark)
            #endif
        } catch {
            let failure = error as NSError
            log.error("Could not save directory authorization: \(failure.domain, privacy: .public) (\(failure.code)): \(failure.localizedDescription, privacy: .public)")
            throw SyncError.unavailable
        }
        directory = root
        self.connectionID = connectionID
        return bookmark
    }

    func connectContainer(connectionID: UUID) throws -> Bool {
        disconnect()
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else { return false }
        let root = container.appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Kumone", isDirectory: true)
        try coordinate(root, writing: true) { url in
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try validateRepository(at: root)
        directory = root
        self.connectionID = connectionID
        return true
    }

    func disconnect(connectionID: UUID? = nil) {
        if let connectionID, self.connectionID != connectionID { return }
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        directory = nil
        self.connectionID = nil
        conflicts.removeAll()
        decodedFiles.removeAll()
        playbackStore.reset()
        if let presenter { NSFileCoordinator.removeFilePresenter(presenter) }
        presenter = nil
    }

    func observeChanges(_ onChange: @escaping @Sendable (URL) -> Void) {
        guard let directory else { return }
        if let presenter { NSFileCoordinator.removeFilePresenter(presenter) }
        let observer = SyncDirectoryPresenter(directory: directory, onChange: onChange)
        presenter = observer
        NSFileCoordinator.addFilePresenter(observer)
    }

    func read<Payload: Codable>(_ domain: Domain, as type: Payload.Type, connectionID: UUID) throws -> [SyncRecord<Payload>] {
        let directory = try connectedDirectory(connectionID: connectionID)
        let devices: [URL] = try coordinate(directory, writing: false) { root in
            let devices = root.appendingPathComponent("Devices", isDirectory: true)
            guard FileManager.default.fileExists(atPath: devices.path) else { return [] }
            return try FileManager.default.contentsOfDirectory(at: devices, includingPropertiesForKeys: nil)
                .filter { UUID(uuidString: $0.lastPathComponent) != nil }
        }
        decodedFiles = decodedFiles.filter { FileManager.default.fileExists(atPath: $0.key) }
        return try devices.flatMap { device -> [SyncRecord<Payload>] in
            let file = device.appendingPathComponent(domain.rawValue).appendingPathExtension("json")
            guard FileManager.default.fileExists(atPath: file.path) else { return [] }
            do {
                return try coordinate(file, writing: false) { url in
                    let records: [SyncRecord<Payload>] = try self.readVersions(at: url)
                    guard records.allSatisfy({ $0.id.uuidString == device.lastPathComponent }) else {
                        throw SyncError.invalidRecord
                    }
                    return records
                }
            } catch {
                // Login devices are independent. A malformed or unavailable file
                // cannot revoke other devices' valid accounts; retry it next round.
                guard domain == .login else { throw error }
                log.error("Could not read login for device \(device.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return []
            }
        }
    }

    /// Cache only successfully decoded content. File generations identify in-place
    /// edits; resource identity also detects atomic replacements. Providers without
    /// these identifiers compare bytes, rather than trusting timestamps or size.
    func readRecord<Payload: Codable>(at url: URL) throws -> SyncRecord<Payload> {
        let key = fileKey(for: url)
        do {
            let values = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey,
                                                         .fileResourceIdentifierKey, .generationIdentifierKey])
            if values.ubiquitousItemDownloadingStatus == .notDownloaded {
                try FileManager.default.startDownloadingUbiquitousItem(at: url)
                throw SyncError.downloading
            }
            let stamp: FileStamp?
            if let identity = values.fileResourceIdentifier, let generation = values.generationIdentifier {
                stamp = FileStamp(identity: identity, generation: generation)
            } else { stamp = nil }
            if let stamp, let cached = decodedFiles[key], cached.stamp == stamp,
               let record = cached.record as? SyncRecord<Payload> { return record }
            let data = try Data(contentsOf: url)
            if let cached = decodedFiles[key], cached.data == data,
               let record = cached.record as? SyncRecord<Payload> {
                decodedFiles[key] = CachedRecord(stamp: stamp, data: data, record: record)
                return record
            }
            let record: SyncRecord<Payload>
            do { record = try JSONDecoder().decode(SyncRecord<Payload>.self, from: data) }
            catch is DecodingError { throw SyncError.invalidRecord }
            decodedFiles[key] = CachedRecord(stamp: stamp, data: data, record: record)
            return record
        } catch {
            decodedFiles[key] = nil
            throw error
        }
    }

    /// The caller holds file coordination for the current item and its versions.
    func readVersions<Payload: Codable>(at url: URL) throws -> [SyncRecord<Payload>] {
        let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
        let records = try ([url] + versions.map(\.url)).map { version -> SyncRecord<Payload> in
            try readRecord(at: version)
        }
        conflicts[fileKey(for: url)] = versions.isEmpty ? nil : versions
        return records
    }

    func invalidateCache(at url: URL) {
        let key = fileKey(for: url)
        decodedFiles[key] = nil
        conflicts[key] = nil
    }

    /// File coordination and enumeration can return /var and /private/var for
    /// the same item. Both caches must use its resolved path, not URL spelling.
    private func fileKey(for url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }

    func write<Payload: Codable>(_ record: SyncRecord<Payload>, domain: Domain, connectionID: UUID) throws {
        let directory = try connectedDirectory(connectionID: connectionID)
        let file = directory.appendingPathComponent("Devices/\(record.id.uuidString)/\(domain.rawValue).json")
        try write(record, to: file)
    }

    func write<Payload: Codable>(_ record: SyncRecord<Payload>, to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(record)
        try coordinate(file.deletingLastPathComponent(), writing: true) { url in
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try coordinate(file, writing: true) { url in
            self.decodedFiles[self.fileKey(for: url)] = nil
            try data.write(to: url, options: .atomic)
            let key = self.fileKey(for: url)
            let values = try url.resourceValues(forKeys: [.fileResourceIdentifierKey, .generationIdentifierKey])
            let stamp: FileStamp?
            if let identity = values.fileResourceIdentifier, let generation = values.generationIdentifier {
                stamp = FileStamp(identity: identity, generation: generation)
            } else { stamp = nil }
            self.decodedFiles[key] = CachedRecord(stamp: stamp, data: data, record: record)
            // Only retire conflict versions already read into the domain merge;
            // a version that arrived since the read must survive the next cycle.
            for version in self.conflicts[key] ?? [] {
                version.isResolved = true
                try version.remove()
                self.decodedFiles[self.fileKey(for: version.url)] = nil
            }
            self.conflicts[key] = nil
        }
    }

    /// The folder's one shared login key description; nil until a device sets
    /// a sync passphrase.
    func readLoginKey(connectionID: UUID) throws -> LoginKeyFile? {
        let file = try connectedDirectory(connectionID: connectionID).appendingPathComponent("login-key.json")
        return try coordinate(file, writing: false) { url in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let values = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            if values.ubiquitousItemDownloadingStatus == .notDownloaded {
                try FileManager.default.startDownloadingUbiquitousItem(at: url)
                throw SyncError.downloading
            }
            let keyFile: LoginKeyFile
            do { keyFile = try JSONDecoder().decode(LoginKeyFile.self, from: Data(contentsOf: url)) }
            catch is DecodingError { throw SyncError.invalidRecord }
            try keyFile.validate()
            return keyFile
        }
    }

    func writeLoginKey(_ keyFile: LoginKeyFile, connectionID: UUID) throws {
        let file = try connectedDirectory(connectionID: connectionID).appendingPathComponent("login-key.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(keyFile)
        try coordinate(file, writing: true) { url in try data.write(to: url, options: .atomic) }
    }

    func readPlayback(connectionID: UUID) throws -> PlaybackSyncStore.ReadResult {
        _ = try connectedDirectory(connectionID: connectionID)
        return try playbackStore.read(from: self, connectionID: connectionID)
    }

    func loadPlayback(_ record: SyncRecord<PlaybackCheckpoint>, connectionID: UUID) throws -> PlaybackSession {
        let directory = try connectedDirectory(connectionID: connectionID)
        return try playbackStore.load(record, from: self, directory: directory)
    }

    func writePlayback(_ record: SyncRecord<PlaybackSession>, connectionID: UUID) throws {
        let directory = try connectedDirectory(connectionID: connectionID)
        try playbackStore.write(record, to: self, directory: directory, connectionID: connectionID)
    }

    private func connectedDirectory(connectionID: UUID) throws -> URL {
        guard self.connectionID == connectionID, let directory else { throw CancellationError() }
        try checkDirectory(directory)
        return directory
    }

    private func checkDirectory(_ url: URL) throws {
        do {
            var currentURL = url
            currentURL.removeAllCachedResourceValues()
            guard try currentURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw SyncError.unavailable
            }
        } catch {
            let failure = error as NSError
            log.error("Sync directory is unavailable: \(failure.domain, privacy: .public) (\(failure.code)): \(failure.localizedDescription, privacy: .public)")
            throw SyncError.unavailable
        }
    }

    private func validateRepository(at directory: URL) throws {
        let file = directory.appendingPathComponent("repository.json")
        try coordinate(file, writing: true) { url in
            if FileManager.default.fileExists(atPath: url.path) {
                do {
                    let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
                    guard manifest.application == "Kumone" else { throw SyncError.invalidRecord }
                    guard manifest.schemaVersion == 1 else { throw SyncError.newerVersion }
                } catch is DecodingError { throw SyncError.invalidRecord }
            } else {
                let manifest = Manifest(application: "Kumone", schemaVersion: 1)
                try JSONEncoder().encode(manifest).write(to: url, options: .atomic)
            }
        }
    }

    func coordinate<T>(_ url: URL, writing: Bool, access: @escaping (URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<T, Error>?
        let accessor: (URL) -> Void = { coordinatedURL in
            result = Result { try access(coordinatedURL) }
        }
        if writing {
            coordinator.coordinate(writingItemAt: url, options: [], error: &coordinationError, byAccessor: accessor)
        } else {
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError, byAccessor: accessor)
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw SyncError.unavailable }
        return try result.get()
    }

    func coordinate<T>(reading file: URL, writing directory: URL, access: @escaping (URL, URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<T, Error>?
        coordinator.coordinate(readingItemAt: file, options: [], writingItemAt: directory, options: [],
                               error: &coordinationError) { file, directory in
            result = Result { try access(file, directory) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw SyncError.unavailable }
        return try result.get()
    }
}

private final class SyncDirectoryPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    private let onChange: @Sendable (URL) -> Void

    init(directory: URL, onChange: @escaping @Sendable (URL) -> Void) {
        presentedItemURL = directory
        self.onChange = onChange
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        presentedItemOperationQueue = queue
        super.init()
    }

    func presentedItemDidChange() {
        if let presentedItemURL { onChange(presentedItemURL) }
    }
    func presentedSubitemDidChange(at url: URL) { onChange(url) }
    func presentedSubitemDidAppear(at url: URL) { onChange(url) }
    func presentedItemDidMove(to newURL: URL) { onChange(newURL) }
}
