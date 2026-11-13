import Foundation

/// In-list song search shared by the playlist and cloud-disk pages: the
/// trimmed query is matched as a case- and diacritic-insensitive substring
/// (Finder's `localizedStandardContains`) of the song, artist and album.
enum TrackSearch {
    /// The query to match, or nil when the text is blank and every song shows.
    static func query(_ text: String) -> String? {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? nil : query
    }

    /// Whether `track`, or any of the `extra` fields shown alongside it
    /// (such as a cloud upload's file name), contains `query`.
    static func matches(_ track: Track, query: String, extra: [String?] = []) -> Bool {
        track.name.localizedStandardContains(query)
            || track.artistNames.localizedStandardContains(query)
            || track.album.name.localizedStandardContains(query)
            || extra.contains { $0?.localizedStandardContains(query) == true }
    }
}
