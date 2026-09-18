import Foundation

struct QueuePrefetchRequest: Equatable {
    let scope: String
    let currentTrackID: Int
    let tracks: [Track]
    let quality: String
    let context: MusicCacheContext
    let pendingDownloadTrackIDs: Set<Int>

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.scope == rhs.scope && lhs.currentTrackID == rhs.currentTrackID && lhs.tracks == rhs.tracks
            && lhs.quality == rhs.quality && lhs.context == rhs.context
    }
}

/// A single bounded worker. Every await is followed by a generation check so
/// late URL resolutions cannot start work for a replaced queue or account.
@MainActor
final class QueuePrefetcher {
    typealias Resolver = (Track, String, String) async throws -> OfflineAudioResource
    private let store: OfflineStore
    private let metadata: OfflineMetadataStore
    private let resolver: Resolver
    private let metadataFetcher: (Track, String) async -> Void
    private let limits: PrefetchLimits
    private var request: QueuePrefetchRequest?
    private var generation = 0
    private var worker: Task<Void, Never>?
    private var active: PlaybackCacheSession?
    private var closing: Task<Void, Never>?
    private var pendingDownloadTrackIDs: Set<Int> = []
    private(set) var completedTrackIDs: [Int] = []

    init(store: OfflineStore, metadata: OfflineMetadataStore, limits: PrefetchLimits = .init(),
         resolver: @escaping Resolver = { try await NeteaseAPI.songDownloadResource(track: $0, level: $1, accountScope: $2) },
         metadataFetcher: ((Track, String) async -> Void)? = nil) {
        self.store = store
        self.metadata = metadata
        self.limits = limits
        self.resolver = resolver
        self.metadataFetcher = metadataFetcher ?? { await metadata.fetchDisplayData(track: $0, scope: $1) }
    }

    func update(_ next: QueuePrefetchRequest?) {
        // Pending explicit downloads are handled by the background session.
        let pending = next?.pendingDownloadTrackIDs ?? []
        let pendingChanged = pending != pendingDownloadTrackIDs
        pendingDownloadTrackIDs = pending
        guard next != request || (pendingChanged && active == nil && next != nil) else { return }
        let stopped = cancel()
        request = next
        completedTrackIDs = []
        guard let next, next.context.policy != .disabled else { return }
        let ticket = generation
        worker = Task { [weak self] in
            await stopped.value
            guard let self, self.isCurrent(ticket) else { return }
            await self.run(next, ticket: ticket)
        }
    }

    @discardableResult
    func cancel() -> Task<Void, Never> {
        generation += 1
        request = nil
        worker?.cancel()
        worker = nil
        let session = active
        active = nil
        let previous = closing
        let task = Task {
            await previous?.value
            await session?.transfer.setCompletionAllowed(false)
            await session?.close()
        }
        closing = task
        return task
    }

    func prepareForBackgroundDownload(_ resource: OfflineAudioResource) async {
        if let active, active.transfer.resource.descriptor == resource.descriptor {
            await cancel().value
        } else { await closing?.value }
    }

    private func isCurrent(_ ticket: Int) -> Bool { ticket == generation && !Task.isCancelled }

    private func run(_ request: QueuePrefetchRequest, ticket: Int) async {
        var bytes: Int64 = 0
        var seen: Set<Int> = [request.currentTrackID]
        let tracks = limits.window(request.tracks)
        var context = request.context
        context.isPrefetch = true
        context.protectedTracks[request.scope, default: []].formUnion(tracks.map(\.id))
        for track in tracks {
            guard isCurrent(ticket) else { return }
            guard seen.insert(track.id).inserted else { continue }
            do {
                if let local = try await store.availableDescriptor(accountScope: request.scope, trackID: track.id, preferredQuality: request.quality) {
                    guard isCurrent(ticket), local.byteCount <= limits.bytes - bytes else { return }
                    bytes += local.byteCount
                    continue
                }
                guard isCurrent(ticket) else { return }
                guard !pendingDownloadTrackIDs.contains(track.id) else { continue }
                let resource = try await resolver(track, request.quality, request.scope)
                guard isCurrent(ticket) else { return }
                guard !pendingDownloadTrackIDs.contains(track.id) else { continue }
                try resource.descriptor.validate()
                guard isCurrent(ticket), resource.descriptor.identity.accountScope == request.scope,
                      resource.descriptor.identity.trackID == track.id,
                      resource.descriptor.byteCount <= limits.bytes - bytes else { return }
                bytes += resource.descriptor.byteCount
                let session = PlaybackCacheSession(resource: resource, store: store, context: context,
                                                    fallbackURL: resource.url, onFailure: {})
                active = session
                do {
                    try await session.transfer.prepare()
                    guard isCurrent(ticket) else { await session.close(); return }
                    try await session.transfer.download(forCompletion: true)
                    guard isCurrent(ticket) else { await session.close(); return }
                    try await metadata.save(track: track, scope: request.scope)
                    await metadataFetcher(track, request.scope)
                    if isCurrent(ticket) { completedTrackIDs.append(track.id) }
                    await session.close()
                    if active === session { active = nil }
                } catch {
                    await session.close()
                    if active === session { active = nil }
                    // A capacity or transport failure ends this window; it
                    // must not repeatedly evict/retry on a playback timer.
                    return
                }
            } catch {
                guard isCurrent(ticket) else { return }
                if error is URLError { return }
                // An unavailable song still consumes its position in the
                // bounded window; later eligible songs may be prepared.
            }
        }
    }
}
