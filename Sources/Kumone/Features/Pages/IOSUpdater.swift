#if os(iOS)
import SwiftUI
import UIKit

/// iOS in-app updater, Dopamine-style. Detects a newer GitHub release,
/// downloads the IPA with a circular progress ring, then hands it to
/// TrollStore for installation via `apple-magnifier://install?url=`.
///
/// Auto-install requires **TrollStore** (which registers the
/// `apple-magnifier` scheme and installs unsigned IPAs system-wide). On a
/// plain AltStore/SideStore sideload there is no such install primitive, so
/// the updater falls back to opening the release page for a manual reinstall.
@MainActor
final class IOSUpdater: NSObject, ObservableObject {
    static let shared = IOSUpdater()

    enum Phase {
        case idle
        case checking
        case upToDate
        case available(ReleaseChecker.Release)
        case downloading(Double)        // 0…1
        case readyToInstall(URL)        // local .ipa (non-TrollStore)
        case handedOff                  // passed to TrollStore
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var showSheet = false

    private var downloadTask: URLSessionDownloadTask?
    private var progressContinuation: CheckedContinuation<URL, Error>?
    /// Destination filename for the current download. Set on the main actor in
    /// `download(_:)` before the task starts, then read once from the download
    /// delegate queue — the download is single-flight, so this hand-off is safe.
    nonisolated(unsafe) private var pendingDownloadFilename = "Kumone.ipa"

