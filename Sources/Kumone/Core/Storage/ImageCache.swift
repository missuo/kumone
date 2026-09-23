import CryptoKit
import Foundation
import SwiftUI

/// Two-tier (memory + disk) image cache with in-flight request coalescing.
actor ImageCache {
    static let shared = ImageCache()
    typealias CachedImageHandler = @MainActor @Sendable (PlatformImage) -> Void

    private nonisolated(unsafe) let memory = NSCache<NSString, PlatformImage>()
    nonisolated let directory: URL
    private let session: URLSession
    private let offlineArtwork: @Sendable (URL) async -> Data?
    private var generation: UInt64 = 0
    private struct Request {
        let generation: UInt64
        let task: Task<PlatformImage?, Never>
    }
    private var inflight: [String: Request] = [:]

    init(directory: URL = KumonePaths.imageCache, session: URLSession = .shared,
         offlineArtwork: @escaping @Sendable (URL) async -> Data? = { await ImageCache.loadOfflineArtwork(for: $0) }) {
        self.directory = directory
        self.session = session
        self.offlineArtwork = offlineArtwork
        memory.countLimit = 300
        memory.totalCostLimit = 64 * 1024 * 1024
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static func loadOfflineArtwork(for url: URL) async -> Data? {
        guard let scope = await MainActor.run(body: { AccountStore.shared.offlineScope }) else { return nil }
        return await OfflineMetadataStore.shared.artwork(url: url, scope: scope)
    }

    /// Surface local pixels before waiting for a larger version. The returned
    /// image still prefers the requested resolution, including after reconnect.
    func image(for url: URL, onCachedImage: CachedImageHandler? = nil) async -> PlatformImage? {
        let key = Self.cacheKey(for: url)
        if let cached = memory.object(forKey: key as NSString) {
            return cached
        }
        let requestGeneration = generation
        if let onCachedImage,
           let preview = diskImage(for: key) ?? cachedVariant(for: url) {
            await onCachedImage(preview)
        }
        guard !Task.isCancelled else { return nil }
        // Delivering the preview hops to MainActor; another caller may have
        // completed the exact request while this actor was suspended.
        if let cached = memory.object(forKey: key as NSString) { return cached }
        if let existing = inflight[key] {
            let result = await existing.task.value
            return result ?? cachedVariant(for: url)
        }
        let task = Task<PlatformImage?, Never> { [self] in
            let fileURL = directory.appendingPathComponent(key)
            if let image = diskImage(for: key) {
                return image
            }
            if let data = await offlineArtwork(url),
               let image = PlatformImage(data: data) { return image }
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                  let image = PlatformImage(data: data) else { return nil }
            if generation == requestGeneration { try? data.write(to: fileURL, options: .atomic) }
            return image
        }
        inflight[key] = Request(generation: requestGeneration, task: task)
        let result = await task.value
        if inflight[key]?.generation == requestGeneration { inflight[key] = nil }
        if generation == requestGeneration, let result {
            let width = result.size.width
            let height = result.size.height
            memory.setObject(result, forKey: key as NSString,
                             cost: Int(width * height * 4))
        }
        // Do not store a smaller fallback under the requested size: a later
        // online request must still be able to fetch the full-resolution image.
        return result ?? cachedVariant(for: url)
    }

    private func diskImage(for key: String) -> PlatformImage? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(key)) else { return nil }
        return PlatformImage(data: data)
    }

    private func cachedVariant(for url: URL) -> PlatformImage? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.queryItems?.contains(where: { $0.name == "param" }) == true else { return nil }
        let otherItems = components.queryItems?.filter { $0.name != "param" } ?? []
        // Sizes used by app surfaces, including existing on-disk caches from
        // before cross-size fallback. Probe largest first without a disk scan.
        let sizes = [1024, 768, 640, 512, 384, 256, 160, 128, 120, 96, 80, 64, 48]
        for size in [nil] + sizes.map(Optional.some) {
            components.queryItems = otherItems + (size.map { [URLQueryItem(name: "param", value: "\($0)y\($0)")] } ?? [])
            if components.queryItems?.isEmpty == true { components.queryItems = nil }
            guard let candidate = components.url, candidate != url else { continue }
            let key = Self.cacheKey(for: candidate)
            if let image = memory.object(forKey: key as NSString) { return image }
            if let image = diskImage(for: key) { return image }
        }
        return nil
    }

    func usage() throws -> CacheUsage {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        let bytes = files.reduce(Int64(0)) { total, file in
            total + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return CacheUsage(bytes: bytes)
    }

    /// Existing views may finish loading their image, but requests started
    /// before the clear cannot refill either disk or memory caches afterwards.
    func clear() throws {
        generation += 1
        memory.removeAllObjects()
        if FileManager.default.fileExists(atPath: directory.path) {
            let info = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard info.isDirectory == true, info.isSymbolicLink != true else { throw OfflineAudioError.invalidResource }
            try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Synchronous in-memory lookup — safe off the actor (`NSCache` is
    /// thread-safe). Returns nil unless the image is resident in memory; use
    /// `image(for:)` for disk/network loads.
    nonisolated func cachedImage(for url: URL) -> PlatformImage? {
        memory.object(forKey: Self.cacheKey(for: url) as NSString)
    }

    private static func cacheKey(for url: URL) -> String {
        let digest = Insecure.MD5.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Keep pixels bound to their source, even while SwiftUI reuses a view for a
/// different URL or a cancelled request finishes after the next one starts.
struct CachedImageState {
    private(set) var url: URL?
    private var image: PlatformImage?

    init(url: URL? = nil, image: PlatformImage? = nil) {
        self.url = url
        self.image = image
    }

    func image(for url: URL?) -> PlatformImage? {
        guard let url, self.url == url else { return nil }
        return image
    }

    mutating func finish(_ image: PlatformImage?, for url: URL) {
        guard self.url == url else { return }
        self.image = image
    }
}

/// AsyncImage replacement backed by `ImageCache`, with a crossfade reveal.
struct CachedAsyncImage<Placeholder: View>: View {
    let url: URL?
    var animated: Bool = true
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var imageState: CachedImageState

    init(url: URL?, animated: Bool = true,
         @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.animated = animated
        self.placeholder = placeholder
        // Seed from the in-memory cache so a re-created view (e.g. the iOS 26
        // tab-bar accessory rebuilt on a tab switch, #46) shows already-decoded
        // artwork immediately instead of flashing the placeholder.
        let seeded = url.flatMap { ImageCache.shared.cachedImage(for: $0) }
        _imageState = State(initialValue: CachedImageState(url: url, image: seeded))
    }

    var body: some View {
        ZStack {
            placeholder()
            if let image = imageState.image(for: url) {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(animated ? .opacity.animation(.easeIn(duration: 0.22)) : .identity)
            }
        }
        .task(id: url) {
            guard let url else {
                imageState = CachedImageState()
                return
            }
            // Synchronous memory hit first — no actor hop, no placeholder frame.
            let memoryHit = ImageCache.shared.cachedImage(for: url)
            if imageState.url != url || memoryHit != nil {
                imageState = CachedImageState(url: url, image: memoryHit)
            }
            guard memoryHit == nil else { return }
            let cached = await ImageCache.shared.image(for: url) { preview in
                guard !Task.isCancelled else { return }
                imageState.finish(preview, for: url)
            }
            guard !Task.isCancelled, let cached else { return }
            imageState.finish(cached, for: url)
        }
    }
}

extension CachedAsyncImage where Placeholder == AnyView {
    /// Default placeholder: a quiet neutral fill with a music note.
    init(url: URL?, animated: Bool = true) {
        self.init(url: url, animated: animated) {
            AnyView(
                ZStack {
                    Rectangle().fill(.quaternary.opacity(0.5))
                    Image(systemName: "music.note")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.quaternary)
                }
            )
        }
    }
}
