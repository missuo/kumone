import SwiftUI

/// A music-library page, using the same rows and layout as Recents and Cloud.
/// Only explicitly retained downloads belong here; automatic caches stay private.
struct DownloadedMusicView: View {
    var collectionID: String?
    @ObservedObject private var downloads = DownloadManager.shared
    @EnvironmentObject private var player: PlayerService
    @Environment(\.openDestination) private var openDestination

    private var collection: DownloadCollection? { downloads.collections.first { $0.id == collectionID } }
    private var tracks: [Track] { downloads.downloadedSongs(in: collectionID) }
    private var pendingCount: Int { downloads.pendingJobs.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Text("已下载 \(tracks.count) 首")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        openDestination(.downloadTasks)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.circle")
                            Text("下载任务")
                            if pendingCount > 0 { Text("\(pendingCount)").monospacedDigit() }
                        }
                        .font(.system(size: 12.5, weight: .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(.primary.opacity(0.06), in: Capsule())
                    }
                    .buttonStyle(.pressable)

                    Button {
                        player.play(tracks: tracks, source: .none)
                    } label: {
                        Label("播放全部", systemImage: "play.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Theme.accentGradient, in: Capsule())
                    }
                    .buttonStyle(.pressable)
                    .disabled(tracks.isEmpty)
                }
                .padding(.horizontal, Theme.Layout.contentInset)
                .padding(.top, 12)

                if !downloads.isReady, downloads.errorMessage == nil {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 300)
                } else if let error = downloads.errorMessage, tracks.isEmpty {
                    EmptyStateView(icon: "exclamationmark.triangle", title: "无法读取下载", subtitle: LocalizedStringKey(error))
                        .frame(minHeight: 300)
                } else if tracks.isEmpty {
                    EmptyStateView(icon: "arrow.down.circle", title: "还没有下载歌曲",
                                   subtitle: "在歌曲菜单或歌单页面选择下载，即可离线收听")
                        .frame(minHeight: 300)
                } else {
                    TrackListView(tracks: tracks, source: .none)
                        .padding(.horizontal, Theme.Layout.contentInset - 10)
                }
                PlayerClearanceSpacer()
            }
        }
        .navigationTitle(collection?.name ?? String(localized: "已下载"))
        .task { await downloads.start(); await downloads.refreshLibrary() }
    }
}

/// Secondary download controls follow the music pages' spacing and row styling.
struct DownloadTasksView: View {
    @ObservedObject private var downloads = DownloadManager.shared
    @State private var confirmCancelAll = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Text("任务：\(downloads.pendingJobs.count)")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    taskButton("全部暂停", icon: "pause.fill", enabled: downloads.pendingJobs.contains { [.queued, .resolving, .downloading, .waitingNetwork].contains($0.status) }) {
                        Task { for job in downloads.pendingJobs { await downloads.pause(job.id) } }
                    }
                    taskButton("继续全部", icon: "play.fill", enabled: downloads.pendingJobs.contains { $0.status.canResume }) {
                        Task { for job in downloads.pendingJobs where job.status.canResume { await downloads.resume(job.id) } }
                    }
                    Menu {
                        Button("重试失败任务") {
                            Task { for job in downloads.pendingJobs where [.failed, .unavailable].contains(job.status) { await downloads.resume(job.id) } }
                        }
                        Button("取消未完成任务", role: .destructive) { confirmCancelAll = true }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .background(.primary.opacity(0.06), in: Circle())
                    }
                    #if os(macOS)
                    .menuStyle(.borderlessButton)
                    #endif
                    .fixedSize()
                    .accessibilityLabel("更多下载操作")
                    .disabled(downloads.pendingJobs.isEmpty)
                }
                .padding(.horizontal, Theme.Layout.contentInset)
                .padding(.top, 12)

                if downloads.pendingJobs.isEmpty {
                    EmptyStateView(icon: "arrow.down.circle", title: "暂无下载任务")
                        .frame(minHeight: 300)
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(downloads.pendingJobs) { job in
                            DownloadTaskRow(job: job, manager: downloads, progress: downloads.progress)
                        }
                    }
                    .padding(.horizontal, Theme.Layout.contentInset - 10)
                }
                PlayerClearanceSpacer()
            }
        }
        .navigationTitle("下载任务")
        .task { await downloads.start() }
        .alert("取消未完成的下载？", isPresented: $confirmCancelAll) {
            Button("取消下载", role: .destructive) {
                let ids = downloads.pendingJobs.map(\.id)
                Task { for id in ids { await downloads.cancel(id) } }
            }
            Button("保留任务", role: .cancel) {}
        } message: { Text("已完成的下载会保留。") }
    }

    private func taskButton(_ title: LocalizedStringKey, icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12.5, weight: .medium))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(.primary.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.pressable)
        .disabled(!enabled)
    }
}

