import Foundation

struct QueuePrefetchRequest: Equatable {
    let scope: String?
    let currentTrackID: Int
    let tracks: [Track]
    let quality: String
    let allowsUnblock: Bool
    let pendingDownloadTrackIDs: Set<Int>

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.scope == rhs.scope && lhs.currentTrackID == rhs.currentTrackID && lhs.tracks == rhs.tracks
            && lhs.quality == rhs.quality && lhs.allowsUnblock == rhs.allowsUnblock
    }
}

/// Where one upcoming song can be fetched from, as the song URL API answers.
struct QueuePrefetchSource {
    let url: URL
    let servedQuality: String?
    /// Zero when the server did not say.
    let byteCount: Int64
    let fileExtension: String?
}

/// Fills the song cache with the next few songs while the network is free, so
/// the queue keeps playing when it is not. One bounded worker; every await is
/// followed by a generation check so a late answer cannot start work for a
/// replaced queue or account.
@MainActor
final class QueuePrefetcher {
    typealias Resolver = (Track, String) async throws -> QueuePrefetchSource?
    private let cache: AudioCache
    private let resolver: Resolver
    private let cacheLimitMB: () async -> Int
    private let isDownloaded: @MainActor (Int) -> Bool
    private let completion: (Track, String?) async -> Void
    private let limits: PrefetchLimits
    private var request: QueuePrefetchRequest?
    private var generation = 0
    private var worker: Task<Void, Never>?
    private var pendingDownloadTrackIDs: Set<Int> = []
    private var windowBytes: Int64 = 0
    private var visitedTrackIDs: Set<Int> = []
    private var windowStopped = false
    private(set) var completedTrackIDs: [Int] = []

    init(cache: AudioCache = .shared, limits: PrefetchLimits = .init(),
         cacheLimitMB: @escaping () async -> Int = { await SettingsManager.shared.effectiveAudioCacheSizeMB() },
         isDownloaded: @escaping @MainActor (Int) -> Bool = { DownloadManager.shared.isDownloaded(trackID: $0) },
         resolver: @escaping Resolver = QueuePrefetcher.resolveSongURL,
         completion: @escaping (Track, String?) async -> Void = QueuePrefetcher.keepPlaybackData) {
        self.cache = cache
        self.limits = limits
        self.cacheLimitMB = cacheLimitMB
        self.isDownloaded = isDownloaded
        self.resolver = resolver
        self.completion = completion
    }

    /// Only a free, unmetered network and a device not saving power fill the
    /// cache ahead of time.
    nonisolated static func permits(network: DownloadNetworkState, lowPower: Bool) -> Bool {
        network.connected && !network.expensive && !network.constrained && !lowPower
    }

    func update(_ next: QueuePrefetchRequest?) {
        // Pending explicit downloads are handled by the background session.
        let pending = next?.pendingDownloadTrackIDs ?? []
        let pendingChanged = pending != pendingDownloadTrackIDs
        pendingDownloadTrackIDs = pending
        if next == request {
            // An active worker rechecks eligibility after its current song.
            // An idle window resumes with its original byte/track accounting.
            if pendingChanged, let next, worker == nil, !windowStopped { startWorker(next) }
            return
        }
        cancel()
        request = next
        completedTrackIDs = []
        windowBytes = 0
        visitedTrackIDs = next.map { Set([$0.currentTrackID]) } ?? []
        windowStopped = false
        guard let next else { return }
        startWorker(next)
    }

    func cancel() {
        generation += 1
        request = nil
        worker?.cancel()
        worker = nil
    }

    private func startWorker(_ request: QueuePrefetchRequest) {
        let ticket = generation
        worker = Task { [weak self] in
            guard let self, self.isCurrent(ticket) else { return }
            await self.run(request, ticket: ticket)
            if self.isCurrent(ticket) { self.worker = nil }
        }
    }

    private func isCurrent(_ ticket: Int) -> Bool { ticket == generation && !Task.isCancelled }

