import Foundation

struct PlaybackQueueCandidate: Equatable {
    enum Origin: Equatable { case inserted(Int), queue(Int), fm(Int) }
    let track: Track
    let origin: Origin
}

/// Stamped on the playback queue when it is installed straight from resolving a
/// place, and dropped again the moment the queue changes. Replaying the place
/// you are already listening to skips the refetch (and works offline), but only
/// while the queue is still exactly what that place resolved to.
struct ResolvedQueueToken: Equatable {
    let context: PlayContext
    let resolvedAt: Date

    func reusable(for context: PlayContext, source: PlaySource, isFM: Bool,
                  queueIsEmpty: Bool, now: Date = Date()) -> Bool {
        guard self.context == context, !isFM, !queueIsEmpty,
              context.source != .none, source == context.source else { return false }
        // Daily recommendations are a different list tomorrow.
        guard context.kind == .daily else { return true }
        return Calendar.current.isDate(resolvedAt, inSameDayAs: now)
    }
}

enum PlaybackQueuePlan {
    /// One bounded pass through the actual order. The original queue is never
    /// sorted or filtered to produce an offline/prefetch view of it.
    static func next(queue: [Track], currentIndex: Int, inserted: [Track], fm: [Track],
                     isFM: Bool, repeatAll: Bool, limit: Int = .max) -> [PlaybackQueueCandidate] {
        guard limit > 0 else { return [] }
        if isFM { return fm.prefix(limit).enumerated().map { .init(track: $0.element, origin: .fm($0.offset)) } }
        var result = inserted.prefix(limit).enumerated().map { PlaybackQueueCandidate(track: $0.element, origin: .inserted($0.offset)) }
        let start = min(queue.count, max(0, currentIndex + 1))
        for index in queue.indices.dropFirst(start).prefix(limit - result.count) {
            result.append(.init(track: queue[index], origin: .queue(index)))
        }
        if repeatAll, queue.indices.contains(currentIndex) {
            for index in (0...currentIndex).prefix(limit - result.count) {
                result.append(.init(track: queue[index], origin: .queue(index)))
            }
        }
        return result
    }
}

struct PrefetchLimits: Equatable {
    var tracks = 5
    var seconds: TimeInterval = 20 * 60
    var bytes: Int64 = 100_000_000

    func window(_ candidates: [Track]) -> [Track] {
        var result: [Track] = []
        var duration: TimeInterval = 0
        for track in candidates {
            guard result.count < tracks, track.duration.isFinite, track.duration > 0,
                  duration + track.duration <= seconds else { break }
            result.append(track)
            duration += track.duration
        }
        return result
    }
}

struct OfflineQueueSelection {
    let candidate: PlaybackQueueCandidate
    let lease: OfflinePlaybackLease
    let skipped: Int
}

enum OfflineQueueSelector {
    static func firstAvailable(_ candidates: [PlaybackQueueCandidate], scope: String, quality: String,
                               store: OfflineStore) async throws -> OfflineQueueSelection? {
        for (skipped, candidate) in candidates.enumerated() {
            try Task.checkCancellation()
            if let lease = try await store.acquire(accountScope: scope, trackID: candidate.track.id, preferredQuality: quality) {
                if Task.isCancelled { try? await store.release(lease); throw CancellationError() }
                return .init(candidate: candidate, lease: lease, skipped: skipped)
            }
        }
        return nil
    }
}

struct OfflinePlaybackIssue: Identifiable {
    enum Kind { case missingTrack, emptyQueue }
    let id = UUID()
    let kind: Kind
    let trackName: String?
}
