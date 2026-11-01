#if os(macOS)
import Foundation
import Testing
@testable import KumoneCore

/// Deliberately ignores cancellation until released, so old and new picks
/// can finish in a deterministic order.
@MainActor
private final class HeldQueueAcquisition<Value> {
    private var pending: [Int: CheckedContinuation<Value, Never>] = [:]
    private(set) var requests = 0

    func value() async -> Value {
        requests += 1
        let request = requests
        return await withCheckedContinuation { pending[request] = $0 }
    }

    func waitForRequests(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while requests < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(requests == count)
    }

    func finish(_ request: Int, returning value: Value) throws {
        let held = pending.removeValue(forKey: request)
        let continuation = try #require(held)
        continuation.resume(returning: value)
    }
}

@MainActor
struct QueueOrderAcquisitionTests {
    private func track(_ id: Int) throws -> Track {
        let json = Data("""
        {"id":\(id),"name":"Track \(id)","ar":[],"al":{"id":1,"name":"Album"},"dt":180000}
        """.utf8)
        return try JSONDecoder().decode(Track.self, from: json)
    }

    @Test func cancelledScanReleasesItsSlotWithoutMarkingTracksScanned() async throws {
        let scan = HeldQueueAcquisition<[Int: TrackAnalysis]>()
        let selector = QueueOrderSelector(loadAnalyses: { _ in await scan.value() })
        let tracks = [try track(1)]
        #expect(selector.acquire(remaining: tracks, mayDownload: false) == .acquiring)
        let old = selector.acquisitionTasksForTesting()
        try await scan.waitForRequests(1)
        old.forEach { $0.cancel() }
        try scan.finish(1, returning: [:])
        for task in old { await task.value }
        #expect(selector.acquisitionTasksForTesting().isEmpty)
        // A cancelled disk lookup has not consumed the scan for this track.
        #expect(selector.acquire(remaining: tracks, mayDownload: false) == .acquiring)
        let retry = selector.acquisitionTasksForTesting()
        try await scan.waitForRequests(2)
        try scan.finish(2, returning: [:])
        for task in retry { await task.value }
        #expect(selector.acquire(remaining: tracks, mayDownload: false) == .deferred)
    }

    @Test func lateScanCannotClearOrPublishIntoANewPick() async throws {
        let scan = HeldQueueAcquisition<[Int: TrackAnalysis]>()
        let selector = QueueOrderSelector(loadAnalyses: { _ in await scan.value() })
        #expect(selector.acquire(remaining: [try track(1)]) == .acquiring)
        let old = selector.acquisitionTasksForTesting()
        try await scan.waitForRequests(1)
        selector.beginPick()
        #expect(selector.acquire(remaining: [try track(2)]) == .acquiring)
        let current = selector.acquisitionTasksForTesting()
        try await scan.waitForRequests(2)
        try scan.finish(1, returning: [:])
        for task in old { await task.value }
        #expect(selector.acquisitionTasksForTesting().count == 1)
        #expect(selector.acquire(remaining: [try track(2)], mayDownload: false) == .acquiring)
        #expect(scan.requests == 2)
        try scan.finish(2, returning: [:])
        for task in current { await task.value }
        #expect(selector.acquire(remaining: [try track(2)], mayDownload: false) == .deferred)
        // The discarded scan must not mark the old pick's tracks as scanned.
        #expect(selector.acquire(remaining: [try track(1)], mayDownload: false) == .acquiring)
        let next = selector.acquisitionTasksForTesting()
        try await scan.waitForRequests(3)
        try scan.finish(3, returning: [:])
        for task in next { await task.value }
    }

