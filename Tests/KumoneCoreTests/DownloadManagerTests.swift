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
    var beforeRestore: (() async -> Void)?

    init(inbox: URL) {
        self.inbox = inbox
        let stream = AsyncStream<DownloadTransportEvent>.makeStream()
        events = stream.stream
        continuation = stream.continuation
    }
    func restoreTasks() async -> Set<String> { await beforeRestore?(); return existing }
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
    func pause(token: String) async -> Data? {
        guard existing.contains(token) else { return nil }
        cancel(token: token)
        return Data("resume".utf8)
    }
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

    init(resolver: DownloadManager.Resolver? = nil, online: Bool = true, expensive: Bool = false,
         metadataReader: ((Int, String) async -> Track?)? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-download-tests-\(UUID())")
        fixture = try OfflineAudioFixture()
        track = try JSONDecoder().decode(Track.self, from: Data("{\"id\":1,\"name\":\"Offline fixture\",\"dt\":3000}".utf8))
        store = OfflineStore(directory: root.appendingPathComponent("audio"), minimumFreeBytes: 0)
        metadata = OfflineMetadataStore(directory: root.appendingPathComponent("metadata"))
        persistence = DownloadCatalogStore(directory: root.appendingPathComponent("catalog"))
        transport = FakeDownloadTransport(inbox: root.appendingPathComponent("inbox"))
        manager = DownloadManager(store: store, metadata: metadata, persistence: persistence, transport: transport,
                                  accountScope: "test-account", resolver: resolver ?? Self.resolve, metadataFetcher: { _, _ in },
                                  metadataReader: metadataReader)
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

@MainActor
private final class DownloadRestoreGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}

