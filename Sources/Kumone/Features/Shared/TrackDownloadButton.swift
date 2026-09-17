import SwiftUI

/// A fixed-width row action: hover reveals it without moving the duration or title.
struct TrackDownloadButton: View {
    let track: Track
    var isVisible = true
    var onNavigate: () -> Void = {}

    @ObservedObject private var downloads = DownloadManager.shared
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var settings: SettingsManager
    @Environment(\.openLogin) private var openLogin
    @Environment(\.openDestination) private var openDestination
    @FocusState private var isFocused: Bool
    @State private var isSubmitting = false

    private var job: DownloadJob? {
        downloads.jobs.first { $0.track.id == track.id && !$0.owners.isEmpty && $0.status != .complete }
    }
    private var isDownloaded: Bool {
        downloads.downloadedTracks.contains { $0.id == track.id }
    }
    private var canResume: Bool { job.map { $0.status.canResume && $0.status != .waitingNetwork } ?? false }
    private var title: String {
        if isDownloaded { return String(localized: "已下载") }
        if job != nil { return canResume ? String(localized: "继续下载") : String(localized: "下载任务") }
        return String(localized: "下载")
    }
    private var symbol: String {
        if isDownloaded { return "checkmark" }
        if job != nil, !canResume { return "arrow.down.circle" }
        return "arrow.down"
    }

    var body: some View {
        Button(action: activate) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 24, height: 24)
                .contentShape(Circle())
        }
        .buttonStyle(.pressable)
        .focused($isFocused)
        .opacity(isVisible || isFocused ? 1 : 0)
        .allowsHitTesting(isVisible || isFocused)
        .disabled(isSubmitting)
        .accessibilityLabel(title)
        .accessibilityHint(track.name)
        .accessibilityIdentifier("track-download-\(track.id)")
        .help(title)
    }

    private func activate() {
        guard account.isLoggedIn else { openLogin(); return }
        if isDownloaded { onNavigate(); openDestination(.downloaded); return }
        if job != nil, !canResume { onNavigate(); openDestination(.downloadTasks); return }
        guard !isSubmitting else { return }
        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            if let job { await downloads.resume(job.id) }
            else { await downloads.enqueue(track: track, quality: settings.audioQuality.rawValue, allowsMetered: false) }
        }
    }
}