    @Test(arguments: [false, true])
    func fetchFailureReleasesTheSlotAndOnlyRealFailuresRefuseTheTrack(cancelled: Bool) async throws {
        let selector = QueueOrderSelector(fetchAnalysis: { _ in
            if cancelled { throw CancellationError() }
            throw URLError(.cannotConnectToHost)
        })
        let tracks = [try track(1)]
        selector.markScannedForTesting(tracks)
        var callbacks = 0
        selector.onCandidateReady = { callbacks += 1 }
        #expect(selector.acquire(remaining: tracks) == .acquiring)
        for task in selector.acquisitionTasksForTesting() { await task.value }
        #expect(selector.acquisitionTasksForTesting().isEmpty)
        #expect(selector.isSettled(tracks) == !cancelled)
        #expect(callbacks == (cancelled ? 0 : 1))
        #expect(selector.acquire(remaining: tracks, mayDownload: false)
                == (cancelled ? .deferred : .exhausted))
    }

    @Test func lateCancelledFetchCannotRefuseATrackOrClearItsReplacement() async throws {
        let fetch = HeldQueueAcquisition<Result<QueueOrderSelector.ScoringFetch, Error>>()
        let selector = QueueOrderSelector(fetchAnalysis: { _ in try await fetch.value().get() })
        let tracks = [try track(1)]
        selector.markScannedForTesting(tracks)
        #expect(selector.acquire(remaining: tracks) == .acquiring)
        let old = selector.acquisitionTasksForTesting()
        try await fetch.waitForRequests(1)
        selector.beginPick()
        #expect(selector.acquire(remaining: tracks) == .acquiring)
        let current = selector.acquisitionTasksForTesting()
        try await fetch.waitForRequests(2)
        try fetch.finish(1, returning: .success(.refused("late result")))
        for task in old { await task.value }
        #expect(!selector.isSettled(tracks))
        #expect(selector.acquisitionTasksForTesting().count == 1)
        #expect(selector.acquire(remaining: tracks) == .acquiring)
        #expect(fetch.requests == 2)
        try fetch.finish(2, returning: .failure(CancellationError()))
        for task in current { await task.value }
        #expect(selector.acquire(remaining: tracks, mayDownload: false) == .deferred)
        #expect(!selector.isSettled(tracks))
    }

    @Test func aCancelledFetchResultDoesNotEnterTheRefusalList() async throws {
        let fetch = HeldQueueAcquisition<QueueOrderSelector.ScoringFetch>()
        let selector = QueueOrderSelector(fetchAnalysis: { _ in await fetch.value() })
        let tracks = [try track(1)]
        selector.markScannedForTesting(tracks)
        #expect(selector.acquire(remaining: tracks) == .acquiring)
        let pending = selector.acquisitionTasksForTesting()
        try await fetch.waitForRequests(1)
        pending.forEach { $0.cancel() }
        try fetch.finish(1, returning: .refused("cancelled transport"))
        for task in pending { await task.value }
        #expect(selector.acquisitionTasksForTesting().isEmpty)
        #expect(!selector.isSettled(tracks))
        #expect(selector.acquire(remaining: tracks, mayDownload: false) == .deferred)
    }

    @Test func callbackCanStartTheNextFetchWithoutLosingItsOwnership() async throws {
        let fetch = HeldQueueAcquisition<QueueOrderSelector.ScoringFetch>()
        let selector = QueueOrderSelector(fetchAnalysis: { _ in await fetch.value() })
        let tracks = [try track(1), try track(2)]
        selector.markScannedForTesting(tracks)
        var callbackResults: [QueueOrderSelector.Acquisition?] = []
        selector.onCandidateReady = { [weak selector] in
            callbackResults.append(selector?.acquire(remaining: tracks))
        }
        #expect(selector.acquire(remaining: tracks) == .acquiring)
        let first = selector.acquisitionTasksForTesting()
        try await fetch.waitForRequests(1)
        try fetch.finish(1, returning: .refused("unavailable"))
        for task in first { await task.value }
        try await fetch.waitForRequests(2)
        #expect(callbackResults == [.acquiring])
        #expect(selector.acquisitionTasksForTesting().count == 1)
        let second = selector.acquisitionTasksForTesting()
        try fetch.finish(2, returning: .refused("unavailable"))
        for task in second { await task.value }
        #expect(callbackResults == [.acquiring, .exhausted])
        #expect(selector.acquisitionTasksForTesting().isEmpty)
    }
}
#endif
