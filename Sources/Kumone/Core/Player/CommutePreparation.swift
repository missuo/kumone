import Foundation

struct OfflineListeningSnapshot: Equatable {
    let scope: String?
    let tracks: [Track]
    let quality: String
}

struct OfflineListeningReadiness: Equatable {
    let durations: [TimeInterval]
    let totalTracks: Int

    func remaining(after progress: TimeInterval) -> TimeInterval {
        guard let current = durations.first else { return 0 }
        let offset = progress.isFinite ? min(current, max(0, progress)) : 0
        return max(0, durations.reduce(0, +) - offset)
    }
}

struct CommutePreparation: Codable, Equatable {
    let targetSeconds: TimeInterval
    let firstTrackOffset: TimeInterval
    let quality: String
}

struct CommutePlan: Equatable {
    let scope: String
    let tracks: [Track]
    let preparation: CommutePreparation
    let plannedSeconds: TimeInterval
    let stoppedAtUnknownDuration: Bool
}

enum CommutePlanner {
    static func orderedTracks(current: Track?, next: [PlaybackQueueCandidate], currentQueueIndex: Int?) -> [Track] {
        guard let current else { return [] }
        // List repeat must not manufacture another occurrence of the current
        // queue slot. Explicit duplicates at other positions remain intact.
        let following = next.filter { candidate in
            guard case .queue(let index) = candidate.origin else { return true }
            return index != currentQueueIndex
        }
        return [current] + following.map(\.track)
    }

    /// Freeze the saved playback order. Repeated occurrences count as listening
    /// time, while DownloadManager still stores each audio representation once.
    static func plan(_ snapshot: OfflineListeningSnapshot, progress: TimeInterval,
                     target: TimeInterval = 60 * 60) -> CommutePlan? {
        guard let scope = snapshot.scope, target.isFinite, target > 0 else { return nil }
        var tracks: [Track] = []
        var seconds: TimeInterval = 0
        var offset: TimeInterval = 0
        var unknown = false
        for (index, track) in snapshot.tracks.enumerated() {
            guard track.duration.isFinite, track.duration > 0 else { unknown = true; break }
            let consumed = index == 0 && progress.isFinite ? min(track.duration, max(0, progress)) : 0
            let remaining = track.duration - consumed
            guard remaining > 0 else { continue }
            if tracks.isEmpty { offset = consumed }
            tracks.append(track)
            seconds += remaining
            if seconds >= target { break }
        }
        guard !tracks.isEmpty else { return nil }
        return .init(scope: scope, tracks: tracks,
                     preparation: .init(targetSeconds: target, firstTrackOffset: offset, quality: snapshot.quality),
                     plannedSeconds: seconds, stoppedAtUnknownDuration: unknown)
    }

    static func matches(_ collection: DownloadCollection, plan: CommutePlan) -> Bool {
        collection.accountScope == plan.scope && collection.preparation?.quality == plan.preparation.quality
            && collection.preparation?.targetSeconds == plan.preparation.targetSeconds
            && collection.tracks.map(\.id) == plan.tracks.map(\.id)
    }
}

@MainActor
final class OfflineQueueReadinessModel: ObservableObject {
    @Published private(set) var readiness: OfflineListeningReadiness?
    @Published private(set) var isLoading = false
    @Published private(set) var failed = false
    private let read: (OfflineListeningSnapshot) async throws -> OfflineListeningReadiness
    private var ticket = UUID()
    private var snapshot: OfflineListeningSnapshot?

    init(store: OfflineStore = .shared,
         reader: ((OfflineListeningSnapshot) async throws -> OfflineListeningReadiness)? = nil) {
        read = reader ?? { snapshot in
            guard let scope = snapshot.scope else { throw OfflineAudioError.unavailable }
            return try await store.listeningReadiness(accountScope: scope, trackIDs: snapshot.tracks.map(\.id), quality: snapshot.quality)
        }
    }

    func value(for expected: OfflineListeningSnapshot) -> OfflineListeningReadiness? {
        snapshot == expected ? readiness : nil
    }

    func refresh(_ next: OfflineListeningSnapshot) async {
        guard !Task.isCancelled else { return }
        let request = UUID()
        ticket = request
        if snapshot != next { readiness = nil }
        snapshot = next
        isLoading = true
        failed = false
        do {
            guard next.scope != nil else { throw OfflineAudioError.unavailable }
            let result = try await read(next)
            guard ticket == request, !Task.isCancelled else { if ticket == request { isLoading = false }; return }
            readiness = result
        } catch {
            guard ticket == request else { return }
            readiness = nil
            failed = !(error is CancellationError)
        }
        if ticket == request { isLoading = false }
    }
}

enum ListeningDuration {
    static func text(_ seconds: TimeInterval) -> String {
        let value = seconds.isFinite ? min(Double(Int.max / 2), max(0, seconds)) : 0
        if value > 0, value < 1 { return String(localized: "不足 1 秒") }
        if value < 60 { return String(localized: "\(Int(value.rounded(.down))) 秒") }
        return String(localized: "\(Int((value / 60).rounded(.down))) 分钟")
    }
}

extension Notification.Name {
    static let offlineAvailabilityChanged = Notification.Name("Kumone.offlineAvailabilityChanged")
}
