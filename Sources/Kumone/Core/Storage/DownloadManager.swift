import Combine
import Foundation
import Network
#if os(iOS)
import UIKit
#endif

@MainActor
final class DownloadProgress: ObservableObject {
    struct Value { let received: Int64; let expected: Int64 }
    @Published var values: [UUID: Value] = [:]

    func fraction(for job: DownloadJob) -> Double? {
        if [.verifying, .complete].contains(job.status) { return 1 }
        let value = values[job.id]
        let expected = max(value?.expected ?? 0, job.expectedBytes)
        guard expected > 0 else { return nil }
        return min(1, max(0, Double(value?.received ?? job.receivedBytes) / Double(expected)))
    }
}

@MainActor
final class DownloadManager: ObservableObject {
    static let shared: DownloadManager = {
        let root = OfflineStore.shared.directory.appendingPathComponent("downloads", isDirectory: true)
        let manager = DownloadManager(store: .shared, metadata: .shared, persistence: DownloadCatalogStore(directory: root),
                                      transport: BackgroundDownloadTransport(inbox: root.appendingPathComponent("inbox")),
                                      accountScope: AccountStore.shared.offlineScope,
                                      cacheContext: {
                                          let account = AccountStore.shared
                                          return .init(policy: SettingsManager.shared.musicCachePolicy,
                                              likedTracks: account.offlineScope.map { [$0: account.likedTrackIDs] } ?? [:])
                                      },
                                      prepareResource: { await PlaybackCacheController.shared.prepareForBackgroundDownload($0) })
        manager.observeForeground()
        if !KumonePaths.isOfflineUITest { manager.monitorNetwork() }
        Task { await manager.start() }
        return manager
    }()

    typealias Resolver = (Track, String, String) async throws -> OfflineAudioResource
    typealias MetadataFetcher = (Track, String) async -> Void
    @Published private(set) var jobs: [DownloadJob] = []
    @Published private(set) var collections: [DownloadCollection] = []
    @Published private(set) var offlineTracks: [OfflineLibraryTrack] = [] {
        didSet { rebuildDownloadIndex() }
    }
    @Published private(set) var isReady = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var network = DownloadNetworkState.unknown
    private(set) var downloadedTracks: [OfflineLibraryTrack] = []
    private(set) var downloadedTrackIDs: Set<Int> = []
    private(set) var offlineTracksByID: [Int: OfflineLibraryTrack] = [:]
    private(set) var jobsByTrackID: [Int: DownloadJob] = [:]
    private(set) var pendingJobsByTrackID: [Int: DownloadJob] = [:]
    func isDownloaded(trackID: Int) -> Bool { downloadedTrackIDs.contains(trackID) }
    var pendingJobs: [DownloadJob] {
        jobs.filter { !$0.owners.isEmpty && $0.status != .complete && $0.status != .cancelled }
    }

    var storageAssetIDs: Set<String> {
        Set(catalog.jobs.filter { !$0.owners.isEmpty }.flatMap { [$0.assetID, $0.descriptor?.identity.id].compactMap { $0 } })
    }

    var metadataTrackIDs: [String: Set<Int>] {
        var result: [String: Set<Int>] = [:]
        for job in catalog.jobs where !job.owners.isEmpty {
            result[job.accountScope, default: []].insert(job.track.id)
        }
        return result
    }

    func downloadedSongs(in collectionID: String? = nil) -> [Track] {
        guard let collectionID else { return downloadedTracks.map(\.track) }
        guard let collection = collections.first(where: { $0.id == collectionID }) else { return [] }
        let available = Set(downloadedTracks.map(\.id))
        var seen: Set<Int> = []
        return collection.tracks.filter { available.contains($0.id) && seen.insert($0.id).inserted }
    }

    /// Metadata already held by the phone, shared by all playback entry points.
    func localTracks(for context: PlayContext, likedTrackIDs: Set<Int> = []) -> [Track] {
        guard let scope = accountScope else { return [] }
        if let id = context.downloadCollectionID,
           let collection = collections.first(where: { $0.id == id && $0.accountScope == scope }) {
            return collection.tracks
        }
        switch context.kind {
        case .playlist:
            return offlineTracks.map(\.track).filter { likedTrackIDs.contains($0.id) }
        case .album:
            return offlineTracks.map(\.track).filter { $0.album.id == context.id }.sorted { $0.trackNo < $1.trackNo }
        case .artist:
            return offlineTracks.map(\.track).filter { $0.artists.contains { $0.id == context.id } }
        case .cloud:
            return offlineTracks.map(\.track).filter(\.isCloud)
        case .recents:
            return offlineTracks.compactMap { item -> (Track, Date)? in
                guard let played = item.assets.compactMap(\.lastPlayed).max() else { return nil }
                return (item.track, played)
            }.sorted { $0.1 > $1.1 }.map(\.0)
        default:
            return []
        }
    }
    let progress = DownloadProgress()
    private(set) var accountScope: String?
    private let store: OfflineStore
    private let metadata: OfflineMetadataStore
    private let persistence: DownloadCatalogStore
    private let transport: any DownloadTransport
    private let resolver: Resolver
    private let metadataFetcher: MetadataFetcher
    private let metadataReader: (Int, String) async -> Track?
    private let cacheContext: () -> MusicCacheContext
    private let prepareResource: (OfflineAudioResource) async -> Void
    private let retrySleep: (Duration) async throws -> Void
    private var catalog = DownloadCatalog()
    private var networkRetries: [UUID: Int] = [:]
    private var networkRetryTasks: [UUID: Task<Void, Never>] = [:]
    private var workers: [UUID: (attempt: UUID, task: Task<Void, Never>)] = [:]
    private var displayWorkers: [UUID: (id: UUID, task: Task<Void, Never>)] = [:]
    private var restoration: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var cacheObservation: AnyCancellable?
    private var monitor: NWPathMonitor?
    private var backgroundCompletion: (() -> Void)?
    private var backgroundEventsDelivered = false
    private var libraryRefreshID = UUID()
    private var libraryScanID = UUID()
    private var batchOperations = 0
    private var preparationSuspended = false
    private var foregroundObserver: NSObjectProtocol?

