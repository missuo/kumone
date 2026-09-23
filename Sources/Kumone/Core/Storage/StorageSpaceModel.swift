import Foundation

@MainActor
final class StorageSpaceModel: ObservableObject {
    @Published private(set) var snapshot: StorageUsageSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var isClearing = false
    @Published private(set) var clearingCategory: StorageCategory?
    @Published private(set) var message: String?
    private let reader: StorageUsageReader
    private let audio: OfflineStore
    private let images: ImageCache
    private let accountScope: @MainActor () -> String?

    init(reader: StorageUsageReader? = nil, audio: OfflineStore = .shared, images: ImageCache = .shared,
         accountScope: @escaping @MainActor () -> String? = { AccountStore.shared.offlineScope }) {
        self.audio = audio
        self.images = images
        let musicCaches = Self.musicCacheDirectories
        self.reader = reader ?? StorageUsageReader(
            roots: KumonePaths.storageRoots + [images.directory, Bundle.main.bundleURL] + musicCaches,
            imageDirectory: images.directory, musicCacheDirectories: musicCaches,
            downloadDirectory: audio.directory.appendingPathComponent("downloads"),
            volumeURL: KumonePaths.applicationSupport)
        self.accountScope = accountScope
    }

    /// The song cache the player on this platform actually writes to.
    static var musicCacheDirectories: [URL] {
        #if os(macOS)
        [KumoneDirectories.caches("Audio")]
        #else
        [AudioCache.shared.directory]
        #endif
    }

    func reload(clearMessage: Bool = true) async {
        guard !isLoading else { return }
        if clearMessage { message = nil }
        isLoading = true
        defer { isLoading = false }
        do {
            let files = try await audio.storageFiles()
            snapshot = await reader.read(audioFiles: files, accountScope: accountScope())
        } catch {
            // Image usage remains useful when the audio index cannot be read.
            var result = await reader.read(audioFiles: [], accountScope: accountScope())
            result.partial = true
            result.unavailableCategories = [.musicCache, .downloads, .appData]
            snapshot = result
            message = String(localized: "部分存储信息暂时无法读取，请刷新重试")
        }
    }

    func clear(_ category: StorageCategory) async {
        guard !isClearing, !isLoading else { return }
        isClearing = true
        clearingCategory = category
        message = nil
        defer { isClearing = false; clearingCategory = nil }
        do {
            switch category {
            case .imageCache:
                try await images.clear()
                message = String(localized: "图片缓存已清除")
            case .musicCache:
                #if os(macOS)
                await EngineAudioCache.shared.removeAll()
                #else
                try await AudioCache.shared.clear()
                #endif
                message = String(localized: "歌曲缓存已清除")
            default: return
            }
        } catch { message = String(localized: "缓存清除失败，请稍后重试") }
        await reload(clearMessage: false)
    }
}
