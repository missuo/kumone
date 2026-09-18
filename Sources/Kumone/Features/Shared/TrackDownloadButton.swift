import SwiftUI

/// A fixed-width row action: hover reveals it without moving the duration or title.
struct TrackDownloadButton: View {
    let track: Track
    var isVisible = true

    @ObservedObject private var downloads = DownloadManager.shared
    @ObservedObject private var progress = DownloadManager.shared.progress
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var settings: SettingsManager
    @Environment(\.openLogin) private var openLogin
    @FocusState private var isFocused: Bool
    @State private var isSubmitting = false
    @State private var confirmRemoval = false
    @State private var removalScope: String?
    @State private var isRemoving = false

    private var job: DownloadJob? {
        downloads.pendingJobsByTrackID[track.id]
    }
    private var isDownloaded: Bool {
        downloads.isDownloaded(trackID: track.id)
    }
    private var canResume: Bool { job.map { $0.status.canResume && $0.status != .waitingNetwork } ?? false }
    private var isActive: Bool { job?.status.isInProgress == true }
    private var showsControl: Bool { isVisible || isFocused || job != nil || isSubmitting || isDownloaded }
    private var fraction: Double? {
        guard let job, job.status.isInProgress else { return nil }
        return progress.fraction(for: job)
    }
    private var title: String {
        if isActive || isSubmitting { return String(localized: "停止下载") }
        if canResume { return String(localized: "继续下载") }
        if isDownloaded { return String(localized: "移除下载") }
        return String(localized: "下载")
    }
    var body: some View {
        Button(action: activate) {
            DownloadButtonIcon(isActive: isActive || isSubmitting, isComplete: isDownloaded && job == nil,
                               progress: fraction, size: 16, symbolSize: 12, completedSymbol: "arrow.down.circle.fill")
                .foregroundStyle(isDownloaded && job == nil && !isSubmitting ? Color.secondary : Theme.accent)
                .frame(width: 24, height: 24)
                .contentShape(Circle())
        }
        .buttonStyle(.pressable)
        .focused($isFocused)
        .opacity(showsControl ? 1 : 0)
        .allowsHitTesting(showsControl)
        .accessibilityHidden(!showsControl)
        .disabled(isSubmitting || isRemoving)
        .accessibilityLabel(title)
        .accessibilityHint(track.name)
        .accessibilityIdentifier("track-download-\(track.id)")
        .help(title)
        .alert("要移除此下载吗？", isPresented: $confirmRemoval) {
            Button("移除下载", role: .destructive) { removeDownload() }
            Button("取消", role: .cancel) {}
        }
        .onChange(of: downloads.accountScope) { _ in confirmRemoval = false }
        .contextMenu {
            if let job {
                if [.queued, .resolving, .downloading, .waitingNetwork].contains(job.status) {
                    Button("暂停下载") { Task { await downloads.pause(job.id) } }
                } else if canResume {
                    Button("继续下载") { Task { await downloads.resume(job.id, allowsMetered: true) } }
                }
                Button("停止下载") { Task { await downloads.cancel(job.id) } }
            }
        }
    }

    private func activate() {
        guard !isSubmitting, !isRemoving else { return }
        if !isActive, !canResume, isDownloaded {
            removalScope = downloads.accountScope
            confirmRemoval = true
            return
        }
        guard account.isLoggedIn else { openLogin(); return }
        let selectedJob = job
        isSubmitting = true
        Task { [scope = downloads.accountScope] in
            defer { isSubmitting = false }
            guard downloads.accountScope == scope else { return }
            if let job = selectedJob, job.status.isInProgress { await downloads.cancel(job.id) }
            else if let job = selectedJob { await downloads.resume(job.id, allowsMetered: true) }
            else { await downloads.enqueue(track: track, quality: settings.audioQuality.rawValue, allowsMetered: true) }
        }
    }

    private func removeDownload() {
        let scope = removalScope
        guard downloads.accountScope == scope, !isRemoving else { return }
        isRemoving = true
        Task {
            defer { isRemoving = false }
            guard downloads.accountScope == scope else { return }
            let succeeded = await downloads.deleteLocalAudio(trackIDs: [track.id])
            guard downloads.accountScope == scope else { return }
            if !succeeded { ToastCenter.shared.show(String(localized: "部分下载未能移除，请重试")) }
        }
    }
}
