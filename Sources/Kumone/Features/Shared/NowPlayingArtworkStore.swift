import Combine
import SwiftUI

/// Shares the current track artwork and palette between app surfaces.
@MainActor
final class NowPlayingArtworkStore: ObservableObject {
    typealias ImageLoader = (URL) async -> PlatformImage?

    @Published private(set) var colors: ArtworkColors = .fallback
    @Published private(set) var artwork: PlatformImage?
    @Published private(set) var trackID: Int?

    private struct Request: Equatable {
        let trackID: Int
        let artworkURL: String
        let imageURL: URL
    }

    private let imageLoader: ImageLoader
    private var request: Request?
    private var loadTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var artworkURL: String?
    private var artworkIsNeeded = false

    init(
        player: PlayerService?,
        imageLoader: @escaping ImageLoader = { url in
            await ImageCache.shared.image(for: url)
        }
    ) {
        self.imageLoader = imageLoader

        guard let player else { return }
        player.$currentTrack
            .sink { [weak self] track in
                self?.update(trackID: track?.id, artworkURL: track?.album.picUrl)
            }
            .store(in: &cancellables)
    }

    convenience init() {
        self.init(player: PlayerService.shared)
    }

    func update(trackID: Int?, artworkURL: String?) {
        guard self.trackID != trackID || self.artworkURL != artworkURL else { return }

        cancelArtworkLoad()
        self.trackID = trackID
        self.artworkURL = artworkURL
        artwork = nil
        colors = .fallback

        loadArtworkForCurrentTrack()
    }

    func setArtworkNeeded(_ artworkIsNeeded: Bool) {
        guard self.artworkIsNeeded != artworkIsNeeded else { return }
        self.artworkIsNeeded = artworkIsNeeded

        if artworkIsNeeded {
            loadArtworkForCurrentTrack()
        } else {
            cancelArtworkLoad()
            artwork = nil
            colors = .fallback
        }
    }

    private func loadArtworkForCurrentTrack() {
        guard artworkIsNeeded else { return }

        guard let trackID,
              let artworkURL,
              let imageURL = artworkURL.resizedImageURL(768) else {
            return
        }

        let request = Request(
            trackID: trackID,
            artworkURL: artworkURL,
            imageURL: imageURL
        )
        self.request = request
        let imageLoader = imageLoader
        loadTask = Task { [weak self] in
            let image = await imageLoader(request.imageURL)
            guard !Task.isCancelled,
                  let self,
                  self.request == request else {
                return
            }

            self.loadTask = nil
            guard let image else { return }
            self.artwork = image
            self.colors = ArtworkPalette.extract(from: image, cacheKey: request.artworkURL)
        }
    }

    private func cancelArtworkLoad() {
        loadTask?.cancel()
        loadTask = nil
        request = nil
    }
}
