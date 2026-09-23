import SwiftUI

@MainActor
struct StorageSpaceView: View {
    let onManageDownloads: () -> Void
    @StateObject private var model = StorageSpaceModel()
    @EnvironmentObject private var settings: SettingsManager
    @State private var clearing: StorageCategory?
    #if os(iOS)
    @State private var automaticLimitMB: Int?
    #endif
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
                        Text("清除图片缓存")
                        if model.clearingCategory == .imageCache { Spacer(); ProgressView().controlSize(.small) }
                    }
                }
                    .disabled(busy || (model.snapshot?[.imageCache] ?? 0) == 0)
            } footer: {
                Text("浏览时保存的临时图片。清除后可重新加载，已下载歌曲的离线封面会保留。")
            }

            Section {
                usageRow("歌曲缓存", icon: "music.note", category: .musicCache)
                #if os(macOS)
                Picker("歌曲缓存上限", selection: $settings.audioCacheLimit) {
                    Text("512 MB").tag(Int64(512) << 20)
                    Text("2 GB").tag(Int64(2) << 30)
                    Text("8 GB").tag(Int64(8) << 30)
                    Text("不限").tag(Int64(0))
                }
                #else
                Toggle("歌曲缓存", isOn: $settings.enableAudioCache)
                if settings.enableAudioCache {
                    Picker("歌曲缓存上限", selection: cacheLimitSelection) {
                        if let automaticLimitMB {
                            Text("自动（\(format(Int64(automaticLimitMB) * 1_000_000))）").tag(0)
                        } else {
                            Text("自动").tag(0)
                        }
                        ForEach(manualCacheLimitsMB, id: \.self) { megabytes in
                            Text(format(Int64(megabytes) * 1_000_000)).tag(megabytes)
                        }
                    }
                }
                #endif
                Button(role: .destructive) { clearing = .musicCache } label: {
                    HStack {
                        Text("清除歌曲缓存")
                        if model.clearingCategory == .musicCache { Spacer(); ProgressView().controlSize(.small) }
                    }
                }
                    .disabled(busy || (model.snapshot?[.musicCache] ?? 0) == 0)
            } footer: {
                Text("最近播放过的歌曲会暂存在本机，断网时也能重播。已下载的歌曲不占用这里的空间。")
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
                await model.reload()
            }
        }
        #if os(macOS)
        .onChange(of: settings.audioCacheLimit) { _, _ in
            Task { await model.reload() }
        }
        #else
        .task(id: [settings.enableAudioCache ? (settings.audioCacheAutomatic ? -1 : settings.audioCacheSizeMB) : 0]) {
            guard settings.enableAudioCache else { return }
            let limit = await settings.effectiveAudioCacheSizeMB()
            automaticLimitMB = settings.audioCacheAutomatic ? limit : nil
            try? await AudioCache.shared.enforce(maximumSizeMB: limit)
            await model.reload()
        }
        #endif
        .alert(clearTitle, isPresented: Binding(get: { clearing != nil }, set: { if !$0 { clearing = nil } }), presenting: clearing) { category in
            Button("清除", role: .destructive) {
                Task { await model.clear(category) }
                clearing = nil
            }
            Button("取消", role: .cancel) { clearing = nil }
        } message: { category in
            Text(category == .imageCache
                 ? String(localized: "清除临时图片缓存，保留已下载歌曲的离线封面。")
                 : String(localized: "清除后，缓存过的歌曲需要联网才能再次播放。已下载的歌曲不受影响。"))
        }
    }

    private var busy: Bool { model.isLoading || model.isClearing }
    #if os(iOS)
    /// Tag 0 is the automatic limit; the rest are megabytes.
    private var cacheLimitSelection: Binding<Int> {
        Binding(get: { settings.audioCacheAutomatic ? 0 : settings.audioCacheSizeMB },
                set: { value in
                    if value == 0 { settings.audioCacheAutomatic = true }
                    else { settings.audioCacheAutomatic = false; settings.audioCacheSizeMB = value }
                })
    }
    private var manualCacheLimitsMB: [Int] {
        var sizes = [500, 1_000, 2_000, 5_000, 10_000]
        // A size chosen on the old slider stays selectable until it is changed.
        if !settings.audioCacheAutomatic, !sizes.contains(settings.audioCacheSizeMB) {
            sizes.append(settings.audioCacheSizeMB)
            sizes.sort()
        }
        return sizes
    }
    #endif
    private var clearTitle: String {
        clearing == .imageCache ? String(localized: "清除图片缓存？") : String(localized: "清除歌曲缓存？")
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