    init(store: OfflineStore, metadata: OfflineMetadataStore, persistence: DownloadCatalogStore,
         transport: any DownloadTransport, accountScope: String?,
         resolver: @escaping Resolver = { try await NeteaseAPI.songDownloadResource(track: $0, level: $1, accountScope: $2) },
         metadataFetcher: MetadataFetcher? = nil,
         metadataReader: ((Int, String) async -> Track?)? = nil,
         cacheContext: @escaping () -> MusicCacheContext = { .init(policy: .automatic) },
         prepareResource: @escaping (OfflineAudioResource) async -> Void = { _ in },
         retrySleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.store = store
        self.metadata = metadata
        self.persistence = persistence
        self.transport = transport
        self.accountScope = accountScope
        self.resolver = resolver
        self.prepareResource = prepareResource
        self.metadataFetcher = metadataFetcher ?? { await metadata.fetchDisplayData(track: $0, scope: $1) }
        self.metadataReader = metadataReader ?? { await metadata.track(id: $0, scope: $1) }
        self.cacheContext = cacheContext
        self.retrySleep = retrySleep
        cacheObservation = store.cacheCompletions.receive(on: DispatchQueue.main).sink { [weak self] descriptor in
            Task { @MainActor [weak self] in
                guard let self, self.accountScope == descriptor.identity.accountScope else { return }
                await self.start()
                guard self.isReady, self.accountScope == descriptor.identity.accountScope else { return }
                await self.mergeLibraryEntry(trackID: descriptor.identity.trackID, scope: descriptor.identity.accountScope)
            }
        }
    }

    func start() async {
        if let restoration { await restoration.value; return }
        guard !isReady else { return }
        let task = Task {
            await self.restore()
            self.restoration = nil
        }
        restoration = task
        if eventTask == nil {
            let events = transport.events
            eventTask = Task { [weak self] in
                for await event in events {
                    guard let self, !Task.isCancelled else { return }
                    await self.restoration?.value
                    if self.isReady { await self.handle(event) }
                    else if case .backgroundEventsFinished = event {
                        self.backgroundEventsDelivered = true
                        self.finishBackgroundEventsIfPossible()
                    }
                    // Completed receipts remain on disk until restoration can
                    // read the catalog. Drain transient progress in the meantime.
                }
            }
        }
        await task.value
    }

    private func restore() async {
        do {
            catalog = try await persistence.load()
            let discarded = catalog.jobs.filter { $0.owners.isEmpty && $0.status == .cancelled }
            catalog.jobs.removeAll { $0.owners.isEmpty && $0.status == .cancelled }
            for job in discarded { try? await persistence.saveResumeData(nil, jobID: job.id) }
            let received = await transport.restoreTasks()
            let existing = Set(received.keys)
            let receipts = try transport.completedDownloads()
            let receiptTokens = Set(receipts.map(\.token))
            let validTokens = Set(catalog.jobs.filter { $0.accountScope == accountScope && !$0.owners.isEmpty }.compactMap(\.token))
            for token in existing.subtracting(validTokens) { transport.cancel(token: token) }
            for i in catalog.jobs.indices {
                guard !catalog.jobs[i].owners.isEmpty, catalog.jobs[i].status != .complete else { continue }
                let job = catalog.jobs[i]
                if job.accountScope != accountScope {
                    if job.status != .paused { catalog.jobs[i].status = .waitingAccount }
                    catalog.jobs[i].attempt = nil
                } else if ![.paused, .cancelled, .failed, .unavailable].contains(job.status),
                          !existing.contains(job.token ?? ""), !receiptTokens.contains(job.token ?? "") {
                    catalog.jobs[i].status = .queued
                    catalog.jobs[i].attempt = nil
                }
            }
            // Existing completed files recover a crash between importing audio
            // and saving a complete job. No second download is necessary.
            await reconcileCompletedAssets()
            for job in catalog.jobs {
                guard let token = job.token, let receivedBytes = received[token],
                      !receiptTokens.contains(token) else { continue }
                guard current(job), [.resolving, .downloading, .waitingNetwork, .verifying].contains(job.status),
                      let descriptor = job.descriptor else {
                    transport.cancel(token: token)
                    continue
                }
                do {
                    var context = cacheContext()
                    context.protectedAssetIDs.formUnion(storageAssetIDs)
                    try await store.reserveDownload(token: token, bytes: max(0, descriptor.byteCount - receivedBytes), context: context)
                    guard current(job), let i = index(job.id) else {
                        transport.cancel(token: token)
                        await store.releaseDownloadReservation(token: token)
                        continue
                    }
                    catalog.jobs[i].receivedBytes = receivedBytes
                    catalog.jobs[i].expectedBytes = descriptor.byteCount
                } catch {
                    transport.cancel(token: token)
                    await fail(job: job, error: error)
                }
            }
            for receipt in receipts { await handle(.finished(receipt)) }
            try await persist()
            isReady = true
            errorMessage = nil
            publish()
            await refreshLibrary()
            setNetwork(network)
        } catch {
            errorMessage = String(localized: "无法读取下载记录，请重试")
        }
    }

