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
    private let downloadIDs: @MainActor () -> Set<String>
    private let accountScope: @MainActor () -> String?
    private let refreshDownloads: @MainActor () async -> Void

    init(reader: StorageUsageReader? = nil, audio: OfflineStore = .shared, images: ImageCache = .shared,
         downloadIDs: @escaping @MainActor () -> Set<String> = { DownloadManager.shared.storageAssetIDs },
         accountScope: @escaping @MainActor () -> String? = { AccountStore.shared.offlineScope },
         refreshDownloads: @escaping @MainActor () async -> Void = { await DownloadManager.shared.refreshLibrary() }) {
        self.audio = audio
        self.images = images
        self.reader = reader ?? StorageUsageReader(
            roots: KumonePaths.storageRoots + [images.directory, Bundle.main.bundleURL],
            imageDirectory: images.directory, downloadDirectory: audio.directory.appendingPathComponent("downloads"),
            volumeURL: KumonePaths.applicationSupport)
        self.downloadIDs = downloadIDs
        self.accountScope = accountScope
        self.refreshDownloads = refreshDownloads
    }

    func reload(clearMessage: Bool = true) async {
        guard !isLoading else { return }
        if clearMessage { message = nil }
        isLoading = true
        defer { isLoading = false }
        do {
            let files = try await audio.storageFiles()
            snapshot = await reader.read(audioFiles: files, downloadAssetIDs: downloadIDs(), accountScope: accountScope())
        } catch {
            // Image usage remains useful when the audio index cannot be read.
            var result = await reader.read(audioFiles: [], downloadAssetIDs: [], accountScope: accountScope())
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
                message = String(localized: "图片缓存已清理")
            case .musicCache:
                let result = try await audio.clearMusicCache(excluding: downloadIDs())
                if result.failed > 0 { message = String(localized: "部分音乐缓存未能清理，请重试") }
                else if result.inUse > 0 { message = String(localized: "音乐缓存已清理，正在使用的音频已保留") }
                else { message = String(localized: "音乐缓存已清理") }
                await refreshDownloads()
            default: return
            }
        } catch { message = String(localized: "缓存清理失败，请稍后重试") }
        await reload(clearMessage: false)
    }
}
