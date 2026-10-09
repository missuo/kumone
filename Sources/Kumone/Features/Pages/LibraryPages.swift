import SwiftUI

// MARK: - 最近播放

struct RecentsView: View {
    @State private var records: [PlayRecordItem] = []
    @State private var week = false
    @State private var isLoading = true

    @EnvironmentObject private var account: AccountStore
    private let player = PlayerService.shared

    var body: some View {
        TrackListScrollView(trackIDs: records.map { $0.song.id }, style: .compact, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Picker("", selection: $week) {
                        Text("所有时间").tag(false)
                        Text("最近一周").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 200)

                    Spacer()

                    Button {
                        player.play(tracks: records.map(\.song), source: .none, context: .recents)
                    } label: {
                        Label("播放全部", systemImage: "play.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Theme.accentGradient, in: Capsule())
                    }
                    .buttonStyle(.pressable)
                    .disabled(records.isEmpty)
                }
                .padding(.horizontal, Theme.Layout.contentInset)
                .padding(.top, 12)

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else if records.isEmpty {
                    EmptyStateView(icon: "clock", title: "暂无播放记录")
                        .frame(minHeight: 300)
                }
            }
        } rows: { layout in
            recordList(layout: layout)
                .padding(.horizontal, Theme.Layout.contentInset - 10)
        } footer: {
            PlayerClearanceSpacer()
        }
        .navigationTitle("最近播放")
        .task(id: week) {
            await load()
        }
    }

    @ViewBuilder
    private func recordList(layout: TrackListView.Layout) -> some View {
        switch layout {
        case .stack:
            LazyVStack(spacing: 1) {
                ForEach(Array(records.enumerated()), id: \.element.song.id) { index, _ in recordRow(at: index) }
            }
        #if os(macOS)
        case .singleRow(let index):
            recordRow(at: index)
        #endif
        }
    }

    private func recordRow(at index: Int) -> some View {
        let record = records[index]
        return TrackRow(
            track: record.song,
            index: index + 1,
            style: .compact,
            trailingText: String(localized: "\(record.playCount) 次")
        ) {
            player.play(tracks: records.map(\.song), source: .none, startAt: record.song,
                        context: .recents)
        }
    }

    private func load() async {
        guard let uid = account.profile?.userId else {
            isLoading = false
            return
        }
        isLoading = records.isEmpty
        records = (try? await NeteaseAPI.playRecords(uid: uid, week: week)) ?? []
        isLoading = false
    }
}

// MARK: - 音乐云盘

struct CloudView: View {
    @State private var items: [CloudSongItem] = []
    @State private var sizeInfo: String?
    @State private var isLoading = true

    private let player = PlayerService.shared

    var body: some View {
        let displayed = tracks
        TrackListScrollView(trackIDs: displayed.map(\.id), style: .compact, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    if let sizeInfo {
                        Text(sizeInfo)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        player.play(tracks: tracks, source: .cloud, context: .cloud)
                    } label: {
                        Label("播放全部", systemImage: "play.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Theme.accentGradient, in: Capsule())
                    }
                    .buttonStyle(.pressable)
                    .disabled(items.isEmpty)
                }
                .padding(.horizontal, Theme.Layout.contentInset)
                .padding(.top, 12)

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else if items.isEmpty {
                    EmptyStateView(icon: "icloud", title: "云盘还没有歌曲",
                                   subtitle: "在网易云音乐客户端上传的歌曲会出现在这里")
                        .frame(minHeight: 300)
                }
            }
        } rows: { layout in
            TrackListView(tracks: displayed, style: .compact, source: .cloud, context: .cloud, layout: layout)
                .padding(.horizontal, Theme.Layout.contentInset - 10)
        } footer: {
            PlayerClearanceSpacer()
        }
        .navigationTitle("音乐云盘")
        .task {
            if items.isEmpty {
                await load()
            }
        }
    }

    private var tracks: [Track] {
        items.compactMap(\.simpleSong)
    }

    private func load() async {
        isLoading = items.isEmpty
        if let response = try? await NeteaseAPI.cloudSongs() {
            items = response.data ?? []
            if let size = response.size, let max = response.maxSize, max > 0 {
                let used = String(format: "%.1f", Double(size) / 1_073_741_824)
                let total = String(format: "%.0f", Double(max) / 1_073_741_824)
                sizeInfo = String(localized: "已使用 \(used) GB / \(total) GB")
            }
        }
        isLoading = false
    }
}
