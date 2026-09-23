import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsManager
    @EnvironmentObject private var account: AccountStore
    @Environment(\.openDestination) private var openDestination
    @Environment(\.dismiss) private var dismiss
    @State private var audioCacheUsage: String = String(localized: "计算中…")
    @State private var imageCacheUsage: String = String(localized: "计算中…")
    @State private var cacheError: String?
    #if os(macOS)
    @ObservedObject private var downloader = StemModelDownloader.shared
    @State private var audioCacheSize: String = String(localized: "计算中…")
    #endif

    var body: some View {
        #if os(macOS)
        NavigationStack { settingsForm }
            .background(SettingsWindowToolbar())
            .frame(width: 520, height: 620)
        #else
        settingsForm
        #endif
    }

    private var settingsForm: some View {
        Form {
            Section("播放") {
                Picker("音质", selection: $settings.audioQuality) {
                    ForEach(AudioQuality.allCases) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
                Text("无损与 Hi-Res 需要黑胶 VIP，未开通时自动回落到可用音质")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("灰色歌曲解锁", isOn: $settings.enableUnblock)
                Text("无版权或下架歌曲将从已启用音源中匹配播放")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #if os(macOS)

            // AutoMix is a group of its own because it is a group of costs:
            // the master switch buys analysis, and each sub-switch below adds
            // one specific bill (a seam, extra downloads, the GPU) on top.
            Section {
                Toggle("AutoMix", isOn: $settings.automixEnabled)
                    .onChange(of: settings.automixEnabled) { _, _ in
                        PlayerService.shared.reconcileQueueOrderAvailability()
                    }
                Text("分析已下载的歌曲，自动衔接队列里的歌。所有分析都在本机完成。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("自动过渡", isOn: $settings.automixTransitionsEnabled)
                    .disabled(!settings.automixEnabled)
                Text("在两首歌之间做节拍对齐的过渡。只分析本来就要播放的歌曲，不产生额外下载。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("智能顺序", isOn: $settings.automixOrderEnabled)
                    .disabled(!settings.automixEnabled)
                    .onChange(of: settings.automixOrderEnabled) { _, _ in
                        PlayerService.shared.reconcileQueueOrderAvailability()
                    }
                Text("按过渡效果重排队列，随机按钮会多出一个 AutoMix 状态。需要额外下载候选歌曲（标准音质）来打分。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("统一歌曲响度", isOn: $settings.loudnessCompensationEnabled)
                    .disabled(!settings.automixEnabled)
                Text("按每首歌的母带响度调整播放增益，下一首不会突然变响；需要开启 AutoMix")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Stem separation runs on MLX, which is Apple silicon only —
                // the x86_64 slice of the universal app never offers it.
                #if arch(arm64)
                // Off *and* unavailable until the model is on disk: a toggle
                // that cannot do anything must not look like it can, and the
                // section below is where it becomes possible.
                Toggle("增强过渡（人声 / 鼓分离）",
                       isOn: stemsBinding)
                    .disabled(!settings.automixEnabled || !stemModelsInstalled)
                Text("用本机 GPU 分离音轨，过渡更干净。需要下载模型，播放时会占用 GPU 并增加发热和耗电。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                StemModelsSettingsSection()
                #endif
            } header: {
                Text("AutoMix")
            } footer: {
                Text("对古典、现场录音、有声书等内容效果不佳，遇到这类歌单可在这里暂时关闭。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #endif

            if settings.enableUnblock {
                Section {
                    ForEach(AudioSourceID.allCases, id: \.self) { source in
                        Toggle(source.displayName, isOn: Binding(
                            get: { settings.enabledAudioSourceIDs.contains(source) },
                            set: { isEnabled in
                                if isEnabled {
                                    settings.enabledAudioSourceIDs.insert(source)
                                } else {
                                    settings.enabledAudioSourceIDs.remove(source)
                                }
                            }
                        ))
                    }
                } header: {
                    Text("音源")
                }
            }

            Section("外观") {
                Picker("主题", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.displayName).tag(appearance)
                    }
                }
                #if os(macOS)
                // macOS only renders two now-playing layouts — 黑胶 and the
                // regular page; the iOS 沉浸/简洁 options all fall back to the
                // regular page here, so offering four was misleading (#105).
                // Map any non-vinyl value onto 经典模式 so a stored default (e.g.
                // 沉浸模式) still shows a valid selection.
                Picker("播放页模式", selection: Binding(
                    get: { settings.nowPlayingMode == .vinyl ? .vinyl : .classic },
                    set: { settings.nowPlayingMode = $0 }
                )) {
                    Text(NowPlayingMode.vinyl.displayName).tag(NowPlayingMode.vinyl)
                    Text(NowPlayingMode.classic.displayName).tag(NowPlayingMode.classic)
                }
                #else
                Picker("播放页模式", selection: $settings.nowPlayingMode) {
                    ForEach(NowPlayingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                #endif
                Toggle("显示歌词翻译", isOn: $settings.showLyricsTranslation)
                Toggle("逐字歌词（卡拉OK）", isOn: $settings.verbatimLyrics)
                Picker("日文歌词读音", selection: $settings.lyricsAnnotation) {
                    ForEach(LyricsAnnotation.allCases) { annotation in
                        Text(annotation.displayName).tag(annotation)
                    }
                }
                Text("罗马音在歌词上方另起一行，汉字读音把假名标在汉字正上方；缺少官方罗马音时自动生成读音")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("主界面环境色", isOn: $settings.showMainWindowAmbientBackground)
                if settings.showMainWindowAmbientBackground {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("背景色强度")
                            Spacer()
                            Text("\(Int(settings.mainWindowAmbientBackgroundIntensity * 100))%")
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: $settings.mainWindowAmbientBackgroundIntensity,
                            in: SettingsManager.mainWindowAmbientBackgroundIntensityRange,
                            step: 0.1
                        )
                        HStack {
                            Text("50%")
                            Spacer()
                            Text("150%")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                #if os(macOS)
                Toggle("桌面歌词", isOn: $settings.showDesktopLyrics)
                if settings.showDesktopLyrics {
                    Toggle("桌面歌词水平居中", isOn: $settings.desktopLyricsCentered)
                }
                Text("在屏幕上悬浮显示当前歌词，可拖动调整位置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
            }

            Section("存储") {
                NavigationLink {
                    StorageSpaceView {
                        #if os(iOS)
                        dismiss()
                        #endif
                        openDestination(.downloaded)
                    }
                } label: {
                    Label("存储空间", systemImage: "internaldrive")
                }
                #if os(iOS)
                // The cross-platform #109 song cache. On macOS the real playback
                // cache is EngineAudioCache (its own controls below), so these
                // controls would be inert there — keep them iOS-only.
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(
                        "歌曲缓存",
                        isOn: Binding(
                            get: { settings.enableAudioCache },
                            set: { enabled in
                                settings.enableAudioCache = enabled
                                if enabled {
                                    Task { await enforceAudioCacheLimit() }
                                }
                            }
                        )
                    )
                    Text("关闭后将不读取或缓存歌曲")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if settings.enableAudioCache {
                        Slider(
                            value: Binding(
                                get: { Double(settings.audioCacheSizeMB) },
                                set: { settings.audioCacheSizeMB = Int($0.rounded()) }
                            ),
                            in: Double(SettingsManager.audioCacheSizeRangeMB.lowerBound)...Double(
                                SettingsManager.audioCacheSizeRangeMB.upperBound
                            ),
                            step: Double(SettingsManager.audioCacheSizeStepMB)
                        )
                        HStack {
                            Text("100 MB")
                            Spacer()
                            Text("1 GB")
                        }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("\(audioCacheUsage) / \(audioCacheLimit)")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("清理") {
                            Task { await clearAudioCache() }
                        }
                    }
                }
                #endif
                VStack(alignment: .leading, spacing: 6) {
                    Text("图片缓存")
                    HStack {
                        HStack(spacing: 4) {
                            Text("已占用")
                            Text(imageCacheUsage)
                        }
                        .foregroundStyle(.secondary)
                        Spacer()
                        Button("清理") {
                            Task { await clearImageCache() }
                        }
                    }
                }
                if let cacheError {
                    Text(cacheError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                #if os(macOS)
                LabeledContent("歌曲缓存", value: audioCacheSize)
                Picker("歌曲缓存上限", selection: $settings.audioCacheLimit) {
                    Text("512 MB").tag(Int64(512) << 20)
                    Text("2 GB").tag(Int64(2) << 30)
                    Text("8 GB").tag(Int64(8) << 30)
                    Text("不限").tag(Int64(0))
                }
                .onChange(of: settings.audioCacheLimit) { _, _ in
                    updateAudioCacheSize()
                }
                Button("清除歌曲缓存") {
                    Task {
                        await EngineAudioCache.shared.removeAll()
                        updateAudioCacheSize()
                        ToastCenter.shared.show(String(localized: "歌曲缓存已清除"))
                    }
                }
                #endif
            }

            Section("账号") {
                if let profile = account.profile {
                    LabeledContent("当前账号", value: profile.nickname)
                    Button("退出登录", role: .destructive) {
                        Task { await AccountStore.shared.logout() }
                    }
                } else {
                    Text("未登录")
                        .foregroundStyle(.secondary)
                }
            }

            Section("更新") {
                Toggle("启动时自动检查更新", isOn: $settings.autoCheckUpdates)
                Text("关闭后启动不再自动弹出更新提示，仍可手动检查更新")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("关于") {
                LabeledContent("Kumone", value: appVersion)
                #if os(iOS)
                Button {
                    IOSUpdater.shared.check(interactive: true)
                } label: {
                    Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                }
                Text("装有 TrollStore（巨魔）可在应用内一键自动安装；否则可下载 IPA 用侧载工具重装（登录状态与设置保留）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
                Text("网易云音乐第三方客户端 · 数据来自网易云音乐")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            await refreshCacheUsage()
            await enforceAudioCacheLimit()
            #if os(macOS)
            updateAudioCacheSize()
            #endif
        }
        #if os(macOS)
        .onChange(of: settings.audioCacheSizeMB) { _, _ in
            Task { await enforceAudioCacheLimit() }
        }
        #else
        .onChange(of: settings.audioCacheSizeMB) { _ in
            Task { await enforceAudioCacheLimit() }
        }
        #endif
    }
    #if os(macOS)

    /// Whether the two-stem model is on disk, read from the downloader so the
    /// toggle flips the moment a download lands (the launcher wires the
    /// separator in via `onInstalled`; `StemSeparation.isAvailable` is not
    /// observable and only says what was installed at launch).
    private var stemModelsInstalled: Bool { downloader.vocalsInstalled }

    /// Reads as off whenever the models are missing, however the stored
    /// setting stands: the toggle must never claim a capability the machine
    /// does not have. The stored value is left alone so turning it on once and
    /// installing the models later still works.
    private var stemsBinding: Binding<Bool> {
        Binding(get: { settings.automixStemsEnabled && stemModelsInstalled },
                set: { settings.automixStemsEnabled = $0 })
    }

    private func updateAudioCacheSize() {
        Task {
            let bytes = await EngineAudioCache.shared.totalUsageBytes()
            audioCacheSize = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
    }
    #endif

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    private var audioCacheLimit: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(settings.audioCacheSizeMB) * 1_000_000,
            countStyle: .file
        )
    }

    private func refreshCacheUsage() async {
        do {
            audioCacheUsage = (try await AudioCache.shared.usage()).formatted
        } catch {
            cacheError = error.localizedDescription
        }
        do {
            imageCacheUsage = (try await ImageCache.shared.usage()).formatted
        } catch {
            cacheError = error.localizedDescription
        }
    }

    private func enforceAudioCacheLimit() async {
        guard settings.enableAudioCache else { return }
        do {
            try await AudioCache.shared.enforce(maximumSizeMB: settings.audioCacheSizeMB)
            await refreshCacheUsage()
        } catch {
            cacheError = error.localizedDescription
        }
    }

    private func clearAudioCache() async {
        do {
            try await AudioCache.shared.clear()
            ToastCenter.shared.show(String(localized: "歌曲缓存已清除"))
            await refreshCacheUsage()
        } catch {
            cacheError = error.localizedDescription
        }
    }

    private func clearImageCache() async {
        do {
            try await ImageCache.shared.clear()
            ToastCenter.shared.show(String(localized: "图片缓存已清除"))
            await refreshCacheUsage()
        } catch {
            cacheError = error.localizedDescription
        }
    }
}

#if os(macOS)
/// A Settings scene keeps its preference-style toolbar even when given a
/// scene-level windowToolbarStyle. Configure this window through AppKit so
/// navigation shares the title bar instead of becoming a centered second row.
struct SettingsWindowToolbar: NSViewRepresentable {
    func makeNSView(context: Context) -> ToolbarHost { ToolbarHost() }

    func updateNSView(_ nsView: ToolbarHost, context: Context) {
        nsView.updateToolbar()
    }

    final class ToolbarHost: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateToolbar()
        }

        func updateToolbar() {
            DispatchQueue.main.async { [weak self] in
                guard let window = self?.window, window.toolbarStyle != .unifiedCompact else { return }
                window.toolbarStyle = .unifiedCompact
            }
        }
    }
}
#endif
