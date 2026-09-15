import Foundation

/// Typed NetEase Cloud Music API surface, mapped to real weapi/eapi endpoints.
enum NeteaseAPI {
    private static var client: NeteaseClient { .shared }

    private static func weapi<T: Decodable>(
        _ type: T.Type, _ path: String, _ payload: [String: Any] = [:]
    ) async throws -> T {
        let data = try await client.weapi(path, payload)
        return try client.decoded(T.self, from: data)
    }

    private static func eapi<T: Decodable>(
        _ type: T.Type, _ path: String, _ payload: [String: Any] = [:]
    ) async throws -> T {
        let data = try await client.eapi(path, payload)
        return try client.decoded(T.self, from: data)
    }

    struct CodeOnly: Decodable {
        let code: Int
    }

    // MARK: - Auth

    struct QRKeyResponse: Decodable {
        let code: Int
        let unikey: String
    }

    static func qrKey() async throws -> String {
        try await weapi(QRKeyResponse.self, "/login/qrcode/unikey", ["type": 1]).unikey
    }

    static func qrLoginURL(unikey: String) -> String {
        "https://music.163.com/login?codekey=\(unikey)"
    }

    struct QRCheckResponse: Decodable {
        let code: Int
        let message: String?
        let nickname: String?
        let avatarUrl: String?
    }

    /// Codes: 800 expired · 801 waiting · 802 scanned · 803 success.
    /// On 803 the auth cookies arrive via Set-Cookie and are absorbed by the client.
    static func qrCheck(unikey: String) async throws -> QRCheckResponse {
        let data = try await client.weapi("/login/qrcode/client/login", ["key": unikey, "type": 1])
        return try JSONDecoder().decode(QRCheckResponse.self, from: data)
    }

    /// Sends an SMS verification code for phone-number login
    /// (upstream: `/api/sms/captcha/sent`).
    static func sendSMSCode(phone: String, countryCode: String = "86") async throws {
        let data = try await client.weapi("/sms/captcha/sent",
                                          ["ctcode": countryCode, "cellphone": phone,
                                           "secrete": "music_middleuser_pclogin"])
        _ = try client.decoded(CodeOnly.self, from: data)
    }

    /// Phone-number login with an SMS code (upstream: `/api/w/login/cellphone`).
    /// Auth cookies arrive via Set-Cookie.
    static func loginCellphone(phone: String, captcha: String, countryCode: String = "86") async throws {
        let data = try await client.weapi("/w/login/cellphone",
                                          ["type": "1", "https": "true",
                                           "phone": phone, "countrycode": countryCode,
                                           "captcha": captcha, "remember": "true",
                                           "secureCaptcha": ""])
        _ = try client.decoded(CodeOnly.self, from: data)
        guard client.isLoggedIn else {
            throw NeteaseAPIError.business(code: -1, message: String(localized: "登录失败，请重试"))
        }
    }

    static func logout(detachedCookies: [String: String]? = nil) async {
        let oldCookies = detachedCookies ?? client.authenticationCookies()
        if detachedCookies == nil { client.clearAuthCookies() }
        _ = try? await client.weapi("/logout", cookieOverrides: oldCookies, absorbResponseCookies: false)
    }

    static func refreshLogin() async {
        _ = try? await client.weapi("/login/token/refresh")
    }

    struct AccountResponse: Decodable {
        let code: Int
        let profile: UserProfile?
    }

    static func userAccount() async throws -> UserProfile? {
        try await weapi(AccountResponse.self, "/w/nuser/account/get").profile
    }

    // MARK: - User library

    struct UserPlaylistsResponse: Decodable {
        let playlist: [PlaylistSummary]
        let more: Bool?
    }

    static func userPlaylists(uid: Int, limit: Int = 2000, offset: Int = 0) async throws -> [PlaylistSummary] {
        try await weapi(UserPlaylistsResponse.self, "/user/playlist",
                        ["uid": uid, "limit": limit, "offset": offset, "includeVideo": true]).playlist
    }

    struct LikelistResponse: Decodable {
        let ids: [Int]
    }