    func activate(accountScope scope: String?) {
        guard accountScope != scope else { return }
        libraryRefreshID = UUID()
        libraryScanID = libraryRefreshID
        accountScope = scope
        offlineTracks = []
        for job in catalog.jobs where job.accountScope != scope {
            displayWorkers.removeValue(forKey: job.id)?.task.cancel()
        }
        for i in catalog.jobs.indices where catalog.jobs[i].accountScope != scope && catalog.jobs[i].status != .complete {
            let job = catalog.jobs[i]
            cancelNetworkRetry(job.id)
            workers.removeValue(forKey: job.id)?.task.cancel()
            if let token = job.token {
                transport.cancel(token: token)
                Task { await store.releaseDownloadReservation(token: token) }
            }
            catalog.jobs[i].attempt = nil
            if ![.paused, .cancelled, .unavailable, .failed].contains(job.status) { catalog.jobs[i].status = .waitingAccount }
        }
        for i in catalog.jobs.indices where catalog.jobs[i].accountScope == scope && catalog.jobs[i].status == .waitingAccount {
            catalog.jobs[i].status = .queued
        }
        publish()
        guard isReady else { return }
        batchOperations += 1
        Task {
            defer { batchOperations -= 1; schedule() }
            guard accountScope == scope else { return }
            await reconcileCompletedAssets()
            guard accountScope == scope else { return }
            publish()
            try? await persist()
            guard accountScope == scope else { return }
            await refreshLibrary()
        }
    }

    func enqueue(track: Track, quality: String, allowsMetered: Bool) async {
        await enqueue(tracks: [track], owner: "single:\(track.id)", name: nil, quality: quality, allowsMetered: allowsMetered)
    }

    @discardableResult
    func enqueue(tracks: [Track], owner: String, name: String?, quality: String, allowsMetered: Bool) async -> Bool {
        let requestedScope = accountScope
        await start()
        guard isReady else { return false }
        guard let scope = accountScope, scope == requestedScope else {
            if accountScope == requestedScope { errorMessage = String(localized: "登录后即可下载歌曲") }
            return false
        }
        guard !tracks.isEmpty else { return false }
        if let name {
            catalog.collections.removeAll { $0.id == owner && $0.accountScope == scope }
            catalog.collections.append(.init(id: owner, accountScope: scope, name: name, tracks: tracks,
                                             savedAt: Date()))
        }
        var seen: Set<Int> = []
        for track in tracks where seen.insert(track.id).inserted {
            if let i = catalog.jobs.firstIndex(where: { $0.accountScope == scope && $0.track.id == track.id && $0.quality == quality }) {
                catalog.jobs[i].owners.insert(owner)
                if catalog.jobs[i].status == .cancelled { catalog.jobs[i].resetTransferState() }
                if [.cancelled, .failed, .unavailable].contains(catalog.jobs[i].status) {
                    cancelNetworkRetry(catalog.jobs[i].id)
                    catalog.jobs[i].allowsMetered = allowsMetered
                    catalog.jobs[i].status = .queued
                    catalog.jobs[i].errorMessage = nil
                    catalog.jobs[i].retries = 0
                }
            } else { catalog.jobs.append(DownloadJob(scope: scope, track: track, quality: quality, owner: owner, allowsMetered: allowsMetered)) }
        }
        if name != nil {
            let obsolete = catalog.jobs.filter { $0.accountScope == scope && $0.owners.contains(owner) && !seen.contains($0.track.id) }.map(\.id)
            for id in obsolete {
                guard let i = index(id) else { continue }
                catalog.jobs[i].owners.remove(owner)
                if catalog.jobs[i].owners.isEmpty { await cancel(id) }
            }
        }
        publish()
        do { try await persist(); errorMessage = nil; schedule(); return true }
        catch { errorMessage = String(localized: "无法保存下载任务"); return false }
    }

    func pause(_ id: UUID) async {
        await pauseJobs([id])
    }

    func pauseAll() async { await pauseJobs(Set(pendingJobs.map(\.id))) }

    func pauseCollection(_ owner: String) async {
        await pauseJobs(Set(pendingJobs.filter { $0.owners.contains(owner) }.map(\.id)))
    }

    private func pauseJobs(_ ids: Set<UUID>) async {
        var paused: [(job: DownloadJob, stamp: UUID)] = []
        for i in catalog.jobs.indices where ids.contains(catalog.jobs[i].id) && catalog.jobs[i].accountScope == accountScope {
            let job = catalog.jobs[i]
            guard [.queued, .resolving, .downloading, .waitingNetwork].contains(job.status) else { continue }
            let stamp = UUID()
            paused.append((job, stamp))
            cancelNetworkRetry(job.id)
            workers.removeValue(forKey: job.id)?.task.cancel()
            catalog.jobs[i].status = .paused
            catalog.jobs[i].attempt = stamp
        }
        guard !paused.isEmpty else { return }
        batchOperations += 1
        defer { batchOperations -= 1; schedule() }
        publish()
        try? await persist()
        for (job, stamp) in paused {
            guard let token = job.token else { continue }
            let data = await transport.pause(token: token)
            await store.releaseDownloadReservation(token: token)
            if let i = index(job.id), catalog.jobs[i].attempt == stamp, catalog.jobs[i].status == .paused {
                if let data { try? await persistence.saveResumeData(data, jobID: job.id) }
            }
        }
    }

    func resume(_ id: UUID, allowsMetered: Bool? = nil) async {
        await resumeJobs([id], allowsMetered: allowsMetered)
    }

    func resumeAll(failedOnly: Bool = false, allowsMetered: Bool? = nil) async {
        let jobs = pendingJobs.filter { !failedOnly || [.failed, .unavailable].contains($0.status) }
        await resumeJobs(Set(jobs.map(\.id)), allowsMetered: allowsMetered)
    }

    func resumeCollection(_ owner: String, allowsMetered: Bool? = nil) async {
        await resumeJobs(Set(pendingJobs.filter { $0.owners.contains(owner) }.map(\.id)), allowsMetered: allowsMetered)
    }

