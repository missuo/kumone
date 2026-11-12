import Foundation

/// A listener's comment on a song (`/v1/resource/comments/R_SO_4_<id>`).
struct SongComment: Decodable, Hashable, Identifiable {
    /// The comment this one replies to, when it is a reply.
    struct Reply: Hashable {
        let nickname: String
        /// `nil` when the replied comment was deleted.
        let content: String?
    }

    /// Comment ids outgrow Int32; Int is 64-bit on every supported platform.
    let id: Int
    let userID: Int
    let nickname: String
    let avatarURL: String?
    let content: String
    let time: Date?
    var likedCount: Int
    /// Liked by the signed-in listener.
    var liked: Bool
    let ipLocation: String?
    let reply: Reply?

    init(id: Int, userID: Int = 0, nickname: String = "", avatarURL: String? = nil,
         content: String = "", time: Date? = nil, likedCount: Int = 0, liked: Bool = false,
         ipLocation: String? = nil, reply: Reply? = nil) {
        self.id = id
        self.userID = userID
        self.nickname = nickname
        self.avatarURL = avatarURL
        self.content = content
        self.time = time
        self.likedCount = likedCount
        self.liked = liked
        self.ipLocation = ipLocation
        self.reply = reply
    }

    private enum CodingKeys: String, CodingKey {
        case commentId, user, content, time, likedCount, liked, ipLocation, beReplied
    }

    private struct User: Decodable {
        let userId: Int?
        let nickname: String?
        let avatarUrl: String?

        private enum CodingKeys: String, CodingKey { case userId, nickname, avatarUrl }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            userId = SongComment.flexibleInt(c, .userId)
            nickname = try? c.decode(String.self, forKey: .nickname)
            avatarUrl = try? c.decode(String.self, forKey: .avatarUrl)
        }
    }

    private struct Location: Decodable {
        let location: String?

        private enum CodingKeys: String, CodingKey { case location }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            location = try? c.decode(String.self, forKey: .location)
        }
    }

    private struct Replied: Decodable {
        let user: User?
        let content: String?

        private enum CodingKeys: String, CodingKey { case user, content }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            user = try? c.decode(User.self, forKey: .user)
            content = try? c.decode(String.self, forKey: .content)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Without an id a comment cannot be liked or told apart: not a comment.
        guard let id = Self.flexibleInt(c, .commentId), id > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .commentId, in: c,
                                                   debugDescription: "Missing comment id")
        }
        self.id = id
        let user = try? c.decode(User.self, forKey: .user)
        userID = user?.userId ?? 0
        nickname = user?.nickname ?? ""
        avatarURL = user?.avatarUrl.flatMap { $0.isEmpty ? nil : $0 }
        content = (try? c.decode(String.self, forKey: .content)) ?? ""
        time = Self.flexibleInt(c, .time).flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0) / 1000) : nil }
        likedCount = max(0, Self.flexibleInt(c, .likedCount) ?? 0)
        liked = (try? c.decode(Bool.self, forKey: .liked)) ?? false
        let location = (try? c.decode(Location.self, forKey: .ipLocation))?.location?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        ipLocation = location?.isEmpty == false ? location : nil
        let replied = ((try? c.decode([Lossy<Replied>].self, forKey: .beReplied)) ?? []).compactMap(\.value).first
        if let replied, let name = replied.user?.nickname, !name.isEmpty {
            reply = Reply(nickname: name, content: replied.content.flatMap { $0.isEmpty ? nil : $0 })
        } else {
            reply = nil
        }
    }

    /// Ids and times arrive as numbers, occasionally as numeric strings.
    fileprivate static func flexibleInt<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Int? {
        if let value = try? c.decode(Int.self, forKey: key) { return value }
        if let value = try? c.decode(String.self, forKey: key) { return Int(value) }
        if let value = try? c.decode(Double.self, forKey: key), value.isFinite,
           value >= Double(Int.min), value < Double(Int.max) {
            return Int(value)
        }
        return nil
    }
}

/// One page of a song's comments. Hot comments come on the first page only.
struct SongCommentsPage: Decodable {
    let hot: [SongComment]
    let latest: [SongComment]
    let total: Int
    let more: Bool

    init(hot: [SongComment] = [], latest: [SongComment] = [], total: Int = 0, more: Bool = false) {
        self.hot = hot
        self.latest = latest
        self.total = total
        self.more = more
    }

    private enum CodingKeys: String, CodingKey {
        case hotComments, comments, total, more
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A malformed comment is skipped rather than losing the page.
        hot = ((try? c.decode([Lossy<SongComment>].self, forKey: .hotComments)) ?? []).compactMap(\.value)
        latest = ((try? c.decode([Lossy<SongComment>].self, forKey: .comments)) ?? []).compactMap(\.value)
        total = max(0, SongComment.flexibleInt(c, .total) ?? 0)
        // A missing flag ends paging rather than asking forever.
        more = (try? c.decode(Bool.self, forKey: .more)) ?? false
    }
}

/// Decodes an array element as `nil` instead of failing the whole array.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}
