import Foundation
import Testing
@testable import KumoneCore

private func queueTrack(_ id: Int, seconds: Double = 3) throws -> Track {
    try JSONDecoder().decode(Track.self, from: JSONSerialization.data(withJSONObject: ["id": id, "name": "Track \(id)", "dt": seconds * 1000]))
}

private actor PrefetchGate {
    private var pending: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async { entered = true; await withCheckedContinuation { pending = $0 } }
    func open() { pending?.resume(); pending = nil }
}

@MainActor
private func waitForPrefetch(_ predicate: () async throws -> Bool) async throws {
    for _ in 0..<500 {
        if try await predicate() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    struct Timeout: Error {}
    Issue.record("Prefetch did not reach the expected state")
    throw Timeout()
}

@Suite("Queue order and offline selection", .timeLimit(.minutes(1)))
struct PlaybackQueuePlanTests {
    @Test func usesSavedShuffleOrderInsertionsAndOneLoopOnly() throws {
        let queue = try [queueTrack(3), queueTrack(1), queueTrack(2)]
        let inserted = try [queueTrack(8), queueTrack(9)]
        let plan = PlaybackQueuePlan.next(queue: queue, currentIndex: 1, inserted: inserted, fm: [], isFM: false, repeatAll: true)
        #expect(plan.map(\.track.id) == [8, 9, 2, 3, 1])
        #expect(plan.map(\.origin) == [.inserted(0), .inserted(1), .queue(2), .queue(0), .queue(1)])
        #expect(queue.map(\.id) == [3, 1, 2])
        #expect(PlaybackQueuePlan.next(queue: queue, currentIndex: 2, inserted: [], fm: [], isFM: false, repeatAll: false).isEmpty)
        let fm = PlaybackQueuePlan.next(queue: queue, currentIndex: 0, inserted: inserted, fm: try [queueTrack(7)], isFM: true, repeatAll: true)
        #expect(fm.map(\.track.id) == [7])
    }

    @Test func countAndDurationLimitsStopAtFirstExcess() throws {
        let limits = PrefetchLimits()
        #expect(limits.window(try (1...8).map { try queueTrack($0) }).count == 5)
        #expect(limits.window(try [queueTrack(1, seconds: 600), queueTrack(2, seconds: 601), queueTrack(3)]).map(\.id) == [1])
        #expect(limits.window(try [queueTrack(1, seconds: 0), queueTrack(2)]).isEmpty)
        #expect(limits.window(try [queueTrack(1, seconds: 1201), queueTrack(2)]).isEmpty)
    }

    @Test func offlineScanSkipsMissingPartialAndOtherAccountAssets() async throws {
        let fixture = try OfflineAudioFixture(), store = fixture.store()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        func descriptor(_ id: Int, scope: String = "a") -> OfflineAudioDescriptor {
            .init(identity: .init(accountScope: scope, trackID: id, source: "netease", quality: "exhigh", format: .mp3,
                                 contentMD5: fixture.descriptor.identity.contentMD5), byteCount: fixture.descriptor.byteCount, duration: 3)
        }
        for (id, scope) in [(3, "a"), (4, "b"), (5, "a")] {
            let asset = descriptor(id, scope: scope), writer = UUID()
            try await store.begin(asset, writer: writer)
            try await store.write(id == 3 ? fixture.data.prefix(1000) : fixture.data, at: 0, id: asset.identity.id, writer: writer)
            if id != 3 { try await store.finalize(id: asset.identity.id, writer: writer) }
            await store.releaseWriter(id: asset.identity.id, writer: writer)
        }
        let queue = try (1...5).map { try queueTrack($0) }
        let candidates = PlaybackQueuePlan.next(queue: queue, currentIndex: 0, inserted: [], fm: [], isFM: false, repeatAll: false)
        let found = try #require(try await OfflineQueueSelector.firstAvailable(candidates, scope: "a", quality: "exhigh", store: store))
        #expect(found.candidate.track.id == 5 && found.skipped == 3)
        #expect(queue.map(\.id) == [1, 2, 3, 4, 5])
        try await store.release(found.lease)
        #expect(try await OfflineQueueSelector.firstAvailable(candidates, scope: "c", quality: "exhigh", store: store) == nil)
    }
}

@Suite("Bounded queue prefetch", .timeLimit(.minutes(1)))
@MainActor
struct QueuePrefetchTests {
    private func resource(_ fixture: OfflineAudioFixture, track: Track, scope: String, url: URL) -> OfflineAudioResource {
        .init(descriptor: .init(identity: .init(accountScope: scope, trackID: track.id, source: "netease", quality: "exhigh",
                                               format: fixture.descriptor.identity.format, contentMD5: fixture.descriptor.identity.contentMD5),
                                byteCount: fixture.descriptor.byteCount, duration: track.duration), url: url)
    }
    private func request(_ ids: [Int], scope: String = "a", pending: Set<Int> = []) throws -> QueuePrefetchRequest {
        .init(scope: scope, currentTrackID: 1, tracks: try ids.map { try queueTrack($0) }, quality: "exhigh",
              context: .init(policy: .automatic, protectedTracks: [scope: [1]]), pendingDownloadTrackIDs: pending)
    }

    @Test func byteLimitDoesNotSkipOversizedEntryOrMarkPrefetchAsPlayed() async throws {
        let fixture = try OfflineAudioFixture(), store = fixture.store()
        let server = try await AudioFixtureServer(fixture: fixture)
        defer { server.stop(); try? FileManager.default.removeItem(at: store.directory) }
        var resolved: [Int] = []
        let scheduler = QueuePrefetcher(store: store, metadata: .init(directory: store.directory.appendingPathComponent("metadata")),
            limits: .init(bytes: fixture.descriptor.byteCount * 2), resolver: { track, _, scope in
                resolved.append(track.id)
                return resource(fixture, track: track, scope: scope, url: server.url)
            }, metadataFetcher: { _, _ in })
        scheduler.update(try request([2, 3, 4, 5]))
        try await waitForPrefetch { resolved.count == 3 }
        #expect(scheduler.completedTrackIDs == [2, 3])
        #expect(server.ranges.count == 2)
        let second = try #require(try await store.availableDescriptor(accountScope: "a", trackID: 2, preferredQuality: "exhigh"))
        #expect(try await store.record(id: second.identity.id)?.lastPlayed == nil)
        #expect(try await store.availableDescriptor(accountScope: "a", trackID: 4, preferredQuality: "exhigh") == nil)
        await scheduler.cancel().value
    }

    @Test func oldResolutionCannotWriteAfterQueueAndAccountChange() async throws {
        let fixture = try OfflineAudioFixture(), store = fixture.store(), gate = PrefetchGate()
        let server = try await AudioFixtureServer(fixture: fixture)
        defer { server.stop(); try? FileManager.default.removeItem(at: store.directory) }
        let scheduler = QueuePrefetcher(store: store, metadata: .init(directory: store.directory.appendingPathComponent("metadata")),
            resolver: { track, _, scope in
                if track.id == 2 { await gate.wait() }
                return resource(fixture, track: track, scope: scope, url: server.url)
            }, metadataFetcher: { _, _ in })
        scheduler.update(try request([2]))
        try await waitForPrefetch { await gate.entered }
        scheduler.update(try request([3], scope: "b"))
        try await waitForPrefetch { scheduler.completedTrackIDs == [3] }
        await gate.open()
        await Task.yield()
        #expect(try await store.availableRecords(accountScope: "a").isEmpty)
        #expect(try await store.availableRecords(accountScope: "b").map { $0.descriptor.identity.trackID } == [3])
        await scheduler.cancel().value
    }

    @Test func playbackTakesOverPersistedRangesAfterPrefetchCancellation() async throws {
        let fixture = try OfflineAudioFixture(.flac), store = fixture.store()
        let server = try await AudioFixtureServer(fixture: fixture, delay: 0.02)
        defer { server.stop(); try? FileManager.default.removeItem(at: store.directory) }
        let source = resource(fixture, track: try queueTrack(2), scope: "a", url: server.url)
        let scheduler = QueuePrefetcher(store: store, metadata: .init(directory: store.directory.appendingPathComponent("metadata")),
            resolver: { _, _, _ in source }, metadataFetcher: { _, _ in })
        scheduler.update(try request([2]))
        try await waitForPrefetch { try await store.record(id: source.descriptor.identity.id)?.ranges.byteCount ?? 0 >= 65_536 }
        await scheduler.cancel().value
        let cached = try #require(try await store.record(id: source.descriptor.identity.id))
        #expect(cached.lastPlayed == nil)
        let player = AudioTransferCoordinator(resource: source, store: store, cacheContext: .init(policy: .automatic))
        try await player.download()
        #expect(await player.receivedByteCount == fixture.descriptor.byteCount - cached.ranges.byteCount)
        #expect(try await store.record(id: source.descriptor.identity.id)?.lastPlayed != nil)
        await player.close()
    }

    @Test func aUserDownloadCanKeepThePrefetchTransferAlive() async throws {
        let fixture = try OfflineAudioFixture(.flac), store = fixture.store()
        let server = try await AudioFixtureServer(fixture: fixture, delay: 0.01)
        defer { server.stop(); try? FileManager.default.removeItem(at: store.directory) }
        let source = resource(fixture, track: try queueTrack(2), scope: "a", url: server.url)
        let scheduler = QueuePrefetcher(store: store, metadata: .init(directory: store.directory.appendingPathComponent("metadata")),
            resolver: { _, _, _ in source }, metadataFetcher: { _, _ in })
        scheduler.update(try request([2]))
        try await waitForPrefetch { !server.ranges.isEmpty }
        scheduler.update(try request([2], pending: [2]))
        let download = Task { try await scheduler.finishForDownload(resource: source, owner: "download", allowsMetered: false) }
        await Task.yield()
        await scheduler.cancel().value
        let retained = try #require(try await download.value)
        #expect(try await store.record(id: retained.identity.id)?.retainedBy == ["download"])
    }

    @Test func sameFailedWindowDoesNotRetryOnEveryPlaybackTick() async throws {
        let fixture = try OfflineAudioFixture(), store = fixture.store()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        var calls = 0
        let scheduler = QueuePrefetcher(store: store, metadata: .init(directory: store.directory.appendingPathComponent("metadata")),
            resolver: { _, _, _ in calls += 1; throw URLError(.notConnectedToInternet) }, metadataFetcher: { _, _ in })
        let window = try request([2, 3])
        scheduler.update(window)
        try await waitForPrefetch { calls == 1 }
        for _ in 0..<10 { scheduler.update(window); await Task.yield() }
        #expect(calls == 1)
        await scheduler.cancel().value
    }

    @Test func cancelledPendingDownloadAllowsPrefetchToResume() async throws {
        let fixture = try OfflineAudioFixture(), store = fixture.store()
        let server = try await AudioFixtureServer(fixture: fixture)
        defer { server.stop(); try? FileManager.default.removeItem(at: store.directory) }
        var calls = 0
        let scheduler = QueuePrefetcher(store: store, metadata: .init(directory: store.directory.appendingPathComponent("metadata")),
            resolver: { track, _, scope in calls += 1; return resource(fixture, track: track, scope: scope, url: server.url) },
            metadataFetcher: { _, _ in })
        scheduler.update(try request([2], pending: [2]))
        for _ in 0..<5 { await Task.yield() }
        #expect(calls == 0)
        scheduler.update(try request([2]))
        try await waitForPrefetch { scheduler.completedTrackIDs == [2] }
        #expect(calls == 1)
        await scheduler.cancel().value
    }
}
