import Foundation

// MARK: - User

struct UserProfile: Codable, Hashable {
    let userId: Int
    let nickname: String
    let avatarUrl: String?
    let backgroundUrl: String?
    let signature: String?
    let vipType: Int

    private enum CodingKeys: String, CodingKey {
        case userId, nickname, avatarUrl, backgroundUrl, signature, vipType
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = try c.decode(Int.self, forKey: .userId)
        nickname = (try? c.decode(String.self, forKey: .nickname)) ?? ""
        avatarUrl = try? c.decode(String.self, forKey: .avatarUrl)
        backgroundUrl = try? c.decode(String.self, forKey: .backgroundUrl)
        signature = try? c.decode(String.self, forKey: .signature)
        vipType = (try? c.decode(Int.self, forKey: .vipType)) ?? 0
    }
}

// MARK: - Playlist

struct PlaylistCreator: Codable, Hashable {
    let userId: Int
    let nickname: String
    let avatarUrl: String?

    private enum CodingKeys: String, CodingKey {
        case userId, nickname, avatarUrl
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = (try? c.decode(Int.self, forKey: .userId)) ?? 0
        nickname = (try? c.decode(String.self, forKey: .nickname)) ?? ""
        avatarUrl = try? c.decode(String.self, forKey: .avatarUrl)
    }
}

/// A playlist as it appears in grids and sidebars. Tolerates the several cover
/// field names and numeric types the service uses across endpoints.
struct PlaylistSummary: Codable, Hashable, Identifiable {
    let id: Int
    let name: String
    let coverURL: String?
    let playCount: Int
    let trackCount: Int
    let updateTime: Int?
    let copywriter: String?
    let creator: PlaylistCreator?
    let specialType: Int
    let privacy: Int
    let subscribed: Bool

    private enum CodingKeys: String, CodingKey {
        case id, name, picUrl, coverImgUrl, playCount, playcount, trackCount
        case copywriter, creator, specialType, privacy, subscribed, updateTime
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        coverURL = (try? c.decode(String.self, forKey: .picUrl))
            ?? (try? c.decode(String.self, forKey: .coverImgUrl))
        let count = (try? c.decode(Double.self, forKey: .playCount))
            ?? (try? c.decode(Double.self, forKey: .playcount)) ?? 0
        playCount = Int(count)
        trackCount = (try? c.decode(Int.self, forKey: .trackCount)) ?? 0
        updateTime = try? c.decode(Int.self, forKey: .updateTime)
        copywriter = try? c.decode(String.self, forKey: .copywriter)
        creator = try? c.decode(PlaylistCreator.self, forKey: .creator)
        specialType = (try? c.decode(Int.self, forKey: .specialType)) ?? 0
        privacy = (try? c.decode(Int.self, forKey: .privacy)) ?? 0
        subscribed = (try? c.decode(Bool.self, forKey: .subscribed)) ?? false
    }

    /// The auto-created "我喜欢的音乐" playlist.
    var isLikedSongsList: Bool { specialType == 5 }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(coverURL, forKey: .coverImgUrl)
        try c.encode(playCount, forKey: .playCount)
        try c.encode(trackCount, forKey: .trackCount)
        try c.encodeIfPresent(updateTime, forKey: .updateTime)
        try c.encodeIfPresent(copywriter, forKey: .copywriter)
        try c.encodeIfPresent(creator, forKey: .creator)
        try c.encode(specialType, forKey: .specialType)
        try c.encode(privacy, forKey: .privacy)
        try c.encode(subscribed, forKey: .subscribed)
    }
}

struct TrackIDRef: Codable, Hashable {
    let id: Int
}

struct PlaylistDetail: Codable, Hashable {
    let id: Int
    let name: String
    let coverImgUrl: String?
    let creator: PlaylistCreator?
    let description: String?
    var trackCount: Int
    let playCount: Int
    let subscribedCount: Int
    var subscribed: Bool
    var trackIds: [TrackIDRef]
    var tracks: [Track]
    let specialType: Int
    let updateTime: Int

