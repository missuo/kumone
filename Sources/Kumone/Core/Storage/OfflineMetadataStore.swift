import CryptoKit
import Foundation
import ImageIO

/// Small display data stays separate from audio bytes. A failed lyric refresh
/// never erases the last successful response or makes a complete song unplayable.
actor OfflineMetadataStore {
    static let shared = OfflineMetadataStore(directory: OfflineStore.shared.directory.appendingPathComponent("metadata"))
    nonisolated let directory: URL

    init(directory: URL) { self.directory = directory }

    static func key(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func folder(_ scope: String) -> URL { directory.appendingPathComponent(Self.key(scope), isDirectory: true) }

    func save(track: Track, scope: String) throws {
        try write(JSONEncoder().encode(track), to: folder(scope).appendingPathComponent("track-\(track.id).json"))
    }

    func track(id: Int, scope: String) -> Track? {
        guard let data = try? Data(contentsOf: folder(scope).appendingPathComponent("track-\(id).json")) else { return nil }
        return try? JSONDecoder().decode(Track.self, from: data)
    }

    func save(lyrics: LyricResponse, trackID: Int, scope: String) throws {
        try write(JSONEncoder().encode(lyrics), to: folder(scope).appendingPathComponent("lyrics-\(trackID).json"))
    }

    func lyrics(trackID: Int, scope: String) -> LyricResponse? {
        guard let data = try? Data(contentsOf: folder(scope).appendingPathComponent("lyrics-\(trackID).json")) else { return nil }
        return try? JSONDecoder().decode(LyricResponse.self, from: data)
    }

    func saveArtwork(_ data: Data, url: URL, scope: String) throws {
        guard data.count <= 12 * 1024 * 1024,
              let image = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceCreateImageAtIndex(image, 0, nil) != nil else {
            throw OfflineAudioError.invalidResource
        }
        try write(data, to: artworkURL(url, scope: scope))
    }

    func artwork(url: URL, scope: String) -> Data? { try? Data(contentsOf: artworkURL(url, scope: scope)) }

    func hasDisplayData(track: Track, scope: String) -> Bool {
        let hasLyrics = lyrics(trackID: track.id, scope: scope) != nil
        let hasArtwork = track.album.picUrl.flatMap(URL.init(string:)).map { artwork(url: $0, scope: scope) != nil } ?? true
        return hasLyrics && hasArtwork
    }

    func fetchDisplayData(track: Track, scope: String) async {
        guard !Task.isCancelled else { return }
        do { try save(track: track, scope: scope) } catch { return }
        async let response = try? NeteaseAPI.lyric(id: track.id)
        async let cover = fetchArtwork(track: track)
        if let response = await response { try? save(lyrics: response, trackID: track.id, scope: scope) }
        if let (url, data) = await cover { try? saveArtwork(data, url: url, scope: scope) }
    }

    func fetchPlaybackArtwork(track: Track, scope: String) async {
        guard let url = track.album.picUrl.flatMap(URL.init(string:)), artwork(url: url, scope: scope) == nil else { return }
        if let (url, data) = await fetchArtwork(track: track), !Task.isCancelled {
            try? saveArtwork(data, url: url, scope: scope)
        }
    }

    private func fetchArtwork(track: Track) async -> (URL, Data)? {
        guard let original = track.album.picUrl.flatMap(URL.init(string:)),
              let url = track.album.picUrl?.resizedImageURL(640),
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return (original, data)
    }

    private func artworkURL(_ url: URL, scope: String) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems?.filter { $0.name != "param" }
        components?.queryItems = queryItems
        if components?.queryItems?.isEmpty == true { components?.queryItems = nil }
        // http/https and thumbnail sizes refer to the same artwork.
        components?.scheme = "https"
        return folder(scope).appendingPathComponent("art-\(Self.key(components?.string ?? url.absoluteString))")
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        var directory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
}
