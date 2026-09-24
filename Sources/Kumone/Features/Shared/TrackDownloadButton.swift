import SwiftUI

/// A fixed-width row action: hover reveals it without moving the duration or title.
struct TrackDownloadButton: View {
    let track: Track
    var isVisible = true

    @ObservedObject private var state: TrackDownloadState
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var settings: SettingsManager
    @Environment(\.openLogin) private var openLogin
    @FocusState private var isFocused: Bool
    @State private var isSubmitting = false
    @State private var confirmRemoval = false
    @State private var removalScope: String?
    @State private var isRemoving = false

    init(track: Track, isVisible: Bool = true) {
        self.track = track
        self.isVisible = isVisible
        _state = ObservedObject(wrappedValue: DownloadManager.shared.trackState(for: track.id))
    }

    private var downloads: DownloadManager { .shared }
    private var status: DownloadStatus? { state.status }
    private var isDownloaded: Bool { state.isDownloaded }
    private var canResume: Bool { status.map { $0.canResume && $0 != .waitingNetwork } ?? false }
    private var isActive: Bool { status?.isInProgress == true }
    private var showsControl: Bool { isVisible || isFocused || status != nil || isSubmitting || isDownloaded }
    private var title: String {
        if isActive || isSubmitting { return String(localized: "停止下载") }
        if canResume { return String(localized: "继续下载") }
        if isDownloaded { return String(localized: "移除下载") }
        return String(localized: "下载")
    }
    var body: some View {
        Button(action: activate) {
            TrackDownloadButtonIcon(isActive: isActive || isSubmitting, isComplete: isDownloaded && status == nil,
                                    showsFraction: isActive, progress: state.progress)
                .foregroundStyle(isDownloaded && status == nil && !isSubmitting ? Color.secondary : Theme.accent)
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
        .onChange(of: state.accountScope) { _ in confirmRemoval = false }
        .contextMenu {
            if let jobID = state.jobID, let status {
                if [.queued, .resolving, .downloading, .waitingNetwork].contains(status) {
                    Button("暂停下载") { Task { await downloads.pause(jobID) } }
                } else if canResume {
                    Button("继续下载") {
                        MeteredDownloadCenter.shared.request(bulk: false, count: 1, network: downloads.network) { metered in
                            Task { await downloads.resume(jobID, allowsMetered: metered) }
                        }
                    }
                }
                Button("停止下载") { Task { await downloads.cancel(jobID) } }
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
        let jobID = state.jobID
        if isActive, let jobID { submit { await downloads.cancel(jobID) }; return }
        MeteredDownloadCenter.shared.request(bulk: false, count: 1, network: downloads.network) { metered in
            submit {
                if let jobID { await downloads.resume(jobID, allowsMetered: metered) }
                else { await downloads.enqueue(track: track, quality: settings.audioQuality.rawValue, allowsMetered: metered) }
            }
        }
    }

    private func submit(_ operation: @escaping () async -> Void) {
        isSubmitting = true
        Task { [scope = downloads.accountScope] in
            defer { isSubmitting = false }
            guard downloads.accountScope == scope else { return }
            await operation()
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

/// The ring is the only part that follows the byte counter, so it observes the
/// per-track fraction on its own and leaves the button's body alone.
private struct TrackDownloadButtonIcon: View {
    let isActive: Bool
    let isComplete: Bool
    let showsFraction: Bool
    @ObservedObject var progress: TrackProgressState

    var body: some View {
        DownloadButtonIcon(isActive: isActive, isComplete: isComplete, progress: showsFraction ? progress.fraction : nil,
                           size: 16, symbolSize: 12, completedSymbol: "arrow.down.circle.fill")
    }
}