    private func run(_ request: QueuePrefetchRequest, ticket: Int) async {
        let tracks = limits.window(request.tracks)
        while let track = tracks.first(where: { !visitedTrackIDs.contains($0.id) && !pendingDownloadTrackIDs.contains($0.id) }) {
            guard isCurrent(ticket) else { return }
            visitedTrackIDs.insert(track.id)
            if isDownloaded(track.id) { continue }
            do {
                if let cached = try await cache.entry(for: track.id, requestedQuality: request.quality, allowsUnblock: request.allowsUnblock) {
                    guard isCurrent(ticket) else { return }
                    guard cached.metadata.byteCount <= limits.bytes - windowBytes else { windowStopped = true; return }
                    windowBytes += cached.metadata.byteCount
                    continue
                }
                guard isCurrent(ticket) else { return }
                guard let source = try await resolver(track, request.quality) else { continue }
                guard isCurrent(ticket) else { return }
                guard !pendingDownloadTrackIDs.contains(track.id) else { visitedTrackIDs.remove(track.id); continue }
                let limitMB = await cacheLimitMB()
                guard isCurrent(ticket) else { return }
                // A song the cache could never hold is skipped; one the window
                // has no room for ends the window.
                guard CachingAudioResourceLoader.canCache(contentLength: max(source.byteCount, 1), maximumSizeMB: limitMB) else { continue }
                guard source.byteCount <= limits.bytes - windowBytes else { windowStopped = true; return }
                let stored = try await store(source, track: track, quality: request.quality, limitMB: limitMB, ticket: ticket)
                guard isCurrent(ticket) else { return }
                guard let stored else { windowStopped = true; return }
                windowBytes += stored
                await completion(track, request.scope)
                if isCurrent(ticket) { completedTrackIDs.append(track.id) }
            } catch {
                guard isCurrent(ticket) else { return }
                // Network trouble ends this window rather than retrying on a
                // playback timer; an unavailable song only consumes its slot.
                if error is URLError { windowStopped = true; return }
            }
        }
    }

    /// Downloads one song into the cache. Returns its byte count, or nil when
    /// the cache would not keep it at the current limit.
    private func store(_ source: QueuePrefetchSource, track: Track, quality: String, limitMB: Int, ticket: Int) async throws -> Int64? {
        var urlRequest = URLRequest(url: source.url)
        urlRequest.allowsExpensiveNetworkAccess = false
        urlRequest.allowsConstrainedNetworkAccess = false
        let (temporary, response) = try await URLSession.shared.download(for: urlRequest)
        let fileManager = FileManager.default
        var kept = false
        defer { if !kept { try? fileManager.removeItem(at: temporary) } }
        guard isCurrent(ticket) else { return nil }
        let http = response as? HTTPURLResponse
        guard let http, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        let byteCount = Int64((try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard byteCount > 0 else { throw URLError(.zeroByteResource) }
        guard CachingAudioResourceLoader.canCache(contentLength: byteCount, maximumSizeMB: limitMB) else { return nil }
        let contentType = http.mimeType ?? http.value(forHTTPHeaderField: "Content-Type")
        guard let fileExtension = source.fileExtension.flatMap({ Self.sanitized($0) })
            ?? CachingAudioResourceLoader.fileExtension(for: source.url, contentType: contentType) else { return nil }
        let session = try await cache.beginWrite(trackID: track.id, requestedQuality: quality, servedQuality: source.servedQuality,
                                                 source: .netease, fileExtension: fileExtension, maximumSizeMB: limitMB)
        do {
            try fileManager.removeItem(at: session.partialFileURL)
            try fileManager.moveItem(at: temporary, to: session.partialFileURL)
            kept = true
        } catch {
            try? await cache.discard(session)
            throw error
        }
        switch try await cache.commitAndRetain(session, byteCount: byteCount, contentType: contentType) {
        case .retained(_, let lease):
            try? await cache.release(lease)
            return byteCount
        case .deferredDiscard, .rejectedForCurrentLimit:
            try? await cache.discard(session)
            return nil
        }
    }

    private static func sanitized(_ fileExtension: String) -> String? {
        let value = fileExtension.lowercased()
        guard !value.isEmpty, value.count <= 10, value.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains) else { return nil }
        return CachingAudioResourceLoader.resourceContentType(for: value) == nil ? nil : value
    }

    /// NetEase's own file at the chosen quality. Trials and songs it refuses
    /// are left to playback, which knows how to fall back.
    static func resolveSongURL(track: Track, quality: String) async throws -> QueuePrefetchSource? {
        guard let data = try await NeteaseAPI.songURL(ids: [track.id], level: quality).first,
              data.freeTrialInfo == nil, let string = data.url,
              let url = URL(string: string.replacingOccurrences(of: "http://", with: "https://")) else { return nil }
        return .init(url: url, servedQuality: data.level, byteCount: Int64(max(data.size, 0)), fileExtension: data.type)
    }

    /// The words and artwork a cached song shows offline, like a download.
    static func keepPlaybackData(track: Track, scope: String?) async {
        guard let scope else { return }
        let lyrics = try? await NeteaseAPI.lyric(id: track.id)
        guard !Task.isCancelled else { return }
        await OfflineMetadataStore.shared.keepPlaybackData(track: track, lyrics: lyrics, scope: scope)
    }
}
