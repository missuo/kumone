import Foundation
import Testing
@testable import KumoneCore

@Suite("Storage accounting and cache protection")
struct StorageUsageTests {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("kumone-storage-\(UUID())") }

    private func addAudio(_ store: OfflineStore, id: Int, scope: String = "account-a", retained: Bool = false) async throws -> OfflineAudioDescriptor {
        let fixture = try OfflineAudioFixture()
        let identity = OfflineAudioIdentity(accountScope: scope, trackID: id, source: "netease", quality: "exhigh", format: .mp3,
                                            contentMD5: fixture.descriptor.identity.contentMD5)
        let descriptor = OfflineAudioDescriptor(identity: identity, byteCount: fixture.descriptor.byteCount, duration: 3)
        let writer = UUID()
        try await store.begin(descriptor, writer: writer)
        try await store.write(fixture.data, at: 0, id: identity.id, writer: writer)
        try await store.finalize(id: identity.id, writer: writer)
        await store.releaseWriter(id: identity.id, writer: writer)
        if retained { try await store.retain(id: identity.id, owner: "download:\(id)") }
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
        let bundle = base.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let image = images.appendingPathComponent("image")
        try Data(repeating: 1, count: 5_000).write(to: image)
        try Data(repeating: 2, count: 8_000).write(to: bundle.appendingPathComponent("binary"))
        let outside = base.appendingPathComponent("outside")
        try Data(repeating: 3, count: 100_000).write(to: outside)
        try FileManager.default.createSymbolicLink(at: images.appendingPathComponent("linked-file"), withDestinationURL: outside)
        let store = OfflineStore(directory: support.appendingPathComponent("Offline"), minimumFreeBytes: 0)
        let cached = try await addAudio(store, id: 1)
        let download = try await addAudio(store, id: 2, scope: "account-b", retained: true)
        let files = try await store.storageFiles()
        let cachedURL = try #require(files.first { $0.assetID == cached.identity.id && $0.url.path.contains("/audio/") }?.url)
        let downloadURL = try #require(files.first { $0.assetID == download.identity.id && $0.url.path.contains("/audio/") }?.url)
        let reader = StorageUsageReader(roots: [support, images, bundle, support], imageDirectory: images,
                                        downloadDirectory: store.directory.appendingPathComponent("downloads"), volumeURL: support)
        let usage = await reader.read(audioFiles: files, downloadAssetIDs: [], accountScope: "account-a")
        #expect(usage[.imageCache] == (try size(image)))
        #expect(usage[.musicCache] == (try size(cachedURL)))
        #expect(usage[.downloads] == (try size(downloadURL)))
        #expect(usage.otherAccountDownloads == usage[.downloads])
        #expect(usage.musicCacheSongs == 1)
        #expect(!usage.partial)
        let simple = StorageUsageReader(roots: [support, bundle], imageDirectory: images,
                                        downloadDirectory: store.directory.appendingPathComponent("downloads"), volumeURL: support)
        let withoutOverlap = await simple.read(audioFiles: files, downloadAssetIDs: [], accountScope: "account-a")
        #expect(usage.bytes == withoutOverlap.bytes)
    }

    @Test func clearingMusicPreservesDownloadsPlaybackAndPendingPromotions() async throws {
        let base = root()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = OfflineStore(directory: base, minimumFreeBytes: 0)
        let cache = try await addAudio(store, id: 1)
        let download = try await addAudio(store, id: 2, retained: true)
        let playing = try await addAudio(store, id: 3)
        let pending = try await addAudio(store, id: 4)
        let lease = try #require(try await store.acquire(accountScope: "account-a", trackID: 3, preferredQuality: "exhigh"))
        let result = try await store.clearMusicCache(excluding: [pending.identity.id])
        #expect(result.removed == 1 && result.inUse == 1 && result.failed == 0)
        #expect(try await store.record(id: cache.identity.id) == nil)
        #expect(try await store.record(id: download.identity.id)?.state == .complete)
        #expect(try await store.record(id: playing.identity.id)?.state == .complete)
        #expect(try await store.record(id: pending.identity.id)?.state == .complete)
        try await store.release(lease)
        _ = try await store.reusableDescriptor(accountScope: "account-a", trackID: 4, quality: "exhigh", retainingFor: "promoting")
        _ = try await store.clearMusicCache()
        #expect(try await store.record(id: playing.identity.id) == nil)
        #expect(try await store.record(id: pending.identity.id)?.retainedBy == ["promoting"])
    }
}
