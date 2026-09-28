import SwiftUI

/// 我的收藏 — liked albums and followed artists.
struct CollectionsView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case albums = "专辑"
        case artists = "歌手"

        var id: String { rawValue }
    }

    @State private var tab: Tab = .albums
    @State private var isLoading = true

    @EnvironmentObject private var account: AccountStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { tab in
                        Text(LocalizedStringKey(tab.rawValue)).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                .padding(.horizontal, Theme.Layout.contentInset)
                .padding(.top, 12)

                if isLoading, account.likedAlbums.isEmpty, account.likedArtists.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    switch tab {
                    case .albums:
                        if account.likedAlbums.isEmpty {
                            EmptyStateView(icon: "square.stack", title: "还没有收藏专辑")
                                .frame(minHeight: 300)
                        } else {
                            CardGrid {
                                ForEach(account.likedAlbums) { album in
                                    AppDestinationLink(value: Destination.album(album.id)) {
                                        CoverCardBody(
                                            coverURL: album.picUrl?.resizedImageURL(384),
                                            title: album.name,
                                            subtitle: album.artistName
                                        )
                                    }
                                    .buttonStyle(.interactiveCard)
                                }
                            }
                            .padding(.horizontal, Theme.Layout.contentInset)
                        }
                    case .artists:
                        if account.likedArtists.isEmpty {
                            EmptyStateView(icon: "music.microphone", title: "还没有关注歌手")
                                .frame(minHeight: 300)
                        } else {
                            CardGrid(minWidth: 140) {
                                ForEach(account.likedArtists) { artist in
                                    AppDestinationLink(value: Destination.artist(artist.id)) {
                                        VStack(spacing: 10) {
                                            CachedAsyncImage(url: artist.picUrl?.resizedImageURL(256))
                                                .frame(width: 128, height: 128)
                                                .clipShape(Circle())
                                            Text(artist.name)
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                        }
                                        .frame(width: 140)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.interactiveCard)
                                }
                            }
                            .padding(.horizontal, Theme.Layout.contentInset)
                        }
                    }
                }
                PlayerClearanceSpacer()
            }
        }
        .navigationTitle("我的收藏")
        .task {
            await account.refreshSublists()
            isLoading = false
        }
    }
}
