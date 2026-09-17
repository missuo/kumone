import AVFoundation
import Foundation
import Testing
@testable import KumoneCore

@Suite("Automatic current-track cache", .timeLimit(.minutes(1)))
struct AutomaticMusicCacheTests {
    @Test func downloadsReclaimOrdinaryCacheBeforeLikesAndKeepProtectedAudio() async throws {
        let fixture = try OfflineAudioFixture(), root = fixture.store().directory
        defer { try? FileManager.default.removeItem(at: root) }
        let block = Int64((fixture.data.count + 4095) / 4096 * 4096)
        let floor: Int64 = 4096
        let store = OfflineStore(directory: root, minimumFreeBytes: floor, freeSpace: { url in
            let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
            var used: Int64 = 0
            while let file = files?.nextObject() as? URL {
                if file.pathExtension == "mp3" {
                    used += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
                }
            }
            return floor + block * 6 - used
        })
        var assets: [OfflineAudioDescriptor] = []
        for id in 1...5 {
            let asset = descriptor(fixture, id: id)
            let input = root.appendingPathComponent("input")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try fixture.data.write(to: input)
            try await store.importDownload(at: input, descriptor: asset)
            assets.append(asset)
        }
        try await store.retain(id: assets[2].identity.id, owner: "download")
        let playing = try #require(try await store.acquire(accountScope: "test-account", trackID: 4, preferredQuality: "exhigh"))
        let context = MusicCacheContext(policy: .disabled, protectedAssetIDs: [assets[4].identity.id], likedTracks: ["test-account": [2]])
        try await store.reserveDownload(token: "first", bytes: block * 2, context: context)
        #expect(try await store.record(id: assets[0].identity.id) == nil)
        #expect(try await store.record(id: assets[1].identity.id)?.state == .complete)
        try await store.reserveDownload(token: "second", bytes: block, context: context)
        #expect(try await store.record(id: assets[1].identity.id) == nil)
        for asset in assets.suffix(3) { #expect(try await store.record(id: asset.identity.id)?.state == .complete) }
        await #expect(throws: OfflineAudioError.insufficientSpace) {
            try await store.reserveDownload(token: "third", bytes: 1, context: context)
        }
        await store.releaseDownloadReservation(token: "first")
        await store.releaseDownloadReservation(token: "second")
        try await store.release(playing)
    }