    private enum CodingKeys: String, CodingKey {
        case id, name, coverImgUrl, creator, description, trackCount, playCount
        case subscribedCount, subscribed, trackIds, tracks, specialType, updateTime
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        coverImgUrl = try? c.decode(String.self, forKey: .coverImgUrl)
        creator = try? c.decode(PlaylistCreator.self, forKey: .creator)
        description = try? c.decode(String.self, forKey: .description)
        trackCount = (try? c.decode(Int.self, forKey: .trackCount)) ?? 0
        playCount = Int((try? c.decode(Double.self, forKey: .playCount)) ?? 0)
        subscribedCount = (try? c.decode(Int.self, forKey: .subscribedCount)) ?? 0
        subscribed = (try? c.decode(Bool.self, forKey: .subscribed)) ?? false
        trackIds = (try? c.decode([TrackIDRef].self, forKey: .trackIds)) ?? []
        tracks = (try? c.decode([Track].self, forKey: .tracks)) ?? []
        specialType = (try? c.decode(Int.self, forKey: .specialType)) ?? 0
        updateTime = (try? c.decode(Int.self, forKey: .updateTime)) ?? 0
    }

    init(summary: PlaylistSummary) {
        id = summary.id
        name = summary.name
        coverImgUrl = summary.coverURL
        creator = summary.creator
        description = summary.copywriter
        trackCount = summary.trackCount
        playCount = summary.playCount
        subscribedCount = 0
        subscribed = summary.subscribed
        trackIds = []
        tracks = []
        specialType = summary.specialType
        updateTime = 0
    }
}

// MARK: - Album / Artist

struct AlbumSummary: Decodable, Hashable, Identifiable {
    let id: Int
    let name: String
    let picUrl: String?
    let artistName: String
    let publishTime: Int
    let size: Int
    let subType: String?
    let alias: [String]

    private enum CodingKeys: String, CodingKey {
        case id, name, picUrl, cover, artist, artists, publishTime, size, subType, alia, alias
    }

    private struct ArtistName: Codable {
        let name: String?
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        picUrl = (try? c.decode(String.self, forKey: .picUrl))
            ?? (try? c.decode(String.self, forKey: .cover))
        if let artist = try? c.decode(ArtistName.self, forKey: .artist), let n = artist.name {
            artistName = n
        } else if let list = try? c.decode([ArtistName].self, forKey: .artists) {
            artistName = list.compactMap(\.name).joined(separator: " / ")
        } else {
            artistName = ""
        }
        publishTime = (try? c.decode(Int.self, forKey: .publishTime)) ?? 0
        size = (try? c.decode(Int.self, forKey: .size)) ?? 0
        subType = try? c.decode(String.self, forKey: .subType)
        alias = (try? c.decode([String].self, forKey: .alia))
            ?? (try? c.decode([String].self, forKey: .alias)) ?? []
    }

    var publishYear: String {
        guard publishTime > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(publishTime) / 1000)
        return String(Calendar.current.component(.year, from: date))
    }
}

struct AlbumDetailResponse: Decodable {
    let album: AlbumDetail
    let songs: [Track]
}

struct AlbumDetail: Decodable, Hashable {
    let id: Int
    let name: String
    let picUrl: String?
    let artist: ArtistSummary?
    let publishTime: Int
    let description: String?
    let company: String?
    let size: Int
    let subType: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, picUrl, artist, publishTime, description, company, size, subType
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        picUrl = try? c.decode(String.self, forKey: .picUrl)
        artist = try? c.decode(ArtistSummary.self, forKey: .artist)
        publishTime = (try? c.decode(Int.self, forKey: .publishTime)) ?? 0
        description = try? c.decode(String.self, forKey: .description)
        company = try? c.decode(String.self, forKey: .company)
        size = (try? c.decode(Int.self, forKey: .size)) ?? 0
        subType = try? c.decode(String.self, forKey: .subType)
    }
}

struct ArtistSummary: Decodable, Hashable, Identifiable {
    let id: Int
    let name: String
    let picUrl: String?
    let albumSize: Int
    let musicSize: Int
    let briefDesc: String?
    let alias: [String]
    let followed: Bool

