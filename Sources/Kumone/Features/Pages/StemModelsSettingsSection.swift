#if os(macOS)
import SwiftUI

/// The 分离模型 rows of the settings page.
///
/// Deliberately *not* wrapped in a `Section`: it is dropped inside the AutoMix
/// group next to the 增强过渡 toggle, which is the only place the models mean
/// anything, and a nested Section there would draw a second card.
@MainActor
struct StemModelsSettingsSection: View {

    @ObservedObject private var downloader = StemModelDownloader.shared

    var body: some View {
        ForEach(downloader.specs) { spec in
            row(for: spec)
        }
        Text("从 GitHub 下载，校验后存放在本机")
            .font(.caption)
            .foregroundStyle(.secondary)
            .task {
                downloader.refresh()
                await downloader.verifyInstalled()
            }
    }

    @ViewBuilder
    private func row(for spec: StemModelSpec) -> some View {
        let state = downloader.state(for: spec)
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(spec.displayName)
                Text("\(spec.sizeLabel) · \(statusText(spec, state))")
                    .font(.caption)
                    .foregroundStyle(state.isFailure ? Color.red : Color.secondary)
                if case .downloading(let progress) = state {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 200)
                }
            }
            Spacer()
            control(spec, state)
        }
    }

    @ViewBuilder
    private func control(_ spec: StemModelSpec, _ state: StemModelState) -> some View {
        switch state {
        case .installed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .downloading:
            Button("取消") { downloader.cancel(spec) }
                .buttonStyle(.borderless)
        case .verifying:
            ProgressView()
                .controlSize(.small)
        case .notInstalled:
            Button("下载") { downloader.download(spec) }
        case .failed:
            Button("重试") { downloader.download(spec) }
        }
    }

    private func statusText(_ spec: StemModelSpec, _ state: StemModelState) -> String {
        switch state {
        case .notInstalled:
            return String(localized: "未下载")
        case .downloading(let progress):
            return String(localized: "下载中 \(Int(progress * 100))%")
        case .verifying:
            return String(localized: "校验中…")
        case .installed:
            return String(localized: "已安装")
        case .failed(let message):
            return message
        }
    }
}

extension StemModelState {
    fileprivate var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
#endif