    static func likedTrackIDs(uid: Int) async throws -> [Int] {
        try await weapi(LikelistResponse.self, "/song/like/get", ["uid": uid]).ids
    }

    static func likeTrack(id: Int, like: Bool) async throws {
        let resp = try await weapi(CodeOnly.self, "/radio/like?alg=itembased&trackId=\(id)&time=3",
                                   ["trackId": id, "like": like])
        guard resp.code == 200 else {
            throw NeteaseAPIError.business(code: resp.code, message: String(localized: "操作失败，专辑下架或版权锁定"))
        }
    }

    struct SublistResponse<Item: Decodable>: Decodable {
        let data: [Item]
        let count: Int?
        let hasMore: Bool?
    }

    static func likedAlbums(limit: Int = 500, offset: Int = 0) async throws -> [AlbumSummary] {
        try await weapi(SublistResponse<AlbumSummary>.self, "/album/sublist",
                        ["limit": limit, "offset": offset, "total": true]).data
    }

    static func likedArtists(limit: Int = 500, offset: Int = 0) async throws -> [ArtistSummary] {
        try await weapi(SublistResponse<ArtistSummary>.self, "/artist/sublist",
                        ["limit": limit, "offset": offset, "total": true]).data
    }

    struct PlayRecordResponse: Decodable {
        let weekData: [PlayRecordItem]?
        let allData: [PlayRecordItem]?
    }

    static func playRecords(uid: Int, week: Bool) async throws -> [PlayRecordItem] {
        let resp = try await weapi(PlayRecordResponse.self, "/v1/play/record",
                                   ["uid": uid, "type": week ? 1 : 0])
        return (week ? resp.weekData : resp.allData) ?? []
    }

    struct CloudResponse: Decodable {
        let data: [CloudSongItem]?
        let hasMore: Bool?
        /// Bytes; served as a number or a numeric string depending on account age.
        let size: Int64?
        let maxSize: Int64?

        private enum CodingKeys: String, CodingKey {
            case data, hasMore, size, maxSize
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            data = try? c.decode([CloudSongItem].self, forKey: .data)
            hasMore = try? c.decode(Bool.self, forKey: .hasMore)
            size = (try? c.decode(Int64.self, forKey: .size))
                ?? (try? c.decode(String.self, forKey: .size)).flatMap(Int64.init)
            maxSize = (try? c.decode(Int64.self, forKey: .maxSize))
                ?? (try? c.decode(String.self, forKey: .maxSize)).flatMap(Int64.init)
        }
    }

    static func cloudSongs(limit: Int = 1000, offset: Int = 0) async throws -> CloudResponse {
        try await weapi(CloudResponse.self, "/v1/cloud/get", ["limit": limit, "offset": offset])
    }

    static func cloudDelete(id: Int) async throws {
        _ = try await weapi(CodeOnly.self, "/cloud/del", ["songIds": "[\(id)]"])
    }

    /// `startplay` weblog — writes the song into the 最近播放 (recent-plays)
    /// list. NetEase needs this *and* the `play` weblog; sending only `play`
    /// (as before) bumped the listening ranking but never wrote 最近播放 (#33).
    static func scrobbleStart(trackID: Int, sourceID: Int) async {
        await sendWeblog([[
            "action": "startplay",
            "json": [
                "id": trackID, "type": "song",
                "mainsite": "1", "mainsiteWeb": "1",
                "content": "id=\(sourceID)",
            ],
        ]])
    }

    /// `play` weblog — increments the listening-ranking play count and time.
    static func scrobbleFinish(trackID: Int, sourceID: Int, seconds: Int) async {
        await sendWeblog([[
            "action": "play",
            "json": [
                "download": 0, "end": "playend", "id": trackID,
                "sourceId": String(sourceID), "time": seconds,
                "type": "song", "wifi": 0, "source": "list",
                "mainsite": "1", "mainsiteWeb": "1",
                "content": "id=\(sourceID)",
            ],
        ]])
    }

