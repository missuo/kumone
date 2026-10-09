import SwiftUI

struct DailySongsView: View {
    @State private var tracks: [Track] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let player = PlayerService.shared
    @EnvironmentObject private var account: AccountStore

    var body: some View {
        let displayed = isLoading || errorMessage != nil ? [] : tracks
        TrackListScrollView(trackIDs: displayed.map(\.id)) {
            VStack(alignment: .leading, spacing: 20) {
                header
                    .padding(.horizontal, Theme.Layout.contentInset)
                    .padding(.top, 16)
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 300)
                } else if let errorMessage {
                    ErrorStateView(message: errorMessage) { Task { await load() } }
                        .frame(minHeight: 300)
                } else if tracks.isEmpty {
                    EmptyStateView(icon: "calendar.badge.clock", title: "暂无每日推荐",
                                   subtitle: "多听几首歌培养口味，每天 6:00 更新")
                        .frame(minHeight: 300)
                }
            }
        } rows: { layout in
            TrackListView(
                tracks: displayed,
                source: .daily,
                context: .daily,
                recommendationContext: .daily,
                onRecommendationReduced: { rejected, replacement in
                    tracks.replaceRecommendation(rejected, with: replacement)
                },
                layout: layout
            )
            .padding(.horizontal, Theme.Layout.contentInset - 10)
        } footer: {
            PlayerClearanceSpacer()
        }
        .navigationTitle("每日推荐")
        .task {
            if tracks.isEmpty {
                await load()
            }
        }
    }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            CachedAsyncImage(url: tracks.first?.album.picUrl?.resizedImageURL(1024))
                .frame(height: 220)
                .frame(maxWidth: .infinity)
                .clipped()
            LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.72)],
                           startPoint: .top, endPoint: .bottom)

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "calendar")
                            .font(.system(size: 26, weight: .medium))
                        Text(dateString)
                            .font(.system(size: 14, weight: .medium))
                            .opacity(0.85)
                    }
                    Text("每日推荐")
                        .font(.system(size: 30, weight: .bold))
                    Text("根据你的音乐口味 · 每天 6:00 更新")
                        .font(.system(size: 12))
                        .opacity(0.7)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 3, y: 1)

                Spacer()

                Button {
                    player.play(tracks: tracks, source: .daily, context: .daily)
                } label: {
                    Label("播放全部", systemImage: "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(Theme.accentGradient, in: Capsule())
                        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                }
                .buttonStyle(.pressable)
            }
            .padding(20)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
    }

    private var dateString: String {
        let fmt = DateFormatter()
        fmt.locale = .current
        fmt.setLocalizedDateFormatFromTemplate("MMMdEEEE")
        return fmt.string(from: .now)
    }

    private func load() async {
        guard account.isLoggedIn else {
            isLoading = false
            errorMessage = String(localized: "登录后才能查看每日推荐")
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            tracks = try await NeteaseAPI.dailyRecommendSongs()
            isLoading = false
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }
}
