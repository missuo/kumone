import Foundation

/// Disk cache for full song audio plus analysis sidecars, with LRU eviction
/// by file mtime and in-flight download coalescing. See docs/automix-spec.md §3.
actor AudioCache {
    static let shared = AudioCache()

    struct Key: Hashable, Sendable {
        let trackID: Int
        let level: String          // served quality level, e.g. "exhigh"
        let source: String         // "netease" or "unblock:<source>"
        let fileExtension: String  // "mp3"/"flac"/"m4a", inferred by the caller
    }

    private static let limitDefaultsKey = "settings.audioCacheLimit"
    private static let defaultLimitBytes: Int64 = 2_147_483_648  // 2 GB
    private static let partSuffix = ".part"
    private static let sidecarSuffix = ".analysis.json"
    /// Timed lyrics, written by `LyricsSidecar` for the hand-over picker. Unlike
    /// the analysis sidecar this one *replaces* the audio extension (the `.lrc`
    /// convention `Audition.Lyrics` reads), so it needs its own path math.
    private static let lyricsExtension = "lrc"

    private let directory: URL
    private var inflight: [Key: Task<URL, Error>] = [:]
    private(set) var limitBytes: Int64

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("Kumone/Audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if UserDefaults.standard.object(forKey: Self.limitDefaultsKey) != nil {
            limitBytes = Int64(UserDefaults.standard.integer(forKey: Self.limitDefaultsKey))
        } else {
            limitBytes = Self.defaultLimitBytes
        }
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
            let (temp, response) = try await URLSession.shared.download(from: remote)
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

    /// The in-flight coalesced download for this key, if any — lets callers
    /// wait for a prefetch already underway instead of opening a second
    /// transfer of the same file.
    func activeDownload(for key: Key) -> Task<URL, Error>? {
        inflight[key]
    }

    // MARK: - Analysis sidecar

    func loadAnalysis(for key: Key) -> TrackAnalysis? {
        guard let data = try? Data(contentsOf: sidecarURL(for: key)),
              let analysis = try? JSONDecoder().decode(TrackAnalysis.self, from: data),
              analysis.version == TrackAnalysis.currentVersion else { return nil }
        return analysis
    }

    /// Every analysis sidecar on disk for the given tracks, **at any quality
    /// level**, in one directory walk.
    ///
    /// This is the free half of the queue-order candidate pool (predev §2.2):
    /// a track heard before already has a playback-quality analysis sitting
    /// next to its audio, and asking for it costs no network call, no
    /// download and no analyzer pass. Keyed by track ID rather than by `Key`
    /// because the caller does not know — and must not have to resolve — which
    /// level and container that track landed in.
    ///
    /// The best level present wins when a track has several, since a
    /// playback-quality sidecar is strictly better than a scoring one and
    /// costs the same to read.
    func analyses(forTrackIDs ids: Set<Int>) -> [Int: TrackAnalysis] {
        guard !ids.isEmpty,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return [:] }
        var best: [Int: (rank: Int, analysis: TrackAnalysis)] = [:]
        for name in names where name.hasSuffix(Self.sidecarSuffix) {
            // "<trackID>-<level>-<source>.<ext>.analysis.json"
            let parts = name.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let id = Int(parts[0]), ids.contains(id) else { continue }
            let rank = Self.levelRank(String(parts[1]))
            if let existing = best[id], existing.rank >= rank { continue }
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  let analysis = try? JSONDecoder().decode(TrackAnalysis.self, from: data),
                  analysis.version == TrackAnalysis.currentVersion else { continue }
            best[id] = (rank, analysis)
        }
        return best.mapValues(\.analysis)
    }

    /// Quality levels cheapest first. Unknown names sort last, so a level this
    /// build has never heard of is treated as the best thing on disk rather
    /// than silently preferred against.
    private static let levelLadder = ["standard", "higher", "exhigh", "lossless", "hires"]

    private static func levelRank(_ level: String) -> Int {
        levelLadder.firstIndex(of: level) ?? levelLadder.count
    }

    func storeAnalysis(_ analysis: TrackAnalysis, for key: Key) {
        ensureDirectory()
        guard let data = try? JSONEncoder().encode(analysis) else { return }
        try? data.write(to: sidecarURL(for: key), options: .atomic)
    }

    // MARK: - Limits & maintenance

    /// 0 means unlimited. Shrinking the limit evicts immediately.
    func setLimitBytes(_ bytes: Int64) {
        limitBytes = max(0, bytes)
        UserDefaults.standard.set(limitBytes, forKey: Self.limitDefaultsKey)
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

    private func sidecarURL(for key: Key) -> URL {
        URL(fileURLWithPath: fileURL(for: key).path + Self.sidecarSuffix)
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

    /// Deletes least-recently-used audio (and its sidecar) until total usage
    /// fits the limit. In-progress `.part` files and `spare` are never removed.
    private func evictIfNeeded(sparing spare: URL?) {
        guard limitBytes > 0 else { return }
        let files = allFiles()
        var usage = files.reduce(0) { $0 + $1.size }
        guard usage > limitBytes else { return }

        let sidecarSizes = Dictionary(
            uniqueKeysWithValues: files
                .filter {
                    $0.url.lastPathComponent.hasSuffix(Self.sidecarSuffix)
                        || $0.url.pathExtension == Self.lyricsExtension
                }
                .map { ($0.url.path, $0.size) })
        let candidates = files
            .filter {
                let name = $0.url.lastPathComponent
                return !name.hasSuffix(Self.partSuffix)
                    && !name.hasSuffix(Self.sidecarSuffix)
                    // A `.lrc` is not audio; evicting it on its own would strip
                    // a live track of its hand-over words to reclaim a few KB.
                    && $0.url.pathExtension != Self.lyricsExtension
                    && $0.url.path != spare?.path
            }
            .sorted { $0.modified < $1.modified }

        for entry in candidates {
            guard usage > limitBytes else { break }
            try? FileManager.default.removeItem(at: entry.url)
            usage -= entry.size
            // Both sidecars follow the audio out; a lyrics file left behind
            // would otherwise outlive every track that ever passed through.
            for sidecarPath in [entry.url.path + Self.sidecarSuffix,
                                entry.url.deletingPathExtension()
                                    .appendingPathExtension(Self.lyricsExtension).path] {
                if let sidecarSize = sidecarSizes[sidecarPath] {
                    try? FileManager.default.removeItem(atPath: sidecarPath)
                    usage -= sidecarSize
                }
            }
        }
    }
}
