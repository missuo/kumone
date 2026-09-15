import Foundation
import Network

@MainActor
final class DownloadProgress: ObservableObject {
    struct Value { let received: Int64; let expected: Int64 }
    @Published var values: [UUID: Value] = [:]
}

@MainActor
final class DownloadManager: ObservableObject {
    static let shared: DownloadManager = {
        let root = OfflineStore.shared.directory.appendingPathComponent("downloads", isDirectory: true)
        let manager = DownloadManager(store: .shared, metadata: .shared, persistence: DownloadCatalogStore(directory: root),
                                      transport: BackgroundDownloadTransport(inbox: root.appendingPathComponent("inbox")),
                                      accountScope: AccountStore.shared.offlineScope)
        manager.monitorNetwork()
        Task { await manager.start() }
        return manager
    }()

    typealias Resolver = (Track, String, String) async throws -> OfflineAudioResource
    typealias MetadataFetcher = (Track, String) async -> Void
    @Published private(set) var jobs: [DownloadJob] = []
    @Published private(set) var collections: [DownloadCollection] = []
    @Published private(set) var offlineTracks: [OfflineLibraryTrack] = []
    @Published private(set) var isReady = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var network = DownloadNetworkState.unknown
    var downloadedTracks: [OfflineLibraryTrack] { offlineTracks.filter(\.isDownloaded) }
    var pendingJobs: [DownloadJob] {
        jobs.filter { !$0.owners.isEmpty && $0.status != .complete && $0.status != .cancelled }
    }

    var storageAssetIDs: Set<String> {
        Set(catalog.jobs.filter { !$0.owners.isEmpty }.flatMap { [$0.assetID, $0.descriptor?.identity.id].compactMap { $0 } })
    }

    func downloadedSongs(in collectionID: String? = nil) -> [Track] {
        guard let collectionID else { return downloadedTracks.map(\.track) }
        guard let collection = collections.first(where: { $0.id == collectionID }) else { return [] }
        let available = Set(downloadedTracks.map(\.id))
        var seen: Set<Int> = []
        return collection.tracks.filter { available.contains($0.id) && seen.insert($0.id).inserted }
    }
    let progress = DownloadProgress()
    private(set) var accountScope: String?
    private let store: OfflineStore
    private let metadata: OfflineMetadataStore
    private let persistence: DownloadCatalogStore
    private let transport: any DownloadTransport
    private let resolver: Resolver
    private let metadataFetcher: MetadataFetcher
    private var catalog = DownloadCatalog()
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var displayWorkers: [UUID: Task<Void, Never>] = [:]
    private var restoration: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var monitor: NWPathMonitor?
    private var backgroundCompletion: (() -> Void)?
    private var backgroundEventsDelivered = false

    init(store: OfflineStore, metadata: OfflineMetadataStore, persistence: DownloadCatalogStore,
         transport: any DownloadTransport, accountScope: String?,
         resolver: @escaping Resolver = { try await NeteaseAPI.songDownloadResource(track: $0, level: $1, accountScope: $2) },
         metadataFetcher: MetadataFetcher? = nil) {
        self.store = store
        self.metadata = metadata
        self.persistence = persistence
        self.transport = transport
        self.accountScope = accountScope
        self.resolver = resolver
        self.metadataFetcher = metadataFetcher ?? { await metadata.fetchDisplayData(track: $0, scope: $1) }
    }

    func start() async {
        if let restoration { await restoration.value; return }
        let task = Task { await self.restore() }
        restoration = task
        await task.value
    }

    private func restore() async {
        do {
            catalog = try await persistence.load()
            let existing = await transport.restoreTasks()
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
            for receipt in receipts { await handle(.finished(receipt)) }
            try await persist()
            isReady = true
            publish()
            let events = transport.events
            eventTask = Task { [weak self] in
                for await event in events {
                    guard let self else { return }
                    await self.handle(event)
                }
            }
            await refreshLibrary()
            schedule()
        } catch {
            errorMessage = String(localized: "无法读取下载记录，请重新打开应用")
        }
    }

