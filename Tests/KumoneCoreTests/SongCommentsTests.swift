import CommonCrypto
import Foundation
import Testing
@testable import KumoneCore

/// Answers eapi requests from a handler that sees the decrypted payload.
private final class SongCommentsProtocol: URLProtocol, @unchecked Sendable {
    struct Request {
        let path: String
        let payload: [String: Any]
    }

    typealias Handler = @Sendable (Request) -> (status: Int, body: String)

    nonisolated(unsafe) static var handler: Handler = { _ in (200, #"{"code":200}"#) }
    nonisolated(unsafe) static var requests: [Request] = []
    /// Holds a like request until the test has looked at the optimistic state.
    nonisolated(unsafe) static var gate: DispatchSemaphore?
    private static let lock = NSLock()

    static func reset(_ handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
        requests = []
        gate = nil
    }

    static func hold(with gate: DispatchSemaphore) {
        lock.lock(); defer { lock.unlock() }
        self.gate = gate
    }

    static var recorded: [Request] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let payload = EAPIPayload.decode(Self.body(of: request)) ?? [:]
        let recorded = Request(path: path, payload: payload)
        Self.lock.lock()
        Self.requests.append(recorded)
        let handler = Self.handler
        let gate = Self.gate
        Self.lock.unlock()
        gate?.wait()
        let (status, body) = handler(recorded)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// Reverses `RequestCrypto.eapi` so a test can read what was sent.
private enum EAPIPayload {
    static func decode(_ form: Data) -> [String: Any]? {
        guard let text = String(data: form, encoding: .utf8),
              let hex = text.split(separator: "&").first(where: { $0.hasPrefix("params=") })?.dropFirst(7),
              let cipher = bytes(fromHex: String(hex)),
              let plain = decrypt(cipher),
              let message = String(data: plain, encoding: .utf8) else { return nil }
        let parts = message.components(separatedBy: "-36cd479b6b5-")
        guard parts.count == 3, let json = parts[1].data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: json) as? [String: Any]
    }

    private static func bytes(fromHex hex: String) -> Data? {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    private static func decrypt(_ data: Data) -> Data? {
        let key = Data("e82ckenh8dichen8".utf8)
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var written = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { dataPtr in
                key.withUnsafeBytes { keyPtr in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                            keyPtr.baseAddress, key.count, nil,
                            dataPtr.baseAddress, data.count,
                            outPtr.baseAddress, outPtr.count, &written)
                }
            }
        }
        return status == kCCSuccess ? out.prefix(written) : nil
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}

private func json(_ object: Any) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
}

private func comment(_ id: Int, _ content: String = "comment", liked: Bool = false, likedCount: Int = 0) -> [String: Any] {
    [
        "commentId": id,
        "user": ["userId": 10, "nickname": "listener-\(id)", "avatarUrl": "http://p1.example/a.jpg"],
        "content": content,
        "time": 1_762_900_000_000,
        "likedCount": likedCount,
        "liked": liked,
    ]
}

private func page(hot: [[String: Any]] = [], latest: [[String: Any]], total: Int = 100, more: Bool) -> String {
    json(["code": 200, "hotComments": hot, "comments": latest, "total": total, "more": more])
}

@Suite("Song comments", .serialized)
@MainActor
struct SongCommentsTests {
    init() { TestUpstream.configure() }