    private func resumeJobs(_ ids: Set<UUID>, allowsMetered: Bool? = nil) async {
        var resumed: [DownloadJob] = []
        var changed = false
        for i in catalog.jobs.indices where ids.contains(catalog.jobs[i].id) && catalog.jobs[i].accountScope == accountScope {
            let job = catalog.jobs[i]
            guard job.status.canResume else { continue }
            // A job waiting for the network keeps its session task and its bytes;
            // it continues by itself. Only widening the networks it may use has
            // to restart it, because the task carries the old request's limits.
            if job.status == .waitingNetwork, job.attempt != nil, !(allowsMetered == true && !job.allowsMetered) {
                if let allowsMetered, allowsMetered != job.allowsMetered {
                    catalog.jobs[i].allowsMetered = allowsMetered
                    changed = true
                }
                continue
            }
            resumed.append(job)
            cancelNetworkRetry(job.id)
            if job.status == .cancelled { catalog.jobs[i].resetTransferState() }
            catalog.jobs[i].attempt = nil
            catalog.jobs[i].status = .queued
            catalog.jobs[i].errorMessage = nil
            catalog.jobs[i].retries = 0
            if let allowsMetered { catalog.jobs[i].allowsMetered = allowsMetered }
            if catalog.jobs[i].owners.isEmpty { catalog.jobs[i].owners.insert("single:\(job.track.id)") }
            if let token = job.token { transport.cancel(token: token) }
        }
        guard !resumed.isEmpty || changed else { return }
        batchOperations += 1
        defer { batchOperations -= 1; schedule() }
        publish()
        try? await persist()
        for job in resumed {
            if let token = job.token { await store.releaseDownloadReservation(token: token) }
            // Resume blobs contain the previous request's network restrictions.
            if let allowsMetered, allowsMetered != job.allowsMetered {
                try? await persistence.saveResumeData(nil, jobID: job.id)
            }
        }
    }

    func cancel(_ id: UUID) async {
        await cancelJobs([id])
    }

    func cancelAll() async {
        await cancelJobs(Set(pendingJobs.map(\.id)))
    }

    func cancelCollection(_ owner: String) async {
        await cancelJobs(Set(pendingJobs.filter { $0.owners.contains(owner) }.map(\.id)), owner: owner)
    }

    @discardableResult
    private func cancelJobs(_ ids: Set<UUID>, owner: String? = nil, deletingTracks: Set<Int> = []) async -> Bool {
        guard let scope = accountScope else { return false }
        var cancelled: [DownloadJob] = []
        var changed = false
        // Invalidate every selected attempt before yielding so completion and
        // retry callbacks cannot advance the queue while it is being cancelled.
        for i in catalog.jobs.indices where ids.contains(catalog.jobs[i].id) && catalog.jobs[i].accountScope == accountScope {
            let job = catalog.jobs[i]
            if let owner {
                guard catalog.jobs[i].owners.remove(owner) != nil else { continue }
                changed = true
                if !catalog.jobs[i].owners.isEmpty { continue }
            }
            changed = true
            cancelled.append(job)
            cancelNetworkRetry(job.id)
            workers.removeValue(forKey: job.id)?.task.cancel()
            displayWorkers.removeValue(forKey: job.id)?.task.cancel()
            catalog.jobs[i].resetTransferState()
            catalog.jobs[i].status = .cancelled
            catalog.jobs[i].owners = []
            if let token = job.token { transport.cancel(token: token) }
        }
        guard changed || !deletingTracks.isEmpty else { return true }
        batchOperations += 1
        defer { batchOperations -= 1; schedule() }
        let cancelledIDs = Set(cancelled.map(\.id))
        catalog.jobs.removeAll { cancelledIDs.contains($0.id) }
        progress.values = progress.values.filter { !cancelledIDs.contains($0.key) }
        if !deletingTracks.isEmpty { offlineTracks.removeAll { deletingTracks.contains($0.id) } }
        publish()
        try? await persist()
        for job in cancelled {
            if let token = job.token { await store.releaseDownloadReservation(token: token) }
            if deletingTracks.isEmpty {
                if let assetID = job.assetID { try? await store.removeRetention(id: assetID, owner: job.retentionOwner) }
                if job.status != .complete, let descriptor = job.descriptor { try? await store.remove(id: descriptor.identity.id) }
            }
            try? await persistence.saveResumeData(nil, jobID: job.id)
        }
        var succeeded = true
        if !deletingTracks.isEmpty {
            do { try await store.removeDownloads(trackIDs: deletingTracks, accountScope: scope) }
            catch { succeeded = false }
        }
        if !cancelled.isEmpty || !deletingTracks.isEmpty { await refreshLibrary() }
        await pruneCollections()
        return succeeded
    }

    /// A saved collection must not outlive its content: once none of its songs
    /// has a job of its own or audio on disk, its page would only ever be empty.
    private func pruneCollections() async {
        guard let scope = accountScope else { return }
        let owners = Set(catalog.jobs.filter { $0.accountScope == scope }.flatMap(\.owners))
        let stale = Set(catalog.collections.filter {
            $0.accountScope == scope && !owners.contains($0.id)
                && !$0.tracks.contains { downloadedTrackIDs.contains($0.id) }
        }.map(\.id))
        guard !stale.isEmpty else { return }
        catalog.collections.removeAll { $0.accountScope == scope && stale.contains($0.id) }
        publish()
        try? await persist()
    }

    func removeDownloads(trackID: Int) async {
        await cancelJobs(Set(jobs.filter { $0.track.id == trackID && !$0.owners.isEmpty }.map(\.id)))
    }

    func deleteLocalAudio(trackID: Int) async {
        await deleteLocalAudio(trackIDs: [trackID])
    }

    @discardableResult
    func deleteLocalAudio(trackIDs: Set<Int>) async -> Bool {
        guard !trackIDs.isEmpty else { return true }
        let ids = Set(jobs.filter { trackIDs.contains($0.track.id) && !$0.owners.isEmpty }.map(\.id))
        return await cancelJobs(ids, deletingTracks: trackIDs)
    }