    func activate(accountScope scope: String?) {
        guard accountScope != scope else { return }
        accountScope = scope
        offlineTracks = []
        for i in catalog.jobs.indices where catalog.jobs[i].accountScope != scope && catalog.jobs[i].status != .complete {
            let job = catalog.jobs[i]
            workers.removeValue(forKey: job.id)?.cancel()
            displayWorkers.removeValue(forKey: job.id)?.cancel()
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
        Task {
            try? await persist()
            await reconcileCompletedAssets()
            await refreshLibrary()
            schedule()
        }
    }

    func enqueue(track: Track, quality: String, allowsMetered: Bool) async {
        await enqueue(tracks: [track], owner: "single:\(track.id)", name: nil, quality: quality, allowsMetered: allowsMetered)
    }

    func enqueue(tracks: [Track], owner: String, name: String?, quality: String, allowsMetered: Bool) async {
        await start()
        guard isReady, let scope = accountScope else {
            errorMessage = String(localized: "登录后即可下载歌曲")
            return
        }
        guard !tracks.isEmpty else { return }
        if let name {
            catalog.collections.removeAll { $0.id == owner && $0.accountScope == scope }
            catalog.collections.append(.init(id: owner, accountScope: scope, name: name, tracks: tracks, savedAt: Date()))
        }
        var seen: Set<Int> = []
        for track in tracks where seen.insert(track.id).inserted {
            if let i = catalog.jobs.firstIndex(where: { $0.accountScope == scope && $0.track.id == track.id && $0.quality == quality }) {
                catalog.jobs[i].owners.insert(owner)
                if [.cancelled, .failed, .unavailable].contains(catalog.jobs[i].status) {
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
        do { try await persist(); schedule() }
        catch { errorMessage = String(localized: "无法保存下载任务") }
    }

    func pause(_ id: UUID) async {
        guard let i = index(id), catalog.jobs[i].accountScope == accountScope,
              [.queued, .resolving, .downloading, .waitingNetwork].contains(catalog.jobs[i].status) else { return }
        let token = catalog.jobs[i].token
        let stamp = UUID()
        workers.removeValue(forKey: id)?.cancel()
        catalog.jobs[i].status = .paused
        catalog.jobs[i].attempt = stamp
        publish()
        try? await persist()
        if let token {
            let data = await transport.pause(token: token)
            await store.releaseDownloadReservation(token: token)
            if let i = index(id), catalog.jobs[i].attempt == stamp, catalog.jobs[i].status == .paused {
                try? await persistence.saveResumeData(data, jobID: id)
            }
        }
        schedule()
    }

    func resume(_ id: UUID, allowsMetered: Bool? = nil) async {
        guard let i = index(id), catalog.jobs[i].accountScope == accountScope, catalog.jobs[i].status.canResume else { return }
        let oldToken = catalog.jobs[i].token
        catalog.jobs[i].attempt = UUID()
        catalog.jobs[i].status = .queued
        catalog.jobs[i].errorMessage = nil
        catalog.jobs[i].retries = 0
        if let allowsMetered {
            catalog.jobs[i].allowsMetered = allowsMetered
            // Resume blobs contain the previous request's network restrictions.
            try? await persistence.saveResumeData(nil, jobID: id)
        }
        if catalog.jobs[i].owners.isEmpty { catalog.jobs[i].owners.insert("single:\(catalog.jobs[i].track.id)") }
        if let oldToken { transport.cancel(token: oldToken); await store.releaseDownloadReservation(token: oldToken) }
        publish()
        try? await persist()
        schedule()
    }

    func cancel(_ id: UUID) async {
        guard let i = index(id), catalog.jobs[i].accountScope == accountScope else { return }
        let job = catalog.jobs[i]
        workers.removeValue(forKey: id)?.cancel()
        displayWorkers.removeValue(forKey: id)?.cancel()
        catalog.jobs[i].attempt = nil
        catalog.jobs[i].status = .cancelled
        catalog.jobs[i].owners = []
        if let token = job.token { transport.cancel(token: token); await store.releaseDownloadReservation(token: token) }
        if let assetID = job.assetID { try? await store.removeRetention(id: assetID, owner: job.retentionOwner) }
        if job.status != .complete, let descriptor = job.descriptor { try? await store.remove(id: descriptor.identity.id) }
        try? await persistence.saveResumeData(nil, jobID: id)
        publish()
        try? await persist()
        await refreshLibrary()
        schedule()
    }

    func removeCollection(_ owner: String) async {
        let ids = catalog.jobs.filter { $0.accountScope == accountScope && $0.owners.contains(owner) }.map(\.id)
        catalog.collections.removeAll { $0.accountScope == accountScope && $0.id == owner }
        for id in ids {
            guard let i = index(id) else { continue }
            catalog.jobs[i].owners.remove(owner)
            if catalog.jobs[i].owners.isEmpty { await cancel(id) }
        }
        publish()
        try? await persist()
    }

    func removeDownloads(trackID: Int) async {
        for id in jobs.filter({ $0.track.id == trackID && !$0.owners.isEmpty }).map(\.id) { await cancel(id) }
    }

    func deleteLocalAudio(trackID: Int) async {
        let assets = offlineTracks.first { $0.id == trackID }?.assets ?? []
        await removeDownloads(trackID: trackID)
        for asset in assets { try? await store.remove(id: asset.id) }
        await refreshLibrary()
    }

    func setNetwork(_ value: DownloadNetworkState) {
        network = value
        for i in catalog.jobs.indices where catalog.jobs[i].accountScope == accountScope && !catalog.jobs[i].owners.isEmpty {
            if !value.permits(catalog.jobs[i]), catalog.jobs[i].status == .queued { catalog.jobs[i].status = .waitingNetwork }
            else if value.permits(catalog.jobs[i]), catalog.jobs[i].status == .waitingNetwork,
                    catalog.jobs[i].attempt == nil { catalog.jobs[i].status = .queued }
        }
        publish()
        if isReady {
            for job in catalog.jobs where job.status == .complete && job.metadataPending { fetchMetadata(job) }
        }
        schedule()
    }

    func shutdown() {
        eventTask?.cancel()
        workers.values.forEach { $0.cancel() }
        displayWorkers.values.forEach { $0.cancel() }
        monitor?.cancel()
    }

    private func schedule() {
        guard isReady else { return }
        var running = catalog.jobs.filter { $0.accountScope == accountScope && ($0.status.isWorking || ($0.status == .waitingNetwork && $0.attempt != nil)) }.count
        let limit = network.expensive ? 1 : 2
        for i in catalog.jobs.indices where running < limit {
            let job = catalog.jobs[i]
            guard job.accountScope == accountScope, !job.owners.isEmpty,
                  job.status == .queued else { continue }
            // Cached audio can be promoted even without a connection.
            catalog.jobs[i].status = .resolving
            catalog.jobs[i].attempt = UUID()
            let scheduled = catalog.jobs[i]
            running += 1
            workers[job.id] = Task { await self.prepare(scheduled) }
        }
        publish()
    }

    private func prepare(_ job: DownloadJob) async {
        defer {
            if !Task.isCancelled { workers[job.id] = nil; schedule() }
        }
        guard let token = job.token else { return }
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
            var resumeData = await persistence.resumeData(jobID: job.id)
            guard current(job) else { return }
            if catalog.jobs[i].descriptor != resource.descriptor { resumeData = nil }
            try await store.reserveDownload(token: token, bytes: resource.descriptor.byteCount)
            guard current(job) else { await store.releaseDownloadReservation(token: token); return }
            catalog.jobs[i].descriptor = resource.descriptor
            catalog.jobs[i].expectedBytes = resource.descriptor.byteCount
            catalog.jobs[i].status = .downloading
            publish()
            try await persist()
            guard current(job) else { await store.releaseDownloadReservation(token: token); return }
            transport.start(resource: resource, token: token, allowsMetered: catalog.jobs[i].allowsMetered, resumeData: resumeData)
            fetchMetadata(job)
        } catch {
            await fail(job: job, error: error)
        }
        if current(job) { workers[job.id] = nil }
    }

    private func handle(_ event: DownloadTransportEvent) async {
        switch event {
        case let .progress(token, received, expected):
            guard let i = index(token: token), catalog.jobs[i].accountScope == accountScope else { return }
            progress.values[catalog.jobs[i].id] = .init(received: received, expected: expected)
            catalog.jobs[i].receivedBytes = received
            if catalog.jobs[i].status == .waitingNetwork { catalog.jobs[i].status = .downloading; publish() }
            await store.updateDownloadReservation(token: token, remainingBytes: max(0, expected - received))
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
                    catalog.jobs[i].retries += 1
                    catalog.jobs[i].attempt = nil
                    catalog.jobs[i].status = .queued
                    await store.releaseDownloadReservation(token: receipt.token)
                    publish(); try? await persist(); schedule()
                } else { await fail(job: job, error: OfflineAudioError.invalidResponse) }
                return
            }
            catalog.jobs[i].status = .verifying
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
            if domain == NSURLErrorDomain, [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed].contains(code) {
                catalog.jobs[i].status = .waitingNetwork
                catalog.jobs[i].attempt = nil
                publish(); try? await persist()
            } else {
                let hadResumeData = await persistence.resumeData(jobID: job.id) != nil
                guard current(job) else { return }
                if hadResumeData, job.retries < 1 {
                    try? await persistence.saveResumeData(nil, jobID: job.id)
                    guard current(job) else { return }
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
            for worker in preparing { await worker.value }
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
            catalog.jobs[i].errorMessage = nil
            publish()
            try await persist()
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
            await refreshLibrary()
            fetchMetadata(catalog.jobs[i])
            workers[job.id] = nil
            schedule()
        } catch { await fail(job: job, error: error) }
    }

    private func fail(job: DownloadJob, error: Error) async {
        guard current(job), let i = index(job.id) else { return }
        if let token = job.token { await store.releaseDownloadReservation(token: token) }
        guard current(job) else { return }
        catalog.jobs[i].status = (error as? OfflineAudioError) == .unavailable ? .unavailable : .failed
        catalog.jobs[i].errorMessage = Self.message(for: error)
        catalog.jobs[i].attempt = nil
        workers[job.id] = nil
        publish()
        try? await persist()
        schedule()
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
        displayWorkers[job.id] = Task {
            guard !Task.isCancelled else { return }
            await metadataFetcher(job.track, job.accountScope)
            let available = await metadata.hasDisplayData(track: job.track, scope: job.accountScope)
            if let i = index(job.id), catalog.jobs[i].accountScope == accountScope {
                catalog.jobs[i].metadataPending = !available
                publish(); try? await persist()
            }
            displayWorkers[job.id] = nil
        }
    }

    private func reconcileCompletedAssets() async {
        guard let scope = accountScope else { return }
        let available = (try? await store.availableRecords(accountScope: scope)) ?? []
        guard accountScope == scope else { return }
        let ids = Set(available.map(\.id))
        for i in catalog.jobs.indices where catalog.jobs[i].accountScope == scope && !catalog.jobs[i].owners.isEmpty {
            guard let assetID = catalog.jobs[i].assetID ?? catalog.jobs[i].descriptor?.identity.id else { continue }
            if ids.contains(assetID) {
                catalog.jobs[i].assetID = assetID
                catalog.jobs[i].status = .complete
                try? await store.retain(id: assetID, owner: catalog.jobs[i].retentionOwner)
            } else if catalog.jobs[i].status == .complete {
                catalog.jobs[i].status = .failed
                catalog.jobs[i].errorMessage = String(localized: "本地文件缺失，请重新下载")
            }
        }
    }

    func refreshLibrary() async {
        guard let scope = accountScope else { offlineTracks = []; return }
        let available = (try? await store.availableRecords(accountScope: scope)) ?? []
        var result: [OfflineLibraryTrack] = []
        for (trackID, assets) in Dictionary(grouping: available, by: { $0.descriptor.identity.trackID }) {
            if let track = await metadata.track(id: trackID, scope: scope)
                ?? catalog.jobs.first(where: { $0.accountScope == scope && $0.track.id == trackID })?.track {
                result.append(.init(track: track, assets: assets))
            }
        }
        guard accountScope == scope else { return }
        offlineTracks = result.sorted { $0.track.name.localizedStandardCompare($1.track.name) == .orderedAscending }
        let availableIDs = Set(available.map(\.id))
        var changed = false
        for i in catalog.jobs.indices where catalog.jobs[i].accountScope == scope && catalog.jobs[i].status == .complete {
            if let id = catalog.jobs[i].assetID, !availableIDs.contains(id) {
                catalog.jobs[i].status = .failed
                catalog.jobs[i].attempt = nil
                catalog.jobs[i].errorMessage = String(localized: "本地文件缺失，请重新下载")
                changed = true
            }
            if catalog.jobs[i].metadataPending { fetchMetadata(catalog.jobs[i]) }
        }
        if changed { publish(); try? await persist() }
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

    private func monitorNetwork() {
        if KumonePaths.isOfflineUITest { setNetwork(.unknown); return }
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
        collections = catalog.collections.filter { $0.accountScope == accountScope }
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
