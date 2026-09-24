#if os(macOS)
import Foundation
import os

/// Disk cache for full song audio, with LRU eviction by file mtime and
/// in-flight download coalescing. See docs/automix-spec.md §3.
///
/// Track analyses belong to `AnalysisStore`, which lives outside this cache
/// precisely so that evicting or clearing audio does not throw away the
/// expensive part.
actor EngineAudioCache {
    static let shared = EngineAudioCache()

    struct Key: Hashable, Sendable {
        let trackID: Int
        let level: String          // served quality level, e.g. "exhigh"
        let source: String         // "netease" or "unblock:<source>"
        let fileExtension: String  // "mp3"/"flac"/"m4a", inferred by the caller
    }

    private static let partSuffix = ".part"
    /// Timed lyrics, written by `LyricsSidecar` for the hand-over picker. It
    /// *replaces* the audio extension (the `.lrc` convention
    /// `Audition.Lyrics` reads), so it needs its own path math.
    private static let lyricsExtension = "lrc"

    /// A `.part` touched within this long is a live progressive write and is
    /// left entirely alone by eviction; an older one is an abandoned stream
    /// (skipped mid-song, app quit) that nothing will ever commit.
    static let stalePartAge: TimeInterval = 60 * 60

    private let directory: URL
    private var inflight: [Key: Task<URL, Error>] = [:]
    private(set) var limitBytes: Int64
    /// Resolved paths of files a deck currently has open (or is about to), as
    /// last reported by the player. Lock-protected rather than actor-isolated
    /// so the player can replace it synchronously, in order, from the main
    /// actor — an async hop per change could land out of order.
    private let inUse = OSAllocatedUnfairLock(initialState: Set<String>())

    private init() {
        directory = KumoneDirectories.caches("Audio")
        if UserDefaults.standard.object(forKey: SettingsManager.Keys.audioCacheLimit) != nil {
            limitBytes = Int64(UserDefaults.standard
                .integer(forKey: SettingsManager.Keys.audioCacheLimit))
        } else {
            limitBytes = SettingsManager.defaultAudioCacheLimit
        }
    }

    /// A private cache over `directory`, for tests. Does not read or write the
    /// persisted limit.
    init(directory: URL, limitBytes: Int64) {
        self.directory = directory
        self.limitBytes = limitBytes
    }

    // MARK: - Lookup

    /// Returns the cached file URL on hit and touches its mtime so LRU
    /// eviction treats it as recently used. Returns nil on miss.
    func cachedFileURL(for key: Key) -> URL? {
        let url = fileURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }

    /// Any complete cached file of the track, newest first: offline there is
    /// no network answer to derive a key from.
    func cachedFileURL(trackID: Int) -> URL? {
        let prefix = "\(trackID)-"
        return allFiles()
            .filter { $0.url.lastPathComponent.hasPrefix(prefix) && !Self.isAuxiliary($0.url) }
            .max { $0.modified < $1.modified }?.url
    }

    /// Tracks with a complete cached file, for offline availability.
    func cachedTrackIDs() -> Set<Int> {
        Set(allFiles().compactMap { entry in
            guard !Self.isAuxiliary(entry.url) else { return nil }
            return Int(entry.url.lastPathComponent.prefix { $0 != "-" })
        })
    }

    private static func isAuxiliary(_ url: URL) -> Bool {
        url.lastPathComponent.hasSuffix(partSuffix) || url.pathExtension == lyricsExtension
    }

    /// Stable temporary path for progressive writes of the same key.
    /// Pure path math (directory creation is idempotent), so not isolated.
    nonisolated func partFileURL(for key: Key) -> URL {
        ensureDirectory()
        return URL(fileURLWithPath: fileURL(for: key).path + Self.partSuffix)
    }

    /// Atomically promotes the `.part` file to the final cache entry, then
    /// runs LRU eviction (sparing the file just committed).
    @discardableResult
    func commitPartFile(for key: Key) throws -> URL {
        let part = partFileURL(for: key)
        let final = fileURL(for: key)
        if FileManager.default.fileExists(atPath: final.path) {
            try FileManager.default.removeItem(at: final)
        }
        try FileManager.default.moveItem(at: part, to: final)
        evictIfNeeded(sparing: final)
        return final
    }

    // MARK: - Download

    /// Downloads the full file (prefetch path). Concurrent calls for the same
    /// key coalesce into one download. Moves the finished file straight to
    /// its final path — never through the `.part` slot, which belongs to a
    /// possibly concurrent progressive-stream mirror of the same key.
    func download(from remote: URL, key: Key) async throws -> URL {
        if let cached = cachedFileURL(for: key) { return cached }
        if let existing = inflight[key] {
            return try await existing.value
        }
        let task = Task<URL, Error> {
            let (temp, response) = try await Self.fetch(remote)
            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                try? FileManager.default.removeItem(at: temp)
                throw URLError(.badServerResponse)
            }
            let final = fileURL(for: key)
            ensureDirectory()
            if FileManager.default.fileExists(atPath: final.path) {
                try? FileManager.default.removeItem(at: final)
            }
            try FileManager.default.moveItem(at: temp, to: final)
            evictIfNeeded(sparing: final)
            return final
        }
        inflight[key] = task
        defer { inflight[key] = nil }
        return try await task.value
    }

    /// Downloads `remote`, starting on its CDN twin when its host failed
    /// recently, and retrying once on the twin when the host cannot be
    /// reached (see `NeteaseCDNHost`).
    private static func fetch(_ remote: URL) async throws -> (URL, URLResponse) {
        let first = NeteaseCDNHost.preferred(for: remote)
        do {
            return try await URLSession.shared.download(from: first)
        } catch where NeteaseCDNHost.isHostUnreachable(error) {
            guard let twin = NeteaseCDNHost.alternate(for: first) else { throw error }
            NeteaseCDNHost.markUnreachable(first)
            return try await URLSession.shared.download(from: twin)
        }
    }

    /// The in-flight coalesced download for this key, if any — lets callers
    /// wait for a prefetch already underway instead of opening a second
    /// transfer of the same file.
    func activeDownload(for key: Key) -> Task<URL, Error>? {
        inflight[key]
    }

    // MARK: - In use

    /// Replace the set of cached files playback has open: both decks' loaded
    /// files, plus the armed next track and the current one's complete file,
    /// which stem pre-renders and seeks re-open by path. Eviction never
    /// deletes these, however stale their mtime — AutoMix candidate prefetches
    /// touch many files, so LRU order alone does not keep a playing file safe.
    nonisolated func setFilesInUse(_ urls: some Sequence<URL>) {
        let paths = Set(urls.map(Self.identity))
        inUse.withLock { $0 = paths }
    }

    /// One spelling per file (`/var` vs `/private/var`, `..`), so a URL the
    /// player built and one read back from the directory compare equal.
    private static func identity(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    // MARK: - Limits & maintenance

    /// 0 means unlimited. Shrinking the limit evicts immediately.
    func setLimitBytes(_ bytes: Int64) {
        limitBytes = max(0, bytes)
        UserDefaults.standard.set(limitBytes, forKey: SettingsManager.Keys.audioCacheLimit)
        evictIfNeeded(sparing: nil)
    }

    func totalUsageBytes() -> Int64 {
        allFiles().reduce(0) { $0 + $1.size }
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        ensureDirectory()
    }

    // MARK: - Paths

    private nonisolated func fileURL(for key: Key) -> URL {
        directory.appendingPathComponent(fileName(for: key))
    }

    private nonisolated func fileName(for key: Key) -> String {
        "\(key.trackID)-\(Self.sanitize(key.level))-\(Self.sanitize(key.source)).\(Self.sanitize(key.fileExtension))"
    }

    /// Keeps file-name components free of path separators and other
    /// filesystem-hostile characters.
    private static func sanitize(_ component: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let mapped = component.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(mapped)
    }

    private nonisolated func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - LRU eviction

    private struct Entry {
        let url: URL
        let size: Int64
        let modified: Date
    }

    private func allFiles() -> [Entry] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys) else { return [] }
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return Entry(url: url,
                         size: Int64(values.fileSize ?? 0),
                         modified: values.contentModificationDate ?? .distantPast)
        }
    }

    /// Deletes least-recently-used audio (and its `.lrc`) until usage fits
    /// the limit. Never removed: `spare`, files registered through
    /// ``setFilesInUse(_:)``, and live `.part` files.
    ///
    /// The `.part` rule, and why: a live one (touched within
    /// ``stalePartAge``) is being written by the playing stream and cannot be
    /// deleted, so it is not counted either — counting what may not be
    /// evicted only made every pass strip the whole cache chasing a total it
    /// could never reach. It is counted once it commits. A stale one is an
    /// abandoned stream nothing will ever commit, so it counts and is
    /// evictable like any other file, by age.
    func evictIfNeeded(sparing spare: URL?) {
        guard limitBytes > 0 else { return }
        let staleBefore = Date().addingTimeInterval(-Self.stalePartAge)
        let files = allFiles().filter {
            !($0.url.lastPathComponent.hasSuffix(Self.partSuffix) && $0.modified >= staleBefore)
        }
        var usage = files.reduce(0) { $0 + $1.size }
        guard usage > limitBytes else { return }

        var protected = inUse.withLock { $0 }
        if let spare { protected.insert(Self.identity(spare)) }
        let lyricsSizes = Dictionary(
            uniqueKeysWithValues: files
                .filter { $0.url.pathExtension == Self.lyricsExtension }
                .map { ($0.url.path, $0.size) })
        let candidates = files
            .filter {
                // A `.lrc` is not audio; evicting it on its own would strip
                // a live track of its hand-over words to reclaim a few KB.
                $0.url.pathExtension != Self.lyricsExtension
                    && !protected.contains(Self.identity($0.url))
            }
            .sorted { $0.modified < $1.modified }

        for entry in candidates {
            guard usage > limitBytes else { break }
            try? FileManager.default.removeItem(at: entry.url)
            usage -= entry.size
            // The lyrics follow the audio out; a file left behind would
            // otherwise outlive every track that ever passed through.
            let lyricsPath = entry.url.deletingPathExtension()
                .appendingPathExtension(Self.lyricsExtension).path
            if let lyricsSize = lyricsSizes[lyricsPath] {
                try? FileManager.default.removeItem(atPath: lyricsPath)
                usage -= lyricsSize
            }
        }
    }
}
#endif