    func setNetwork(_ value: DownloadNetworkState) {
        network = value
        for i in catalog.jobs.indices where catalog.jobs[i].accountScope == accountScope && !catalog.jobs[i].owners.isEmpty {
            if !value.permits(catalog.jobs[i]) { cancelNetworkRetry(catalog.jobs[i].id) }
            if !value.permits(catalog.jobs[i]), catalog.jobs[i].status == .resolving {
                workers.removeValue(forKey: catalog.jobs[i].id)?.task.cancel()
                catalog.jobs[i].attempt = nil
                catalog.jobs[i].status = .waitingNetwork
            }
            if !value.permits(catalog.jobs[i]), [.queued, .downloading].contains(catalog.jobs[i].status) {
                catalog.jobs[i].status = .waitingNetwork
            } else if value.permits(catalog.jobs[i]), catalog.jobs[i].status == .waitingNetwork,
                      networkRetryTasks[catalog.jobs[i].id] == nil {
                catalog.jobs[i].status = catalog.jobs[i].attempt == nil ? .queued : .downloading
            }
        }
        publish()
        if isReady { Task { try? await persist() } }
        if isReady {
            for job in catalog.jobs where job.status == .complete && job.metadataPending { fetchMetadata(job) }
        }
        schedule()
    }

    func shutdown() {
        isReady = false
        networkRetryTasks.values.forEach { $0.cancel() }
        networkRetryTasks.removeAll()
        eventTask?.cancel()
        cacheObservation?.cancel()
        workers.values.forEach { $0.task.cancel() }
        displayWorkers.values.forEach { $0.task.cancel() }
        monitor?.cancel()
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
    }

    func preparationExpired(jobID: UUID, attempt: UUID) {
        guard let i = index(jobID), catalog.jobs[i].accountScope == accountScope,
              [.resolving, .downloading].contains(catalog.jobs[i].status),
              catalog.jobs[i].attempt == attempt, workers[jobID]?.attempt == attempt else { return }
        preparationSuspended = true
        let token = catalog.jobs[i].token
        workers.removeValue(forKey: jobID)?.task.cancel()
        catalog.jobs[i].attempt = nil
        catalog.jobs[i].status = network.permits(catalog.jobs[i]) ? .queued : .waitingNetwork
        publish()
        Task {
            if let token { await store.releaseDownloadReservation(token: token) }
            try? await persist()
        }
    }

    func resumeAfterForeground() {
        preparationSuspended = false
        if !isReady { Task { await start() }; return }
        setNetwork(network)
    }

    private func schedule() {
        guard isReady, batchOperations == 0, !preparationSuspended else { return }
        var running = catalog.jobs.filter { $0.accountScope == accountScope && ($0.status.isWorking || ($0.status == .waitingNetwork && $0.attempt != nil && network.permits($0))) }.count
        let limit = network.expensive ? 1 : 2
        var changed = false
        for i in catalog.jobs.indices where running < limit {
            let job = catalog.jobs[i]
            guard job.accountScope == accountScope, !job.owners.isEmpty,
                  job.status == .queued else { continue }
            // Cached audio can be promoted even without a connection.
            catalog.jobs[i].status = .resolving
            let attempt = UUID()
            catalog.jobs[i].attempt = attempt
            let scheduled = catalog.jobs[i]
            running += 1
            changed = true
            workers[job.id] = (attempt, Task { await self.prepare(scheduled) })
        }
        if changed { publish() }
    }

    private func prepare(_ job: DownloadJob) async {
        defer {
            if workers[job.id]?.attempt == job.attempt { workers[job.id] = nil; schedule() }
        }
        guard let token = job.token else { return }
        #if os(iOS)
        let activity = DownloadPreparationActivity { [weak self] in
            if let attempt = job.attempt { self?.preparationExpired(jobID: job.id, attempt: attempt) }
        }
        defer { activity.end() }
        #endif
        guard current(job) else { return }
        do {
            try await persist()
            try await metadata.save(track: job.track, scope: job.accountScope)
            if let local = try await store.reusableDescriptor(accountScope: job.accountScope, trackID: job.track.id, quality: job.quality,
                                                              retainingFor: job.retentionOwner) {
                guard current(job) else {
                    try? await store.removeRetention(id: local.identity.id, owner: job.retentionOwner)
                    return
                }
                await complete(job: job, descriptor: local)
                return
            }
            guard current(job), let i = index(job.id) else { return }
            guard network.permits(catalog.jobs[i]) else {
                catalog.jobs[i].status = .waitingNetwork
                catalog.jobs[i].attempt = nil
                publish()
                try await persist()
                return
            }
            let resource = try await resolver(job.track, job.quality, job.accountScope)
            guard current(job), let i = index(job.id) else { return }
            guard network.permits(catalog.jobs[i]) else {
                catalog.jobs[i].status = .waitingNetwork
                catalog.jobs[i].attempt = nil
                publish()
                try await persist()
                return
            }
            await prepareResource(resource)
            guard current(job) else { return }
            if let local = try await store.reusableDescriptor(accountScope: job.accountScope, trackID: job.track.id,
                                                               quality: job.quality, retainingFor: job.retentionOwner) {
                guard current(job) else {
                    try? await store.removeRetention(id: local.identity.id, owner: job.retentionOwner)
                    return
                }
                await complete(job: job, descriptor: local)
                return
            }
            guard current(job) else { return }
            var resumeData = await persistence.resumeData(jobID: job.id)
            guard current(job), let i = index(job.id) else { return }
            if catalog.jobs[i].descriptor != resource.descriptor { resumeData = nil }
            if resumeData == nil {
                catalog.jobs[i].receivedBytes = 0
                progress.values[job.id] = nil
            }
            var context = cacheContext()
            context.protectedAssetIDs.formUnion(storageAssetIDs)
            context.protectedAssetIDs.insert(resource.descriptor.identity.id)
            try await store.reserveDownload(token: token, bytes: resource.descriptor.byteCount, context: context)
            guard current(job), let i = index(job.id) else { await store.releaseDownloadReservation(token: token); return }
            catalog.jobs[i].descriptor = resource.descriptor
            catalog.jobs[i].expectedBytes = resource.descriptor.byteCount
            catalog.jobs[i].status = .downloading
            publish()
            try await persist()
            guard current(job), let i = index(job.id) else { await store.releaseDownloadReservation(token: token); return }
            transport.start(resource: resource, token: token, allowsMetered: catalog.jobs[i].allowsMetered, resumeData: resumeData)
            fetchMetadata(job)
        } catch {
            await fail(job: job, error: error)
        }
    }

