import Foundation
import Testing
@testable import KumoneCore

private actor ReadinessGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}

@Suite("Commute planning and continuous offline time", .timeLimit(.minutes(1)))
struct CommutePreparationTests {
    private func track(_ id: Int, seconds: Double) throws -> Track {
        try JSONDecoder().decode(Track.self, from: JSONSerialization.data(withJSONObject: ["id": id, "name": "Track \(id)", "dt": seconds * 1000]))
    }

    @Test func selectsOnlyThePrefixNeededFromTheCurrentPosition() throws {
        let tracks = try [track(1, seconds: 240), track(2, seconds: 600), track(3, seconds: 700),
                          track(4, seconds: 800), track(5, seconds: 900), track(6, seconds: 1000), track(7, seconds: 200)]
        let plan = try #require(CommutePlanner.plan(.init(scope: "a", tracks: tracks, quality: "exhigh"), progress: 200))
        #expect(plan.tracks.map(\.id) == [1, 2, 3, 4, 5, 6])
        #expect(plan.preparation.firstTrackOffset == 200)
        #expect(plan.plannedSeconds == 4040)
        #expect(plan.preparation.targetSeconds == 3600)
        #expect(!plan.stoppedAtUnknownDuration)
    }

    @Test func preservesRepeatedOccurrencesWithoutExtendingAnInfiniteLoop() throws {
        let first = try track(1, seconds: 1800), second = try track(2, seconds: 1800)
        let plan = try #require(CommutePlanner.plan(.init(scope: "a", tracks: [first, second, first], quality: "exhigh"), progress: 900))
        #expect(plan.tracks.map(\.id) == [1, 2, 1])
        #expect(plan.plannedSeconds == 4500)
        let short = try #require(CommutePlanner.plan(.init(scope: "a", tracks: [first], quality: "exhigh"), progress: 900))
        #expect(short.tracks.count == 1 && short.plannedSeconds == 900)
        let queue = [first, second, first]
        let next = PlaybackQueuePlan.next(queue: queue, currentIndex: 0, inserted: [], fm: [], isFM: false, repeatAll: true)
        #expect(CommutePlanner.orderedTracks(current: first, next: next, currentQueueIndex: 0).map(\.id) == [1, 2, 1])
        let one = PlaybackQueuePlan.next(queue: [first], currentIndex: 0, inserted: [], fm: [], isFM: false, repeatAll: true)
        #expect(CommutePlanner.orderedTracks(current: first, next: one, currentQueueIndex: 0).count == 1)
    }

    @Test func stopsAtUnknownDurationAndSkipsAnEndedCurrentSong() throws {
        let first = try track(1, seconds: 120), unknown = try track(2, seconds: 0), last = try track(3, seconds: 300)
        let short = try #require(CommutePlanner.plan(.init(scope: "a", tracks: [first, unknown, last], quality: "exhigh"), progress: 20))
        #expect(short.tracks.map(\.id) == [1] && short.stoppedAtUnknownDuration)
        #expect(short.plannedSeconds == 100)
        let ended = try #require(CommutePlanner.plan(.init(scope: "a", tracks: [first, last], quality: "exhigh"), progress: 120))
        #expect(ended.tracks.map(\.id) == [3] && ended.preparation.firstTrackOffset == 0)
        #expect(CommutePlanner.plan(.init(scope: nil, tracks: [first], quality: "exhigh"), progress: 0) == nil)
        #expect(CommutePlanner.plan(.init(scope: "a", tracks: [unknown, last], quality: "exhigh"), progress: 0) == nil)
    }

    @Test func legacyCollectionsDecodeWithoutPreparationMetadata() throws {
        let data = Data("{\"id\":\"playlist:1\",\"accountScope\":\"a\",\"name\":\"Saved\",\"tracks\":[],\"savedAt\":0}".utf8)
        let saved = try JSONDecoder().decode(DownloadCollection.self, from: data)
        #expect(saved.preparation == nil)
    }

    @Test func continuousReadinessStopsAtFirstMissingFileAndDoesNotMarkSongsPlayed() async throws {
        let fixture = try OfflineAudioFixture(), store = fixture.store()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        var ids: [String] = []
        for id in 1...3 {
            let descriptor = OfflineAudioDescriptor(identity: .init(accountScope: "a", trackID: id, source: "netease", quality: "exhigh",
                format: .mp3, contentMD5: fixture.descriptor.identity.contentMD5), byteCount: fixture.descriptor.byteCount, duration: 3)
            let writer = UUID()
            try await store.begin(descriptor, writer: writer)
            try await store.write(id == 2 ? fixture.data.prefix(1000) : fixture.data, at: 0, id: descriptor.identity.id, writer: writer)
            if id != 2 { try await store.finalize(id: descriptor.identity.id, writer: writer) }
            await store.releaseWriter(id: descriptor.identity.id, writer: writer)
            ids.append(descriptor.identity.id)
        }
        let gap = try await store.listeningReadiness(accountScope: "a", trackIDs: [1, 2, 3], quality: "exhigh")
        #expect(gap.durations == [3] && gap.remaining(after: 1) == 2)
        let repeats = try await store.listeningReadiness(accountScope: "a", trackIDs: [1, 3, 1], quality: "exhigh")
        #expect(repeats.remaining(after: 1) == 8)
        #expect(try await store.record(id: ids[0])?.lastPlayed == nil)
        #expect(try await store.record(id: ids[2])?.lastPlayed == nil)
        let wrongAccount = try await store.listeningReadiness(accountScope: "b", trackIDs: [1, 3], quality: "exhigh")
        #expect(wrongAccount.remaining(after: 0) == 0)
        _ = try await store.clearMusicCache()
        let removed = try await store.listeningReadiness(accountScope: "a", trackIDs: [1, 3], quality: "exhigh")
        #expect(removed.remaining(after: 0) == 0)
    }

    @Test @MainActor func lateMeasurementCannotReplaceAnotherAccountsReadiness() async throws {
        let first = OfflineListeningSnapshot(scope: "a", tracks: try [track(1, seconds: 3)], quality: "exhigh")
        let second = OfflineListeningSnapshot(scope: "b", tracks: try [track(2, seconds: 3)], quality: "exhigh")
        let gate = ReadinessGate()
        let model = OfflineQueueReadinessModel(reader: { snapshot in
            if snapshot.scope == "a" { await gate.wait(); return .init(durations: [3], totalTracks: 1) }
            return .init(durations: [], totalTracks: 1)
        })
        let old = Task { await model.refresh(first) }
        for _ in 0..<200 where !(await gate.entered) { await Task.yield() }
        #expect(await gate.entered)
        await model.refresh(second)
        await gate.open()
        await old.value
        #expect(model.value(for: first) == nil)
        #expect(model.value(for: second)?.remaining(after: 0) == 0)
        let cancelledModel = OfflineQueueReadinessModel(reader: { snapshot in
            .init(durations: snapshot.scope == "a" ? [3] : [], totalTracks: 1)
        })
        await cancelledModel.refresh(second)
        let cancelled = Task { await cancelledModel.refresh(first) }
        cancelled.cancel()
        await cancelled.value
        #expect(cancelledModel.value(for: second)?.remaining(after: 0) == 0)
    }
}
