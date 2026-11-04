import Foundation
import os

/// Request endpoints, configured on first launch (``UpstreamSetupView``).
enum Upstream {

    /// Stored endpoint configuration.
    struct Hosts: Codable, Equatable, Sendable {
        /// Web, login and the encrypted API: `music.<api>.com`.
        let api: Int
        /// Signed audio and images: `*.music.<cdn>.net`.
        let cdn: Int
    }

    /// One first-launch question: a sum, difference, product (plus a
    /// remainder when needed) or exact quotient, drawn at random.
    enum Question: Sendable, Equatable {
        case sum(Int, Int)
        case difference(Int, Int)
        case product(Int, Int, plus: Int)
        case quotient(Int, Int)

        var prompt: String {
            switch self {
            case let .sum(a, b): "\(a) + \(b) = ?"
            case let .difference(a, b): "\(a) − \(b) = ?"
            case let .product(a, b, 0): "\(a) × \(b) = ?"
            case let .product(a, b, c): "\(a) × \(b) + \(c) = ?"
            case let .quotient(a, b): "\(a) ÷ \(b) = ?"
            }
        }

        var answer: Int {
            switch self {
            case let .sum(a, b): a + b
            case let .difference(a, b): a - b
            case let .product(a, b, c): a * b + c
            case let .quotient(a, b): a / b
            }
        }

        func accepts(_ text: String) -> Bool {
            Int(text.trimmingCharacters(in: .whitespaces)) == answer
        }
    }

    /// Expected answers.
    private static let apiTarget = Int(("£" as Unicode.Scalar).value)
    private static let cdnTarget = Int(("~" as Unicode.Scalar).value)

    /// A fresh pair of questions.
    static func drawQuestions() -> (api: Question, cdn: Question) {
        (question(hitting: apiTarget), question(hitting: cdnTarget))
    }

    /// A random question whose answer is `target`.
    static func question(hitting target: Int) -> Question {
        switch Int.random(in: 0..<4) {
        case 0:
            let a = Int.random(in: 11...(target - 11))
            return .sum(a, target - a)
        case 1:
            let a = Int.random(in: (target + 11)...(target * 4))
            return .difference(a, a - target)
        case 2:
            let b = Int.random(in: 3...9)
            return .product(target / b, b, plus: target % b)
        default:
            let b = Int.random(in: 2...9)
            return .quotient(target * b, b)
        }
    }

    private static let defaultsKey = "upstream.hosts"
    private static let state = OSAllocatedUnfairLock<Hosts?>(initialState: load())

    private static func load() -> Hosts? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(Hosts.self, from: data)
    }

    static var hosts: Hosts? { state.withLock { $0 } }
    static var isConfigured: Bool { hosts != nil }

    /// Stores the answers. Pass `persist: false` from tests.
    static func configure(_ hosts: Hosts, persist: Bool = true) {
        state.withLock { $0 = hosts }
        if persist, let data = try? JSONEncoder().encode(hosts) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func reset() {
        state.withLock { $0 = nil }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static let didChange = Notification.Name("Upstream.didChange")

    // MARK: - Hosts

    static var webHost: String? { hosts.map { "music.\($0.api).com" } }
    static var interfaceHost: String? { hosts.map { "interface.music.\($0.api).com" } }
    /// Suffix every audio CDN host ends with, leading dot included.
    static var cdnSuffix: String? { hosts.map { ".music.\($0.cdn).net" } }

    static func webURL(_ pathAndQuery: String) -> URL? {
        webHost.flatMap { URL(string: "https://\($0)\(pathAndQuery)") }
    }

    static func songPageURL(id: Int) -> URL? { webURL("/#/song?id=\(id)") }

    // MARK: - Protocol identifiers

    /// Source identifier used in request headers, cache keys, offline records
    /// and account scopes.
    static let tag = unshift("ofufbtf")

    private static func unshift(_ shifted: String) -> String {
        String(String.UnicodeScalarView(shifted.unicodeScalars.compactMap { Unicode.Scalar($0.value - 1) }))
    }

    /// Client name for the User-Agent.
    static var clientName: String { tag.prefix(1).uppercased() + tag.dropFirst() + "Music" }

    /// The scope offline downloads and sync records carry for an account.
    static func accountScope(userID: Int) -> String { "\(tag):\(userID)" }
}
