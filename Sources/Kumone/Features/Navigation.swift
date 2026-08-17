import SwiftUI

extension EnvironmentValues {
    @Entry var openLogin: () -> Void = {}
}

struct PlayerChromeModifier: ViewModifier {
    @Environment(PlayerService.self) private var player
    let detailWidth: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) {
                PlayerBar()
                    .frame(width: detailWidth)
            }
            .overlay(alignment: .trailing) {
                rightPanel
            }
            .animation(AppAnimation.standard, value: player.activePanel)
    }

    @ViewBuilder
    private var rightPanel: some View {
        if let panel = player.activePanel {
            Group {
                switch panel {
                case .lyrics:
                    LyricsPanel()
                case .queue:
                    QueuePanel()
                }
            }
            .padding(.top, 12)
            .padding(.bottom, Theme.Layout.playerBarHeight + 20)
            .padding(.trailing, 16)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }
}

enum SidebarItem: Hashable {
    case home
    case explore
    case fm
    case likedSongs
    case daily
    case recents
    case collections
    case cloud
    case playlist(Int)
}

enum Destination: Hashable {
    case playlist(Int)
    case album(Int)
    case artist(Int)
    case daily
    case toplists
    case search(String)
}

/// Registers all shared navigation destinations on a stack.
struct DestinationsModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.navigationDestination(for: Destination.self) { destination in
            Group {
                switch destination {
                case .playlist(let id):
                    PlaylistDetailView(playlistID: id)
                case .album(let id):
                    AlbumDetailView(albumID: id)
                case .artist(let id):
                    ArtistDetailView(artistID: id)
                case .daily:
                    DailySongsView()
                case .toplists:
                    ToplistsView()
                case .search(let query):
                    SearchView(query: query)
                }
            }
            .playerContentInset()
        }
    }
}

extension View {
    func playerChrome(detailWidth: CGFloat) -> some View {
        modifier(PlayerChromeModifier(detailWidth: detailWidth))
    }

    func playerContentInset() -> some View {
        safeAreaPadding(.bottom, Theme.Layout.playerBarHeight + 10)
    }

    func appDestinations() -> some View {
        modifier(DestinationsModifier())
    }
}
