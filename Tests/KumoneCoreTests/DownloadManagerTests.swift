import Combine
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
    var restoredReceivedBytes: [String: Int64] = [:]
    var beforeRestore: (() async -> Void)?

    init(inbox: URL) {
        self.inbox = inbox
        let stream = AsyncStream<DownloadTransportEvent>.makeStream()
        events = stream.stream
        continuation = stream.continuation
    }
    func restoreTasks() async -> [String: Int64] {
        await beforeRestore?()
        return Dictionary(uniqueKeysWithValues: existing.map { ($0, restoredReceivedBytes[$0, default: 0]) })
    }
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
         metadataReader: ((Int, String) async -> Track?)? = nil, freeBytes: Int64? = nil,
         metadataFetcher: @escaping DownloadManager.MetadataFetcher = { _, _ in },
         prepareResource: @escaping (OfflineAudioResource) async -> Void = { _ in },
         retrySleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-download-tests-\(UUID())")
        fixture = try OfflineAudioFixture()
        track = try JSONDecoder().decode(Track.self, from: Data("{\"id\":1,\"name\":\"Offline fixture\",\"dt\":3000}".utf8))
        if let freeBytes {
            store = OfflineStore(directory: root.appendingPathComponent("audio"), minimumFreeBytes: 0, freeSpace: { _ in freeBytes })
        } else {
            store = OfflineStore(directory: root.appendingPathComponent("audio"), minimumFreeBytes: 0)
        }
        metadata = OfflineMetadataStore(directory: root.appendingPathComponent("metadata"))
        persistence = DownloadCatalogStore(directory: root.appendingPathComponent("catalog"))
        transport = FakeDownloadTransport(inbox: root.appendingPathComponent("inbox"))
        manager = DownloadManager(store: store, metadata: metadata, persistence: persistence, transport: transport,
                                  accountScope: "test-account", resolver: resolver ?? Self.resolve, metadataFetcher: metadataFetcher,
                                  metadataReader: metadataReader, prepareResource: prepareResource, retrySleep: retrySleep)
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

@MainActor
private final class DownloadRetryClock {
    var delays: [Duration] = []
    var pending: [CheckedContinuation<Void, Never>] = []
    func sleep(_ delay: Duration) async {
        delays.append(delay)
        await withCheckedContinuation { pending.append($0) }
    }
    func advance() { if !pending.isEmpty { pending.removeFirst().resume() } }
    func finish() { while !pending.isEmpty { advance() } }
}