    /// Routed via eapi with the desktop-client cookie (`os=osx`) to match the
    /// reference scrobble implementation.
    private static func sendWeblog(_ log: [[String: Any]]) async {
        guard let data = try? JSONSerialization.data(withJSONObject: log),
              let logs = String(data: data, encoding: .utf8) else { return }
        _ = try? await client.eapi("/feedback/weblog", ["logs": logs],
                                   cookieOverrides: ["os": "osx"])
    }

    // MARK: - Playlists

    struct PersonalizedResponse: Decodable {
        let result: [PlaylistSummary]
    }

    static func personalizedPlaylists(limit: Int = 30) async throws -> [PlaylistSummary] {
        try await weapi(PersonalizedResponse.self, "/personalized/playlist",
                        ["limit": limit, "total": true, "n": 1000]).result
    }

    struct RecommendResourceResponse: Decodable {
        let recommend: [PlaylistSummary]
    }

    /// Logged-in daily recommended playlists.
    static func recommendResource() async throws -> [PlaylistSummary] {
        try await weapi(RecommendResourceResponse.self, "/v1/discovery/recommend/resource").recommend
    }

    struct RecommendSongsResponse: Decodable {
        struct Body: Decodable {
            let dailySongs: [Track]?
        }

        // New accounts with no listening history get `"data": null`.
        let data: Body?
    }

    static func dailyRecommendSongs() async throws -> [Track] {
        let resp = try await weapi(RecommendSongsResponse.self, "/v3/discovery/recommend/songs")
        return resp.data?.dailySongs ?? []
    }

    struct RecommendDislikeResponse: Decodable {
        let data: Track

