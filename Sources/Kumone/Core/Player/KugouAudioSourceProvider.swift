import CryptoKit
import Foundation

struct KugouAudioSourceProvider: AudioSourceProvider {
    let id: AudioSourceID = .kugou
    let displayName = AudioSourceID.kugou.displayName

    private let httpClient: AudioSourceClient

    init(httpClient: AudioSourceClient = .shared) {
        self.httpClient = httpClient
    }

    func resolve(track: Track) async throws -> ResolvedAudioSource? {
        let query = AudioSourceTrackMatcher.keyword(for: track)
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let searchURL = "http://mobilecdn.kugou.com/api/v3/search/song?format=json&keyword=\(query)&page=1&pagesize=10"
        let data = try await httpClient.data(
            from: searchURL,
            source: id,
            operation: "search"
        )
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObject = object["data"] as? [String: Any],
              let info = dataObject["info"] as? [[String: Any]]
        else { throw AudioSourceProviderError.invalidResponse }

        let matches = info.prefix(5).compactMap { item -> Song? in
            guard let hash = item["hash"] as? String,
                  let title = item["songname"] as? String,
                  let artist = item["singername"] as? String,
                  let duration = item["duration"] as? Int,
                  AudioSourceTrackMatcher.matches(
                    track: track,
                    title: title,
                    artist: artist,
                    durationMS: duration * 1_000
                  )
            else { return nil }
            let albumID = (item["album_id"] as? String) ?? String(item["album_id"] as? Int ?? 0)
            return Song(hash: hash, albumID: albumID)
        }
        guard let match = matches.first else { return nil }

        let key = Insecure.MD5.hash(data: Data("\(match.hash)kgcloudv2".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let streamURL = "https://trackercdn.kugou.com/i/v2/?key=\(key)&hash=\(match.hash)"
            + "&appid=1005&pid=2&cmd=25&behavior=play&album_id=\(match.albumID)"
        let streamData = try await httpClient.data(
            from: streamURL,
            source: id,
            operation: "resolve-stream"
        )
        guard let object = try JSONSerialization.jsonObject(with: streamData) as? [String: Any],
              let urlString = (object["url"] as? [String])?.first,
              let url = URL(string: urlString)
        else { throw AudioSourceProviderError.invalidResponse }

        return ResolvedAudioSource(id: id, displayName: displayName, url: url)
    }

    private struct Song {
        let hash: String
        let albumID: String
    }
}