    private func handle(_ event: DownloadTransportEvent) async {
        switch event {
        case let .progress(token, received, expected):
            guard let i = index(token: token), catalog.jobs[i].accountScope == accountScope else { return }
            progress.values[catalog.jobs[i].id] = .init(received: received, expected: expected)
            catalog.jobs[i].receivedBytes = received
            if catalog.jobs[i].status == .waitingNetwork, network.permits(catalog.jobs[i]) {
                catalog.jobs[i].status = .downloading; publish()
            }
            let total = max(expected, catalog.jobs[i].descriptor?.byteCount ?? catalog.jobs[i].expectedBytes)
            await store.updateDownloadReservation(token: token, remainingBytes: max(0, total - received))
        case let .waiting(token):
            guard let i = index(token: token), [.downloading, .waitingNetwork].contains(catalog.jobs[i].status) else { return }
            catalog.jobs[i].status = .waitingNetwork
            publish()
            try? await persist()
        case let .finished(receipt):
            guard let i = index(token: receipt.token), catalog.jobs[i].accountScope == accountScope,
                  !catalog.jobs[i].owners.isEmpty, let descriptor = catalog.jobs[i].descriptor else {
                transport.acknowledge(receipt)
                return
            }
            let job = catalog.jobs[i]
            if job.status == .complete { transport.acknowledge(receipt); return }
            guard [200, 206].contains(receipt.statusCode), descriptor.identity.format.accepts(mimeType: receipt.mimeType) else {
                transport.acknowledge(receipt)
                if [401, 403, 404, 416].contains(receipt.statusCode), job.retries < 1 {
                    try? await persistence.saveResumeData(nil, jobID: job.id)
                    guard current(job), let i = index(job.id) else { return }
                    catalog.jobs[i].retries += 1
                    catalog.jobs[i].attempt = nil
                    catalog.jobs[i].status = .queued
                    await store.releaseDownloadReservation(token: receipt.token)
                    publish(); try? await persist(); schedule()
                } else { await fail(job: job, error: OfflineAudioError.invalidResponse) }
                return
            }
            catalog.jobs[i].status = .verifying
            catalog.jobs[i].receivedBytes = descriptor.byteCount
            catalog.jobs[i].expectedBytes = descriptor.byteCount
            progress.values[job.id] = .init(received: descriptor.byteCount, expected: descriptor.byteCount)
            publish()
            try? await persist()
            guard current(job) else { transport.acknowledge(receipt); return }
            do {
                try await store.importDownload(at: transport.inbox.appendingPathComponent(receipt.fileName), descriptor: descriptor)
                if current(job) { await complete(job: job, descriptor: descriptor) }
                else { try? await store.remove(id: descriptor.identity.id) }
            } catch { await fail(job: job, error: error) }
            transport.acknowledge(receipt)
            await store.releaseDownloadReservation(token: receipt.token)
        case let .failed(token, domain, code, resumeData):
            guard let i = index(token: token), ![.complete, .paused, .cancelled].contains(catalog.jobs[i].status) else { return }
            let job = catalog.jobs[i]
            transport.cancel(token: token)
            await store.releaseDownloadReservation(token: token)
            guard current(job) else { return }
            if let resumeData { try? await persistence.saveResumeData(resumeData, jobID: job.id) }
            guard current(job) else { return }
            if AudioTransferCoordinator.isConnectivityFailure(NSError(domain: domain, code: code)) {
                await fail(job: job, error: NSError(domain: domain, code: code))
            } else {
                let hadResumeData = await persistence.resumeData(jobID: job.id) != nil
                guard current(job) else { return }
                if hadResumeData, job.retries < 1 {
                    try? await persistence.saveResumeData(nil, jobID: job.id)
                    guard current(job), let i = index(job.id) else { return }
                    catalog.jobs[i].retries += 1
                    catalog.jobs[i].attempt = nil
                    catalog.jobs[i].status = .queued
                    publish(); try? await persist(); schedule()
                } else { await fail(job: job, error: NSError(domain: domain, code: code)) }
            }
        case .backgroundEventsFinished:
            // Register the next small batch with the system before handing
            // execution back to iOS; metadata work does not delay this handoff.
            let preparing = Array(workers.values)
            for worker in preparing { await worker.task.value }
            try? await persist()
            backgroundEventsDelivered = true
            finishBackgroundEventsIfPossible()
        }
    }

    private func complete(job: DownloadJob, descriptor: OfflineAudioDescriptor) async {
        guard current(job) else { return }
        do {
            try await store.retain(id: descriptor.identity.id, owner: job.retentionOwner)
            guard current(job), let i = index(job.id) else {
                try? await store.removeRetention(id: descriptor.identity.id, owner: job.retentionOwner)
                return
            }
            catalog.jobs[i].assetID = descriptor.identity.id
            catalog.jobs[i].descriptor = descriptor
            catalog.jobs[i].receivedBytes = descriptor.byteCount
            catalog.jobs[i].expectedBytes = descriptor.byteCount
            catalog.jobs[i].status = .complete
            cancelNetworkRetry(job.id)
            catalog.jobs[i].errorMessage = nil
            publish()
            try await persist()
            guard current(job), let i = index(job.id) else { return }
            // Move only the overlapping collection/single-song intentions to
            // the new version after it is complete. Other collections keep
            // their existing download, and failed upgrades leave it intact.
            let oldIDs = catalog.jobs.filter {
                $0.id != job.id && $0.accountScope == job.accountScope && $0.track.id == job.track.id
                    && !$0.owners.isDisjoint(with: catalog.jobs[i].owners)
            }.map(\.id)
            for oldID in oldIDs {
                guard current(job), let oldIndex = index(oldID), let newIndex = index(job.id) else { break }
                catalog.jobs[oldIndex].owners.subtract(catalog.jobs[newIndex].owners)
                if catalog.jobs[oldIndex].owners.isEmpty { await cancel(oldID) }
            }
            guard current(job) else { return }
            try await persist()
            try? await persistence.saveResumeData(nil, jobID: job.id)
            if let token = job.token { await store.releaseDownloadReservation(token: token) }
            await mergeLibraryEntry(trackID: job.track.id, scope: job.accountScope)
            guard current(job), let i = index(job.id) else { return }
            fetchMetadata(catalog.jobs[i])
            if workers[job.id]?.attempt == job.attempt { workers[job.id] = nil }
            schedule()
        } catch { await fail(job: job, error: error) }
    }

