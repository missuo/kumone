#if os(macOS)
import SwiftUI

struct AutoMixSettingsSection: View {
    @EnvironmentObject private var settings: SettingsManager

    var body: some View {
        Section("AutoMix") {
            Toggle("AutoMix", isOn: $settings.automixEnabled)
            Text("让歌曲丝滑衔接，让听感更流畅。关闭时使用系统 AVPlayer 播放，支持 AirPods 空间音频。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if settings.automixEnabled {
                Toggle("自动过渡", isOn: $settings.automixTransitionsEnabled)
                Toggle(isOn: $settings.automixOrderEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("智能顺序")
                        Text("按歌曲契合度排序，会增加网络用量。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("智能顺序")
                .accessibilityHint("按歌曲契合度排序，会增加网络用量。")
                Toggle("响度均衡", isOn: $settings.loudnessCompensationEnabled)
                #if arch(arm64)
                StemTransitionSettings()
                #endif
            }
        }
    }
}

/// Only these controls need model state; download progress never reaches the form root.
private struct StemTransitionSettings: View {
    @EnvironmentObject private var settings: SettingsManager
    @ObservedObject private var downloader = StemModelDownloader.shared

    var body: some View {
        Toggle(isOn: Binding(
            get: { settings.automixStemsEnabled && downloader.vocalsInstalled },
            set: { settings.automixStemsEnabled = $0 }
        )) {
            VStack(alignment: .leading, spacing: 4) {
                Text("增强过渡")
                Text("分离人声与伴奏，让衔接更自然。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(!downloader.vocalsInstalled)
        .accessibilityLabel("增强过渡")
        .accessibilityHint("分离人声与伴奏，让衔接更自然。")
        StemModelsSettingsSection()
        Text("下载后可用，耗电较高。")
            .font(.caption)
            .foregroundStyle(.secondary)
            // On a single view, so the models are hashed once per appearance.
            .task {
                downloader.refresh()
                await downloader.verifyInstalled()
            }
    }
}
#endif