    @Test func impossibleDownloadDoesNotEraseTheCache() async throws {
        let fixture = try OfflineAudioFixture(), root = fixture.store().directory
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OfflineStore(directory: root, minimumFreeBytes: 0, freeSpace: { _ in 0 })
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("input")
        try fixture.data.write(to: input)
        try await store.importDownload(at: input, descriptor: fixture.descriptor)
        await #expect(throws: OfflineAudioError.insufficientSpace) {
            try await store.reserveDownload(token: "too-large", bytes: 1_000_000)
        }
        #expect(try await store.record(id: fixture.descriptor.identity.id)?.state == .complete)
    }

    @Test @MainActor func switchingSongsDoesNotCancelAnAttachedDownload() async throws {
        let fixture = try OfflineAudioFixture(.flac), store = fixture.store()
        let server = try await AudioFixtureServer(fixture: fixture, delay: 0.01)
        defer { server.stop(); try? FileManager.default.removeItem(at: store.directory) }
        let session = PlaybackCacheSession(resource: fixture.resource(url: server.url), store: store,
                                            context: .init(policy: .automatic), fallbackURL: server.url, onFailure: {})
        try await session.transfer.prepare()
        let download = Task { try await session.finishForDownload(owner: "download:attached", allowsMetered: false) }
        for _ in 0..<200 where server.ranges.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        await session.close()
        let descriptor = try await download.value
        #expect(try await store.record(id: descriptor.identity.id)?.retainedBy == ["download:attached"])
        #expect(await session.transfer.receivedByteCount == fixture.descriptor.byteCount)
    }

    @Test func eligibilityRequiresTheSameCompleteRepresentation() async throws {
        let fixture = try OfflineAudioFixture()
        let track = try JSONDecoder().decode(Track.self, from: Data("{\"id\":1,\"name\":\"Fixture\",\"dt\":3000}".utf8))
        var json: [String: Any] = ["id": 1, "url": "https://example.test/audio.mp3", "code": 200,
                                  "level": "exhigh", "type": "mp3", "size": fixture.data.count,
                                  "time": 3000, "md5": fixture.descriptor.identity.contentMD5]
        func data() throws -> SongURLData { try JSONDecoder().decode(SongURLData.self, from: JSONSerialization.data(withJSONObject: json)) }
        let grant = fixture.resource(url: URL(string: "https://example.test/download.mp3")!)
        let resolved = try await PlaybackCacheResolver.resolve(data: data(), track: track, scope: "test-account", grant: { _, _, _ in grant })
        #expect(resolved.descriptor == grant.descriptor)
        #expect(resolved.url.path == "/audio.mp3")
        let changed = OfflineAudioResource(descriptor: .init(identity: .init(accountScope: "test-account", trackID: 1, source: "netease",
            quality: "higher", format: .mp3, contentMD5: fixture.descriptor.identity.contentMD5), byteCount: fixture.descriptor.byteCount, duration: 3), url: grant.url)
        await #expect(throws: OfflineAudioError.unavailable) {
            try await PlaybackCacheResolver.resolve(data: data(), track: track, scope: "test-account", grant: { _, _, _ in changed })
        }
        json["freeTrialInfo"] = ["start": 0, "end": 1000]
        await #expect(throws: OfflineAudioError.unavailable) {
            try await PlaybackCacheResolver.resolve(data: data(), track: track, scope: "test-account", grant: { _, _, _ in grant })
        }
    }

    @Test func closingDuringPreparationReleasesBothWriterAndPlaybackProtection() async throws {
        let fixture = try OfflineAudioFixture(), store = fixture.store()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let source = AudioTransferCoordinator(resource: fixture.resource(url: URL(string: "https://example.test/audio")!), store: store,
                                               cacheContext: .init(policy: .automatic))
        let starting = Task { try await source.prepare() }
        await source.close()
        _ = await starting.result
        let writer = UUID()
        try await store.begin(fixture.descriptor, writer: writer)
        await store.releaseWriter(id: fixture.descriptor.identity.id, writer: writer)
        _ = try await store.clearMusicCache()
        #expect(try await store.record(id: fixture.descriptor.identity.id) == nil)
    }

    @Test func deletingPromotedDownloadDefersRemovalUntilPlaybackStops() async throws {
        let fixture = try OfflineAudioFixture(), store = fixture.store()
        let server = try await AudioFixtureServer(fixture: fixture)
        defer { server.stop(); try? FileManager.default.removeItem(at: store.directory) }
        let source = AudioTransferCoordinator(resource: fixture.resource(url: server.url), store: store,
                                               cacheContext: .init(policy: .automatic))
        try await source.download()
        try await store.retain(id: fixture.descriptor.identity.id, owner: "download")
        try await store.removeRetention(id: fixture.descriptor.identity.id, owner: "download")
        try await store.remove(id: fixture.descriptor.identity.id)
        #expect(try await source.read(at: 0, maximum: 100) == fixture.data.prefix(100))
        await source.close()
        #expect(try await store.record(id: fixture.descriptor.identity.id) == nil)
    }

    @Test func capacityDoesNotShrinkAsItsOwnCacheGrows() {
        let gb: Int64 = 1_000_000_000
        let empty = MusicCachePolicy.automatic.limit(free: 100 * gb, cacheBytes: 0, downloadReservations: 0, floor: gb, isMac: false)
        let filled = MusicCachePolicy.automatic.limit(free: 92 * gb, cacheBytes: 8 * gb, downloadReservations: 0, floor: gb, isMac: false)
        #expect(empty == 10 * gb && filled == empty)
        #expect(MusicCachePolicy.automatic.limit(free: 500 * gb, cacheBytes: 0, downloadReservations: 0, floor: gb, isMac: false) == 30 * gb)
        #expect(MusicCachePolicy.automatic.limit(free: 500 * gb, cacheBytes: 0, downloadReservations: 0, floor: 2 * gb, isMac: true) == 50 * gb)
        #expect(MusicCachePolicy.gb5.limit(free: 2 * gb, cacheBytes: 0, downloadReservations: gb, floor: gb, isMac: false) == 0)
        #expect(MusicCachePolicy.disabled.limit(free: 100 * gb, cacheBytes: 0, downloadReservations: 0, floor: gb, isMac: false) == 0)
    }

    @Test func completionNeedsAnUnmeteredUnconstrainedNetworkAndPower() {
        #expect(PlaybackCacheController.permitsCompletion(network: .init(connected: true, expensive: false, constrained: false), lowPower: false))
        for network in [DownloadNetworkState.unknown,
                        .init(connected: true, expensive: true, constrained: false),
                        .init(connected: true, expensive: false, constrained: true)] {
            #expect(!PlaybackCacheController.permitsCompletion(network: network, lowPower: false))
        }
        #expect(!PlaybackCacheController.permitsCompletion(network: .init(connected: true, expensive: false, constrained: false), lowPower: true))
    }

    @Test(arguments: OfflineAudioFormat.allCases)
    func playbackAndCompletionShareBytesAndSurviveOfflineReopen(_ format: OfflineAudioFormat) async throws {
        let fixture = try OfflineAudioFixture(format), store = fixture.store()
        let server = try await AudioFixtureServer(fixture: fixture, delay: 0.002)
        defer { server.stop(); try? FileManager.default.removeItem(at: store.directory) }
        let transfer = AudioTransferCoordinator(resource: fixture.resource(url: server.url), store: store,
                                                cacheContext: .init(policy: .automatic))
        try await transfer.prepare()
        let loader = CachingAssetResourceLoader(transfer: transfer)
        async let completing: Void = transfer.download(forCompletion: true)
        let tracks = try await loader.asset.loadTracks(withMediaType: .audio)
        #expect(!tracks.isEmpty)
        let tail = try await transfer.read(at: fixture.descriptor.byteCount - 100, maximum: 100)
        #expect(tail == fixture.data.suffix(100))
        try await completing
        #expect(await transfer.receivedByteCount == fixture.descriptor.byteCount)
        #expect(try await store.record(id: fixture.descriptor.identity.id)?.retainedBy.isEmpty == true)
        await loader.close()
        server.stop()

        let reopened = OfflineStore(directory: store.directory, minimumFreeBytes: 0)
        let lease = try #require(try await reopened.acquire(accountScope: fixture.descriptor.identity.accountScope,
                                                           trackID: 1, preferredQuality: "exhigh"))
        #expect(try Data(contentsOf: lease.url) == fixture.data)
        let offline = AVURLAsset(url: lease.url)
        #expect(try await offline.load(.isPlayable))
        let track = try #require(try await offline.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: offline)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 600), duration: CMTime(seconds: 1, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        reader.add(output)
        #expect(reader.startReading())
        #expect(output.copyNextSampleBuffer() != nil)
        reader.cancelReading()
        try await reopened.release(lease)
    }

    @Test func stoppingCompletionKeepsPlaybackReadsUsable() async throws {
        let fixture = try OfflineAudioFixture(.flac), store = fixture.store()
        let server = try await AudioFixtureServer(fixture: fixture, delay: 0.02)
        defer { server.stop(); try? FileManager.default.removeItem(at: store.directory) }
        let transfer = AudioTransferCoordinator(resource: fixture.resource(url: server.url), store: store,
                                                cacheContext: .init(policy: .automatic))
        let completing = Task { try await transfer.download(forCompletion: true) }
        for _ in 0..<200 where server.ranges.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        await transfer.setCompletionAllowed(false)
        completing.cancel()
        _ = await completing.result
        let bytes = try await transfer.read(at: 0, maximum: 1_024)
        #expect(bytes == fixture.data.prefix(1_024))
        await transfer.close()
        let requests = server.ranges.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(server.ranges.count == requests)
        let writer = UUID()
        try await store.begin(fixture.descriptor, writer: writer)
        await store.releaseWriter(id: fixture.descriptor.identity.id, writer: writer)
    }

    @Test func evictionPreservesDownloadsPlaybackAndLikesBeforeOrdinarySongs() async throws {
        let fixture = try OfflineAudioFixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-cache-quota-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let block = Int64((fixture.data.count + 4095) / 4096 * 4096)
        let store = OfflineStore(directory: root, minimumFreeBytes: 0, freeSpace: { url in
            let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
            var used: Int64 = 0
            while let file = files?.nextObject() as? URL {
                if file.pathExtension == "mp3" {
                    used += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
                }
            }
            return block * 9 / 2 - used
        })
        var assets: [OfflineAudioDescriptor] = []
        for id in 1...4 {
            let descriptor = descriptor(fixture, id: id)
            let input = root.appendingPathComponent("input")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try fixture.data.write(to: input)
            try await store.importDownload(at: input, descriptor: descriptor)
            assets.append(descriptor)
        }
        try await store.retain(id: assets[2].identity.id, owner: "download")
        let lease = try #require(try await store.acquire(accountScope: "test-account", trackID: 4, preferredQuality: "exhigh"))
        let writer = UUID(), next = descriptor(fixture, id: 5)
        let context = MusicCacheContext(policy: .automatic, likedTracks: ["test-account": [2]])
        try await store.beginCaching(next, writer: writer, context: context)
        #expect(try await store.record(id: assets[0].identity.id) == nil)
        #expect(try await store.record(id: assets[1].identity.id)?.state == .complete)
        #expect(try await store.record(id: assets[2].identity.id)?.retainedBy == ["download"])
        #expect(try await store.record(id: assets[3].identity.id)?.state == .complete)
        await store.releaseWriter(id: next.identity.id, writer: writer)
        try await store.release(lease)
    }

    @Test func impossibleAdmissionAndDisabledPolicyPreserveExistingCache() async throws {
        let fixture = try OfflineAudioFixture(), store = fixture.store()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fixture.data.write(to: input)
        try await store.importDownload(at: input, descriptor: fixture.descriptor)
        let tooLarge = OfflineAudioDescriptor(identity: descriptor(fixture, id: 2).identity, byteCount: 1_500_000_000, duration: 3)
        await #expect(throws: OfflineAudioError.insufficientSpace) {
            try await store.beginCaching(tooLarge, writer: UUID(), context: .init(policy: .gb1))
        }
        await #expect(throws: OfflineAudioError.unavailable) {
            try await store.beginCaching(descriptor(fixture, id: 3), writer: UUID(), context: .init(policy: .disabled))
        }
        _ = try await store.reconcileCache(.init(policy: .disabled))
        #expect(try await store.record(id: fixture.descriptor.identity.id)?.state == .complete)
    }

    private func descriptor(_ fixture: OfflineAudioFixture, id: Int) -> OfflineAudioDescriptor {
        .init(identity: .init(accountScope: "test-account", trackID: id, source: "netease", quality: "exhigh", format: .mp3,
                             contentMD5: fixture.descriptor.identity.contentMD5), byteCount: fixture.descriptor.byteCount, duration: 3)
    }
}
