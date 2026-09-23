import Foundation
import Testing
@testable import KumoneCore

@Suite("Storage accounting")
struct StorageUsageTests {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("kumone-storage-\(UUID())") }

    private func addDownload(_ store: OfflineStore, id: Int, scope: String = "account-a") async throws -> OfflineAudioDescriptor {
        let fixture = try OfflineAudioFixture()
        let identity = OfflineAudioIdentity(accountScope: scope, trackID: id, source: "netease", quality: "exhigh", format: .mp3,
                                            contentMD5: fixture.descriptor.identity.contentMD5)
        let descriptor = OfflineAudioDescriptor(identity: identity, byteCount: fixture.descriptor.byteCount, duration: 3)
        try await store.importFixture(fixture.data, descriptor: descriptor)
        try await store.retain(id: identity.id, owner: "download:\(id)")
        return descriptor
    }

    private func size(_ url: URL) throws -> Int64 {
        let info = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey])
        return Int64(info.totalFileAllocatedSize ?? info.fileAllocatedSize ?? info.fileSize ?? 0)
    }

    @Test func storageBarUsesOneCapacityAndClampsInvalidInputs() {
        let capacity = DeviceStorageCapacity(total: 100, available: 20)
        #expect(capacity.fractions(appBytes: 10) == [0.1, 0.7, 0.2])
        #expect(capacity.fractions(appBytes: 200) == [0.8, 0, 0.2])
        #expect(DeviceStorageCapacity(total: 100, available: 200).fractions(appBytes: 50) == [0, 0, 1])
        #expect(DeviceStorageCapacity(total: 0, available: 0).fractions(appBytes: 1) == [0, 0, 1])
        #expect(DeviceStorageCapacity(total: 100, available: -10).fractions(appBytes: 25) == [0.25, 0.75, 0])
    }

    @Test func separatesStorageWithoutCountingOverlappingRootsOrSymlinks() async throws {
        let base = root()
        defer { try? FileManager.default.removeItem(at: base) }
        let support = base.appendingPathComponent("support")
        let images = support.appendingPathComponent("images")
        let musicCache = support.appendingPathComponent("audio-cache")
        let bundle = base.appendingPathComponent("app")
        for directory in [images, musicCache, bundle] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let image = images.appendingPathComponent("image")
        try Data(repeating: 1, count: 5_000).write(to: image)
        let cached = musicCache.appendingPathComponent("song.mp3")
        try Data(repeating: 4, count: 6_000).write(to: cached)
        try Data(repeating: 2, count: 8_000).write(to: bundle.appendingPathComponent("binary"))
        let outside = base.appendingPathComponent("outside")
        try Data(repeating: 3, count: 100_000).write(to: outside)
        try FileManager.default.createSymbolicLink(at: images.appendingPathComponent("linked-file"), withDestinationURL: outside)
        let store = OfflineStore(directory: support.appendingPathComponent("Offline"), minimumFreeBytes: 0)
        let mine = try await addDownload(store, id: 1)
        let theirs = try await addDownload(store, id: 2, scope: "account-b")
        let files = try await store.storageFiles()
        let mineURL = try #require(files.first { $0.url.lastPathComponent.hasPrefix(mine.identity.id) && $0.url.path.contains("/audio/") }?.url)
        let theirsURL = try #require(files.first { $0.url.lastPathComponent.hasPrefix(theirs.identity.id) && $0.url.path.contains("/audio/") }?.url)
        let reader = StorageUsageReader(roots: [support, images, bundle, support], imageDirectory: images, musicCacheDirectories: [musicCache],
                                        downloadDirectory: store.directory.appendingPathComponent("downloads"), volumeURL: support)
        let usage = await reader.read(audioFiles: files, accountScope: "account-a")
        #expect(usage[.imageCache] == (try size(image)))
        #expect(usage[.musicCache] == (try size(cached)))
        #expect(usage[.downloads] == (try size(mineURL) + size(theirsURL)))
        #expect(usage.otherAccountDownloads == (try size(theirsURL)))
        #expect(!usage.partial)
        let simple = StorageUsageReader(roots: [support, bundle], imageDirectory: images, musicCacheDirectories: [musicCache],
                                        downloadDirectory: store.directory.appendingPathComponent("downloads"), volumeURL: support)
        let withoutOverlap = await simple.read(audioFiles: files, accountScope: "account-a")
        #expect(usage.bytes == withoutOverlap.bytes)
    }
}
