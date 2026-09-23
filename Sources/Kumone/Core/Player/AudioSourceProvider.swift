import Foundation

enum AudioSourceID: String, CaseIterable, Hashable {
    case pyncmd
    case kugou
    case kuwo

    var displayName: String {
        switch self {
        case .pyncmd: return "pyncmd"
        case .kugou: return String(localized: "酷狗音乐")
        case .kuwo: return String(localized: "酷我音乐")
        }
    }
}

struct ResolvedAudioSource {
    let id: AudioSourceID
    let displayName: String
    let url: URL
}

protocol AudioSourceProvider {
    var id: AudioSourceID { get }
    var displayName: String { get }

    func resolve(track: Track) async throws -> ResolvedAudioSource?
}

enum AudioSourceProviderError: LocalizedError {
    case invalidResponse
    case invalidURL
    case missingBitrate
    case missingStreamURL

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid audio-source response"
        case .invalidURL: return "Invalid audio-source URL"
        case .missingBitrate: return "Audio-source response has no bitrate"
        case .missingStreamURL: return "Audio-source response has no stream URL"
        }
    }
}

enum AudioSourceTrackMatcher {
    static func keyword(for track: Track) -> String {
        "\(track.name) \(track.artists.first?.name ?? "")"
            .trimmingCharacters(in: .whitespaces)
    }

    static func matches(
        track: Track,
        title: String,
        artist: String,
        durationMS: Int
    ) -> Bool {
        guard track.durationMS > 0,
              durationMS > 0,
              abs(durationMS - track.durationMS) <= 5_000,
              normalized(title) == normalized(track.name),
              !hasVersionConflict(original: track.name, candidate: title)
        else { return false }

        let expectedArtist = normalized(track.artists.first?.name ?? "")
        guard !expectedArtist.isEmpty else { return false }
        return artistNames(in: artist).contains(expectedArtist)
    }

    private static let versionMarkers = [
        "live", "remix", "伴奏", "dj", "cover", "翻唱", "instrumental", "karaoke"
    ]

    private static func hasVersionConflict(original: String, candidate: String) -> Bool {
        let originalMarkers = Set(versionMarkers.filter { normalized(original).contains($0) })
        let candidateMarkers = Set(versionMarkers.filter { normalized(candidate).contains($0) })
        return originalMarkers != candidateMarkers
    }

    private static func artistNames(in value: String) -> [String] {
        value.split(whereSeparator: { "/&、,，;；".contains($0) })
            .map { normalized(String($0)) }
            .filter { !$0.isEmpty }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map { String($0) }
            .joined()
    }
}
