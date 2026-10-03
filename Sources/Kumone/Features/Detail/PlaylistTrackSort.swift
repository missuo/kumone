import Foundation

enum PlaylistTrackSort: String, CaseIterable {
    case addedNewestFirst = "添加时间（由新到旧）"
    case addedOldestFirst = "添加时间（由旧到新）"
    case songName = "歌曲名"
    case albumName = "专辑名"
    case artistName = "歌手名"

    func sorted(_ tracks: [Track]) -> [Track] {
        // The liked playlist is supplied in newest-addition order. Preserve
        // that order or reverse it; song IDs are unrelated to addition time.
        let name: (Track) -> String
        switch self {
        case .addedNewestFirst: return tracks
        case .addedOldestFirst: return Array(tracks.reversed())
        case .songName: name = { $0.name }
        case .albumName: name = { $0.album.name }
        case .artistName: name = { $0.artistNames }
        }
        let entries = tracks.enumerated().map { (index: $0.offset, track: $0.element, name: name($0.element)) }
        return entries.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.index < $1.index : comparison == .orderedAscending
        }.map(\.track)
    }
}