    private enum CodingKeys: String, CodingKey {
        case id, name, picUrl, img1v1Url, cover, avatar, albumSize, musicSize, briefDesc, alias, followed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        picUrl = (try? c.decode(String.self, forKey: .picUrl))
            ?? (try? c.decode(String.self, forKey: .cover))
            ?? (try? c.decode(String.self, forKey: .avatar))
            ?? (try? c.decode(String.self, forKey: .img1v1Url))
        albumSize = (try? c.decode(Int.self, forKey: .albumSize)) ?? 0
        musicSize = (try? c.decode(Int.self, forKey: .musicSize)) ?? 0
        briefDesc = try? c.decode(String.self, forKey: .briefDesc)
        alias = (try? c.decode([String].self, forKey: .alias)) ?? []
        followed = (try? c.decode(Bool.self, forKey: .followed)) ?? false
    }
}

// MARK: - Toplist

struct ToplistItem: Decodable, Hashable, Identifiable {
    let id: Int
    let name: String
    let coverImgUrl: String?
    let updateFrequency: String?
    let tracks: [ToplistTrackPreview]
    let playCount: Int

    private enum CodingKeys: String, CodingKey {
        case id, name, coverImgUrl, updateFrequency, tracks, playCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        coverImgUrl = try? c.decode(String.self, forKey: .coverImgUrl)
        updateFrequency = try? c.decode(String.self, forKey: .updateFrequency)
        tracks = (try? c.decode([ToplistTrackPreview].self, forKey: .tracks)) ?? []
        playCount = Int((try? c.decode(Double.self, forKey: .playCount)) ?? 0)
    }
}

struct ToplistTrackPreview: Codable, Hashable {
    let first: String
    let second: String
}

// MARK: - Lyrics

struct LyricResponse: Codable {
    struct LyricBody: Codable {
        let lyric: String?
    }

    let lrc: LyricBody?
    let tlyric: LyricBody?
    let romalrc: LyricBody?
    /// Verbatim (word-by-word) lyrics for karaoke highlighting; only present
    /// on the `/song/lyric/v1` endpoint and only for songs that have them.
    let yrc: LyricBody?
    let ytlrc: LyricBody?
    let yromalrc: LyricBody?
    let lyricUser: LyricContributor?
    let transUser: LyricContributor?
    let nolyric: Bool?
    let uncollected: Bool?
}

struct LyricContributor: Codable {
    let nickname: String?
}

// MARK: - Song URL

struct SongURLData: Decodable, Hashable {
    let id: Int
    let url: String?
    let br: Int
    let size: Int
    let type: String?
    let level: String?
    let fee: Int
    let freeTrialInfo: FreeTrialInfo?
    let time: Int
    let code: Int?
    let md5: String?

    private enum CodingKeys: String, CodingKey {
        case id, url, br, size, type, level, fee, freeTrialInfo, time, code, md5
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        url = try? c.decode(String.self, forKey: .url)
        br = (try? c.decode(Int.self, forKey: .br)) ?? 0
        size = (try? c.decode(Int.self, forKey: .size)) ?? 0
        type = try? c.decode(String.self, forKey: .type)
        level = try? c.decode(String.self, forKey: .level)
        fee = (try? c.decode(Int.self, forKey: .fee)) ?? 0
        freeTrialInfo = try? c.decode(FreeTrialInfo.self, forKey: .freeTrialInfo)
        time = (try? c.decode(Int.self, forKey: .time)) ?? 0
        code = try? c.decode(Int.self, forKey: .code)
        md5 = try? c.decode(String.self, forKey: .md5)
    }
}

struct FreeTrialInfo: Codable, Hashable {
    let start: Int?
    let end: Int?
}

// MARK: - Cloud disk

/// A cloud-disk entry. The real payload nests metadata under `privateCloud`
/// and the playable track under `simpleSong`; older docs show flat fields,
/// so both shapes are tolerated.
struct CloudSongItem: Decodable, Hashable, Identifiable {
    let songId: Int
    let songName: String?
    let artist: String?
    let album: String?
    /// The uploaded file's name, which often differs from the matched song.
    let fileName: String?
    let fileSize: Int
    let simpleSong: Track?

    var id: Int { songId }

    private enum CodingKeys: String, CodingKey {
        case songId, songName, artist, album, fileName, fileSize, simpleSong, privateCloud
    }

    private struct PrivateCloud: Decodable {
        let songId: Int?
        let song: String?
        let artist: String?
        let album: String?
        let fileName: String?
        let fileSize: Int?

        private enum CodingKeys: String, CodingKey {
            case songId, song, artist, album, fileName, fileSize
        }

