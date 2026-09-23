import Foundation
import Testing
@testable import KumoneCore

private func queueTrack(_ id: Int, seconds: Double = 3) throws -> Track {
    try JSONDecoder().decode(Track.self, from: JSONSerialization.data(withJSONObject: ["id": id, "name": "Track \(id)", "dt": seconds * 1000]))
}

@MainActor
private func waitForPrefetch(_ predicate: () async throws -> Bool) async throws {
    for _ in 0..<600 {
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

    @Test(arguments: [0, 1, 5, 200, 20_000])
    func boundedCandidatesKeepTheSameOccurrenceOrder(limit: Int) throws {
        let queue = try (1...10_000).map { try queueTrack($0) }, inserted = try [queueTrack(99), queueTrack(99)]
        let full = PlaybackQueuePlan.next(queue: queue, currentIndex: 9998, inserted: inserted, fm: [], isFM: false, repeatAll: true)
        let bounded = PlaybackQueuePlan.next(queue: queue, currentIndex: 9998, inserted: inserted, fm: [], isFM: false, repeatAll: true, limit: limit)
        #expect(bounded == Array(full.prefix(limit)))
        let fm = PlaybackQueuePlan.next(queue: [], currentIndex: -1, inserted: [], fm: queue, isFM: true, repeatAll: false, limit: limit)
        #expect(fm.map(\.track.id) == Array(queue.prefix(limit)).map(\.id))
    }

    @Test func countAndDurationLimitsStopAtFirstExcess() throws {
        let limits = PrefetchLimits()
        #expect(limits.window(try (1...8).map { try queueTrack($0) }).count == 5)
        #expect(limits.window(try [queueTrack(1, seconds: 600), queueTrack(2, seconds: 601), queueTrack(3)]).map(\.id) == [1])
        #expect(limits.window(try [queueTrack(1, seconds: 0), queueTrack(2)]).isEmpty)
        #expect(limits.window(try [queueTrack(1, seconds: 1201), queueTrack(2)]).isEmpty)
    }

    @Test func onlyAFreeNetworkOnAChargedDeviceFillsTheCacheAhead() {
        let wifi = DownloadNetworkState(connected: true, expensive: false, constrained: false)
        #expect(QueuePrefetcher.permits(network: wifi, lowPower: false))
        #expect(!QueuePrefetcher.permits(network: wifi, lowPower: true))
        #expect(!QueuePrefetcher.permits(network: .init(connected: true, expensive: true, constrained: false), lowPower: false))
        #expect(!QueuePrefetcher.permits(network: .init(connected: true, expensive: false, constrained: true), lowPower: false))
        #expect(!QueuePrefetcher.permits(network: .init(connected: false, expensive: false, constrained: false), lowPower: false))
        #expect(!QueuePrefetcher.permits(network: .unknown, lowPower: false))
    }

    @Test func offlineScanSkipsMissingAndOtherAccountAssetsButTakesTheCache() async throws {
        let fixture = try OfflineAudioFixture(), store = fixture.store()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        func descriptor(_ id: Int, scope: String = "a") -> OfflineAudioDescriptor {
            .init(identity: .init(accountScope: scope, trackID: id, source: "netease", quality: "exhigh", format: .mp3,
                                 contentMD5: fixture.descriptor.identity.contentMD5), byteCount: fixture.descriptor.byteCount, duration: 3)
        }
        try await store.importFixture(fixture.data, descriptor: descriptor(4, scope: "b"))
        try await store.importFixture(fixture.data, descriptor: descriptor(5))
        let queue = try (1...5).map { try queueTrack($0) }
        let candidates = PlaybackQueuePlan.next(queue: queue, currentIndex: 0, inserted: [], fm: [], isFM: false, repeatAll: false)
        let found = try #require(try await OfflineQueueSelector.firstAvailable(candidates, scope: "a", quality: "exhigh", store: store) { _ in false })
        #expect(found.candidate.track.id == 5 && found.skipped == 3)
        #expect(found.lease != nil)
        #expect(queue.map(\.id) == [1, 2, 3, 4, 5])
        if let lease = found.lease { try await store.release(lease) }
        // The song cache answers for a song no account downloaded.
        let cached = try #require(try await OfflineQueueSelector.firstAvailable(candidates, scope: "c", quality: "exhigh", store: store) { $0 == 3 })
        #expect(cached.candidate.track.id == 3 && cached.lease == nil && cached.skipped == 1)
        #expect(try await OfflineQueueSelector.firstAvailable(candidates, scope: "c", quality: "exhigh", store: store) { _ in false } == nil)
    }
}

@Suite("Bounded queue prefetch", .timeLimit(.minutes(1)))
@MainActor
struct QueuePrefetchTests {
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var resolvedIDs: [Int] = []
        private var keptIDs: [(Int, String?)] = []
        func resolved(_ id: Int) { lock.lock(); resolvedIDs.append(id); lock.unlock() }
        func kept(_ id: Int, scope: String?) { lock.lock(); keptIDs.append((id, scope)); lock.unlock() }
        var resolved: [Int] { lock.lock(); defer { lock.unlock() }; return resolvedIDs }
        var kept: [(Int, String?)] { lock.lock(); defer { lock.unlock() }; return keptIDs }
    }

    private func makeCache() -> (AudioCache, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QueuePrefetchTests-\(UUID().uuidString)", isDirectory: true)
        return (AudioCache(cacheDirectory: directory), directory)
    }

    private func prefetcher(cache: AudioCache, server: AudioFixtureServer, fixture: OfflineAudioFixture, log: Log,
                            limits: PrefetchLimits = .init(), limitMB: Int = 500, downloaded: Set<Int> = [],
                            byteCount: Int64? = nil) -> QueuePrefetcher {
        QueuePrefetcher(cache: cache, limits: limits, cacheLimitMB: { limitMB }, isDownloaded: { downloaded.contains($0) },
                        resolver: { track, _ in
                            log.resolved(track.id)
                            return .init(url: server.url, servedQuality: "exhigh",
                                         byteCount: byteCount ?? Int64(fixture.data.count), fileExtension: "mp3")
                        },
                        completion: { track, scope in log.kept(track.id, scope: scope) })
    }

    private func request(_ ids: [Int], scope: String? = "a", pending: Set<Int> = []) throws -> QueuePrefetchRequest {
        .init(scope: scope, currentTrackID: 1, tracks: try ids.map { try queueTrack($0) }, quality: "exhigh",
              allowsUnblock: false, pendingDownloadTrackIDs: pending)
    }

    @Test func fillsTheCacheWithUpcomingSongsInOrder() async throws {
        let fixture = try OfflineAudioFixture(), (cache, directory) = makeCache(), log = Log()
        let server = try await AudioFixtureServer(fixture: fixture, mode: .sequential)
        defer { server.stop(); try? FileManager.default.removeItem(at: directory) }
        let prefetcher = prefetcher(cache: cache, server: server, fixture: fixture, log: log)

        prefetcher.update(try request([1, 2, 3]))
        try await waitForPrefetch { prefetcher.completedTrackIDs == [2, 3] }

        // The current song is never fetched; each song was resolved once and
        // landed in the cache at the quality the player will ask for.
        #expect(log.resolved == [2, 3])
        #expect(log.kept.map(\.0) == [2, 3] && log.kept.allSatisfy { $0.1 == "a" })
        let entry = try #require(try await cache.entry(for: 2, requestedQuality: "exhigh", allowsUnblock: false))
        #expect(entry.metadata.byteCount == Int64(fixture.data.count) && entry.metadata.servedQuality == "exhigh")
        #expect(try Data(contentsOf: entry.fileURL) == fixture.data)
        #expect(try await cache.entry(for: 3, requestedQuality: "exhigh", allowsUnblock: false) != nil)
        #expect(try await cache.entry(for: 1, requestedQuality: "exhigh", allowsUnblock: false) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("partial").path).isEmpty)

        // The same window again is a no-op.
        prefetcher.update(try request([1, 2, 3]))
        try await Task.sleep(for: .milliseconds(50))
        #expect(log.resolved == [2, 3])
    }

    @Test func skipsDownloadedCachedAndPendingSongsAndRevisitsAfterCancellation() async throws {
        let fixture = try OfflineAudioFixture(), (cache, directory) = makeCache(), log = Log()
        let server = try await AudioFixtureServer(fixture: fixture, mode: .sequential)
        defer { server.stop(); try? FileManager.default.removeItem(at: directory) }
        let prefetcher = prefetcher(cache: cache, server: server, fixture: fixture, log: log, downloaded: [2])

        prefetcher.update(try request([1, 2, 3, 4], pending: [3]))
        try await waitForPrefetch { prefetcher.completedTrackIDs == [4] }
        #expect(log.resolved == [4])

        // The pending download was cancelled: the idle window picks it up
        // with the same accounting, and the cached song is not fetched again.
        prefetcher.update(try request([1, 2, 3, 4]))
        try await waitForPrefetch { prefetcher.completedTrackIDs == [4, 3] }
        #expect(log.resolved == [4, 3])
        #expect(try await cache.entry(for: 3, requestedQuality: "exhigh", allowsUnblock: false) != nil)
    }

    @Test func aSongOverTheWindowBudgetEndsTheWindowWithoutATransfer() async throws {
        let fixture = try OfflineAudioFixture(), (cache, directory) = makeCache(), log = Log()
        let server = try await AudioFixtureServer(fixture: fixture, mode: .sequential)
        defer { server.stop(); try? FileManager.default.removeItem(at: directory) }
        var limits = PrefetchLimits()
        limits.bytes = Int64(fixture.data.count) + 10
        let prefetcher = prefetcher(cache: cache, server: server, fixture: fixture, log: log, limits: limits)

        prefetcher.update(try request([1, 2, 3]))
        try await waitForPrefetch { prefetcher.completedTrackIDs == [2] }
        try await Task.sleep(for: .milliseconds(50))

        #expect(log.resolved == [2, 3])
        #expect(try await cache.entry(for: 3, requestedQuality: "exhigh", allowsUnblock: false) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("partial").path).isEmpty)
    }

    @Test func aSongTheCacheCannotHoldIsSkipped() async throws {
        let fixture = try OfflineAudioFixture(), (cache, directory) = makeCache(), log = Log()
        let server = try await AudioFixtureServer(fixture: fixture, mode: .sequential)
        defer { server.stop(); try? FileManager.default.removeItem(at: directory) }
        let prefetcher = prefetcher(cache: cache, server: server, fixture: fixture, log: log, limitMB: 1, byteCount: 2_000_000)

        prefetcher.update(try request([1, 2, 3]))
        try await waitForPrefetch { log.resolved == [2, 3] }
        try await Task.sleep(for: .milliseconds(50))

        #expect(prefetcher.completedTrackIDs.isEmpty)
        #expect(try await cache.usage() == .zero)
    }

    @Test func replacingTheQueueDropsTheTransferInFlight() async throws {
        let fixture = try OfflineAudioFixture(), (cache, directory) = makeCache(), log = Log()
        let slow = try await AudioFixtureServer(fixture: fixture, mode: .sequential, delay: 0.2)
        defer { slow.stop(); try? FileManager.default.removeItem(at: directory) }
        let prefetcher = prefetcher(cache: cache, server: slow, fixture: fixture, log: log)

        prefetcher.update(try request([1, 2]))
        try await waitForPrefetch { log.resolved == [2] }
        prefetcher.update(nil)
        try await Task.sleep(for: .milliseconds(300))

        #expect(prefetcher.completedTrackIDs.isEmpty)
        #expect(log.kept.isEmpty)
        #expect(try await cache.entry(for: 2, requestedQuality: "exhigh", allowsUnblock: false) == nil)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("partial").path)) ?? []).isEmpty)
    }
}