private struct DownloadTaskRow: View {
    let job: DownloadJob
    @ObservedObject var manager: DownloadManager
    @ObservedObject var progress: DownloadProgress
    @State private var isHovering = false
    @ScaledMetric(relativeTo: .body) private var artworkSize: CGFloat = 42

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CachedAsyncImage(url: job.track.album.picUrl?.resizedImageURL(160), animated: false)
                .frame(width: artworkSize, height: artworkSize)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.track.name).font(.body.weight(.medium)).lineLimit(1)
                        Text(job.track.artistNames).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if job.status.canResume {
                        control(job.status == .paused ? "play.fill" : "arrow.clockwise", title: "继续下载") {
                            Task { await manager.resume(job.id) }
                        }
                    } else if [.queued, .resolving, .downloading].contains(job.status) {
                        control("pause.fill", title: "暂停下载") { Task { await manager.pause(job.id) } }
                    }
                    control("xmark", title: "取消下载") { Task { await manager.cancel(job.id) } }
                }
                let value = progress.values[job.id]
                let received = value?.received ?? job.receivedBytes
                let expected = value?.expected ?? job.expectedBytes
                if [.downloading, .waitingNetwork, .paused].contains(job.status), expected > 0 {
                    ProgressView(value: min(1, Double(received) / Double(expected)))
                        .tint(Theme.accent).controlSize(.small)
                }
                HStack {
                    Text(job.errorMessage ?? job.status.label)
                    Spacer(minLength: 8)
                    if expected > 0 {
                        Text("\(ByteCountFormatter.string(fromByteCount: received, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: expected, countStyle: .file))")
                            .monospacedDigit()
                    }
                }.font(.system(size: 11)).foregroundStyle(.secondary)
                if job.status == .waitingNetwork, !job.allowsMetered, manager.network.connected {
                    Button("使用当前网络下载") { Task { await manager.resume(job.id, allowsMetered: true) } }
                        .font(.system(size: 11.5)).buttonStyle(.plain).foregroundStyle(Theme.accent)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous)
            .fill(isHovering ? Color.primary.opacity(0.06) : .clear))
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
    }

    private func control(_ icon: String, title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.callout.weight(.medium))
                #if os(macOS)
                .frame(width: 28, height: 28)
                #else
                .frame(width: 44, height: 44)
                #endif
        }
        .buttonStyle(.pressable)
        .foregroundStyle(.secondary)
        .accessibilityLabel(title)
    }
}

struct TrackDownloadActions: View {
    let track: Track
    @ObservedObject private var downloads = DownloadManager.shared
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var settings: SettingsManager
    @Environment(\.openLogin) private var openLogin

    private var job: DownloadJob? { downloads.jobs.first { $0.track.id == track.id && !$0.owners.isEmpty } }

    var body: some View {
        if let job, job.status == .complete {
            Button("移除下载", role: .destructive) { Task { await downloads.deleteLocalAudio(trackID: track.id) } }
        } else if let job, [.queued, .resolving, .downloading, .verifying, .waitingNetwork].contains(job.status) {
            if job.status != .verifying { Button("暂停下载") { Task { await downloads.pause(job.id) } } }
            Button("取消下载", role: .destructive) { Task { await downloads.cancel(job.id) } }
        } else if let job, job.status.canResume {
            Button("继续下载") { Task { await downloads.resume(job.id) } }
        } else {
            Button { enqueue() } label: { Label("下载", systemImage: "arrow.down.circle") }
        }
    }

    private func enqueue() {
        guard account.isLoggedIn else { openLogin(); return }
        Task { await downloads.enqueue(track: track, quality: settings.audioQuality.rawValue, allowsMetered: false) }
    }
}

struct DownloadCollectionButton: View {
    let tracks: [Track]
    let owner: String
    let name: String
    var enabled = true
    var compact = false
    @ObservedObject private var downloads = DownloadManager.shared
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var settings: SettingsManager
    @Environment(\.openLogin) private var openLogin
    @Environment(\.openDestination) private var openDestination

    private var collectionJobs: [DownloadJob] { downloads.jobs.filter { $0.owners.contains(owner) } }
    private var isComplete: Bool {
        let saved = Set(collectionJobs.filter { $0.status == .complete }.map { $0.track.id })
        return !tracks.isEmpty && Set(tracks.map(\.id)).isSubset(of: saved)
    }
    private var hasWholeRequest: Bool {
        !tracks.isEmpty && Set(tracks.map(\.id)).isSubset(of: Set(collectionJobs.map { $0.track.id }))
    }
    private var title: String {
        if isComplete { return String(localized: "已下载") }
        return hasWholeRequest ? String(localized: "下载任务") : String(localized: "下载全部")
    }

    var body: some View {
        Button {
            guard account.isLoggedIn else { openLogin(); return }
            if isComplete { openDestination(.downloaded); return }
            if hasWholeRequest { openDestination(.downloadTasks); return }
            Task { await downloads.enqueue(tracks: tracks, owner: owner, name: name,
                                           quality: settings.audioQuality.rawValue, allowsMetered: false) }
        } label: {
            if compact {
                Image(systemName: isComplete ? "checkmark" : "arrow.down")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 38, height: 38)
                    .background(.primary.opacity(0.06), in: Circle())
            } else {
                Label(title, systemImage: isComplete ? "checkmark" : "arrow.down")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.primary.opacity(0.06), in: Capsule())
            }
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(title)
        .disabled(!enabled || tracks.isEmpty)
    }
}