        // Field by field, so one unexpected shape does not discard the rest.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            songId = try? c.decode(Int.self, forKey: .songId)
            song = try? c.decode(String.self, forKey: .song)
            artist = try? c.decode(String.self, forKey: .artist)
            album = try? c.decode(String.self, forKey: .album)
            fileName = try? c.decode(String.self, forKey: .fileName)
            fileSize = try? c.decode(Int.self, forKey: .fileSize)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let nested = try? c.decode(PrivateCloud.self, forKey: .privateCloud)
        simpleSong = try? c.decode(Track.self, forKey: .simpleSong)
        songId = (try? c.decode(Int.self, forKey: .songId))
            ?? nested?.songId ?? simpleSong?.id ?? 0
        songName = (try? c.decode(String.self, forKey: .songName))
            ?? nested?.song ?? simpleSong?.name
        artist = (try? c.decode(String.self, forKey: .artist)) ?? nested?.artist
        album = (try? c.decode(String.self, forKey: .album)) ?? nested?.album
        fileName = (try? c.decode(String.self, forKey: .fileName)) ?? nested?.fileName
        fileSize = (try? c.decode(Int.self, forKey: .fileSize)) ?? nested?.fileSize ?? 0
    }

    /// Whether the in-list search `query` matches this upload: the matched
    /// song as playlists search it, plus the cloud's own metadata and file name.
    func matches(_ query: String) -> Bool {
        guard let simpleSong else { return false }
        return TrackSearch.matches(simpleSong, query: query, extra: [songName, artist, album, fileName])
    }
}

// MARK: - Play record

struct PlayRecordItem: Decodable, Hashable {
    let playCount: Int
    let score: Int
    let song: Track

    private enum CodingKeys: String, CodingKey {
        case playCount, score, song
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        playCount = (try? c.decode(Int.self, forKey: .playCount)) ?? 0
        score = (try? c.decode(Int.self, forKey: .score)) ?? 0
        song = try c.decode(Track.self, forKey: .song)
    }
}

/// One entry of the account's 最近播放 list (`/play-record/song/list`), which
/// the service orders by when each song was last played, newest first.
struct RecentPlay: Decodable, Hashable {
    let song: Track
    /// Nil when the service leaves `playTime` out.
    let playedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case data, playTime
    }

    init(song: Track, playedAt: Date?) {
        self.song = song
        self.playedAt = playedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        song = try c.decode(Track.self, forKey: .data)
        // Milliseconds since 1970.
        playedAt = (try? c.decode(Int64.self, forKey: .playTime))
            .flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0) / 1000) : nil }
    }
}

// MARK: - Formatting helpers

enum Formatters {
    private static var usesChineseUnits: Bool {
        Locale.current.language.languageCode?.identifier == "zh"
    }

    static func playCount(_ count: Int) -> String {
        if usesChineseUnits {
            switch count {
            case 100_000_000...:
                return String(format: "%.1f亿", Double(count) / 100_000_000)
            case 10_000...:
                return String(format: "%.1f万", Double(count) / 10_000)
            default:
                return String(count)
            }
        }
        switch count {
        case 1_000_000_000...:
            return String(format: "%.1fB", Double(count) / 1_000_000_000)
        case 1_000_000...:
            return String(format: "%.1fM", Double(count) / 1_000_000)
        case 10_000...:
            return String(format: "%.1fK", Double(count) / 1_000)
        default:
            return String(count)
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func longDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        if total >= 3600 {
            return String(localized: "\(total / 3600) 小时 \((total % 3600) / 60) 分钟")
        }
        return String(localized: "\(total / 60) 分钟")
    }

    static func date(fromMS ms: Int) -> String {
        guard ms > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }
}

extension String {
    /// Image CDN resize convention: `<picUrl>?param=<W>y<H>`.
    /// Also upgrades `http:` to `https:`.
    func resizedImageURL(_ size: Int) -> URL? {
        guard var components = URLComponents(string: self) else { return nil }
        if components.scheme == "http" { components.scheme = "https" }
        // Replacing a previous size keeps the CDN and local decoder in sync;
        // appending a second `param` can leave the original large size active.
        var items = components.queryItems?.filter { $0.name != "param" } ?? []
        items.append(URLQueryItem(name: "param", value: "\(size)y\(size)"))
        components.queryItems = items
        return components.url
    }
}
