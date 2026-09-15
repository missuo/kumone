import AVFoundation
import Combine
import Foundation

enum PlaybackCacheResolver {
    /// Only cache the exact version being played, after a separate download
    /// eligibility check. A trial, alternate source or quality mismatch streams.
    static func resolve(data: SongURLData, track: Track, scope: String,
                        grant: (Track, String, String) async throws -> OfflineAudioResource = {
                            try await NeteaseAPI.songDownloadResource(track: $0, level: $1, accountScope: $2)
                        }) async throws -> OfflineAudioResource {
        let playing = try NeteaseAPI.downloadResource(data: data, track: track, accountScope: scope)
        let allowed = try await grant(track, playing.descriptor.identity.quality, scope)
        guard playing.descriptor == allowed.descriptor else { throw OfflineAudioError.unavailable }
        return playing
    }
}

@MainActor
final class PlaybackCacheSession {
    let transfer: AudioTransferCoordinator
    let loader: CachingAssetResourceLoader
    let fallbackURL: URL
    private let store: OfflineStore
    private var downloadConsumers = 0
    private var completion: Task<Void, Never>?
    private var closing: Task<Void, Never>?
    private(set) var isClosed = false

    init(resource: OfflineAudioResource, store: OfflineStore, context: MusicCacheContext,
         fallbackURL: URL, onFailure: @escaping @Sendable () -> Void) {
        transfer = AudioTransferCoordinator(resource: resource, store: store, cacheContext: context)
        loader = CachingAssetResourceLoader(transfer: transfer, onFailure: onFailure)
        self.fallbackURL = fallbackURL
        self.store = store
    }

    func updateCompletion(allowed: Bool) async {
        guard !isClosed else { return }
        await transfer.setCompletionAllowed(allowed)
        guard !isClosed else { return }
        if !allowed { completion?.cancel(); completion = nil }
        else if completion == nil {
            completion = Task { [transfer] in try? await transfer.download(forCompletion: true) }
        }
    }

    func close() async {
        if let closing { await closing.value; return }
        isClosed = true
        completion?.cancel()
        let task = Task { [self, completion] in
            // Leaving the song ends the player consumer. A user-requested
            // download may still own this same transfer until it finishes.
            await loader.close(closeTransfer: false)
            await completion?.value
            if downloadConsumers == 0 { await transfer.close() }
        }
        closing = task
        await task.value
    }

    func finishForDownload(owner: String, allowsMetered: Bool) async throws -> OfflineAudioDescriptor {
        guard !isClosed else { throw CancellationError() }
        downloadConsumers += 1
        do {
            try await transfer.download(allowsMetered: allowsMetered)
            try Task.checkCancellation()
            let descriptor = transfer.resource.descriptor
            try await store.retain(id: descriptor.identity.id, owner: owner)
            await releaseDownloadConsumer()
            return descriptor
        } catch {
            await releaseDownloadConsumer()
            throw error
        }
    }

    private func releaseDownloadConsumer() async {
        downloadConsumers -= 1
        if isClosed, downloadConsumers == 0 { await transfer.close() }
    }
}

@MainActor
final class PlaybackCacheController: ObservableObject {
    static let shared = PlaybackCacheController()
    @Published private(set) var capacity: MusicCacheCapacity?
    private(set) var active: PlaybackCacheSession?
    private var closing: Task<Void, Never>?
    private var generation = 0
    private var observations: Set<AnyCancellable> = []
    private var network = DownloadNetworkState.unknown
    private var protectedTrack: (scope: String, id: Int)?

    private init() {
        DownloadManager.shared.$network.removeDuplicates().sink { [weak self] network in
            self?.network = network
            self?.updateCompletion()
        }.store(in: &observations)
        NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange).receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.updateCompletion()
        }.store(in: &observations)
        NotificationCenter.default.publisher(for: .musicCachePolicyChanged).sink { [weak self] _ in
            if SettingsManager.shared.musicCachePolicy == .disabled {
                PlayerService.shared.stopAutomaticCaching()
                if self?.active != nil { self?.stop() }
            }
            self?.updateCompletion()
            Task { await self?.reconcile() }
        }.store(in: &observations)
    }

    private var context: MusicCacheContext {
        let account = AccountStore.shared
        let liked = account.offlineScope.map { [$0: account.likedTrackIDs] } ?? [:]
        return .init(policy: SettingsManager.shared.musicCachePolicy,
                     protectedAssetIDs: DownloadManager.shared.storageAssetIDs,
                     protectedTracks: protectedTrack.map { [$0.scope: [$0.id]] } ?? [:], likedTracks: liked)
    }

    func protect(trackID: Int?, scope: String?) {
        protectedTrack = scope.flatMap { scope in trackID.map { (scope, $0) } }
    }

    func begin(resource: OfflineAudioResource, fallbackURL: URL,
               onFailure: @escaping @Sendable () -> Void) async -> PlaybackCacheSession? {
        let ticket = generation
        await closing?.value
        guard ticket == generation, active == nil, context.policy != .disabled else { return nil }
        let candidate = PlaybackCacheSession(resource: resource, store: .shared, context: context,
                                             fallbackURL: fallbackURL, onFailure: onFailure)
        active = candidate
        do {
            try await candidate.transfer.prepare()
            guard ticket == generation, active === candidate, !candidate.isClosed, context.policy != .disabled else {
                if active === candidate { active = nil }
                await candidate.close()
                return nil
            }
            return candidate
        } catch {
            if active === candidate { active = nil }
            await candidate.close()
            return nil
        }
    }

    func startCompletion(for session: PlaybackCacheSession) {
        guard active === session else { return }
        updateCompletion()
    }

    @discardableResult
    func stop() -> Task<Void, Never> {
        generation += 1
        let previous = active
        active = nil
        let pending = closing
        let task = Task {
            await pending?.value
            await previous?.close()
        }
        closing = task
        Task { await task.value; await reconcile() }
        return task
    }

    /// A download requested during playback can finish the same transfer.
    /// Its caller retains the file before this method releases playback.
    func completeForDownload(resource: OfflineAudioResource, owner: String, allowsMetered: Bool) async throws -> OfflineAudioDescriptor? {
        guard let session = active, !session.isClosed else { return nil }
        let descriptor = session.transfer.resource.descriptor
        guard descriptor == resource.descriptor else { return nil }
        return try await session.finishForDownload(owner: owner, allowsMetered: allowsMetered)
    }

    func reconcile() async {
        let requested = context
        let measured = try? await OfflineStore.shared.reconcileCache(requested)
        if requested.policy == SettingsManager.shared.musicCachePolicy { capacity = measured }
    }

    private func updateCompletion() {
        guard let session = active else { return }
        let allowed = Self.permitsCompletion(network: network, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
            && SettingsManager.shared.musicCachePolicy != .disabled
        Task { await session.updateCompletion(allowed: allowed) }
    }

    nonisolated static func permitsCompletion(network: DownloadNetworkState, lowPower: Bool) -> Bool {
        network.connected && !network.expensive && !network.constrained && !lowPower
    }
}
