import CryptoKit
import Foundation
import SwiftUI

/// Two-tier (memory + disk) image cache with in-flight request coalescing.
actor ImageCache {
    static let shared = ImageCache()

    private nonisolated(unsafe) let memory = NSCache<NSString, PlatformImage>()
    private let diskURL: URL
    private var inflight: [String: Task<PlatformImage?, Never>] = [:]

    private init() {
        memory.countLimit = 300
        memory.totalCostLimit = 64 * 1024 * 1024
        diskURL = KumonePaths.imageCache
        try? FileManager.default.createDirectory(at: diskURL, withIntermediateDirectories: true)
    }

    func image(for url: URL) async -> PlatformImage? {
        let key = Self.cacheKey(for: url)
        if let cached = memory.object(forKey: key as NSString) {
            return cached
        }
        if let existing = inflight[key] {
            return await existing.value
        }
        let task = Task<PlatformImage?, Never> { [diskURL] in
            let fileURL = diskURL.appendingPathComponent(key)
            if let data = try? Data(contentsOf: fileURL), let image = PlatformImage(data: data) {
                return image
            }
            if let scope = await MainActor.run(body: { AccountStore.shared.offlineScope }),
               let data = await OfflineMetadataStore.shared.artwork(url: url, scope: scope),
               let image = PlatformImage(data: data) { return image }
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                  let image = PlatformImage(data: data) else { return nil }
            try? data.write(to: fileURL, options: .atomic)
            return image
        }
        inflight[key] = task
        let result = await task.value
        inflight[key] = nil
        if let result {
            let width = result.size.width
            let height = result.size.height
            memory.setObject(result, forKey: key as NSString,
                             cost: Int(width * height * 4))
        }
        return result
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

/// AsyncImage replacement backed by `ImageCache`, with a crossfade reveal.
struct CachedAsyncImage<Placeholder: View>: View {
    let url: URL?
    var animated: Bool = true
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: PlatformImage?
    @State private var loadedURL: URL?

    init(url: URL?, animated: Bool = true,
         @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.animated = animated
        self.placeholder = placeholder
        // Seed from the in-memory cache so a re-created view (e.g. the iOS 26
        // tab-bar accessory rebuilt on a tab switch, #46) shows already-decoded
        // artwork immediately instead of flashing the placeholder.
        let seeded = url.flatMap { ImageCache.shared.cachedImage(for: $0) }
        _image = State(initialValue: seeded)
        _loadedURL = State(initialValue: seeded == nil ? nil : url)
    }

    var body: some View {
        ZStack {
            placeholder()
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(animated ? .opacity.animation(.easeIn(duration: 0.22)) : .identity)
            }
        }
        .task(id: url) {
            guard let url else {
                image = nil
                loadedURL = nil
                return
            }
            guard url != loadedURL else { return }
            // Synchronous memory hit first — no actor hop, no placeholder frame.
            if let memoryHit = ImageCache.shared.cachedImage(for: url) {
                image = memoryHit
                loadedURL = url
                return
            }
            if let cached = await ImageCache.shared.image(for: url) {
                guard !Task.isCancelled else { return }
                image = cached
                loadedURL = url
            }
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