@Suite("Persistent downloads", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct DownloadManagerTests {
    @Test func playbackContextsReuseSavedCollectionsAndCachedMetadata() async throws {
        let h = try DownloadHarness(online: false)
        defer { h.close() }
        var tracks: [Track] = []
        for id in 1...3 {
            var json: [String: Any] = ["id": id, "name": "Track \(id)", "dt": 3000, "no": 4 - id,
                "al": ["id": id == 3 ? 60 : 50, "name": "Album"],
                "ar": [["id": id == 2 ? 200 : 100, "name": "Artist"]]]
            if id == 3 { json["pc"] = [:] as [String: String] }
            let track = try JSONDecoder().decode(Track.self, from: JSONSerialization.data(withJSONObject: json))
            tracks.append(track)
            let resource = try await DownloadHarness.resolve(track: track, quality: "exhigh", scope: "test-account")
            let writer = UUID()
            try await h.store.begin(resource.descriptor, writer: writer)
            try await h.store.write(h.fixture.data, at: 0, id: resource.descriptor.identity.id, writer: writer)
            try await h.store.finalize(id: resource.descriptor.identity.id, writer: writer)
            await h.store.releaseWriter(id: resource.descriptor.identity.id, writer: writer)
            try await h.metadata.save(track: track, scope: "test-account")
        }
        await h.manager.enqueue(tracks: [tracks[1], tracks[0]], owner: "playlist:9", name: "Saved", quality: "exhigh", allowsMetered: false)
        try await waitForDownload { h.manager.jobs.count == 2 && h.manager.jobs.allSatisfy { $0.status == .complete } }
        let played = try #require(try await h.store.acquire(accountScope: "test-account", trackID: 1, preferredQuality: "exhigh"))
        try await h.store.release(played)
        await h.manager.refreshLibrary()
        #expect(h.manager.localTracks(for: .playlist(id: 9, name: "Saved")).map(\.id) == [2, 1])
        #expect(h.manager.localTracks(for: .playlist(id: 99, name: "Liked"), likedTrackIDs: [2]).map(\.id) == [2])
        #expect(h.manager.localTracks(for: .album(id: 50, name: "Album")).map(\.id) == [2, 1])
        #expect(Set(h.manager.localTracks(for: .artist(id: 100, name: "Artist")).map(\.id)) == [1, 3])
        #expect(h.manager.localTracks(for: .cloud).map(\.id) == [3])
        #expect(h.manager.localTracks(for: .recents).map(\.id) == [1])
        #expect(h.transport.started.isEmpty)
        h.manager.activate(accountScope: "other-account")
        #expect(h.manager.localTracks(for: .playlist(id: 9, name: "Saved")).isEmpty)
        #expect(h.manager.localTracks(for: .album(id: 50, name: "Album")).isEmpty)
    }

    @Test func oldLibraryScanCannotMarkANewDownloadMissing() async throws {
        let gate = DownloadRestoreGate()
        var blockNextRead = false
        let h = try DownloadHarness(metadataReader: { id, _ in
            if id == 1, blockNextRead { blockNextRead = false; await gate.wait() }
            return nil
        })
        defer { gate.open(); h.close() }
        await h.enqueue()
        try await waitForDownload { h.transport.started.count == 1 }
        try h.transport.finish(h.transport.started[0])
        try await waitForDownload { h.manager.offlineTracks.count == 1 }
        blockNextRead = true
        let oldScan = Task { await h.manager.refreshLibrary() }
        try await waitForDownload { gate.entered }

        let next = try JSONDecoder().decode(Track.self, from: Data("{\"id\":2,\"name\":\"Just downloaded\",\"dt\":3000}".utf8))
        await h.manager.enqueue(track: next, quality: "exhigh", allowsMetered: false)
        try await waitForDownload { h.transport.started.count == 2 }
        try h.transport.finish(h.transport.started[1])
        try await waitForDownload { h.manager.offlineTracks.count == 2 && h.manager.jobs.allSatisfy { $0.status == .complete } }
        gate.open()
        await oldScan.value
        #expect(h.manager.jobs.allSatisfy { $0.status == .complete })
        #expect(Set(h.manager.downloadedSongs().map(\.id)) == [1, 2])
        #expect(try await h.persistence.load().jobs.allSatisfy { $0.status == .complete })
    }

    @Test func libraryScanStillReportsAnActuallyMissingDownload() async throws {
        let h = try DownloadHarness()
        defer { h.close() }
        await h.enqueue()
        try await waitForDownload { h.transport.started.count == 1 }
        try h.transport.finish(h.transport.started[0])
        try await waitForDownload { h.manager.downloadedSongs().count == 1 }
        let lease = try #require(try await h.store.acquire(accountScope: "test-account", trackID: 1, preferredQuality: "exhigh"))
        try await h.store.release(lease)
        try FileManager.default.removeItem(at: lease.url)
        await h.manager.refreshLibrary()
        #expect(h.manager.jobs.first?.status == .failed)
        #expect(h.manager.downloadedSongs().isEmpty)
    }

    @Test func queuedResumeKeepsItsPlaceAndResumeDataAcrossNetworkChanges() async throws {
        let h = try DownloadHarness()
        defer { h.close() }
        var catalog = DownloadCatalog()
        for id in 1...3 {
            let track = try JSONDecoder().decode(Track.self, from: Data("{\"id\":\(id),\"name\":\"Track \(id)\",\"dt\":3000}".utf8))
            var job = DownloadJob(scope: "test-account", track: track, quality: "exhigh", owner: "single:\(id)", allowsMetered: false)
            job.descriptor = try await DownloadHarness.resolve(track: track, quality: "exhigh", scope: "test-account").descriptor
            if id == 3 { job.status = .paused }
            catalog.jobs.append(job)
        }
        let waiting = catalog.jobs[2]
        try await h.persistence.save(catalog)
        try await h.persistence.saveResumeData(Data("resume".utf8), jobID: waiting.id)
        await h.manager.start()
        try await waitForDownload { h.transport.started.count == 2 }

        await h.manager.resume(waiting.id)
        #expect(h.manager.jobs.first { $0.id == waiting.id }?.status == .queued)
        #expect(h.manager.jobs.first { $0.id == waiting.id }?.token == nil)
        await h.manager.pause(waiting.id)
        #expect(await h.persistence.resumeData(jobID: waiting.id) == Data("resume".utf8))
        await h.manager.resume(waiting.id)
        h.manager.setNetwork(.init(connected: true, expensive: true, constrained: false))
        #expect(h.manager.jobs.first { $0.id == waiting.id }?.status == .waitingNetwork)
        #expect(h.manager.jobs.first { $0.id == waiting.id }?.token == nil)
        h.manager.setNetwork(.init(connected: true, expensive: false, constrained: false))
        try h.transport.finish(h.transport.started[0])
        try await waitForDownload { h.transport.started.count == 3 }
        #expect(h.transport.started[2].resource.descriptor.identity.trackID == 3)
        #expect(h.transport.started[2].resumed)
    }

    @Test func wifiDownloadWaitsAndCanBeOverriddenWithoutDelegateNotification() async throws {
        let h = try DownloadHarness()
        defer { h.close() }
        await h.enqueue()
        try await waitForDownload { h.transport.started.count == 1 }
        let old = h.transport.started[0], id = try #require(h.manager.jobs.first?.id)
        h.manager.setNetwork(.init(connected: true, expensive: true, constrained: false))
        #expect(h.manager.jobs.first?.status == .waitingNetwork)
        await h.manager.resume(id, allowsMetered: true)
        try await waitForDownload { h.transport.started.count == 2 }
        #expect(h.transport.cancelled.contains(old.token))
        #expect(h.transport.started[1].metered)
        try h.transport.finish(h.transport.started[1])
        try await waitForDownload { h.manager.jobs.first?.status == .complete }
    }

    @Test func failedTransferFreesTheSlotAndKeepsResumeData() async throws {
        let h = try DownloadHarness(expensive: true)
        defer { h.close() }
        let next = try JSONDecoder().decode(Track.self, from: Data("{\"id\":2,\"name\":\"Next\",\"dt\":3000}".utf8))
        await h.manager.enqueue(tracks: [h.track, next], owner: "playlist:1", name: "Test", quality: "exhigh", allowsMetered: true)
        try await waitForDownload { h.transport.started.count == 1 }
        let first = h.transport.started[0]
        let id = try #require(h.manager.jobs.first { $0.track.id == 1 }?.id)
        h.transport.continuation.yield(.failed(token: first.token, domain: NSURLErrorDomain,
                                              code: NSURLErrorNetworkConnectionLost, resumeData: Data("resume".utf8)))
        try await waitForDownload { h.transport.started.count == 2 }
        #expect(h.transport.started[1].resource.descriptor.identity.trackID == 2)
        #expect(h.manager.jobs.first { $0.id == id }?.status == .waitingNetwork)
        #expect(h.manager.jobs.first { $0.id == id }?.token == nil)
        await h.manager.resume(id)
        try h.transport.finish(h.transport.started[1])
        try await waitForDownload { h.transport.started.count == 3 }
        #expect(h.transport.started[2].resumed)
        h.transport.continuation.yield(.failed(token: first.token, domain: NSURLErrorDomain,
                                              code: NSURLErrorCancelled, resumeData: nil))
        try h.transport.finish(h.transport.started[2])
        try await waitForDownload { h.manager.jobs.allSatisfy { $0.status == .complete } }
    }

    @Test func restoredWifiTransferCanBeResumedOnCellular() async throws {
        let h = try DownloadHarness(expensive: true)
        defer { h.close() }
        var job = DownloadJob(scope: "test-account", track: h.track, quality: "exhigh", owner: "single:1", allowsMetered: false)
        job.status = .downloading
        job.attempt = UUID()
        job.descriptor = h.fixture.descriptor
        let token = try #require(job.token)
        var catalog = DownloadCatalog()
        catalog.jobs = [job]
        try await h.persistence.save(catalog)
        h.transport.existing.insert(token)
        await h.manager.start()
        #expect(h.manager.jobs.first?.status == .waitingNetwork)
        await h.manager.resume(job.id, allowsMetered: true)
        try await waitForDownload { h.transport.started.count == 1 }
        #expect(h.transport.started[0].metered)
        #expect(h.transport.started[0].token != token && h.transport.cancelled.contains(token))
    }

    @Test func enqueueCannotCrossAnAccountChangeDuringRestore() async throws {
        let h = try DownloadHarness()
        defer { h.close() }
        let gate = DownloadRestoreGate()
        h.transport.beforeRestore = { await gate.wait() }
        let creation = Task {
            await h.manager.enqueue(tracks: [h.track], owner: "playlist:1", name: "Saved playlist",
                                    quality: "exhigh", allowsMetered: false)
        }
        try await waitForDownload { gate.entered }
        h.manager.activate(accountScope: "other-account")
        gate.open()
        #expect(await creation.value == false)
        let saved = try await h.persistence.load()
        #expect(saved.collections.isEmpty && saved.jobs.isEmpty && h.transport.started.isEmpty)
    }

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
