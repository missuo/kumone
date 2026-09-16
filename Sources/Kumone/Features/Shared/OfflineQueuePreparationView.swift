import SwiftUI
import Combine

/// A compact listening aid inside the existing queue, not a cache browser.
struct OfflineQueuePreparationView: View {
    let onOpenCollection: (String) -> Void
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var settings: SettingsManager
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var downloads = DownloadManager.shared
    @StateObject private var model = OfflineQueueReadinessModel()
    @State private var preparing = false
    @State private var preparedID: String?
    @State private var message: String?
    @State private var messageScope: String?
    @State private var availabilityRefresh: Task<Void, Never>?

    private var snapshot: OfflineListeningSnapshot {
        .init(scope: account.offlineScope, tracks: player.offlineListeningSnapshot.tracks, quality: settings.audioQuality.rawValue)
    }
    private var preparation: DownloadCollection? {
        downloads.commuteCollections.first { $0.id == preparedID } ?? downloads.commuteCollections.first
    }

    var body: some View {
        let input = snapshot
        VStack(alignment: .leading, spacing: 8) {
            OfflineReadinessLabel(readiness: model.value(for: input), failed: model.failed, clock: player.clock)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { actions(input) }
                VStack(alignment: .leading, spacing: 8) { actions(input) }
            }
            if let preparation {
                Text(downloads.progress(for: preparation).summary)
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message, messageScope == input.scope {
                Text(message).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.Radius.small))
        .task(id: input) { await model.refresh(input) }
        .onReceive(NotificationCenter.default.publisher(for: .offlineAvailabilityChanged).receive(on: DispatchQueue.main)) { _ in
            availabilityRefresh?.cancel()
            availabilityRefresh = Task {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, snapshot == input else { return }
                if !downloads.commuteCollections.isEmpty { await downloads.refreshLibrary() }
                guard !Task.isCancelled, snapshot == input else { return }
                await model.refresh(input)
            }
        }
        .onDisappear { availabilityRefresh?.cancel() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { Task { await model.refresh(input) } }
        }
    }

    @ViewBuilder
    private func actions(_ input: OfflineListeningSnapshot) -> some View {
        Button {
            guard !preparing else { return }
            messageScope = input.scope
            guard let plan = CommutePlanner.plan(input, progress: player.progress) else {
                message = input.tracks.first.map { $0.duration > 0 } == true
                    ? String(localized: "当前队列没有可准备的剩余歌曲")
                    : String(localized: "当前队列缺少有效时长，暂时无法准备")
                return
            }
            preparing = true
            message = nil
            Task {
                defer { preparing = false }
                do {
                    let id = try await downloads.prepareCommute(plan)
                    guard account.offlineScope == plan.scope else { return }
                    preparedID = id
                    if plan.stoppedAtUnknownDuration {
                        message = String(localized: "部分歌曲缺少时长，本次准备 \(ListeningDuration.text(plan.plannedSeconds))")
                    } else if plan.plannedSeconds < plan.preparation.targetSeconds {
                        message = String(localized: "当前顺序不足 60 分钟，已加入全部剩余歌曲")
                    }
                } catch {
                    guard account.offlineScope == plan.scope else { return }
                    message = String(localized: "无法创建通勤准备，请重试")
                }
            }
        } label: {
            HStack(spacing: 6) {
                if preparing { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.down.circle") }
                Text("准备 60 分钟")
            }
            .font(.system(size: 12.5, weight: .medium))
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.primary.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.pressable)
        .disabled(preparing || input.scope == nil || input.tracks.isEmpty)

        if let preparation {
            Button { onOpenCollection(preparation.id) } label: {
                Text("查看准备")
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.primary.opacity(0.06), in: Capsule())
            }
            .buttonStyle(.pressable)
        }
    }
}

private struct OfflineReadinessLabel: View {
    let readiness: OfflineListeningReadiness?
    let failed: Bool
    @ObservedObject var clock: PlaybackClock

    var body: some View {
        Group {
            if let readiness {
                let seconds = readiness.remaining(after: clock.progress)
                if seconds > 0 {
                    Label("可连续离线收听 \(ListeningDuration.text(seconds))", systemImage: "checkmark.circle")
                } else if !readiness.durations.isEmpty {
                    Label("当前歌曲已可离线", systemImage: "checkmark.circle")
                } else {
                    Label("当前歌曲尚未完整缓存", systemImage: "wifi.slash")
                }
            } else if failed {
                Label("暂时无法读取离线状态", systemImage: "exclamationmark.circle")
            } else {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("正在检查离线歌曲…") }
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .monospacedDigit()
    }
}

extension DownloadCollectionProgress {
    var summary: String {
        if isComplete { return String(localized: "通勤准备已完成 · \(ListeningDuration.text(readySeconds))") }
        if hasFailures { return String(localized: "已下载 \(completed)/\(total) 首 · 部分歌曲未完成") }
        if waiting { return String(localized: "已下载 \(completed)/\(total) 首 · 等待可用网络") }
        return String(localized: "已下载 \(completed)/\(total) 首")
    }
}
