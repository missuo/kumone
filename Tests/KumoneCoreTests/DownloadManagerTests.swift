import Foundation
import Testing
@testable import KumoneCore

@MainActor
private final class FakeDownloadTransport: DownloadTransport {
    struct Started { let resource: OfflineAudioResource; let token: String; let metered: Bool; let resumed: Bool }
    let inbox: URL
    let events: AsyncStream<DownloadTransportEvent>
    let continuation: AsyncStream<DownloadTransportEvent>.Continuation
    var started: [Started] = []
    var cancelled: [String] = []
    var existing: Set<String> = []

    init(inbox: URL) {
        self.inbox = inbox
        let stream = AsyncStream<DownloadTransportEvent>.makeStream()
        events = stream.stream
        continuation = stream.continuation
    }
    func restoreTasks() async -> Set<String> { existing }
    func completedDownloads() throws -> [CompletedDownload] {
        guard FileManager.default.fileExists(atPath: inbox.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(CompletedDownload.self, from: Data(contentsOf: $0)) }
    }
    func start(resource: OfflineAudioResource, token: String, allowsMetered: Bool, resumeData: Data?) {
        started.append(.init(resource: resource, token: token, metered: allowsMetered, resumed: resumeData != nil))
        existing.insert(token)
    }
    func pause(token: String) async -> Data? { cancel(token: token); return Data("resume".utf8) }
    func cancel(token: String) { cancelled.append(token); existing.remove(token) }
    func acknowledge(_ receipt: CompletedDownload) {
        existing.remove(receipt.token)
        try? FileManager.default.removeItem(at: inbox.appendingPathComponent(receipt.fileName))
        try? FileManager.default.removeItem(at: inbox.appendingPathComponent("\(receipt.token).json"))
    }
    func finish(_ item: Started, corrupt: Bool = false, deliver: Bool = true, statusCode: Int = 200) throws {
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        var data = try OfflineAudioFixture(item.resource.descriptor.identity.format).data
        if corrupt { data[100] ^= 0xff }
        let receipt = CompletedDownload(token: item.token, statusCode: statusCode, mimeType: "application/octet-stream", fileName: "\(item.token).audio")
        try data.write(to: inbox.appendingPathComponent(receipt.fileName))
        try JSONEncoder().encode(receipt).write(to: inbox.appendingPathComponent("\(receipt.token).json"))
        existing.remove(item.token)
        if deliver { continuation.yield(.finished(receipt)) }
    }
}

@MainActor
private final class DownloadHarness {
    let root: URL
    let track: Track
    let fixture: OfflineAudioFixture
    let store: OfflineStore
    let metadata: OfflineMetadataStore
    let persistence: DownloadCatalogStore
    let transport: FakeDownloadTransport
    let manager: DownloadManager

    init(resolver: DownloadManager.Resolver? = nil, online: Bool = true, expensive: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-download-tests-\(UUID())")
        fixture = try OfflineAudioFixture()
        track = try JSONDecoder().decode(Track.self, from: Data("{\"id\":1,\"name\":\"Offline fixture\",\"dt\":3000}".utf8))
        store = OfflineStore(directory: root.appendingPathComponent("audio"), minimumFreeBytes: 0)
        metadata = OfflineMetadataStore(directory: root.appendingPathComponent("metadata"))
        persistence = DownloadCatalogStore(directory: root.appendingPathComponent("catalog"))
        transport = FakeDownloadTransport(inbox: root.appendingPathComponent("inbox"))
        manager = DownloadManager(store: store, metadata: metadata, persistence: persistence, transport: transport,
                                  accountScope: "test-account", resolver: resolver ?? Self.resolve, metadataFetcher: { _, _ in })
        manager.setNetwork(.init(connected: online, expensive: expensive, constrained: false))
    }

    static func resolve(track: Track, quality: String, scope: String) async throws -> OfflineAudioResource {
        let fixture = try OfflineAudioFixture(quality == "lossless" ? .flac : .mp3, scope: scope)
        let original = fixture.descriptor.identity
        let descriptor = OfflineAudioDescriptor(identity: .init(accountScope: scope, trackID: track.id, source: "netease",
            quality: quality, format: original.format, contentMD5: original.contentMD5), byteCount: fixture.descriptor.byteCount, duration: 3)
        return .init(descriptor: descriptor, url: URL(string: "https://example.test/audio")!)
    }

