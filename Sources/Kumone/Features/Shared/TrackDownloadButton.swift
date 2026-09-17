import SwiftUI

/// A fixed-width row action: hover reveals it without moving the duration or title.
struct TrackDownloadButton: View {
    let track: Track
    var isVisible = true
    var onNavigate: () -> Void = {}

    @ObservedObject private var downloads = DownloadManager.shared
    @ObservedObject private var progress = DownloadManager.shared.progress
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
    private var isActive: Bool { job?.status.isInProgress == true }
    private var showsControl: Bool { isVisible || isFocused || job != nil || isSubmitting }
    private var fraction: Double? {
        guard let job, job.status == .downloading else { return nil }
        return progress.fraction(for: job)
    }
    private var title: String {
        if isActive || isSubmitting { return String(localized: "停止下载") }
        if canResume { return String(localized: "继续下载") }
        if isDownloaded { return String(localized: "已下载") }
        return String(localized: "下载")
    }
    private var symbol: String {
        if isDownloaded && job == nil { return "arrow.down.circle.fill" }
        return "arrow.down"
    }

    var body: some View {
        Button(action: activate) {
            Group {
                if isActive || isSubmitting { DownloadProgressIcon(progress: fraction, size: 16) }
                else { Image(systemName: symbol).font(.system(size: 12, weight: .medium)) }
            }
                .foregroundStyle(isDownloaded && job == nil && !isSubmitting ? Color.secondary : Theme.accent)
                .frame(width: 24, height: 24)
                .contentShape(Circle())
        }
        .buttonStyle(.pressable)
        .focused($isFocused)
        .opacity(showsControl ? 1 : 0)
        .allowsHitTesting(showsControl)
        .accessibilityHidden(!showsControl)
        .disabled(isSubmitting)
        .accessibilityLabel(title)
        .accessibilityHint(track.name)
        .accessibilityIdentifier("track-download-\(track.id)")
        .help(title)
        .contextMenu {
            if let job {
                if [.queued, .resolving, .downloading, .waitingNetwork].contains(job.status) {
                    Button("暂停下载") { Task { await downloads.pause(job.id) } }
                } else if canResume {
                    Button("继续下载") { Task { await downloads.resume(job.id) } }
                }
                Button("停止下载") { Task { await downloads.cancel(job.id) } }
            }
        }
    }

    private func activate() {
        guard account.isLoggedIn else { openLogin(); return }
        guard !isSubmitting else { return }
        if !isActive, !canResume, isDownloaded { onNavigate(); openDestination(.downloaded); return }
        let selectedJob = job
        isSubmitting = true
        Task { [scope = downloads.accountScope] in
            defer { isSubmitting = false }
            guard downloads.accountScope == scope else { return }
            if let job = selectedJob, job.status.isInProgress { await downloads.cancel(job.id) }
            else if let job = selectedJob { await downloads.resume(job.id) }
            else { await downloads.enqueue(track: track, quality: settings.audioQuality.rawValue, allowsMetered: false) }
        }
    }
}