@Suite("Persistent downloads", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct DownloadManagerTests {
    @Test func activatingAnAccountPublishesAndPersistsReconciledDownloads() async throws {
        let h = try DownloadHarness()
        defer { h.close() }
        var job = DownloadJob(scope: "test-account", track: h.track, quality: "exhigh", owner: "single:1", allowsMetered: true)
        job.descriptor = h.fixture.descriptor
        job.status = .waitingAccount
        job.metadataPending = false
        let input = h.root.appendingPathComponent("completed.mp3")
        try FileManager.default.createDirectory(at: h.root, withIntermediateDirectories: true)
        try h.fixture.data.write(to: input)
        try await h.store.importDownload(at: input, descriptor: h.fixture.descriptor)
        try await h.persistence.save(DownloadCatalog(jobs: [job]))
        h.manager.activate(accountScope: "another")
        await h.manager.start()
        h.manager.activate(accountScope: "test-account")
        h.manager.setNetwork(h.manager.network)
        try await waitForDownload { h.manager.jobs.first?.status == .complete && h.manager.downloadedTracks.count == 1 }
        #expect(try await h.persistence.load().jobs.first?.status == .complete)
        #expect(h.transport.started.isEmpty)
    }

    @Test func cancelledMetadataWorkerCannotEraseItsReplacement() async throws {
        let first = DownloadRestoreGate(), replacement = DownloadRestoreGate()
        var calls = 0, firstReturned = false
        let h = try DownloadHarness(metadataFetcher: { _, _ in
            calls += 1
            if calls == 1 { await first.wait(); firstReturned = true }
            else if calls == 2 { await replacement.wait() }
        })
        defer { first.open(); replacement.open(); h.close() }
        await h.enqueue()
        try await waitForDownload { first.entered && h.transport.started.count == 1 }
        try h.transport.finish(h.transport.started[0])
        try await waitForDownload { h.manager.downloadedTracks.count == 1 }
        h.manager.activate(accountScope: "another")
        h.manager.activate(accountScope: "test-account")
        try await waitForDownload { replacement.entered }
        first.open()
        try await waitForDownload { firstReturned }
        try await Task.sleep(for: .milliseconds(30))
        h.manager.setNetwork(h.manager.network)
        try await Task.sleep(for: .milliseconds(30))
        #expect(calls == 2)
        replacement.open()
    }

    @Test(arguments: [false, true])
    func automaticCacheCompletionRefreshesOfflineAvailability(forCompletion: Bool) async throws {
        let h = try DownloadHarness(online: false)
        let server = try await AudioFixtureServer(fixture: h.fixture)
        defer { server.stop(); h.close() }
        await h.manager.start()
        try await h.metadata.save(track: h.track, scope: "test-account")
        let source = AudioTransferCoordinator(resource: h.fixture.resource(url: server.url), store: h.store,
                                              cacheContext: .init(policy: .automatic))
        try await source.prepare()
        #expect(h.manager.offlineTracksByID[1] == nil)
        try await source.download(forCompletion: forCompletion)
        try await waitForDownload { h.manager.offlineTracksByID[1] != nil }
        #expect(!h.manager.network.connected)
        #expect(h.manager.offlineTracksByID[1]?.isDownloaded == false)
        #expect(!h.manager.isDownloaded(trackID: 1) && h.manager.jobs.isEmpty)
        // Account-scoped events must not put the old account's cache in a new list.
        h.manager.activate(accountScope: "other-account")
        #expect(h.manager.offlineTracksByID.isEmpty)
        await source.close()
    }

    @Test func prefetchedAudioIsAvailableBeforeOptionalMetadataFinishes() async throws {
        let h = try DownloadHarness(online: false), gate = DownloadRestoreGate()
        let server = try await AudioFixtureServer(fixture: h.fixture)
        defer { gate.open(); server.stop(); h.close() }
        await h.manager.start()
        let prefetcher = QueuePrefetcher(store: h.store, metadata: h.metadata,
            resolver: { _, _, _ in h.fixture.resource(url: server.url) },
            metadataFetcher: { _, _ in await gate.wait() })
        prefetcher.update(.init(scope: "test-account", currentTrackID: 2, tracks: [h.track], quality: "exhigh",
                                context: .init(policy: .automatic), pendingDownloadTrackIDs: []))
        try await waitForDownload { gate.entered && h.manager.offlineTracksByID[1] != nil }
        #expect(h.manager.offlineTracksByID[1]?.track.id == h.track.id)
        #expect(h.manager.downloadedTracks.isEmpty)
        gate.open()
        await prefetcher.cancel().value
    }

    @Test func removingAnEarlierJobDuringPreparationKeepsTheRemainingJobIdentity() async throws {
        let gate = DownloadRestoreGate()
        let h = try DownloadHarness(prepareResource: { resource in
            if resource.descriptor.identity.trackID == 2 { await gate.wait() }
        })
        defer { gate.open(); h.close() }
        let tracks = try (1...3).map { id in
            try JSONDecoder().decode(Track.self, from: Data("{\"id\":\(id),\"name\":\"Track\"}".utf8))
        }
        await h.manager.enqueue(tracks: tracks, owner: "playlist:1", name: "Fixture", quality: "exhigh", allowsMetered: true)
        try await waitForDownload { gate.entered && h.transport.started.count == 1 }
        let firstID = try #require(h.manager.jobs.first { $0.track.id == 1 }?.id)
        await h.manager.cancel(firstID)
        #expect(h.manager.jobs.count == 2)
        gate.open()
        try await waitForDownload { h.transport.started.count == 3 }
        for transfer in h.transport.started.dropFirst() { try h.transport.finish(transfer) }
        try await waitForDownload { h.manager.jobs.allSatisfy { $0.status == .complete } && h.manager.downloadedTracks.count == 2 }
        #expect(Set(h.manager.downloadedTracks.map(\.id)) == [2, 3])
        #expect(h.manager.jobs.allSatisfy { $0.track.id == $0.descriptor?.identity.trackID })
    }

    @Test func restoringCatalogDiscardsCancelledJobsAndTheirResumeFiles() async throws {
        let h = try DownloadHarness(online: false)
        defer { h.close() }
        var catalog = DownloadCatalog()
        for _ in 0..<100 {
            var job = DownloadJob(scope: "test-account", track: h.track, quality: "exhigh", owner: "single:1", allowsMetered: true)
            job.owners = []
            job.status = .cancelled
            catalog.jobs.append(job)
            try await h.persistence.saveResumeData(Data("resume".utf8), jobID: job.id)
        }
        try await h.persistence.save(catalog)
        await h.manager.start()
        #expect(h.manager.jobs.isEmpty)
        #expect(try await h.persistence.load().jobs.isEmpty)
        for job in catalog.jobs { #expect(await h.persistence.resumeData(jobID: job.id) == nil) }
    }

    @Test func catalogReadFailureCanBeRetriedWithoutMisreportingLogin() async throws {
        let h = try DownloadHarness()
        defer { h.close() }
        try FileManager.default.createDirectory(at: h.persistence.directory, withIntermediateDirectories: true)
        let file = h.persistence.directory.appendingPathComponent("downloads.json")
        try Data("invalid".utf8).write(to: file)
        await h.enqueue()
        #expect(!h.manager.isReady && h.manager.errorMessage == String(localized: "无法读取下载记录，请重试"))
        // Events must still drain while protected/unreadable catalog data is unavailable.
        var finished = false
        h.manager.registerBackgroundCompletion { finished = true }
        h.transport.continuation.yield(.backgroundEventsFinished)
        try await waitForDownload { finished }
        try JSONEncoder().encode(DownloadCatalog()).write(to: file, options: .atomic)
        await h.enqueue()
        try await waitForDownload { h.transport.started.count == 1 }
        #expect(h.manager.isReady && h.manager.errorMessage == nil)
        try h.transport.finish(h.transport.started[0])
        try await waitForDownload { h.manager.isDownloaded(trackID: 1) }
        #expect(h.manager.jobsByTrackID[1]?.status == .complete)
        #expect(h.manager.pendingJobsByTrackID[1] == nil)
        await h.manager.deleteLocalAudio(trackID: 1)
        #expect(!h.manager.isDownloaded(trackID: 1) && h.manager.offlineTracksByID[1] == nil)
        h.manager.activate(accountScope: "another")
        #expect(h.manager.jobsByTrackID.isEmpty && h.manager.downloadedTrackIDs.isEmpty)
    }

    @Test func failedRestorationRetainsCompletedReceiptsUntilRetry() async throws {
        let h = try DownloadHarness()
        defer { h.close() }
        let resource = try await DownloadHarness.resolve(track: h.track, quality: "exhigh", scope: "test-account")
        var job = DownloadJob(scope: "test-account", track: h.track, quality: "exhigh", owner: "single:1", allowsMetered: true)
        job.attempt = UUID()
        job.descriptor = resource.descriptor
        job.status = .downloading
        let token = try #require(job.token)
        try FileManager.default.createDirectory(at: h.persistence.directory, withIntermediateDirectories: true)
        let file = h.persistence.directory.appendingPathComponent("downloads.json")
        try Data("unreadable catalog".utf8).write(to: file)
        await h.manager.start()
        #expect(!h.manager.isReady)
        h.transport.start(resource: resource, token: token, allowsMetered: true, resumeData: nil)
        try h.transport.finish(h.transport.started[0])
        var drained = false
        h.manager.registerBackgroundCompletion { drained = true }
        h.transport.continuation.yield(.backgroundEventsFinished)
        try await waitForDownload { drained }
        #expect(try h.transport.completedDownloads().count == 1)
        try JSONEncoder().encode(DownloadCatalog(jobs: [job])).write(to: file, options: .atomic)
        await h.manager.start()
        #expect(h.manager.isDownloaded(trackID: 1))
        #expect(try h.transport.completedDownloads().isEmpty)
        #expect(h.transport.started.count == 1)
    }

    @Test func cellularApprovalSurvivesDisconnectionAndRestartsTheQueue() async throws {
        let h = try DownloadHarness(expensive: true)
        defer { h.close() }
        let second = try JSONDecoder().decode(Track.self, from: Data("{\"id\":2,\"name\":\"Second\",\"dt\":3000}".utf8))
        await h.manager.enqueue(tracks: [h.track, second], owner: "playlist:1", name: "Saved", quality: "exhigh", allowsMetered: false)
        try await waitForDownload { h.manager.jobs.allSatisfy { $0.status == .waitingNetwork } }
        await h.manager.resumeAll(allowsMetered: true)
        try await waitForDownload { h.transport.started.count == 1 }
        let first = h.transport.started[0]
        h.manager.setNetwork(.init(connected: false, expensive: true, constrained: false))
        h.transport.continuation.yield(.failed(token: first.token, domain: NSURLErrorDomain,
            code: NSURLErrorNetworkConnectionLost, resumeData: Data("resume".utf8)))
        try await waitForDownload { h.manager.jobs.first { $0.track.id == 1 }?.token == nil }
        h.manager.setNetwork(.init(connected: true, expensive: true, constrained: false))
        try await waitForDownload { h.transport.started.count == 2 }
        #expect(h.transport.started[1].metered && h.transport.started[1].resumed)
        try h.transport.finish(h.transport.started[1])
        try await waitForDownload { h.transport.started.count == 3 }
        #expect(h.transport.started[2].metered)
        try h.transport.finish(h.transport.started[2])
        try await waitForDownload { h.manager.jobs.allSatisfy { $0.status == .complete } }
        #expect(try await h.persistence.load().jobs.allSatisfy { $0.allowsMetered })
    }

    @Test func backgroundPreparationExpirationRecoversOnForeground() async throws {
        let gate = DownloadRestoreGate()
        var preparations = 0
        let h = try DownloadHarness(prepareResource: { _ in
            preparations += 1
            if preparations == 1 { await gate.wait() }
        })
        defer { gate.open(); h.close() }
        await h.enqueue()
        try await waitForDownload { gate.entered }
        let job = try #require(h.manager.jobs.first), attempt = try #require(job.attempt)
        h.manager.preparationExpired(jobID: job.id, attempt: attempt)
        #expect(h.manager.jobs.first?.status == .queued && h.manager.jobs.first?.attempt == nil)
        h.manager.setNetwork(h.manager.network)
        #expect(h.transport.started.isEmpty)
        h.manager.resumeAfterForeground()
        try await waitForDownload { h.transport.started.count == 1 }
        gate.open()
        try h.transport.finish(h.transport.started[0])
        try await waitForDownload { h.manager.jobs.first?.status == .complete }
        #expect(preparations == 2)
    }

    @Test func preparationExpirationCannotUndoACompletedCachePromotion() async throws {
        let gate = DownloadRestoreGate()
        var blockRead = false
        let h = try DownloadHarness(metadataReader: { _, _ in
            if blockRead { await gate.wait() }
            return nil
        })
        defer { gate.open(); h.close() }
        await h.manager.start()
        let input = h.root.appendingPathComponent("completed.mp3")
        try h.fixture.data.write(to: input)
        try await h.store.importDownload(at: input, descriptor: h.fixture.descriptor)
        blockRead = true
        await h.enqueue()
        try await waitForDownload { gate.entered }
        let job = try #require(h.manager.jobs.first), attempt = try #require(job.attempt)
        #expect(job.status == .complete)
        h.manager.preparationExpired(jobID: job.id, attempt: attempt)
        #expect(h.manager.jobs.first?.status == .complete)
        gate.open()
        try await waitForDownload { h.manager.downloadedTracks.count == 1 }
        #expect(h.transport.started.isEmpty && h.manager.pendingJobs.isEmpty)
    }

    @Test func redownloadingAfterRemovalStartsWithFreshProgress() async throws {
        let gate = DownloadRestoreGate()
        var resolutions = 0
        let h = try DownloadHarness(resolver: { track, quality, scope in
            resolutions += 1
            if resolutions == 2 { await gate.wait() }
            return try await DownloadHarness.resolve(track: track, quality: quality, scope: scope)
        })
        defer { gate.open(); h.close() }
        await h.enqueue()
        try await waitForDownload { h.transport.started.count == 1 }
        let first = h.transport.started[0]
        try h.transport.finish(first)
        try await waitForDownload { h.manager.downloadedTracks.count == 1 }
        let id = try #require(h.manager.jobs.first?.id)
        await h.manager.deleteLocalAudio(trackID: h.track.id)
        var startupProgress: [Double?] = []
        let observer = h.manager.$jobs.dropFirst().sink { jobs in
            if let job = jobs.first, [.queued, .resolving].contains(job.status) {
                startupProgress.append(h.manager.progress.fraction(for: job))
            }
        }
        defer { observer.cancel() }
        await h.manager.resume(id)
        #expect(h.manager.jobs.isEmpty)
        await h.enqueue()
        #expect(h.manager.jobs.first?.id != id)
        try await waitForDownload { gate.entered }
        #expect(!startupProgress.isEmpty && startupProgress.allSatisfy { $0 == nil })
        #expect(h.manager.jobs.first?.receivedBytes == 0)
        #expect(h.manager.jobs.first?.expectedBytes == 0)
        gate.open()
        try await waitForDownload { h.transport.started.count == 2 }
        #expect(!h.transport.started[1].resumed)
        #expect(h.manager.progress.fraction(for: h.manager.jobs[0]) == 0)
        h.transport.continuation.yield(.progress(token: first.token, received: 100, expected: 100))
        try await Task.sleep(for: .milliseconds(20))
        #expect(h.manager.progress.fraction(for: h.manager.jobs[0]) == 0)
        let total = h.fixture.descriptor.byteCount
        h.transport.continuation.yield(.progress(token: h.transport.started[1].token, received: total / 4, expected: total))
        try await waitForDownload { h.manager.progress.fraction(for: h.manager.jobs[0]) == 0.25 }
    }

    @Test func pausingAndResumingStillKeepsValidPartialProgress() async throws {
        let h = try DownloadHarness()
        defer { h.close() }
        await h.manager.enqueue(track: h.track, quality: "exhigh", allowsMetered: true)
        try await waitForDownload { h.transport.started.count == 1 }
        let id = try #require(h.manager.jobs.first?.id), total = h.fixture.descriptor.byteCount
        h.transport.continuation.yield(.progress(token: h.transport.started[0].token, received: total * 3 / 4, expected: total))
        try await waitForDownload { h.manager.progress.fraction(for: h.manager.jobs[0]) == 0.75 }
        await h.manager.pause(id)
        await h.manager.resume(id, allowsMetered: true)
        try await waitForDownload { h.transport.started.count == 2 }
        #expect(h.transport.started[1].resumed)
        #expect(h.manager.progress.fraction(for: h.manager.jobs[0]) == 0.75)
    }

    @Test func resumedDownloadReservesOnlyMissingBytesAlongsideOtherTransfers() async throws {
        let h = try DownloadHarness(freeBytes: 80_000)
        defer { h.close() }
        var job = DownloadJob(scope: "test-account", track: h.track, quality: "exhigh", owner: "single:1", allowsMetered: false)
        job.status = .paused
        job.descriptor = h.fixture.descriptor
        job.expectedBytes = h.fixture.descriptor.byteCount
        job.receivedBytes = job.expectedBytes - 40_000
        try await h.persistence.save(DownloadCatalog(jobs: [job]))
        try await h.persistence.saveResumeData(Data("resume".utf8), jobID: job.id)
        try await h.store.reserveDownload(token: "other-transfer", bytes: 30_000)
        await h.manager.start()

        await h.manager.resume(job.id)
        try await waitForDownload { h.transport.started.count == 1 }
        #expect(h.transport.started[0].resumed)
        #expect(h.manager.jobs.first?.receivedBytes == job.receivedBytes)
        // The resumed 40 KB and the other transfer's 30 KB must both remain
        // reserved, leaving exactly 10 KB for another transfer.
        await #expect(throws: OfflineAudioError.insufficientSpace) {
            try await h.store.reserveDownload(token: "probe", bytes: 10_001)
        }
        try await h.store.reserveDownload(token: "probe", bytes: 10_000)
        try h.transport.finish(h.transport.started[0])
        try await waitForDownload { h.manager.jobs.first?.status == .complete }
    }

    @Test(arguments: ["missing", "changed", "negative", "beyond", "minimum", "maximum"])
    func unusableResumeProgressStillRequiresTheFullDownloadSize(reason: String) async throws {
        let h = try DownloadHarness(freeBytes: 60_000)
        defer { h.close() }
        var job = DownloadJob(scope: "test-account", track: h.track, quality: "exhigh", owner: "single:1", allowsMetered: false)
        job.status = .paused
        job.descriptor = reason == "changed" ? try OfflineAudioFixture(.flac).descriptor : h.fixture.descriptor
        job.expectedBytes = h.fixture.descriptor.byteCount
        switch reason {
        case "negative": job.receivedBytes = -1
        case "beyond": job.receivedBytes = job.expectedBytes + 1
        case "minimum": job.receivedBytes = .min
        case "maximum": job.receivedBytes = .max
        default: job.receivedBytes = 80_000
        }
        try await h.persistence.save(DownloadCatalog(jobs: [job]))
        if reason != "missing" { try await h.persistence.saveResumeData(Data("resume".utf8), jobID: job.id) }
        await h.manager.start()

        await h.manager.resume(job.id)
        try await waitForDownload { h.manager.jobs.first?.status == .failed }
        #expect(h.transport.started.isEmpty)
        #expect(h.manager.jobs.first?.receivedBytes == 0)
        #expect(h.manager.jobs.first?.errorMessage == DownloadManager.message(for: OfflineAudioError.insufficientSpace))
        #expect(await h.persistence.resumeData(jobID: job.id) == nil)
        try await h.store.reserveDownload(token: "probe", bytes: 60_000)
    }

    @Test func aTransferOnlyNotifiesItsOwnTrackState() async throws {
        let h = try DownloadHarness()
        defer { h.close() }
        let other = try JSONDecoder().decode(Track.self, from: Data("{\"id\":2,\"name\":\"Second fixture\",\"dt\":3000}".utf8))
        await h.manager.enqueue(tracks: [h.track, other], owner: "playlist:two", name: "two",
                                quality: "exhigh", allowsMetered: true)
        try await waitForDownload { h.transport.started.count == 2 }
        let mine = h.manager.trackState(for: h.track.id), theirs = h.manager.trackState(for: other.id)
        try await waitForDownload { mine.status == .downloading && theirs.status == .downloading }
        var myTicks = 0, theirTicks = 0, theirRowTicks = 0, aggregateTicks = 0
        let observers = [
            mine.progress.objectWillChange.sink { _ in myTicks += 1 },
            theirs.progress.objectWillChange.sink { _ in theirTicks += 1 },
            theirs.objectWillChange.sink { _ in theirRowTicks += 1 },
            h.manager.progress.objectWillChange.sink { _ in aggregateTicks += 1 },
        ]
        defer { observers.forEach { $0.cancel() } }
        let transfer = try #require(h.transport.started.first { $0.resource.descriptor.identity.trackID == h.track.id })
        let total = transfer.resource.descriptor.byteCount
        h.transport.continuation.yield(.progress(token: transfer.token, received: total / 2, expected: total))
        try await waitForDownload { mine.progress.fraction == 0.5 }
        #expect(myTicks == 1)
        #expect(theirTicks == 0)
        #expect(theirRowTicks == 0)
        #expect(aggregateTicks >= 1)
        #expect(h.manager.progress.values[try #require(mine.jobID)]?.received == total / 2)
    }

    @Test(arguments: [false, true])
    func finishingAFileKeepsTheRingFullUntilValidationEnds(corrupt: Bool) async throws {
        let h = try DownloadHarness()
        defer { h.close() }
        await h.enqueue()
        try await waitForDownload { h.transport.started.count == 1 }
        let transfer = h.transport.started[0], total = h.fixture.descriptor.byteCount
        h.transport.continuation.yield(.progress(token: transfer.token, received: total * 3 / 4, expected: total))
        try await waitForDownload { h.manager.progress.values[h.manager.jobs[0].id]?.received == total * 3 / 4 }
        #expect(h.manager.progress.fraction(for: h.manager.jobs[0]) == 0.75)
        var fractions: [(status: DownloadStatus, value: Double?)] = []
        let observer = h.manager.$jobs.dropFirst().sink { jobs in
            if let job = jobs.first { fractions.append((job.status, h.manager.progress.fraction(for: job))) }
        }
        defer { observer.cancel() }
        // The final byte-count callback can be coalesced; the receipt itself
        // establishes that transfer is finished, even if 75% was last displayed.
        try h.transport.finish(transfer, corrupt: corrupt)
        try await waitForDownload { h.manager.jobs.first?.status == (corrupt ? .failed : .complete) }
        #expect(fractions.contains { $0.status == .verifying })
        #expect(fractions.filter { [.verifying, .complete].contains($0.status) }.allSatisfy { $0.value == 1 })
        #expect(h.manager.progress.values[h.manager.jobs[0].id]?.received == total)
        #expect(h.manager.isDownloaded(trackID: h.track.id) == !corrupt)
    }

    @Test func completedIconDoesNotWaitForTheLibraryScan() async throws {
        let gate = DownloadRestoreGate()
        let h = try DownloadHarness(metadataReader: { _, _ in await gate.wait(); return nil })
        defer { gate.open(); h.close() }
        await h.enqueue()
        try await waitForDownload { h.transport.started.count == 1 }
        try h.transport.finish(h.transport.started[0])
        try await waitForDownload { gate.entered }
        #expect(h.manager.jobs.first?.status == .complete && h.manager.downloadedTracks.isEmpty)
        #expect(h.manager.isDownloaded(trackID: h.track.id))
        gate.open()
        try await waitForDownload { h.manager.downloadedTracks.count == 1 }
        await h.manager.deleteLocalAudio(trackID: h.track.id)
        #expect(!h.manager.isDownloaded(trackID: h.track.id))
    }

    @Test func removingSelectedDownloadsPreservesOtherSongsAccountsAndPlayback() async throws {
        let h = try DownloadHarness(online: false)
        defer { h.close() }
        let tracks = try (1...4).map { id in
            try JSONDecoder().decode(Track.self, from: Data("{\"id\":\(id),\"name\":\"Track \(id)\",\"dt\":3000}".utf8))
        }
        var descriptors: [OfflineAudioDescriptor] = []
        for (track, scope) in tracks.map({ ($0, "test-account") }) + [(tracks[0], "other-account")] {
            let resource = try await DownloadHarness.resolve(track: track, quality: "exhigh", scope: scope)
            descriptors.append(resource.descriptor)
            let input = h.root.appendingPathComponent("input.mp3")
            try FileManager.default.createDirectory(at: h.root, withIntermediateDirectories: true)
            try h.fixture.data.write(to: input)
            try await h.store.importDownload(at: input, descriptor: resource.descriptor)
            try await h.metadata.save(track: track, scope: scope)
            if scope == "other-account" { try await h.store.retain(id: resource.descriptor.identity.id, owner: "other-download") }
        }
        await h.manager.enqueue(tracks: Array(tracks.prefix(3)), owner: "playlist:a", name: "A", quality: "exhigh", allowsMetered: false)
        try await waitForDownload { h.manager.downloadedTracks.count == 3 && h.manager.pendingJobs.isEmpty }
        await h.manager.enqueue(tracks: Array(tracks.prefix(2)), owner: "playlist:b", name: "B", quality: "exhigh", allowsMetered: false)
        let playing = try #require(try await h.store.acquire(accountScope: "test-account", trackID: 1, preferredQuality: "exhigh"))
        var counts: [Int] = []
        let observer = h.manager.$offlineTracks.dropFirst().sink { counts.append($0.filter(\.isDownloaded).count) }
        defer { observer.cancel() }
        #expect(await h.manager.deleteLocalAudio(trackIDs: [1, 2]))
        #expect(!counts.isEmpty && counts.allSatisfy { $0 == 1 })
        #expect(h.manager.downloadedSongs().map(\.id) == [3])
        #expect(Set(h.manager.offlineTracks.map(\.id)) == [3, 4])
        // A partly removed collection keeps every song, so the missing ones can
        // be downloaded again; one with nothing left stops claiming a page.
        #expect(h.manager.collections.first { $0.id == "playlist:a" }?.tracks.map(\.id) == [1, 2, 3])
        #expect(h.manager.collections.first { $0.id == "playlist:b" } == nil)
        #expect(h.manager.jobs.filter { [1, 2].contains($0.track.id) }.isEmpty)
        #expect(try await h.store.record(id: descriptors[1].identity.id) == nil)
        #expect(try await h.store.availableRecords(accountScope: "other-account").count == 1)
        #expect(try Data(contentsOf: playing.url) == h.fixture.data)
        #expect(try await h.store.acquire(accountScope: "test-account", trackID: 1, preferredQuality: "exhigh") == nil)
        try await h.store.release(playing)
        #expect(!FileManager.default.fileExists(atPath: playing.url.path))
    }

    @Test func aSavedCollectionDoesNotOutliveItsDownloads() async throws {
        let h = try DownloadHarness(online: false)
        defer { h.close() }
        let tracks = try (1...2).map { id in
            try JSONDecoder().decode(Track.self, from: Data("{\"id\":\(id),\"name\":\"Track \(id)\",\"dt\":3000}".utf8))
        }
        try FileManager.default.createDirectory(at: h.root, withIntermediateDirectories: true)
        for track in tracks {
            let resource = try await DownloadHarness.resolve(track: track, quality: "exhigh", scope: "test-account")
            let input = h.root.appendingPathComponent("input.mp3")
            try h.fixture.data.write(to: input)
            try await h.store.importDownload(at: input, descriptor: resource.descriptor)
            try await h.metadata.save(track: track, scope: "test-account")
        }
        await h.manager.enqueue(tracks: tracks, owner: "playlist:a", name: "A", quality: "exhigh", allowsMetered: false)
        try await waitForDownload { h.manager.downloadedTracks.count == 2 && h.manager.pendingJobs.isEmpty }
        #expect(await h.manager.deleteLocalAudio(trackIDs: [1]))
        #expect(h.manager.collections.first { $0.id == "playlist:a" }?.tracks.map(\.id) == [1, 2])
        #expect(await h.manager.deleteLocalAudio(trackIDs: [2]))
        #expect(h.manager.collections.isEmpty && h.manager.downloadedSongs(in: "playlist:a").isEmpty)
        #expect(try await h.persistence.load().collections.isEmpty)
    }

    @Test func restoringDropsCollectionsThatLostEverySongAndKeepsQueuedOnes() async throws {
        let h = try DownloadHarness(online: false)
        defer { h.close() }
        var job = DownloadJob(scope: "test-account", track: h.track, quality: "exhigh", owner: "playlist:queued", allowsMetered: false)
        job.status = .paused
        let collections = [
            DownloadCollection(id: "album:9", accountScope: "test-account", name: "Gone", tracks: [h.track], savedAt: Date()),
            DownloadCollection(id: "playlist:queued", accountScope: "test-account", name: "Queued", tracks: [h.track], savedAt: Date()),
            DownloadCollection(id: "album:9", accountScope: "other-account", name: "Other", tracks: [h.track], savedAt: Date()),
        ]
        try await h.persistence.save(DownloadCatalog(jobs: [job], collections: collections))
        await h.manager.start()
        #expect(h.manager.collections.map(\.id) == ["playlist:queued"])
        let saved = try await h.persistence.load()
        #expect(saved.collections.map(\.id) == ["playlist:queued", "album:9"])
        #expect(saved.collections.map(\.accountScope) == ["test-account", "other-account"])
    }

    @Test func removingDownloadWithoutACatalogJobStillRemovesItsAudio() async throws {
        let h = try DownloadHarness(online: false)
        defer { h.close() }
        let input = h.root.appendingPathComponent("input.mp3")
        try FileManager.default.createDirectory(at: h.root, withIntermediateDirectories: true)
        try h.fixture.data.write(to: input)
        try await h.store.importDownload(at: input, descriptor: h.fixture.descriptor)
        try await h.store.retain(id: h.fixture.descriptor.identity.id, owner: "download:missing-job")
        try await h.metadata.save(track: h.track, scope: "test-account")
        await h.manager.start()
        #expect(h.manager.jobs.isEmpty && h.manager.downloadedTracks.count == 1)
        #expect(await h.manager.deleteLocalAudio(trackIDs: [1]))
        #expect(h.manager.downloadedTracks.isEmpty)
        #expect(try await h.store.record(id: h.fixture.descriptor.identity.id) == nil)
    }

    @Test func removing600DownloadedSongsSavesAndRefreshesOnce() async throws {
        let h = try DownloadHarness(online: false)
        defer { h.close() }
        try FileManager.default.createDirectory(at: h.root, withIntermediateDirectories: true)
        var catalog = DownloadCatalog()
        for id in 1...600 {
            let track = try JSONDecoder().decode(Track.self, from: Data("{\"id\":\(id),\"name\":\"Track \(id)\",\"dt\":3000}".utf8))
            let resource = try await DownloadHarness.resolve(track: track, quality: "exhigh", scope: "test-account")
            let input = h.root.appendingPathComponent("input.mp3")
            try h.fixture.data.write(to: input)
            try await h.store.importDownload(at: input, descriptor: resource.descriptor)
            var job = DownloadJob(scope: "test-account", track: track, quality: "exhigh", owner: "playlist:600", allowsMetered: false)
            job.status = .complete
            job.descriptor = resource.descriptor
            job.assetID = resource.descriptor.identity.id
            job.metadataPending = false
            try await h.store.retain(id: resource.descriptor.identity.id, owner: job.retentionOwner)
            catalog.jobs.append(job)
        }
        try await h.persistence.save(catalog)
        await h.manager.start()
        #expect(h.manager.downloadedTracks.count == 600)
        let revision = try await h.persistence.load().revision
        var counts: [Int] = []
        let observer = h.manager.$offlineTracks.dropFirst().sink { counts.append($0.filter(\.isDownloaded).count) }
        defer { observer.cancel() }
        let start = ContinuousClock.now
        #expect(await h.manager.deleteLocalAudio(trackIDs: Set(1...600)))
        print("Removed 600 downloaded songs in \(start.duration(to: .now))")
        #expect(!counts.isEmpty && counts.allSatisfy { $0 == 0 })
        let saved = try await h.persistence.load()
        #expect(saved.revision == revision + 1)
        #expect(saved.jobs.isEmpty)
        #expect(try await h.store.storageFiles().isEmpty)
    }

    @Test func stoppingACollectionPreservesCompletedSongsAndOtherDownloadRequests() async throws {
        let h = try DownloadHarness()
        defer { h.close() }
        await h.enqueue(owner: "playlist:a")
        try await waitForDownload { h.transport.started.count == 1 }
        try h.transport.finish(h.transport.started[0])
        try await waitForDownload { h.manager.downloadedTracks.count == 1 }
        let tracks = try (2...4).map { id in
            try JSONDecoder().decode(Track.self, from: Data("{\"id\":\(id),\"name\":\"Track \(id)\",\"dt\":3000}".utf8))
        }
        await h.manager.enqueue(tracks: [h.track, tracks[0], tracks[1]], owner: "playlist:a", name: "A", quality: "exhigh", allowsMetered: false)
        try await waitForDownload { h.transport.started.count == 3 }
        let shared = h.transport.started.first { $0.resource.descriptor.identity.trackID == 2 }!
        let stopped = h.transport.started.first { $0.resource.descriptor.identity.trackID == 3 }!
        await h.manager.enqueue(tracks: [tracks[0]], owner: "playlist:b", name: "B", quality: "exhigh", allowsMetered: false)
        await h.manager.enqueue(track: tracks[2], quality: "exhigh", allowsMetered: false)
        await h.manager.cancelCollection("playlist:a")
        try await waitForDownload { h.transport.started.count == 4 }
        #expect(!h.transport.cancelled.contains(shared.token))
        #expect(h.transport.cancelled.contains(stopped.token))
        #expect(h.manager.jobs.first { $0.track.id == 2 }?.owners == ["playlist:b"])
        #expect(h.manager.jobs.first { $0.track.id == 3 } == nil)
        #expect(h.manager.pendingJobs.allSatisfy { !$0.owners.contains("playlist:a") })
        #expect(h.manager.downloadedSongs().map(\.id) == [1])
        #expect(h.manager.jobs.first { $0.track.id == 1 }?.owners == ["playlist:a"])
        try h.transport.finish(stopped)
        try h.transport.finish(shared)
        try await waitForDownload { h.manager.downloadedTracks.count == 2 }
        #expect(h.manager.jobs.first { $0.track.id == 2 }?.owners == ["playlist:b"])
        #expect(h.manager.pendingJobs.map { $0.track.id } == [4])
    }

    @Test func a600SongCollectionPausesAndResumesAsABatch() async throws {
        let h = try DownloadHarness()
        defer { h.close() }
        let tracks = try (1...600).map { id in
            try JSONDecoder().decode(Track.self, from: Data("{\"id\":\(id),\"name\":\"Track \(id)\",\"dt\":3000}".utf8))
        }
        await h.manager.enqueue(tracks: tracks, owner: "playlist:600", name: "600 songs", quality: "exhigh", allowsMetered: false)
        try await waitForDownload { h.transport.started.count == 2 }
        let revision = try await h.persistence.load().revision
        var pausedCounts: [Int] = []
        let observer = h.manager.$jobs.dropFirst().sink { jobs in pausedCounts.append(jobs.filter { $0.status == .paused }.count) }
        let start = ContinuousClock.now
        await h.manager.pauseCollection("playlist:600")
        print("Paused 600 songs in \(start.duration(to: .now))")
        observer.cancel()
        #expect(!pausedCounts.isEmpty && pausedCounts.allSatisfy { $0 == 600 })
        let pausedCatalog = try await h.persistence.load()
        #expect(pausedCatalog.revision - revision < 10)
        #expect(h.transport.started.count == 2)
        #expect(h.manager.jobs.allSatisfy { $0.status == .paused && $0.owners == ["playlist:600"] })
        await h.manager.resumeCollection("playlist:600")
        try await waitForDownload { h.transport.started.count == 4 }
        #expect(h.transport.started.suffix(2).allSatisfy { $0.resumed })
        #expect(!h.manager.jobs.contains { $0.status == .paused })
        await h.manager.cancelCollection("playlist:600")
        #expect(h.manager.pendingJobs.isEmpty)
        #expect(h.manager.jobs.isEmpty)
    }

    @Test func cancelling600TasksPublishesOneEmptyQueueAndPreservesCompletedAudio() async throws {
        let h = try DownloadHarness()
        defer { h.close() }
        await h.enqueue()
        try await waitForDownload { h.transport.started.count == 1 }
        try h.transport.finish(h.transport.started[0])
        try await waitForDownload { h.manager.downloadedTracks.count == 1 }
        let tracks = try (2...601).map { id in
            try JSONDecoder().decode(Track.self, from: Data("{\"id\":\(id),\"name\":\"Track \(id)\",\"dt\":3000}".utf8))
        }
        await h.manager.enqueue(tracks: tracks, owner: "playlist:600", name: "600 songs", quality: "exhigh", allowsMetered: false)
        try await waitForDownload { h.transport.started.count == 3 }
        #expect(h.manager.pendingJobs.count == 600)
        let revision = try await h.persistence.load().revision
        var counts: [Int] = []
        let observer = h.manager.$jobs.dropFirst().sink { jobs in
            counts.append(jobs.filter { !$0.owners.isEmpty && ![.complete, .cancelled].contains($0.status) }.count)
        }
        defer { observer.cancel() }
        let start = ContinuousClock.now
        await h.manager.cancelAll()
        print("Cancelled 600 tasks in \(start.duration(to: .now))")
        #expect(!counts.isEmpty && counts.allSatisfy { $0 == 0 })
        #expect(h.transport.started.count == 3)
        #expect(h.manager.pendingJobs.isEmpty && h.manager.downloadedSongs().map(\.id) == [1])
        let saved = try await h.persistence.load()
        #expect(saved.jobs.count == 1 && saved.jobs.first?.status == .complete)
        // Metadata callbacks may also save, but cancelling must not save per song.
        #expect(saved.revision - revision < 10)
        for transfer in h.transport.started.dropFirst() {
            #expect(h.transport.cancelled.contains(transfer.token))
            try h.transport.finish(transfer)
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(h.manager.pendingJobs.isEmpty && h.manager.downloadedSongs().map(\.id) == [1])
        #expect(try await h.store.availableRecords(accountScope: "test-account").count == 1)
    }

    @Test func tasksAddedDuringBatchCleanupStartAfterCleanupFinishes() async throws {
        let gate = DownloadRestoreGate()
        var blockRead = false
        let h = try DownloadHarness(metadataReader: { _, _ in
            if blockRead { await gate.wait() }
            return nil
        })
        defer { gate.open(); h.close() }
        await h.enqueue()
        try await waitForDownload { h.transport.started.count == 1 }
        try h.transport.finish(h.transport.started[0])
        try await waitForDownload { h.manager.downloadedTracks.count == 1 }
        let second = try JSONDecoder().decode(Track.self, from: Data("{\"id\":2,\"name\":\"Second\",\"dt\":3000}".utf8))
        let third = try JSONDecoder().decode(Track.self, from: Data("{\"id\":3,\"name\":\"Third\",\"dt\":3000}".utf8))
        await h.manager.enqueue(track: second, quality: "exhigh", allowsMetered: false)
        try await waitForDownload { h.transport.started.count == 2 }
        blockRead = true
        let cancellation = Task { await h.manager.cancelAll() }
        try await waitForDownload { gate.entered }
        #expect(h.manager.pendingJobs.isEmpty)
        await h.manager.enqueue(track: third, quality: "exhigh", allowsMetered: false)
        #expect(h.transport.started.count == 2)
        #expect(h.manager.jobs.first { $0.track.id == third.id }?.status == .queued)
        blockRead = false
        gate.open()
        await cancellation.value
        try await waitForDownload { h.transport.started.count == 3 }
        #expect(h.transport.started[2].resource.descriptor.identity.trackID == third.id)
    }

    @Test func connectedNetworkRetriesWithoutAPathChangeAndKeepsResumeData() async throws {
        let clock = DownloadRetryClock()
        let h = try DownloadHarness(retrySleep: { await clock.sleep($0) })
        defer { h.close(); clock.finish() }
        await h.enqueue()
        try await waitForDownload { h.transport.started.count == 1 }
        let first = h.transport.started[0]
        h.transport.continuation.yield(.failed(token: first.token, domain: NSURLErrorDomain,
            code: NSURLErrorNetworkConnectionLost, resumeData: Data("resume".utf8)))
        try await waitForDownload { clock.pending.count == 1 }
        #expect(h.manager.jobs.first?.status == .waitingNetwork)
        #expect(clock.delays == [.seconds(1)])
        #expect(h.transport.started.count == 1)
        // A duplicate path callback must not skip the backoff.
        h.manager.setNetwork(h.manager.network)
        #expect(h.manager.jobs.first?.status == .waitingNetwork)
        clock.advance()
        try await waitForDownload { h.transport.started.count == 2 }
        #expect(h.transport.started[1].resumed)
        #expect(h.transport.started[1].token != first.token)
        try h.transport.finish(h.transport.started[1])
        try await waitForDownload { h.manager.jobs.first?.status == .complete }
    }

    @Test func repeatedNetworkFailuresStopAfterThreeBackoffRetries() async throws {
        let clock = DownloadRetryClock()
        let h = try DownloadHarness(retrySleep: { await clock.sleep($0) })
        defer { h.close(); clock.finish() }
        await h.enqueue()
        for attempt in 0...3 {
            try await waitForDownload { h.transport.started.count == attempt + 1 }
            h.transport.continuation.yield(.failed(token: h.transport.started[attempt].token,
                domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost, resumeData: nil))
            if attempt < 3 {
                try await waitForDownload { clock.pending.count == 1 }
                clock.advance()
            }
        }
        try await waitForDownload { h.manager.jobs.first?.status == .failed }
        #expect(clock.delays == [.seconds(1), .seconds(2), .seconds(4)])
        #expect(clock.pending.isEmpty)
        #expect(h.transport.started.count == 4)
        await h.manager.resume(try #require(h.manager.jobs.first?.id))
        try await waitForDownload { h.transport.started.count == 5 }
        h.transport.continuation.yield(.failed(token: h.transport.started[4].token,
            domain: NSURLErrorDomain, code: NSURLErrorTimedOut, resumeData: nil))
        try await waitForDownload { clock.pending.count == 1 }
        #expect(clock.delays.last == .seconds(1))
    }

    @Test func resolutionConnectivityFailureUsesTheSameRetryBudget() async throws {
        let clock = DownloadRetryClock()
        var calls = 0
        let h = try DownloadHarness(resolver: { track, quality, scope in
            calls += 1
            if calls == 1 { throw URLError(.networkConnectionLost) }
            return try await DownloadHarness.resolve(track: track, quality: quality, scope: scope)
        }, retrySleep: { await clock.sleep($0) })
        defer { h.close(); clock.finish() }
        await h.enqueue()
        try await waitForDownload { clock.pending.count == 1 }
        #expect(h.transport.started.isEmpty)
        clock.advance()
        try await waitForDownload { h.transport.started.count == 1 }
        #expect(calls == 2)
    }

    @Test(arguments: ["pause", "cancel", "account", "metered", "shutdown", "resume"])
    func pendingRetryCannotOverrideNewerUserOrNetworkState(action: String) async throws {
        let clock = DownloadRetryClock()
        let h = try DownloadHarness(retrySleep: { await clock.sleep($0) })
        defer { h.close(); clock.finish() }
        await h.enqueue()
        try await waitForDownload { h.transport.started.count == 1 }
        let id = try #require(h.manager.jobs.first?.id)
        h.transport.continuation.yield(.failed(token: h.transport.started[0].token,
            domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost, resumeData: nil))
        try await waitForDownload { clock.pending.count == 1 }
        switch action {
        case "pause": await h.manager.pause(id)
        case "cancel": await h.manager.cancel(id)
        case "account": h.manager.activate(accountScope: "other-account")
        case "metered": h.manager.setNetwork(.init(connected: true, expensive: true, constrained: false))
        case "shutdown": h.manager.shutdown()
        default:
            await h.manager.resume(id)
            try await waitForDownload { h.transport.started.count == 2 }
        }
        let status = h.manager.jobs.first?.status
        clock.advance()
        try await Task.sleep(for: .milliseconds(30))
        #expect(h.transport.started.count == (action == "resume" ? 2 : 1))
        #expect(h.manager.jobs.first?.status == status)
        if action == "metered" {
            h.manager.setNetwork(.init(connected: true, expensive: false, constrained: false))
            try await waitForDownload { h.transport.started.count == 2 }
        }
    }

    @Test(arguments: [false, true])
    func restoredTransferReservesSpaceBeforeNewDownloadsOrCache(expensive: Bool) async throws {
        let h = try DownloadHarness(expensive: expensive, freeBytes: 180_000)
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
        #expect(h.manager.jobs.first?.status == (expensive ? .waitingNetwork : .downloading))
        // Unknown response length must not discard the restored reservation.
        h.transport.continuation.yield(.progress(token: token, received: 1_024, expected: -1))
        try await waitForDownload { h.manager.progress.values[job.id]?.received == 1_024 }
        let next = try JSONDecoder().decode(Track.self, from: Data("{\"id\":2,\"name\":\"Next\",\"dt\":3000}".utf8))
        await h.manager.enqueue(track: next, quality: "exhigh", allowsMetered: true)
        try await waitForDownload { h.manager.jobs.first { $0.track.id == 2 }?.status == .failed }
        #expect(h.transport.started.isEmpty)
        let resource = try await DownloadHarness.resolve(track: next, quality: "exhigh", scope: "test-account")
        await #expect(throws: OfflineAudioError.insufficientSpace) {
            try await h.store.beginCaching(resource.descriptor, writer: UUID(), context: .init(policy: .gb1))
        }
        await h.manager.pause(job.id)
        await h.manager.resume(try #require(h.manager.jobs.first { $0.track.id == 2 }?.id))
        try await waitForDownload { h.transport.started.count == 1 }
        #expect(h.transport.started[0].resource.descriptor.identity.trackID == 2)
    }

    @Test func restorationUsesActualReceivedBytesRatherThanStaleCatalogProgress() async throws {
        let h = try DownloadHarness(freeBytes: 180_000)
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
        h.transport.restoredReceivedBytes[token] = 80_000
        await h.manager.start()
        #expect(h.manager.jobs.first?.receivedBytes == 80_000)
        let next = try JSONDecoder().decode(Track.self, from: Data("{\"id\":2,\"name\":\"Next\",\"dt\":3000}".utf8))
        await h.manager.enqueue(track: next, quality: "exhigh", allowsMetered: false)
        try await waitForDownload { h.transport.started.count == 1 }
        #expect(h.transport.started[0].resource.descriptor.identity.trackID == 2)
        #expect(!h.transport.cancelled.contains(token))
    }

    @Test func restorationCancelsATransferThatNoLongerFits() async throws {
        let h = try DownloadHarness(freeBytes: 100)
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
        #expect(h.manager.isReady)
        #expect(h.manager.jobs.first?.status == .failed)
        #expect(h.manager.jobs.first?.errorMessage == DownloadManager.message(for: OfflineAudioError.insufficientSpace))
        #expect(h.transport.cancelled.contains(token))
        try await h.store.reserveDownload(token: "probe", bytes: 100)
    }

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

    @Test func completionDuringALibraryScanDoesNotHideARemovedDownload() async throws {
        let gate = DownloadRestoreGate()
        var blockNextRead = false
        let h = try DownloadHarness(metadataReader: { id, _ in
            if id == 3, blockNextRead { blockNextRead = false; await gate.wait() }
            return nil
        })
        defer { gate.open(); h.close() }
        let kept = try JSONDecoder().decode(Track.self, from: Data("{\"id\":3,\"name\":\"Kept\",\"dt\":3000}".utf8))
        await h.enqueue()
        await h.manager.enqueue(track: kept, quality: "exhigh", allowsMetered: false)
        try await waitForDownload { h.transport.started.count == 2 }
        try h.transport.finish(h.transport.started[0])
        try h.transport.finish(h.transport.started[1])
        try await waitForDownload { h.manager.offlineTracks.count == 2 }

        // The song's audio disappears; the next full scan must notice.
        let lease = try #require(try await h.store.acquire(accountScope: "test-account", trackID: 1, preferredQuality: "exhigh"))
        try await h.store.release(lease)
        try FileManager.default.removeItem(at: lease.url)
        let next = try JSONDecoder().decode(Track.self, from: Data("{\"id\":2,\"name\":\"Just downloaded\",\"dt\":3000}".utf8))
        await h.manager.enqueue(track: next, quality: "exhigh", allowsMetered: false)
        try await waitForDownload { h.transport.started.count == 3 }

        blockNextRead = true
        let scan = Task { await h.manager.refreshLibrary() }
        try await waitForDownload { gate.entered }
        try h.transport.finish(h.transport.started[2])
        try await waitForDownload { h.manager.offlineTracks.contains { $0.id == 2 } }
        gate.open()
        await scan.value
        #expect(h.manager.offlineTracks.map(\.id) == [2, 3])
        #expect(h.manager.jobs.first { $0.track.id == 1 }?.status == .failed)
        #expect(h.manager.jobs.first { $0.track.id == 2 }?.status == .complete)
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

    @Test func eachCompletionReadsOnlyItsOwnSongAndLandsWhereAFullScanWould() async throws {
        var reads: [Int] = []
        let h = try DownloadHarness(metadataReader: { id, _ in reads.append(id); return nil })
        defer { h.close() }
        let names = ["Cherry", "apple", "Banana"]
        let tracks = try names.enumerated().map { index, name in
            try JSONDecoder().decode(Track.self, from: Data("{\"id\":\(index + 1),\"name\":\"\(name)\",\"dt\":3000}".utf8))
        }
        await h.manager.enqueue(tracks: tracks, owner: "playlist:sorted", name: "Sorted", quality: "exhigh", allowsMetered: false)
        try await waitForDownload { h.transport.started.count == 2 }
        func transfer(_ trackID: Int) throws -> FakeDownloadTransport.Started {
            try #require(h.transport.started.first { $0.resource.descriptor.identity.trackID == trackID })
        }
        try h.transport.finish(try transfer(2))
        try await waitForDownload { h.transport.started.count == 3 && h.manager.offlineTracks.count == 1 }
        try h.transport.finish(try transfer(1))
        try h.transport.finish(try transfer(3))
        try await waitForDownload { h.manager.offlineTracks.count == 3 }
        // A rescan per finished song would read every earlier song again.
        #expect(reads == [2, 1, 3])
        #expect(h.manager.offlineTracks.map(\.track.name) == ["apple", "Banana", "Cherry"])
        let incremental = h.manager.offlineTracks
        await h.manager.refreshLibrary()
        #expect(h.manager.offlineTracks.map(\.id) == incremental.map(\.id))
        #expect(h.manager.offlineTracks.map { $0.assets.map(\.id) } == incremental.map { $0.assets.map(\.id) })
        #expect(h.manager.offlineTracks.map(\.isDownloaded) == incremental.map(\.isDownloaded))
        #expect(h.manager.downloadedTrackIDs == Set(tracks.map(\.id)))
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

    @Test func resumingAWaitingTransferKeepsItsLivePartialDownload() async throws {
        let h = try DownloadHarness()
        defer { h.close() }
        await h.manager.enqueue(track: h.track, quality: "exhigh", allowsMetered: true)
        try await waitForDownload { h.transport.started.count == 1 }
        let transfer = h.transport.started[0], total = h.fixture.descriptor.byteCount
        h.transport.continuation.yield(.progress(token: transfer.token, received: total / 2, expected: total))
        try await waitForDownload { h.manager.progress.fraction(for: h.manager.jobs[0]) == 0.5 }
        h.manager.setNetwork(.init(connected: false, expensive: false, constrained: false))
        #expect(h.manager.jobs.first?.status == .waitingNetwork)
        await h.manager.resumeAll(allowsMetered: true)
        #expect(!h.transport.cancelled.contains(transfer.token))
        #expect(h.manager.jobs.first?.token == transfer.token)
        #expect(h.manager.jobs.first?.status == .waitingNetwork)
        #expect(h.transport.started.count == 1)
        #expect(h.manager.progress.fraction(for: h.manager.jobs[0]) == 0.5)
        h.manager.setNetwork(.init(connected: true, expensive: false, constrained: false))
        #expect(h.manager.jobs.first?.status == .downloading)
        try h.transport.finish(transfer)
        try await waitForDownload { h.manager.jobs.first?.status == .complete }
        #expect(h.transport.started.count == 1)
    }

    @Test func waitingForWiFiHoldsDownloadsUntilTheNetworkIsUnmetered() async throws {
        let h = try DownloadHarness(expensive: true)
        defer { h.close() }
        await h.manager.enqueue(track: h.track, quality: "exhigh", allowsMetered: false)
        try await waitForDownload { h.manager.jobs.first?.status == .waitingNetwork }
        #expect(h.transport.started.isEmpty)
        await h.manager.resumeAll()
        try await waitForDownload { h.manager.jobs.first?.status == .waitingNetwork }
        #expect(h.transport.started.isEmpty)
        h.manager.setNetwork(.init(connected: true, expensive: false, constrained: false))
        try await waitForDownload { h.transport.started.count == 1 }
        #expect(!h.transport.started[0].metered)
    }

    @Test func bulkResumeCanSendApprovedJobsBackToWaitForWiFi() async throws {
        let h = try DownloadHarness(expensive: true)
        defer { h.close() }
        await h.manager.enqueue(track: h.track, quality: "exhigh", allowsMetered: true)
        try await waitForDownload { h.transport.started.count == 1 }
        await h.manager.pause(try #require(h.manager.jobs.first?.id))
        await h.manager.resumeAll(allowsMetered: false)
        try await waitForDownload { h.manager.jobs.first?.status == .waitingNetwork }
        #expect(h.transport.started.count == 1)
        #expect(try await h.persistence.load().jobs.allSatisfy { !$0.allowsMetered })
        h.manager.setNetwork(.init(connected: true, expensive: false, constrained: false))
        try await waitForDownload { h.transport.started.count == 2 }
        try h.transport.finish(h.transport.started[1])
        try await waitForDownload { h.manager.jobs.first?.status == .complete }
    }

    @Test func waitingTransferRebuildsItsRequestWhenMeteredApprovalIsRevoked() async throws {
        let h = try DownloadHarness(expensive: true)
        defer { h.close() }
        await h.manager.enqueue(track: h.track, quality: "exhigh", allowsMetered: true)
        try await waitForDownload { h.transport.started.count == 1 }
        let original = h.transport.started[0], total = h.fixture.descriptor.byteCount
        let id = try #require(h.manager.jobs.first?.id)
        h.transport.continuation.yield(.progress(token: original.token, received: total / 2, expected: total))
        h.transport.continuation.yield(.waiting(token: original.token))
        try await waitForDownload { h.manager.jobs.first?.status == .waitingNetwork }
        try await h.persistence.saveResumeData(Data("previous request allows cellular".utf8), jobID: id)

        await h.manager.resumeAll(allowsMetered: false)
        try await waitForDownload { h.manager.jobs.first?.status == .waitingNetwork }
        #expect(h.transport.cancelled.contains(original.token))
        #expect(h.transport.started.count == 1)
        #expect(h.manager.jobs.first?.token == nil)
        #expect(await h.persistence.resumeData(jobID: id) == nil)
        #expect(try await h.persistence.load().jobs.first?.allowsMetered == false)

        h.manager.setNetwork(.init(connected: true, expensive: false, constrained: false))
        try await waitForDownload { h.transport.started.count == 2 }
        let restarted = h.transport.started[1]
        #expect(!restarted.metered && !restarted.resumed)
        #expect(h.manager.progress.fraction(for: h.manager.jobs[0]) == 0)
        try h.transport.finish(restarted)
        try await waitForDownload { h.manager.jobs.first?.status == .complete }
    }

    @Test(arguments: [false, true], [DownloadStatus.waitingNetwork, .paused])
    func newCollectionAppliesMeteredApprovalToAnExistingSharedJob(liveTransfer: Bool, status: DownloadStatus) async throws {
        let h = try DownloadHarness(expensive: !liveTransfer)
        defer { h.close() }
        await h.enqueue()
        if liveTransfer { try await waitForDownload { h.transport.started.count == 1 } }
        h.manager.setNetwork(.init(connected: true, expensive: true, constrained: false))
        try await waitForDownload { h.manager.jobs.first?.status == .waitingNetwork }
        let id = try #require(h.manager.jobs.first?.id)
        if status == .paused { await h.manager.pause(id) }
        let startsBeforeRequest = h.transport.started.count
        #expect(h.manager.jobs.first?.owners == ["single:1"])

        // The collection button resumes its own jobs before attaching a new
        // owner; that first step cannot find the existing single-song request.
        await h.manager.resumeCollection("playlist:new", allowsMetered: true)
        #expect(h.manager.jobs.first?.status == status)
        await h.manager.enqueue(tracks: [h.track], owner: "playlist:new", name: "New playlist",
                                quality: "exhigh", allowsMetered: true)
        try await waitForDownload { h.transport.started.count == startsBeforeRequest + 1 }
        #expect(h.manager.jobs.count == 1)
        #expect(h.manager.jobs.first?.id == id)
        #expect(h.manager.jobs.first?.owners == ["single:1", "playlist:new"])
        let transfer = try #require(h.transport.started.last)
        #expect(transfer.metered && !transfer.resumed)
        try h.transport.finish(transfer)
        try await waitForDownload { h.manager.jobs.first?.status == .complete }
    }

    @Test func newCollectionResumesAPausedSharedJobWithItsNewWiFiRestriction() async throws {
        let h = try DownloadHarness(expensive: true)
        defer { h.close() }
        await h.manager.enqueue(track: h.track, quality: "exhigh", allowsMetered: true)
        try await waitForDownload { h.transport.started.count == 1 }
        let id = try #require(h.manager.jobs.first?.id)
        await h.manager.pause(id)
        await h.manager.enqueue(tracks: [h.track], owner: "playlist:new", name: "New playlist",
                                quality: "exhigh", allowsMetered: false)
        try await waitForDownload { h.manager.jobs.first?.status == .waitingNetwork }
        #expect(h.transport.started.count == 1)
        #expect(h.manager.jobs.first?.allowsMetered == false)
        #expect(await h.persistence.resumeData(jobID: id) == nil)
        h.manager.setNetwork(.init(connected: true, expensive: false, constrained: false))
        try await waitForDownload { h.transport.started.count == 2 }
        #expect(!h.transport.started[1].metered && !h.transport.started[1].resumed)
    }

    @Test(arguments: [false, true])
    func newCollectionOnlyWidensAnActiveSharedJobsNetworkApproval(originalApproval: Bool) async throws {
        let h = try DownloadHarness()
        defer { h.close() }
        await h.manager.enqueue(track: h.track, quality: "exhigh", allowsMetered: originalApproval)
        try await waitForDownload { h.transport.started.count == 1 }
        let original = h.transport.started[0]
        await h.manager.enqueue(tracks: [h.track], owner: "playlist:new", name: "New playlist",
                                quality: "exhigh", allowsMetered: !originalApproval)
        // Widening approval on Wi-Fi keeps the live transfer and its bytes.
        #expect(h.transport.cancelled.isEmpty)
        #expect(h.transport.started.count == 1)
        #expect(h.manager.jobs.first?.allowsMetered == true)
        #expect(try await h.persistence.load().jobs.first?.allowsMetered == true)

        // Only a metered path forces the Wi-Fi-only request to be rebuilt.
        h.manager.setNetwork(.init(connected: true, expensive: true, constrained: false))
        if !originalApproval { try await waitForDownload { h.transport.started.count == 2 } }
        #expect(h.transport.cancelled.contains(original.token) == !originalApproval)
        #expect(h.transport.started.count == (originalApproval ? 1 : 2))
        #expect(h.transport.started.last?.metered == true)
        #expect(h.transport.started.last?.resumed == false)
        try h.transport.finish(try #require(h.transport.started.last))
        try await waitForDownload { h.manager.jobs.first?.status == .complete }
    }

    @Test func pausingAWidenedTransferDropsItsWiFiOnlyResumeData() async throws {
        let h = try DownloadHarness()
        defer { h.close() }
        await h.enqueue()
        try await waitForDownload { h.transport.started.count == 1 }
        let id = try #require(h.manager.jobs.first?.id)
        await h.manager.enqueue(track: h.track, quality: "exhigh", allowsMetered: true)
        await h.manager.pause(id)
        #expect(await h.persistence.resumeData(jobID: id) != nil)
        await h.manager.resume(id)
        #expect(await h.persistence.resumeData(jobID: id) == nil)
        try await waitForDownload { h.transport.started.count == 2 }
        #expect(h.transport.started[1].metered && !h.transport.started[1].resumed)
    }

    @Test(arguments: [false, true])
    func bulkDownloadsOnlyUseCellularWhenTheUserApprovedIt(bulk: Bool) {
        let wifi = DownloadNetworkState(connected: true, expensive: false, constrained: false)
        for network in [wifi, .unknown] {
            var approval: Bool?
            MeteredDownloadCenter.shared.request(bulk: bulk, count: 1, network: network) { approval = $0 }
            #expect(approval == !bulk)
            #expect(MeteredDownloadCenter.shared.prompt == nil)
        }
    }

    @Test func meteredConfirmationOnlyCoversBulkDownloadsAndLowDataMode() {
        let wifi = DownloadNetworkState(connected: true, expensive: false, constrained: false)
        #expect(!wifi.needsMeteredConfirmation(bulk: true) && !wifi.needsMeteredConfirmation(bulk: false))
        let cellular = DownloadNetworkState(connected: true, expensive: true, constrained: false)
        #expect(cellular.needsMeteredConfirmation(bulk: true) && !cellular.needsMeteredConfirmation(bulk: false))
        let lowData = DownloadNetworkState(connected: true, expensive: false, constrained: true)
        #expect(lowData.needsMeteredConfirmation(bulk: true) && lowData.needsMeteredConfirmation(bulk: false))
        #expect(!DownloadNetworkState.unknown.needsMeteredConfirmation(bulk: true))
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

    @Test func partialPlaybackCacheDoesNotBlockBackgroundDownload() async throws {
        let h = try DownloadHarness()
        defer { h.close() }
        let server = try await AudioFixtureServer(fixture: h.fixture, delay: 0.05)
        defer { server.stop() }
        let resource = h.fixture.resource(url: server.url)
        let source = AudioTransferCoordinator(resource: resource, store: h.store, cacheContext: .init(policy: .automatic))
        _ = try await source.read(at: 0, maximum: 1_024)
        let manager = DownloadManager(store: h.store, metadata: h.metadata, persistence: h.persistence,
            transport: h.transport, accountScope: "test-account", resolver: { _, _, _ in resource }, metadataFetcher: { _, _ in },
            prepareResource: { requested in
                #expect(requested.descriptor == resource.descriptor)
                await source.close()
            })
        defer { manager.shutdown() }
        manager.setNetwork(.init(connected: true, expensive: false, constrained: false))
        await manager.enqueue(tracks: [h.track], owner: "single:1", name: nil, quality: "exhigh", allowsMetered: false)
        try await waitForDownload { h.transport.started.count == 1 }
        #expect(await source.receivedByteCount < h.fixture.descriptor.byteCount)
        try h.transport.finish(h.transport.started[0])
        try await waitForDownload { manager.jobs.first?.status == .complete }
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
        #expect(h.manager.jobs.count == 1)
        #expect(h.manager.jobs.first?.owners == ["playlist:1", "playlist:2"])
        #expect(h.manager.offlineTracks.first?.isDownloaded == true)
        #expect(h.manager.downloadedSongs(in: "playlist:1").map(\.id) == [h.track.id])
        #expect(h.manager.downloadedSongs(in: "playlist:2").map(\.id) == [h.track.id])
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
        #expect(h.manager.jobs.isEmpty)
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
        try await waitForDownload { h.manager.jobs.count == 1 && h.manager.jobs.first?.quality == "lossless" && h.manager.jobs.first?.status == .complete }
        let saved = try await h.persistence.load()
        #expect(saved.jobs.first { $0.quality == "exhigh" } == nil)
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