    private func client(signedIn: Bool = true) -> MusicClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SongCommentsProtocol.self]
        let client = MusicClient(configuration: configuration, persistsCookies: false)
        if signedIn { client.setCookies(["MUSIC_U": "song-comments-test-session"]) }
        return client
    }

    // MARK: Decoding

    @Test func decodesHotLatestRepliesAndLocations() throws {
        let body: [String: Any] = [
            "code": 200,
            "total": 12345,
            "more": true,
            "hotComments": [
                [
                    "commentId": 9_876_543_210, // beyond Int32
                    "user": ["userId": 3_000_000_001, "nickname": "热评", "avatarUrl": "http://p1.example/h.jpg"],
                    "content": "第一行\n第二行",
                    "time": 1_762_900_000_000,
                    "likedCount": 52000,
                    "liked": true,
                    "ipLocation": ["location": "广东"],
                ],
            ],
            "comments": [
                [
                    "commentId": "7000000001", // a numeric string still counts
                    "user": ["userId": 2, "nickname": "回复者"],
                    "content": "同意",
                    "time": 1_762_800_000_000,
                    "likedCount": 0,
                    "liked": false,
                    "ipLocation": ["location": ""],
                    "beReplied": [["user": ["nickname": "楼主"], "content": "好听"]],
                ],
                [
                    "commentId": 7_000_000_002,
                    "user": ["nickname": "删除回复"],
                    "content": "?",
                    "beReplied": [["user": ["nickname": "已删"], "content": NSNull()]],
                ],
            ],
        ]
        let page = try JSONDecoder().decode(SongCommentsPage.self, from: Data(json(body).utf8))

        #expect(page.total == 12345 && page.more)
        let hot = try #require(page.hot.first)
        #expect(hot.id == 9_876_543_210)
        #expect(hot.userID == 3_000_000_001)
        #expect(hot.nickname == "热评" && hot.avatarURL == "http://p1.example/h.jpg")
        #expect(hot.content == "第一行\n第二行")
        #expect(hot.time == Date(timeIntervalSince1970: 1_762_900_000))
        #expect(hot.likedCount == 52000 && hot.liked)
        #expect(hot.ipLocation == "广东")
        #expect(hot.reply == nil)

        #expect(page.latest.map(\.id) == [7_000_000_001, 7_000_000_002])
        #expect(page.latest[0].ipLocation == nil)
        #expect(page.latest[0].reply == SongComment.Reply(nickname: "楼主", content: "好听"))
        #expect(page.latest[1].reply == SongComment.Reply(nickname: "已删", content: nil))
        #expect(page.latest[1].time == nil && page.latest[1].avatarURL == nil)
    }

    @Test func skipsMalformedCommentsWithoutLosingThePage() throws {
        let body: [String: Any] = [
            "code": 200,
            "hotComments": NSNull(),
            "comments": [
                comment(1),
                ["content": "no id"],
                "not a comment",
                NSNull(),
                ["commentId": 0, "content": "zero id"],
                comment(2),
            ],
        ]
        let page = try JSONDecoder().decode(SongCommentsPage.self, from: Data(json(body).utf8))
        #expect(page.hot.isEmpty)
        #expect(page.latest.map(\.id) == [1, 2])
        // A page without `more` ends paging.
        #expect(page.more == false && page.total == 0)
    }

    // MARK: Paging

    @Test func pagesHotThenLatestAndStopsWhenThereIsNoMore() async throws {
        SongCommentsProtocol.reset { request in
            switch request.payload["offset"] as? Int {
            case 0:
                return (200, page(hot: [comment(100), comment(100)], latest: [comment(1), comment(2)], more: true))
            case 2:
                // Hot comments again must not come back; 2 shifted onto this page.
                return (200, page(hot: [comment(101)], latest: [comment(2), comment(3)], total: 120, more: true))
            case 4:
                return (200, page(latest: [comment(4)], total: 120, more: false))
            default:
                return (500, "")
            }
        }
        let content = SongCommentsContent(songID: 186016, pageSize: 2, client: client())

        await content.loadFirstPage()
        #expect(content.phase == .loaded)
        #expect(content.hot.map(\.id) == [100])
        #expect(content.latest.map(\.id) == [1, 2])
        #expect(content.total == 100 && content.hasMore)

        await content.loadMore()
        #expect(content.hot.map(\.id) == [100])
        #expect(content.latest.map(\.id) == [1, 2, 3])
        #expect(content.total == 120 && content.hasMore)

        await content.loadMore()
        #expect(content.latest.map(\.id) == [1, 2, 3, 4])
        #expect(!content.hasMore)

        await content.loadMore() // nothing more to ask for
        let requests = SongCommentsProtocol.recorded
        #expect(requests.count == 3)
        #expect(requests.allSatisfy { $0.path == "/eapi/v1/resource/comments/R_SO_4_186016" })
        #expect(requests.map { $0.payload["offset"] as? Int } == [0, 2, 4])
        #expect(requests.allSatisfy { $0.payload["limit"] as? Int == 2 })
    }

    @Test func stopsWhenAPageBringsNothingNew() async throws {
        SongCommentsProtocol.reset { request in
            (200, page(latest: [comment(1), comment(2)], more: true))
        }
        let content = SongCommentsContent(songID: 1, pageSize: 2, client: client())
        await content.loadFirstPage()
        await content.loadMore()
        #expect(content.latest.map(\.id) == [1, 2])
        #expect(!content.hasMore)
    }

    @Test func anEmptyThreadIsLoadedAndEmpty() async throws {
        SongCommentsProtocol.reset { _ in (200, page(latest: [], total: 0, more: false)) }
        let content = SongCommentsContent(songID: 1, client: client(signedIn: false))
        await content.loadFirstPage()
        #expect(content.phase == .loaded && content.isEmpty && !content.hasMore)
    }

    @Test func aFailedFirstPageCanBeRetried() async throws {
        let attempts = Counter()
        SongCommentsProtocol.reset { _ in
            attempts.next() == 1 ? (502, "") : (200, page(hot: [comment(9)], latest: [comment(1)], more: false))
        }
        let content = SongCommentsContent(songID: 1, client: client(signedIn: false))

        await content.loadFirstPage()
        guard case .failed = content.phase else {
            Issue.record("Expected a failure, got \(content.phase)")
            return
        }
        #expect(content.isEmpty)

        await content.retry()
        #expect(content.phase == .loaded)
        #expect(content.hot.map(\.id) == [9] && content.latest.map(\.id) == [1])
    }

    @Test func aFailedLaterPageKeepsTheCommentsAndCanBeRetried() async throws {
        let laterPages = Counter()
        SongCommentsProtocol.reset { request in
            if request.payload["offset"] as? Int == 0 {
                return (200, page(latest: [comment(1)], more: true))
            }
            if laterPages.next() == 1 { return (200, #"{"code":-460,"message":"busy"}"#) }
            return (200, page(latest: [comment(2)], more: false))
        }
        let content = SongCommentsContent(songID: 1, pageSize: 1, client: client())
        await content.loadFirstPage()

        await content.loadMore()
        #expect(content.loadMoreError == "busy")
        #expect(content.latest.map(\.id) == [1] && content.hasMore && content.phase == .loaded)

        await content.retry()
        #expect(content.loadMoreError == nil)
        #expect(content.latest.map(\.id) == [1, 2] && !content.hasMore)
    }

    // MARK: Likes

    @Test func guestsCannotLikeAndSendNothing() async throws {
        SongCommentsProtocol.reset { _ in (200, #"{"code":200}"#) }
        do {
            try await MusicAPI.likeComment(threadID: "R_SO_4_1", commentID: 1, like: true,
                                           using: client(signedIn: false))
            Issue.record("A guest must not like a comment")
        } catch MusicAPIError.needLogin {
            // Expected before any request is sent.
        }
        #expect(SongCommentsProtocol.recorded.isEmpty)
    }

    @Test(arguments: [true, false])
    func sendsTheThreadAndCommentAsStrings(like: Bool) async throws {
        SongCommentsProtocol.reset { _ in (200, #"{"code":200}"#) }
        try await MusicAPI.likeComment(threadID: "R_SO_4_186016", commentID: 9_876_543_210, like: like,
                                       using: client())
        let request = try #require(SongCommentsProtocol.recorded.first)
        #expect(request.path == (like ? "/eapi/v1/comment/like" : "/eapi/v1/comment/unlike"))
        #expect(request.payload["threadId"] as? String == "R_SO_4_186016")
        #expect(request.payload["commentId"] as? String == "9876543210")
    }

    @Test func likesOptimisticallyAndRollsBackWhenRefused() async throws {
        SongCommentsProtocol.reset { request in
            if request.path.hasPrefix("/eapi/v1/resource/comments/") {
                // The same comment is both hot and latest.
                return (200, page(hot: [comment(5, likedCount: 10)], latest: [comment(5, likedCount: 10), comment(6)],
                                  more: false))
            }
            return (200, #"{"code":400,"message":"操作过于频繁"}"#)
        }
        let content = SongCommentsContent(songID: 1, client: client())
        await content.loadFirstPage()

        let gate = DispatchSemaphore(value: 0)
        SongCommentsProtocol.hold(with: gate)
        let like = Task { try await content.toggleLike(commentID: 5) }
        var waited = 0
        while !content.pendingLikes.contains(5), waited < 400 {
            try await Task.sleep(for: .milliseconds(5))
            waited += 1
        }
        // Shown liked at once, in both sections, before the service answers.
        #expect(content.hot.first?.liked == true && content.hot.first?.likedCount == 11)
        #expect(content.latest.first?.liked == true && content.latest.first?.likedCount == 11)
        // A second tap while the first is in flight is ignored.
        try await content.toggleLike(commentID: 5)
        gate.signal()

        do {
            try await like.value
            Issue.record("The refusal must reach the caller")
        } catch MusicAPIError.business(let code, let message) {
            #expect(code == 400 && message == "操作过于频繁")
        }
        #expect(content.hot.first?.liked == false && content.hot.first?.likedCount == 10)
        #expect(content.latest.first?.liked == false && content.latest.first?.likedCount == 10)
        #expect(content.pendingLikes.isEmpty)
        let likes = SongCommentsProtocol.recorded.filter { $0.path == "/eapi/v1/comment/like" }
        #expect(likes.count == 1)
    }

    @Test func unlikesAndKeepsTheResultWhenAccepted() async throws {
        SongCommentsProtocol.reset { request in
            if request.path.hasPrefix("/eapi/v1/resource/comments/") {
                return (200, page(latest: [comment(7, liked: true, likedCount: 3)], more: false))
            }
            return (200, #"{"code":200}"#)
        }
        let content = SongCommentsContent(songID: 1, client: client())
        await content.loadFirstPage()
        try await content.toggleLike(commentID: 7)
        #expect(content.latest.first?.liked == false && content.latest.first?.likedCount == 2)
        #expect(SongCommentsProtocol.recorded.last?.path == "/eapi/v1/comment/unlike")
    }
}