    private func fail(job: DownloadJob, error: Error) async {
        guard current(job) else { return }
        if let token = job.token { await store.releaseDownloadReservation(token: token) }
        guard current(job), let i = index(job.id) else { return }
        let delays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]
        let retries = networkRetries[job.id, default: 0]
        let waitsForNetwork = AudioTransferCoordinator.isConnectivityFailure(error)
            && (!network.permits(catalog.jobs[i]) || retries < delays.count)
        catalog.jobs[i].status = waitsForNetwork ? .waitingNetwork : ((error as? OfflineAudioError) == .unavailable ? .unavailable : .failed)
        catalog.jobs[i].errorMessage = waitsForNetwork ? nil : Self.message(for: error)
        catalog.jobs[i].attempt = nil
        if workers[job.id]?.attempt == job.attempt { workers[job.id] = nil }
        if waitsForNetwork, network.permits(catalog.jobs[i]) {
            networkRetries[job.id] = retries + 1
            networkRetryTasks[job.id] = Task { [weak self, retrySleep] in
                do { try await retrySleep(delays[retries]) } catch { return }
                guard let self, !Task.isCancelled, self.isReady,
                      let i = self.index(job.id), self.catalog.jobs[i].accountScope == self.accountScope,
                      !self.catalog.jobs[i].owners.isEmpty,
                      self.catalog.jobs[i].status == .waitingNetwork, self.catalog.jobs[i].attempt == nil else { return }
                self.networkRetryTasks[job.id] = nil
                guard self.network.permits(self.catalog.jobs[i]) else { return }
                self.catalog.jobs[i].status = .queued
                self.publish()
                try? await self.persist()
                self.schedule()
            }
        }
        publish()
        try? await persist()
        schedule()
    }

    private func cancelNetworkRetry(_ id: UUID) {
        networkRetryTasks.removeValue(forKey: id)?.cancel()
        networkRetries[id] = nil
    }

    static func message(for error: Error) -> String {
        if let offline = error as? OfflineAudioError {
            switch offline {
            case .unavailable: return String(localized: "此歌曲或所选音质暂不可下载")
            case .insufficientSpace: return String(localized: "存储空间不足，请释放空间后重试")
            case .checksumMismatch, .invalidAudio, .incomplete, .invalidResponse, .changedResource:
                return String(localized: "音频校验失败，请重试")
            default: return String(localized: "无法保存音频，请重试")
            }
        }
        let code = (error as NSError).code
        if code == NSURLErrorCannotFindHost || code == NSURLErrorDNSLookupFailed { return String(localized: "无法解析音源地址，请检查网络后重试") }
        return String(localized: "下载失败，请检查网络或账号权限后重试")
    }

    private func fetchMetadata(_ job: DownloadJob) {
        guard job.accountScope == accountScope, !job.owners.isEmpty, network.permits(job), displayWorkers[job.id] == nil else { return }
        let workerID = UUID()
        displayWorkers[job.id] = (workerID, Task {
            defer { if displayWorkers[job.id]?.id == workerID { displayWorkers[job.id] = nil } }
            guard !Task.isCancelled else { return }
            await metadataFetcher(job.track, job.accountScope)
            guard !Task.isCancelled, displayWorkers[job.id]?.id == workerID else { return }
            let available = await metadata.hasDisplayData(track: job.track, scope: job.accountScope)
            guard !Task.isCancelled, displayWorkers[job.id]?.id == workerID else { return }
            if let i = index(job.id), catalog.jobs[i].accountScope == accountScope {
                catalog.jobs[i].metadataPending = !available
                publish(); try? await persist()
            }
        })
    }

    private func reconcileCompletedAssets() async {
        guard let scope = accountScope else { return }
        let available = (try? await store.availableRecords(accountScope: scope)) ?? []
        guard accountScope == scope else { return }
        let ids = Set(available.map(\.id))
        for job in catalog.jobs where job.accountScope == scope && !job.owners.isEmpty {
            guard accountScope == scope else { return }
            guard let i = index(job.id), !catalog.jobs[i].owners.isEmpty,
                  let assetID = catalog.jobs[i].assetID ?? catalog.jobs[i].descriptor?.identity.id else { continue }
            if ids.contains(assetID) {
                catalog.jobs[i].assetID = assetID
                catalog.jobs[i].status = .complete
                try? await store.retain(id: assetID, owner: job.retentionOwner)
                if index(job.id) == nil { try? await store.removeRetention(id: assetID, owner: job.retentionOwner) }
            } else if catalog.jobs[i].status == .complete {
                catalog.jobs[i].status = .failed
                catalog.jobs[i].errorMessage = String(localized: "本地文件缺失，请重新下载")
            }
        }
    }

    func refreshLibrary() async {
        let requestID = UUID()
        libraryRefreshID = requestID
        libraryScanID = requestID
        guard let scope = accountScope else { offlineTracks = []; return }
        let completedAtStart = Dictionary(uniqueKeysWithValues: catalog.jobs.filter {
            $0.accountScope == scope && $0.status == .complete
        }.map { ($0.id, (assetID: $0.assetID, attempt: $0.attempt)) })
        let available: [OfflineAudioRecord]
        do { available = try await store.availableRecords(accountScope: scope) }
        catch { return }
        var result: [OfflineLibraryTrack] = []
        for (trackID, assets) in Dictionary(grouping: available, by: { $0.descriptor.identity.trackID }) {
            guard libraryRefreshID == requestID, accountScope == scope, !Task.isCancelled else { return }
            if let track = await metadataReader(trackID, scope)
                ?? catalog.jobs.first(where: { $0.accountScope == scope && $0.track.id == trackID })?.track {
                result.append(.init(track: track, assets: assets))
            }
        }
        guard libraryRefreshID == requestID, accountScope == scope, !Task.isCancelled else { return }
        offlineTracks = result.sorted(by: Self.precedes)
        let availableIDs = Set(available.map(\.id))
        var changed = false
        for i in catalog.jobs.indices where catalog.jobs[i].accountScope == scope && catalog.jobs[i].status == .complete {
            let job = catalog.jobs[i]
            // A scan can only invalidate the completed attempt it started with.
            // Downloads completed or retried during metadata reads are newer.
            if let id = job.assetID, let scanned = completedAtStart[job.id],
               scanned.assetID == id, scanned.attempt == job.attempt, !availableIDs.contains(id) {
                catalog.jobs[i].status = .failed
                catalog.jobs[i].attempt = nil
                catalog.jobs[i].errorMessage = String(localized: "本地文件缺失，请重新下载")
                changed = true
            }
            if catalog.jobs[i].metadataPending { fetchMetadata(catalog.jobs[i]) }
        }
        if changed { publish(); try? await persist() }
        await pruneCollections()
    }

    nonisolated private static func precedes(_ lhs: OfflineLibraryTrack, _ rhs: OfflineLibraryTrack) -> Bool {
        lhs.track.name.localizedStandardCompare(rhs.track.name) == .orderedAscending
    }

    /// One finished song must not rescan the library: read that song's records
    /// and merge its entry where a full refresh would have sorted it. The merge
    /// supersedes an older scan, which cannot see this song's retention yet, and
    /// steps aside for a newer one, whose own snapshot already covers the song.
    private func mergeLibraryEntry(trackID: Int, scope: String) async {
        libraryRefreshID = UUID()
        let scanID = libraryScanID
        guard let records = try? await store.availableRecords(accountScope: scope, trackID: trackID) else { return }
        guard libraryScanID == scanID, accountScope == scope, !Task.isCancelled else { return }
        guard !records.isEmpty else { offlineTracks.removeAll { $0.id == trackID }; return }
        let stored = await metadataReader(trackID, scope)
        guard libraryScanID == scanID, accountScope == scope, !Task.isCancelled else { return }
        guard let track = stored ?? catalog.jobs.first(where: { $0.accountScope == scope && $0.track.id == trackID })?.track else { return }
        let entry = OfflineLibraryTrack(track: track, assets: records)
        var merged = offlineTracks.filter { $0.id != trackID }
        merged.insert(entry, at: merged.firstIndex { Self.precedes(entry, $0) } ?? merged.endIndex)
        offlineTracks = merged
    }

    func registerBackgroundCompletion(_ completion: @escaping () -> Void) {
        backgroundCompletion = completion
        finishBackgroundEventsIfPossible()
    }

    private func finishBackgroundEventsIfPossible() {
        guard backgroundEventsDelivered, let completion = backgroundCompletion else { return }
        backgroundCompletion = nil
        backgroundEventsDelivered = false
        completion()
    }

    private func observeForeground() {
        #if os(iOS)
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.resumeAfterForeground() }
        }
        #endif
    }

    private func monitorNetwork() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let value = DownloadNetworkState(connected: path.status == .satisfied, expensive: path.isExpensive, constrained: path.isConstrained)
            Task { @MainActor in self?.setNetwork(value) }
        }
        monitor.start(queue: DispatchQueue(label: "im.missuo.Kumone.download-network"))
        self.monitor = monitor
    }

    private func current(_ job: DownloadJob) -> Bool {
        guard !Task.isCancelled, let i = index(job.id) else { return false }
        return catalog.jobs[i].attempt == job.attempt && catalog.jobs[i].accountScope == accountScope && !catalog.jobs[i].owners.isEmpty
    }
    private func index(_ id: UUID) -> Int? { catalog.jobs.firstIndex { $0.id == id } }
    private func index(token: String) -> Int? { catalog.jobs.firstIndex { $0.token == token } }
    private func publish() {
        jobs = catalog.jobs.filter { $0.accountScope == accountScope }.sorted { $0.createdAt > $1.createdAt }
        jobsByTrackID = Dictionary(jobs.filter { !$0.owners.isEmpty }.map { ($0.track.id, $0) }, uniquingKeysWith: { first, _ in first })
        pendingJobsByTrackID = Dictionary(jobs.filter { !$0.owners.isEmpty && $0.status != .complete }.map { ($0.track.id, $0) }, uniquingKeysWith: { first, _ in first })
        rebuildDownloadIndex()
        collections = catalog.collections.filter { $0.accountScope == accountScope }
    }
    private func rebuildDownloadIndex() {
        offlineTracksByID = Dictionary(offlineTracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        downloadedTracks = offlineTracks.filter(\.isDownloaded)
        downloadedTrackIDs = Set(downloadedTracks.map(\.id))
        downloadedTrackIDs.formUnion(jobs.filter { $0.status == .complete && !$0.owners.isEmpty }.map { $0.track.id })
    }
    private func persist() async throws {
        catalog.revision += 1
        try await persistence.save(catalog)
    }
}

@MainActor
public enum OfflineDownloadEvents {
    public static func handleBackgroundSession(identifier: String, completion: @escaping () -> Void) {
        guard identifier == BackgroundDownloadTransport.identifier else { completion(); return }
        DownloadManager.shared.registerBackgroundCompletion(completion)
        Task { await DownloadManager.shared.start() }
    }
}
