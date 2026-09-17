import SwiftUI

@MainActor
struct StorageSpaceView: View {
    let onManageDownloads: () -> Void
    @StateObject private var model = StorageSpaceModel()
    @ObservedObject private var cache = PlaybackCacheController.shared
    @EnvironmentObject private var settings: SettingsManager
    @State private var clearing: StorageCategory?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    if let capacity = model.snapshot?.device {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(deviceName).font(.headline)
                                Spacer()
                                capacityText(capacity)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(deviceName).font(.headline)
                                capacityText(capacity)
                            }
                        }
                        StorageCapacityBar(capacity: capacity, appBytes: model.snapshot?.appBytes ?? 0)
                    } else if model.isLoading {
                        HStack { ProgressView(); Text("正在计算存储空间…").foregroundStyle(.secondary) }
                    } else {
                        Text("暂时无法读取设备容量").foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                LabeledContent(model.snapshot?.partial == true ? String(localized: "已统计的 Kumone 占用") : String(localized: "Kumone 占用")) {
                    Text(model.snapshot.map { format($0.appBytes) } ?? "—")
                        .font(.body.weight(.semibold)).monospacedDigit()
                }
                if model.snapshot?.partial == true {
                    Text("部分存储信息暂时无法读取，请刷新重试").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                usageRow("图片缓存", icon: "photo.on.rectangle", category: .imageCache)
                Button(role: .destructive) { clearing = .imageCache } label: {
                    HStack {
                        Text("清理图片缓存")
                        if model.clearingCategory == .imageCache { Spacer(); ProgressView().controlSize(.small) }
                    }
                }
                    .disabled(busy || (model.snapshot?[.imageCache] ?? 0) == 0)
            } footer: {
                Text("浏览时保存的临时图片。清理后可重新加载，已下载歌曲的离线封面会保留。")
            }

            Section {
                usageRow("音乐缓存", icon: "music.note", category: .musicCache)
                Picker("缓存上限", selection: $settings.musicCachePolicy) {
                    ForEach(MusicCachePolicy.options) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                if settings.musicCachePolicy == .automatic, let capacity = cache.capacity {
                    LabeledContent("当前自动上限", value: format(capacity.limit))
                        .foregroundStyle(.secondary)
                }
                Button(role: .destructive) { clearing = .musicCache } label: {
                    HStack {
                        Text("清理音乐缓存")
                        if model.clearingCategory == .musicCache { Spacer(); ProgressView().controlSize(.small) }
                    }
                }
                    .disabled(busy || (model.snapshot?.clearableMusicCacheBytes ?? 0) == 0)
            } footer: {
                Text("自动缓存音乐，完整缓存的歌曲可离线播放。")
            }

            Section {
                Button(action: onManageDownloads) {
                    HStack {
                        Label("下载的音乐", systemImage: "arrow.down.circle")
                        Spacer()
                        Text(size(.downloads)).foregroundStyle(.secondary).monospacedDigit()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(.primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } footer: {
                if let other = model.snapshot?.otherAccountDownloads, other > 0 {
                    Text("包含其他账号的 \(format(other)) 下载。管理页显示当前账号的歌曲。")
                } else {
                    Text("已下载的歌曲会固定保留，可前往已下载页面管理。")
                }
            }

            Section {
                usageRow("应用与其他数据", icon: "internaldrive", category: .appData)
            } footer: {
                Text("包括应用本体、歌词、离线封面、账号资料与运行所需数据。")
            }

            if let message = model.message {
                Section { Text(message).font(.footnote).foregroundStyle(.secondary).accessibilityAddTraits(.updatesFrequently) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("存储空间")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #else
        .background(SettingsWindowToolbar())
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await model.reload() } } label: {
                    Image(systemName: "arrow.clockwise")
                }.disabled(busy).accessibilityLabel("刷新存储空间")
            }
        }
        .task(id: scenePhase) {
            if scenePhase == .active, !model.isClearing, clearing == nil {
                await cache.reconcile()
                await model.reload()
            }
        }
        .task(id: settings.musicCachePolicy) {
            await cache.reconcile()
            await model.reload()
        }
        .alert(clearTitle, isPresented: Binding(get: { clearing != nil }, set: { if !$0 { clearing = nil } }), presenting: clearing) { category in
            Button("清理", role: .destructive) {
                Task {
                    await model.clear(category)
                    if category == .musicCache {
                        await cache.reconcile(forceMetadataCleanup: true)
                        await model.reload()
                    }
                }
                clearing = nil
            }
            Button("取消", role: .cancel) { clearing = nil }
        } message: { category in
            Text(category == .imageCache
                 ? String(localized: "清理临时图片缓存，保留已下载歌曲的离线封面。")
                 : String(localized: "清理后，未下载的缓存歌曲需要联网才能再次播放。已下载和正在使用的音频会保留。"))
        }
    }

    private var busy: Bool { model.isLoading || model.isClearing }
    private var clearTitle: String {
        clearing == .imageCache ? String(localized: "清理图片缓存？") : String(localized: "清理音乐缓存？")
    }
    private var deviceName: String {
        #if os(macOS)
        return "Mac"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }
    private func size(_ category: StorageCategory) -> String {
        guard let snapshot = model.snapshot, !snapshot.unavailableCategories.contains(category) else { return "—" }
        return format(snapshot[category])
    }
    private func format(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    private func capacityText(_ capacity: DeviceStorageCapacity) -> some View {
        Text("已用 \(format(capacity.used))，共 \(format(capacity.total))")
            .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
    }
    private func usageRow(_ title: LocalizedStringKey, icon: String, category: StorageCategory) -> some View {
        LabeledContent {
            Text(size(category)).monospacedDigit().foregroundStyle(.secondary)
        } label: { Label(title, systemImage: icon) }
    }
}