    func check(interactive: Bool) {
        phase = .checking
        if interactive { showSheet = true }
        Task {
            do {
                let latest = try await ReleaseChecker.latest()
                if ReleaseChecker.isNewer(latest.version, than: ReleaseChecker.currentVersion) {
                    phase = .available(latest)
                    showSheet = true
                } else {
                    phase = .upToDate
                    if !interactive { showSheet = false }
                }
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// TrollStore path (Dopamine-style): hand the remote IPA URL straight to
    /// TrollStore via its `apple-magnifier://install` scheme. We do **not**
    /// detect TrollStore first — detection via `canOpenURL` /
    /// `LSApplicationProxy` is unreliable and produced false negatives (present
    /// but reported "not detected"). `UIApplication.open` does not require the
    /// scheme to be whitelisted, so we always fire it: if TrollStore is
    /// installed it fetches and installs the IPA with its own privileges and
    /// relaunches; if it is not, `open` fails and we point the user at the
    /// manual download.
    func installViaTrollStore(_ release: ReleaseChecker.Release) {
        guard let ipaURL = release.ipaURL else {
            openReleasePage(release)
            return
        }
        // Percent-encode the whole URL as the `url` query value so TrollStore's
        // parser reconstructs it exactly (GitHub asset URLs are otherwise safe,
        // but this is robust against any reserved characters).
        let encoded = ipaURL.absoluteString
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ipaURL.absoluteString
        guard let url = URL(string: "apple-magnifier://install?url=\(encoded)") else {
            phase = .failed(String(localized: "无法构造安装链接"))
            return
        }
        UIApplication.shared.open(url) { [weak self] success in
            Task { @MainActor in
                self?.phase = success
                    ? .handedOff
                    : .failed(String(localized: "无法唤起 TrollStore，请改用「下载 IPA」手动侧载"))
            }
        }
    }

    /// Non-TrollStore path: download the IPA into Documents (findable in the
    /// Files app under On My iPhone ▸ Kumone), then open the share sheet so the
    /// user can Save to Files or hand it straight to a signing app.
    func download(_ release: ReleaseChecker.Release) {
        guard let ipaURL = release.ipaURL else {
            openReleasePage(release)
            return
        }
        pendingDownloadFilename = "Kumone-\(release.version).ipa"
        phase = .downloading(0)
        Task {
            do {
                let localURL = try await downloadIPA(from: ipaURL)
                phase = .readyToInstall(localURL)
                share(localURL)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func openReleasePage(_ release: ReleaseChecker.Release) {
        UIApplication.shared.open(release.url)
    }

    // MARK: - Download (non-TrollStore fallback)

    private func downloadIPA(from url: URL) async throws -> URL {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        return try await withCheckedThrowingContinuation { continuation in
            progressContinuation = continuation
            let task = session.downloadTask(with: url)
            downloadTask = task
            task.resume()
        }
    }

    /// Present the system share sheet for the downloaded IPA. This offers both
    /// "Save to Files" and "Copy to <app>" for any installed signing tool
    /// (全能签 / ESign / AltStore / Sideloadly …) that registers as an `.ipa`
    /// document handler — the direct import path requested in #50. Re-invokable
    /// from the "导入到签名工具" button in the sheet.
    func share(_ url: URL) {
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let root = scene.keyWindow?.rootViewController else { return }
        // Present on top of whatever is frontmost (the update sheet is itself a
        // presented controller).
        var presenter = root
        while let next = presenter.presentedViewController { presenter = next }
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        // iPad requires a popover anchor.
        if let pop = activity.popoverPresentationController {
            pop.sourceView = presenter.view
            pop.sourceRect = CGRect(x: presenter.view.bounds.midX,
                                    y: presenter.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        presenter.present(activity, animated: true)
    }
}

extension IOSUpdater: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in
            if case .downloading = self.phase { self.phase = .downloading(fraction) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // Move into Documents (findable in Files under On My iPhone ▸ Kumone via
        // UIFileSharingEnabled) before the temp download is reaped.
        let dir = (try? FileManager.default.url(for: .documentDirectory,
                                                in: .userDomainMask,
                                                appropriateFor: nil,
                                                create: true))
            ?? FileManager.default.temporaryDirectory
        let dest = dir.appendingPathComponent(pendingDownloadFilename)
        try? FileManager.default.removeItem(at: dest)
        let moved = (try? { try FileManager.default.moveItem(at: location, to: dest); return true }()) ?? false
        let result = moved ? dest : location
        Task { @MainActor in
            self.progressContinuation?.resume(returning: result)
            self.progressContinuation = nil
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor in
            self.progressContinuation?.resume(throwing: error)
            self.progressContinuation = nil
        }
    }
}

// MARK: - UI

struct IOSUpdaterSheet: View {
    @StateObject private var updater = IOSUpdater.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 22) {
            switch updater.phase {
            case .checking:
                ProgressView()
                Text("正在检查更新…").foregroundStyle(.secondary)

            case .upToDate:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44)).foregroundStyle(.green)
                Text("已是最新版本").font(.headline)
                doneButton

            case .available(let release):
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 44)).foregroundStyle(Theme.accent)
                VStack(spacing: 4) {
                    Text("发现新版本 \(release.version)").font(.headline)
                    Text("当前版本 \(ReleaseChecker.currentVersion)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("已装 TrollStore（巨魔）将自动安装；否则用「下载 IPA」手动侧载")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                primaryButton("自动安装（TrollStore）") { updater.installViaTrollStore(release) }
                Button("下载 IPA 手动侧载") { updater.download(release) }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.accent)
                laterButton

            case .downloading(let progress):
                ProgressRing(progress: progress)
                Text("正在下载 \(Int(progress * 100))%")
                    .font(.headline).monospacedDigit()

            case .readyToInstall(let url):
                Image(systemName: "square.and.arrow.down.fill")
                    .font(.system(size: 40)).foregroundStyle(Theme.accent)
                Text("下载完成").font(.headline)
                Text("已保存到「文件」App ▸ 我的 iPhone ▸ Kumone。用下方按钮直接导入签名工具（全能签 / ESign 等），或在「文件」里手动打开。")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                primaryButton("导入到签名工具") { updater.share(url) }
                doneButton

            case .handedOff:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44)).foregroundStyle(.green)
                Text("已移交 TrollStore 安装").font(.headline)
                Text("请在 TrollStore 中完成安装").font(.caption).foregroundStyle(.secondary)
                doneButton

            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40)).foregroundStyle(.orange)
                Text(message).font(.subheadline)
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                doneButton

            case .idle:
                EmptyView()
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .compatSheetHeight(360)
    }

    private func primaryButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(Theme.accentGradient, in: Capsule())
        }
        .buttonStyle(.pressable)
    }

    private var laterButton: some View {
        Button("稍后") {
            IOSUpdater.shared.showSheet = false
            dismiss()
        }
        .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(.secondary)
    }

    private var doneButton: some View {
        Button("完成") { dismiss() }.buttonStyle(.pressable)
    }
}

/// Circular download-progress ring.
struct ProgressRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(.primary.opacity(0.12), lineWidth: 8)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Theme.accentGradient,
                        style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.2), value: progress)
            Text("\(Int(progress * 100))")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .frame(width: 96, height: 96)
    }
}
#endif