    func enqueue(owner: String = "single:1", quality: String = "exhigh") async {
        await manager.enqueue(tracks: [track], owner: owner, name: owner.hasPrefix("playlist:") ? owner : nil,
                              quality: quality, allowsMetered: false)
    }
    func close() { manager.shutdown(); transport.continuation.finish(); try? FileManager.default.removeItem(at: root) }
}

@MainActor
private func waitForDownload(_ condition: () -> Bool) async throws {
    for _ in 0..<500 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    struct Timeout: Error {}
    Issue.record("Download state did not settle")
    throw Timeout()
}

@Suite("Persistent downloads", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct DownloadManagerTests {
    @Test func downloadingCurrentStreamSharesItsTransfer() async throws {
        let h = try DownloadHarness()
        defer { h.close() }
        let server = try await AudioFixtureServer(fixture: h.fixture, delay: 0.01)
        defer { server.stop() }
        let resource = h.fixture.resource(url: server.url)
        let source = AudioTransferCoordinator(resource: resource, store: h.store, cacheContext: .init(policy: .automatic))
        _ = try await source.read(at: 0, maximum: 1_024)
        let manager = DownloadManager(store: h.store, metadata: h.metadata, persistence: h.persistence,
            transport: h.transport, accountScope: "test-account", resolver: { _, _, _ in resource }, metadataFetcher: { _, _ in },
            cacheCompletion: { requested, owner, allowsMetered in
                #expect(requested.descriptor == resource.descriptor)
                try await source.download(allowsMetered: allowsMetered)
                try await h.store.retain(id: resource.descriptor.identity.id, owner: owner)
                return resource.descriptor
            })
        defer { manager.shutdown() }
        manager.setNetwork(.init(connected: true, expensive: false, constrained: false))
        await manager.enqueue(tracks: [h.track], owner: "single:1", name: nil, quality: "exhigh", allowsMetered: false)
        try await waitForDownload { manager.jobs.first?.status == .complete }
        #expect(h.transport.started.isEmpty)
        #expect(await source.receivedByteCount == h.fixture.descriptor.byteCount)
        #expect(try await h.store.record(id: resource.descriptor.identity.id)?.retainedBy.isEmpty == false)
        await source.close()
    }

    @Test func promotesCachedAudioWithoutNetwork() async throws {
        let h = try DownloadHarness(online: false)
        defer { h.close() }
        let writer = UUID(), descriptor = h.fixture.descriptor
        try await h.store.begin(descriptor, writer: writer)
        try await h.store.write(h.fixture.data, at: 0, id: descriptor.identity.id, writer: writer)
        try await h.store.finalize(id: descriptor.identity.id, writer: writer)
        await h.store.releaseWriter(id: descriptor.identity.id, writer: writer)
        await h.enqueue()
        try await waitForDownload { h.manager.jobs.first?.status == .complete && !h.manager.offlineTracks.isEmpty }
        #expect(h.transport.started.isEmpty)
        #expect(h.manager.offlineTracks.first?.isDownloaded == true)
        #expect(h.manager.downloadedSongs().map(\.id) == [h.track.id])
    }

    @Test func sharesOneFileAcrossTwoCollections() async throws {
        let h = try DownloadHarness()
        defer { h.close() }
        await h.enqueue(owner: "playlist:1")
        await h.enqueue(owner: "playlist:2")
        try await waitForDownload { h.transport.started.count == 1 }
        try h.transport.finish(h.transport.started[0])
        try await waitForDownload { h.manager.jobs.first?.status == .complete && h.manager.offlineTracks.count == 1 }
        await h.manager.removeCollection("playlist:1")
        #expect(h.manager.jobs.first?.owners == ["playlist:2"])
        #expect(h.manager.offlineTracks.first?.isDownloaded == true)
        await h.manager.removeCollection("playlist:2")
        #expect(h.manager.offlineTracks.first?.isDownloaded == false)
        #expect(h.manager.offlineTracks.count == 1)
        #expect(h.manager.downloadedTracks.isEmpty)
        #expect(h.manager.downloadedSongs().isEmpty)
    }

    @Test func waitsForNetworkAndPreservesUserPause() async throws {
        let h = try DownloadHarness(expensive: true)
        defer { h.close() }
        await h.enqueue()
        try await waitForDownload { h.manager.jobs.first?.status == .waitingNetwork }
        #expect(h.transport.started.isEmpty)
        let id = try #require(h.manager.jobs.first?.id)
        await h.manager.resume(id, allowsMetered: true)
        try await waitForDownload { h.transport.started.count == 1 }
        #expect(h.transport.started[0].metered)
        await h.manager.pause(id)
        h.manager.setNetwork(.init(connected: false, expensive: false, constrained: false))
        h.manager.setNetwork(.init(connected: true, expensive: false, constrained: false))
        #expect(h.manager.jobs.first?.status == .paused)
        #expect(h.transport.started.count == 1)
        await h.manager.resume(id)
        try await waitForDownload { h.transport.started.count == 2 }
        #expect(h.transport.started[1].resumed)
        try h.transport.finish(h.transport.started[1], statusCode: 206)
        try await waitForDownload { h.manager.jobs.first?.status == .complete }
    }

    @Test func lateCompletionCannotCrossAccounts() async throws {
        let h = try DownloadHarness()
        defer { h.close() }
        await h.enqueue()
        try await waitForDownload { !h.transport.started.isEmpty }
        let old = h.transport.started[0]
        h.manager.activate(accountScope: "different-account")
        try h.transport.finish(old)
        try await Task.sleep(for: .milliseconds(40))
        #expect(h.manager.jobs.isEmpty)
        #expect(h.manager.offlineTracks.isEmpty)
        #expect(h.transport.cancelled.contains(old.token))
        #expect(try await h.store.availableRecords(accountScope: "different-account").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: h.transport.inbox.appendingPathComponent("\(old.token).audio").path))
    }

    @Test func cancelledResolutionDoesNotStartTransfer() async throws {
        final class Gate { var continuation: CheckedContinuation<Void, Never>? }
        let gate = Gate()
        let h = try DownloadHarness(resolver: { track, quality, scope in
            await withCheckedContinuation { gate.continuation = $0 }
            return try await DownloadHarness.resolve(track: track, quality: quality, scope: scope)
        })
        defer { h.close() }
        await h.enqueue()
        try await waitForDownload { gate.continuation != nil }
        let id = try #require(h.manager.jobs.first?.id)
        await h.manager.cancel(id)
        gate.continuation?.resume()
        try await Task.sleep(for: .milliseconds(40))
        #expect(h.transport.started.isEmpty)
        #expect(h.manager.jobs.first?.status == .cancelled)
    }

    @Test func recoversFinishedFileWithoutStartingAnotherDownload() async throws {
        let h = try DownloadHarness()
        defer { h.close() }
        await h.enqueue()
        try await waitForDownload { !h.transport.started.isEmpty }
        h.manager.shutdown()
        try h.transport.finish(h.transport.started[0], deliver: false)
        let transport = FakeDownloadTransport(inbox: h.transport.inbox)
        let restored = DownloadManager(store: h.store, metadata: h.metadata,
            persistence: DownloadCatalogStore(directory: h.persistence.directory), transport: transport,
            accountScope: "test-account", resolver: DownloadHarness.resolve, metadataFetcher: { _, _ in })
        defer { restored.shutdown(); transport.continuation.finish() }
        await restored.start()
        #expect(restored.jobs.first?.status == .complete)
        #expect(restored.offlineTracks.count == 1)
        #expect(transport.started.isEmpty)
    }

    @Test func failedUpgradeKeepsOriginalDownload() async throws {
        let h = try DownloadHarness()
        defer { h.close() }
        await h.enqueue()
        try await waitForDownload { h.transport.started.count == 1 }
        try h.transport.finish(h.transport.started[0])
        try await waitForDownload { h.manager.jobs.first?.status == .complete && h.manager.offlineTracks.count == 1 }
        await h.enqueue(quality: "lossless")
        try await waitForDownload { h.transport.started.count == 2 }
        try h.transport.finish(h.transport.started[1], corrupt: true)
        try await waitForDownload { h.manager.jobs.contains { $0.quality == "lossless" && $0.status == .failed } }
        #expect(h.manager.jobs.contains { $0.quality == "exhigh" && $0.status == .complete && $0.owners.contains("single:1") })
        #expect(h.manager.offlineTracks.first?.isDownloaded == true)
    }

    @Test func successfulUpgradeMovesRetentionAfterValidation() async throws {
        let h = try DownloadHarness()
        defer { h.close() }
        await h.enqueue()
        try await waitForDownload { h.transport.started.count == 1 }
        try h.transport.finish(h.transport.started[0])
        try await waitForDownload { h.manager.jobs.first?.status == .complete && !h.manager.offlineTracks.isEmpty }
        await h.enqueue(quality: "lossless")
        try await waitForDownload { h.transport.started.count == 2 }
        try h.transport.finish(h.transport.started[1])
        try await waitForDownload { h.manager.jobs.contains { $0.quality == "exhigh" && $0.owners.isEmpty } }
        let saved = try await h.persistence.load()
        #expect(saved.jobs.first { $0.quality == "exhigh" }?.owners.isEmpty == true)
        #expect(saved.jobs.first { $0.quality == "lossless" }?.status == .complete)
    }

    @Test func backgroundCompletionRunsAfterAudioImport() async throws {
        let h = try DownloadHarness()
        defer { h.close() }
        await h.enqueue()
        try await waitForDownload { !h.transport.started.isEmpty }
        var completed = false
        h.manager.registerBackgroundCompletion { completed = true }
        try h.transport.finish(h.transport.started[0])
        h.transport.continuation.yield(.backgroundEventsFinished)
        try await waitForDownload { completed }
        #expect(h.manager.jobs.first?.status == .complete)
        #expect(try await h.persistence.load().jobs.first?.status == .complete)
    }

    @Test func realDownloadTaskImportsCompleteAudio() async throws {
        let h = try DownloadHarness()
        defer { h.close() }
        let server = try await AudioFixtureServer(fixture: h.fixture, mode: .sequential)
        defer { server.stop() }
        let transport = BackgroundDownloadTransport(inbox: h.root.appendingPathComponent("real-inbox"), backgroundIdentifier: nil)
        let manager = DownloadManager(store: h.store, metadata: h.metadata, persistence: h.persistence, transport: transport,
            accountScope: "test-account", resolver: { _, _, _ in h.fixture.resource(url: server.url) }, metadataFetcher: { _, _ in })
        defer { manager.shutdown(); transport.shutdown() }
        manager.setNetwork(.init(connected: true, expensive: false, constrained: false))
        await manager.enqueue(track: h.track, quality: "exhigh", allowsMetered: false)
        try await waitForDownload { manager.jobs.first?.status == .complete && !manager.offlineTracks.isEmpty }
        #expect(manager.offlineTracks.first?.byteCount == h.fixture.descriptor.byteCount)
    }

    @Test func restartKeepsPausedTasksPaused() async throws {
        let h = try DownloadHarness()
        defer { h.close() }
        await h.enqueue()
        try await waitForDownload { !h.transport.started.isEmpty }
        await h.manager.pause(try #require(h.manager.jobs.first?.id))
        h.manager.shutdown()
        let transport = FakeDownloadTransport(inbox: h.transport.inbox)
        let restored = DownloadManager(store: h.store, metadata: h.metadata,
            persistence: DownloadCatalogStore(directory: h.persistence.directory), transport: transport,
            accountScope: "test-account", resolver: DownloadHarness.resolve, metadataFetcher: { _, _ in })
        defer { restored.shutdown(); transport.continuation.finish() }
        restored.setNetwork(.init(connected: true, expensive: false, constrained: false))
        await restored.start()
        #expect(restored.jobs.first?.status == .paused)
        #expect(transport.started.isEmpty)
    }

    @Test func removingDownloadDeletesAudioAndLeavesOtherCachePrivate() async throws {
        let h = try DownloadHarness(online: false)
        defer { h.close() }
        let cachedTrack = try JSONDecoder().decode(Track.self, from: Data("{\"id\":42,\"name\":\"Private cache\",\"dt\":3000}".utf8))
        let cachedResource = try await DownloadHarness.resolve(track: cachedTrack, quality: "exhigh", scope: "test-account")
        for descriptor in [h.fixture.descriptor, cachedResource.descriptor] {
            let writer = UUID()
            try await h.store.begin(descriptor, writer: writer)
            try await h.store.write(h.fixture.data, at: 0, id: descriptor.identity.id, writer: writer)
            try await h.store.finalize(id: descriptor.identity.id, writer: writer)
            await h.store.releaseWriter(id: descriptor.identity.id, writer: writer)
        }
        try await h.metadata.save(track: cachedTrack, scope: "test-account")
        await h.enqueue(owner: "playlist:1")
        try await waitForDownload { h.manager.downloadedSongs().count == 1 && h.manager.offlineTracks.count == 2 }
        #expect(h.manager.downloadedSongs(in: "playlist:1").map(\.id) == [h.track.id])
        #expect(h.manager.downloadedSongs(in: "missing").isEmpty)
        #expect(h.manager.pendingJobs.isEmpty)
        await h.manager.deleteLocalAudio(trackID: h.track.id)
        #expect(h.manager.downloadedSongs().isEmpty)
        #expect(try await h.store.record(id: h.fixture.descriptor.identity.id) == nil)
        #expect(try await h.store.record(id: cachedResource.descriptor.identity.id)?.state == .complete)
        #expect(h.transport.started.isEmpty)
    }

}
