import Foundation

enum StorageCategory: String, CaseIterable, Hashable {
    case imageCache, musicCache, downloads, appData
}

struct AudioStorageFile {
    let url: URL
    let accountScope: String
}

struct DeviceStorageCapacity: Equatable {
    let total: Int64
    let available: Int64
    var used: Int64 { max(0, total - max(0, min(total, available))) }

    /// A single common denominator keeps every bar segment truthful.
    func fractions(appBytes: Int64) -> [Double] {
        guard total > 0 else { return [0, 0, 1] }
        let app = max(0, min(used, appBytes))
        let other = max(0, used - app)
        return [Double(app) / Double(total), Double(other) / Double(total), Double(total - used) / Double(total)]
    }
}

struct StorageUsageSnapshot {
    var bytes: [StorageCategory: Int64] = [:]
    var otherAccountDownloads: Int64 = 0
    var device: DeviceStorageCapacity?
    var partial = false
    var unavailableCategories: Set<StorageCategory> = []
    var measuredAt = Date()

    subscript(_ category: StorageCategory) -> Int64 { bytes[category] ?? 0 }
    var appBytes: Int64 { bytes.values.reduce(0, +) }
}

/// Scans only the app's own roots and bundle, never the global Caches folder.
/// It neither follows symlinks nor counts overlapping roots twice.
actor StorageUsageReader {
    let roots: [URL]
    let imageDirectory: URL
    let musicCacheDirectories: [URL]
    let downloadDirectory: URL
    let volumeURL: URL

    init(roots: [URL], imageDirectory: URL, musicCacheDirectories: [URL], downloadDirectory: URL, volumeURL: URL) {
        self.roots = roots
        self.imageDirectory = imageDirectory.standardizedFileURL
        self.musicCacheDirectories = musicCacheDirectories.map(\.standardizedFileURL)
        self.downloadDirectory = downloadDirectory.standardizedFileURL
        self.volumeURL = volumeURL
    }

    func read(audioFiles: [AudioStorageFile], accountScope: String?) -> StorageUsageSnapshot {
        var snapshot = StorageUsageSnapshot()
        if let values = try? volumeURL.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
           let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity, total > 0 {
            snapshot.device = .init(total: Int64(total), available: Int64(available))
        }
        let assets = Dictionary(audioFiles.map { ($0.url.standardizedFileURL.path, $0) }, uniquingKeysWith: { first, _ in first })
        var visited: Set<String> = []
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                                        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]

        func count(_ url: URL) {
            let path = url.standardizedFileURL.path
            guard visited.insert(path).inserted else { return }
            do {
                let info = try url.resourceValues(forKeys: keys)
                guard info.isSymbolicLink != true, info.isRegularFile == true else { return }
                let size = Int64(max(0, info.totalFileAllocatedSize ?? info.fileAllocatedSize ?? info.fileSize ?? 0))
                let category: StorageCategory
                if Self.contains(url, in: imageDirectory) {
                    category = .imageCache
                } else if musicCacheDirectories.contains(where: { Self.contains(url, in: $0) }) {
                    category = .musicCache
                } else if let asset = assets[path] {
                    category = .downloads
                    if asset.accountScope != accountScope { snapshot.otherAccountDownloads += size }
                } else if Self.contains(url, in: downloadDirectory), ["audio", "resume"].contains(url.pathExtension) {
                    category = .downloads
                } else { category = .appData }
                snapshot.bytes[category, default: 0] += size
            } catch {
                let error = error as NSError
                if error.domain != NSCocoaErrorDomain || error.code != NSFileReadNoSuchFileError { snapshot.partial = true }
            }
        }

        for root in roots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            if (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { continue }
            count(root)
            guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                options: [], errorHandler: { _, error in
                    if (error as NSError).code != NSFileReadNoSuchFileError { snapshot.partial = true }
                    return true
                }) else { continue }
            for case let url as URL in files {
                if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                    files.skipDescendants()
                    continue
                }
                count(url)
            }
        }
        snapshot.measuredAt = Date()
        return snapshot
    }

    private static func contains(_ url: URL, in root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path == root.path || path.hasPrefix(root.path + "/")
    }
}
