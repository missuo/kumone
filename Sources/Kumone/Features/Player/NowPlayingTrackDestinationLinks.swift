import SwiftUI

/// Links the current track metadata to its artist and album without requiring
/// the immersive presentation to own a second navigation stack.
struct NowPlayingTrackDestinationLinks: View {
    let track: Track
    let font: Font
    let color: Color

    @Environment(\.openDestination) private var openDestination

    private var artists: [ArtistRef] {
        track.artists.filter { $0.id > 0 && !$0.name.isEmpty }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(artists.enumerated()), id: \.offset) { index, artist in
                if index > 0 {
                    Text(" / ")
                }
                Button {
                    openDestination(.artist(artist.id))
                } label: {
                    Text(artist.name)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("打开歌手：\(artist.name)")
            }

            if track.album.id > 0, !track.album.name.isEmpty {
                if !artists.isEmpty {
                    Text(" — ")
                }
                Button {
                    openDestination(.album(track.album.id))
                } label: {
                    Text(track.album.name)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("打开专辑：\(track.album.name)")
            }
        }
        .font(font)
        .foregroundStyle(color)
        .lineLimit(1)
    }
}