        private enum CodingKeys: String, CodingKey {
            case data
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let track = try container.decode(Track.self, forKey: .data)
            guard track.id > 0,
                  !track.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .data,
                    in: container,
                    debugDescription: "Recommendation replacement is incomplete"
                )
            }
            data = track
        }
    }

    static func dislikeRecommendedSong(id: Int) async throws -> Track {
        try await weapi(
            RecommendDislikeResponse.self,
            "/v2/discovery/recommend/dislike",
            ["resId": id, "resType": 4, "sceneType": 1]
        ).data
    }

    struct PlaylistDetailResponse: Decodable {
        let playlist: PlaylistDetail
        let privileges: [TrackPrivilege]?
    }

    static func playlistDetail(id: Int) async throws -> PlaylistDetailResponse {
        try await weapi(PlaylistDetailResponse.self, "/v6/playlist/detail",
                        ["id": id, "n": 100_000, "s": 8])
    }

    struct PlaylistBrief: Decodable {
        struct Body: Decodable {
            let id: Int
            let name: String?
            let coverImgUrl: String?
        }

        let playlist: Body
    }

    /// Lightweight name + cover fetch (used for the personalized radar playlists,
    /// whose title/artwork are generated per account).
    static func playlistBrief(id: Int) async throws -> PlaylistBrief.Body {
        try await weapi(PlaylistBrief.self, "/v6/playlist/detail", ["id": id, "n": 1, "s": 0]).playlist
    }

    struct SongDetailResponse: Decodable {
        let songs: [Track]
        let privileges: [TrackPrivilege]?
    }

    static func songDetails(ids: [Int]) async throws -> SongDetailResponse {
        guard !ids.isEmpty else { return SongDetailResponse(songs: [], privileges: []) }
        let c = "[" + ids.map { "{\"id\":\($0)}" }.joined(separator: ",") + "]"
        return try await weapi(SongDetailResponse.self, "/v3/song/detail", ["c": c])
    }

    struct TopPlaylistResponse: Decodable {
        let playlists: [PlaylistSummary]
        let total: Int?
        let more: Bool?
    }

    static func topPlaylists(category: String, order: String = "hot",
                             limit: Int = 50, offset: Int = 0) async throws -> TopPlaylistResponse {
        try await weapi(TopPlaylistResponse.self, "/playlist/list",
                        ["cat": category, "order": order, "limit": limit, "offset": offset, "total": true])
    }

    struct HighQualityResponse: Decodable {
        let playlists: [PlaylistSummary]
        let lasttime: Int?
        let more: Bool?
    }

    static func highQualityPlaylists(category: String = "全部", limit: Int = 50,
                                     before: Int = 0) async throws -> HighQualityResponse {
        try await weapi(HighQualityResponse.self, "/playlist/highquality/list",
                        ["cat": category, "limit": limit, "lasttime": before, "total": true])
    }

    struct ToplistResponse: Decodable {
        let list: [ToplistItem]
    }

    static func toplists() async throws -> [ToplistItem] {
        try await eapi(ToplistResponse.self, "/toplist").list
    }

    struct PlaylistCreateResponse: Decodable {
        let code: Int
        let id: Int?
    }

    @discardableResult
    static func createPlaylist(name: String, isPrivate: Bool) async throws -> Int? {
        try await weapi(PlaylistCreateResponse.self, "/playlist/create",
                        ["name": name, "privacy": isPrivate ? 10 : 0, "type": "NORMAL"]).id
    }

    static func deletePlaylist(id: Int) async throws {
        _ = try await weapi(CodeOnly.self, "/playlist/remove", ["ids": "[\(id)]"])
    }

    static func subscribePlaylist(id: Int, subscribe: Bool) async throws {
        _ = try await weapi(CodeOnly.self, "/playlist/\(subscribe ? "subscribe" : "unsubscribe")", ["id": id])
    }

    struct ManipulateResponse: Decodable {
        let code: Int?
    }

    static func playlistTracks(op: String, playlistID: Int, trackIDs: [Int]) async throws {
        let ids = "[" + trackIDs.map(String.init).joined(separator: ",") + "]"
        let data = try await client.weapi("/playlist/manipulate/tracks",
                                          ["op": op, "pid": playlistID, "trackIds": ids, "imme": "true"])
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let code = obj["code"] as? Int, code != 200 {
            // 512: already-in-playlist quirk — retry with doubled ids like the reference impl
            if code == 512, op == "add" {
                let doubled = "[" + (trackIDs + trackIDs).map(String.init).joined(separator: ",") + "]"
                _ = try await client.weapi("/playlist/manipulate/tracks",
                                           ["op": op, "pid": playlistID, "trackIds": doubled, "imme": "true"])
                return
            }
            throw NeteaseAPIError.business(code: code, message: obj["message"] as? String)
        }
    }

    struct IntelligenceResponse: Decodable {
        struct Item: Decodable {
            let songInfo: Track?
            let id: Int?
        }

        let data: [Item]?
    }

    /// 心动模式 — generates a heartbeat-mode queue from a seed song in a playlist.
    static func intelligenceList(songID: Int, playlistID: Int) async throws -> [Track] {
        let resp = try await weapi(IntelligenceResponse.self, "/playmode/intelligence/list",
                                   ["songId": songID, "type": "fromPlayOne",
                                    "playlistId": playlistID, "startMusicId": songID, "count": 1])
        return (resp.data ?? []).compactMap(\.songInfo)
    }

    // MARK: - Tracks

    struct SongURLResponse: Decodable {
        let data: [SongURLData]
    }

    static func songURL(ids: [Int], level: String) async throws -> [SongURLData] {
        let idString = "[" + ids.map(String.init).joined(separator: ",") + "]"
        var payload: [String: Any] = ["ids": idString, "level": level, "encodeType": "flac"]
        if level == "sky" { payload["immerseType"] = "c51" }
        return try await eapi(SongURLResponse.self, "/song/enhance/player/url/v1", payload).data
    }

    /// Download eligibility is resolved independently of the playback URL.
    /// An injectable client lets the compatibility probe use an isolated cookie
    /// jar without reading or changing the listener's current login.
    static func songDownloadResource(track: Track, level: String, accountScope: String,
                                     client: NeteaseClient = .shared) async throws -> OfflineAudioResource {
        let data = try await songDownloadURL(id: track.id, level: level, client: client)
        return try downloadResource(data: data, track: track, accountScope: accountScope)
    }

    static func songDownloadURL(id: Int, level: String, client: NeteaseClient = .shared) async throws -> SongURLData {
        struct Response: Decodable { let data: SongURLData? }
        let body = try await client.eapi("/song/enhance/download/url/v1",
                                         ["id": id, "level": level, "immerseType": "c51"])
        let response = try client.decoded(Response.self, from: body)
        guard let data = response.data else { throw OfflineAudioError.unavailable }
        return data
    }

    static func downloadResource(data: SongURLData, track: Track, accountScope: String) throws -> OfflineAudioResource {
        guard data.id == track.id, data.code == 200, data.freeTrialInfo == nil,
              let md5 = data.md5?.lowercased(), let quality = data.level,
              let format = data.type.flatMap({ OfflineAudioFormat(rawValue: $0.lowercased()) }),
              let rawURL = data.url, var components = URLComponents(string: rawURL),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host != nil else { throw OfflineAudioError.unavailable }
        components.scheme = "https"
        guard let url = components.url else { throw OfflineAudioError.invalidResource }
        // Some download responses omit time. Track metadata then supplies the
        // independent duration check, including protection against a trial URL.
        if data.time > 0, abs(Double(data.time) / 1000 - track.duration) > max(2, track.duration * 0.03) {
            throw OfflineAudioError.invalidAudio
        }
        let identity = OfflineAudioIdentity(accountScope: accountScope, trackID: track.id, source: "netease",
                                            quality: quality, format: format, contentMD5: md5)
        let descriptor = OfflineAudioDescriptor(identity: identity, byteCount: Int64(data.size), duration: track.duration)
        try descriptor.validate()
        return OfflineAudioResource(descriptor: descriptor, url: url)
    }

    static func lyric(id: Int) async throws -> LyricResponse {
        // `/song/lyric/v1` also returns verbatim (word-by-word) `yrc`. Fall back
        // to the classic endpoint if it yields nothing usable, so plain lyrics
        // never regress.
        if let v1 = try? await weapi(LyricResponse.self, "/song/lyric/v1",
            ["id": id, "cp": false,
             "lv": 0, "kv": 0, "tv": 0, "rv": 0, "yv": 0, "ytv": 0, "yrv": 0]),
            (v1.lrc?.lyric?.isEmpty == false) || (v1.yrc?.lyric?.isEmpty == false) {
            return v1
        }
        return try await weapi(LyricResponse.self, "/song/lyric",
                               ["id": id, "lv": -1, "kv": -1, "tv": -1, "rv": -1])
    }

    struct FMResponse: Decodable {
        let data: [Track]?
    }

    static func personalFM() async throws -> [Track] {
        try await weapi(FMResponse.self, "/v1/radio/get").data ?? []
    }

    static func fmTrash(id: Int) async throws {
        _ = try await weapi(CodeOnly.self, "/radio/trash/add?alg=RT&songId=\(id)&time=25",
                            ["songId": id])
    }

    struct SimiSongResponse: Decodable {
        let songs: [Track]
    }

    static func similarSongs(id: Int, limit: Int = 30) async throws -> [Track] {
        try await weapi(SimiSongResponse.self, "/v1/discovery/simiSong",
                        ["songid": id, "limit": limit, "offset": 0]).songs
    }

    // MARK: - Albums

    static func album(id: Int) async throws -> AlbumDetailResponse {
        try await weapi(AlbumDetailResponse.self, "/v1/album/\(id)")
    }

    struct NewAlbumsResponse: Decodable {
        let albums: [AlbumSummary]
    }

    static func newAlbums(area: String = "ALL", limit: Int = 30, offset: Int = 0) async throws -> [AlbumSummary] {
        try await weapi(NewAlbumsResponse.self, "/album/new",
                        ["area": area, "limit": limit, "offset": offset, "total": true]).albums
    }

    struct AlbumDynamicResponse: Decodable {
        let isSub: Bool?
        let subCount: Int?
    }

    static func albumDynamic(id: Int) async throws -> AlbumDynamicResponse {
        try await eapi(AlbumDynamicResponse.self, "/album/detail/dynamic", ["id": id])
    }

    static func subscribeAlbum(id: Int, subscribe: Bool) async throws {
        _ = try await weapi(CodeOnly.self, "/album/\(subscribe ? "sub" : "unsub")", ["id": id])
    }

    // MARK: - Artists

    struct ArtistResponse: Decodable {
        let artist: ArtistSummary
        let hotSongs: [Track]
    }

    static func artist(id: Int) async throws -> ArtistResponse {
        try await weapi(ArtistResponse.self, "/v1/artist/\(id)")
    }

    struct ArtistAlbumsResponse: Decodable {
        let hotAlbums: [AlbumSummary]
        let more: Bool?
    }

    static func artistAlbums(id: Int, limit: Int = 100, offset: Int = 0) async throws -> ArtistAlbumsResponse {
        try await weapi(ArtistAlbumsResponse.self, "/artist/albums/\(id)",
                        ["limit": limit, "offset": offset, "total": true])
    }

    static func subscribeArtist(id: Int, subscribe: Bool) async throws {
        _ = try await weapi(CodeOnly.self, "/artist/\(subscribe ? "sub" : "unsub")",
                            ["artistId": id, "artistIds": "[\(id)]"])
    }

    struct ToplistArtistResponse: Decodable {
        struct Body: Decodable {
            let artists: [ArtistSummary]
        }

        let list: Body
    }

    static func topArtists(limit: Int = 100) async throws -> [ArtistSummary] {
        try await weapi(ToplistArtistResponse.self, "/toplist/artist",
                        ["type": 1, "limit": limit, "offset": 0, "total": true]).list.artists
    }

    struct SimiArtistResponse: Decodable {
        let artists: [ArtistSummary]
    }

    static func similarArtists(id: Int) async throws -> [ArtistSummary] {
        try await weapi(SimiArtistResponse.self, "/discovery/simiArtist", ["artistid": id]).artists
    }

    // MARK: - Search

    enum SearchType: Int {
        case songs = 1
        case albums = 10
        case artists = 100
        case playlists = 1000
    }

    struct SearchResult: Decodable {
        let songs: [Track]?
        let albums: [AlbumSummary]?
        let artists: [ArtistSummary]?
        let playlists: [PlaylistSummary]?
        let songCount: Int?
        let albumCount: Int?
        let artistCount: Int?
        let playlistCount: Int?
    }

    struct SearchResponse: Decodable {
        let result: SearchResult?
    }

    static func search(_ keywords: String, type: SearchType,
                       limit: Int = 30, offset: Int = 0) async throws -> SearchResult {
        let resp = try await eapi(SearchResponse.self, "/cloudsearch/pc",
                                  ["s": keywords, "type": type.rawValue,
                                   "limit": limit, "offset": offset, "total": true])
        return resp.result ?? SearchResult(songs: nil, albums: nil, artists: nil, playlists: nil,
                                           songCount: nil, albumCount: nil, artistCount: nil, playlistCount: nil)
    }

    struct SearchSuggestResponse: Decodable {
        struct Body: Decodable {
            let songs: [Track]?
            let artists: [ArtistSummary]?
            let albums: [AlbumSummary]?
            let playlists: [PlaylistSummary]?
        }

        let result: Body?
    }

    static func searchSuggest(_ keywords: String) async throws -> SearchSuggestResponse.Body? {
        try await weapi(SearchSuggestResponse.self, "/search/suggest/web", ["s": keywords]).result
    }

    struct SearchDefaultResponse: Decodable {
        struct Body: Decodable {
            let showKeyword: String?
            let realkeyword: String?
        }

        let data: Body?
    }

    static func searchDefaultKeyword() async throws -> String? {
        try await eapi(SearchDefaultResponse.self, "/search/defaultkeyword/get").data?.showKeyword
    }

    // MARK: - Personalized extras

    struct PersonalizedNewsongResponse: Decodable {
        struct Item: Decodable {
            let id: Int
            let name: String?
            let song: Track?
        }

        let result: [Item]
    }

    static func personalizedNewSongs(limit: Int = 10) async throws -> [Track] {
        let resp = try await weapi(PersonalizedNewsongResponse.self, "/personalized/newsong",
                                   ["type": "recommend", "limit": limit, "areaId": 0])
        return resp.result.compactMap(\.song)
    }
}
