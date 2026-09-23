import Foundation

struct KuwoAudioSourceProvider: AudioSourceProvider {
    let id: AudioSourceID = .kuwo
    let displayName = AudioSourceID.kuwo.displayName

    private let httpClient: AudioSourceClient

    init(httpClient: AudioSourceClient = .shared) {
        self.httpClient = httpClient
    }

    func resolve(track: Track) async throws -> ResolvedAudioSource? {
        let query = AudioSourceTrackMatcher.keyword(for: track)
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let searchURL = "https://search.kuwo.cn/r.s?&correct=1&vipver=1&stype=comprehensive&encoding=utf8"
            + "&rformat=json&mobi=1&show_copyright_off=1&searchapi=6&all=\(query)"
        let data = try await httpClient.data(
            from: searchURL,
            source: id,
            operation: "search"
        )
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = object["content"] as? [[String: Any]],
              content.count >= 2,
              let musicPage = content[1]["musicpage"] as? [String: Any],
              let songs = musicPage["abslist"] as? [[String: Any]]
        else { throw AudioSourceProviderError.invalidResponse }

        let matches = songs.prefix(5).compactMap { item -> Song? in
            guard let musicRID = item["MUSICRID"] as? String,
                  let rid = musicRID.components(separatedBy: "_").last,
                  let title = item["SONGNAME"] as? String,
                  let artist = item["ARTIST"] as? String
            else { return nil }
            let durationSeconds = Int((item["DURATION"] as? String) ?? "") ?? (item["DURATION"] as? Int ?? 0)
            guard AudioSourceTrackMatcher.matches(
                track: track,
                title: title,
                artist: artist,
                durationMS: durationSeconds * 1_000
            ) else { return nil }
            return Song(rid: rid)
        }
        guard let match = matches.first else { return nil }

        let convertURL = "https://antiserver.kuwo.cn/anti.s?type=convert_url&format=mp3&response=url&rid=MUSIC_\(match.rid)"
        let body = try await httpClient.data(
            from: convertURL,
            source: id,
            operation: "resolve-stream",
            userAgent: "okhttp/3.10.0"
        )
        guard let text = String(data: body, encoding: .utf8),
              let range = text.range(of: #"http[^\s$"]+"#, options: .regularExpression),
              let url = URL(string: String(text[range]))
        else { throw AudioSourceProviderError.invalidURL }

        return ResolvedAudioSource(id: id, displayName: displayName, url: url)
    }

    private struct Song {
        let rid: String
    }
}
