import Foundation
import os

/// NetEase serves every signed audio path from a pair of CDN hosts,
/// `mN.music.126.net` and `mNc.music.126.net`. The signature lives in the
/// path and is not bound to the host, so a URL whose host cannot be reached
/// can be retried on its twin. The official client switches between the two
/// the same way (`^(m|s|v|sv|p|d)(\d+)(c)?.music.126.net$`).
///
/// Why it matters: a resolver can fail one host of the pair and not the
/// other. Some resolvers time out on `166cdn.com`, which `m801` CNAMEs
/// through, while `m801c` goes through `163jiasu.com` and resolves fine. So
/// without the swap every song NetEase happens to place on `m801` fails on
/// such a network after a ten-second DNS stall.
enum NeteaseCDNHost {

    private static let suffix = ".music.126.net"
    private static let log = Logger(subsystem: "im.missuo.kumone", category: "audio-source")

    /// How long a host that failed to connect is skipped in favour of its
    /// twin. Short enough that moving to a network where it works again
    /// costs nothing noticeable (the twin serves the same file anyway).
    static let unreachableTTL: TimeInterval = 10 * 60

    private static let unreachable = OSAllocatedUnfairLock(initialState: [String: Date]())

    /// `url` on the twin CDN host (`m801` <-> `m801c`), or nil when `url` is not
    /// a NetEase audio CDN URL.
    static func alternate(for url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(),
              host.hasSuffix(suffix) else { return nil }
        var label = host.dropLast(suffix.count)
        guard label.first == "m" else { return nil }
        label = label.dropFirst()
        let isTwin = label.last == "c"
        if isTwin { label = label.dropLast() }
        guard !label.isEmpty, label.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        components.host = "m\(label)\(isTwin ? "" : "c")\(suffix)"
        return components.url
    }

    /// True for failures that mean the host itself could not be reached, the
    /// only ones the twin can fix. Anything after a response (an HTTP status,
    /// a parse error) is about the file, not the host.
    ///
    /// Walks `NSUnderlyingErrorKey`: AVPlayer wraps the network failure
    /// (AVFoundation -11800 over NSURLError or CFNetwork -1003), while
    /// URLSession hands it over directly.
    static func isHostUnreachable(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        while let error = current {
            if (error.domain == NSURLErrorDomain || error.domain == kCFErrorDomainCFNetwork as String),
               unreachableCodes.contains(error.code) {
                return true
            }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    private static let unreachableCodes: Set<Int> = [
        NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed, NSURLErrorCannotConnectToHost,
        NSURLErrorTimedOut, NSURLErrorSecureConnectionFailed,
    ]

    /// Remember that `url`'s host could not be reached, so later requests go
    /// straight to the twin instead of paying the same stall again.
    static func markUnreachable(_ url: URL, now: Date = Date()) {
        guard alternate(for: url) != nil, let host = url.host?.lowercased() else { return }
        unreachable.withLock { $0[host] = now }
        log.notice("CDN host \(host, privacy: .public) unreachable, switching to its twin")
    }

    /// `url`, or its twin when `url`'s host failed recently and the twin has
    /// not.
    static func preferred(for url: URL, now: Date = Date()) -> URL {
        guard let twin = alternate(for: url),
              let host = url.host?.lowercased(),
              let twinHost = twin.host else { return url }
        let isFresh = { (host: String, table: [String: Date]) -> Bool in
            table[host].map { now.timeIntervalSince($0) < unreachableTTL } ?? false
        }
        let useTwin = unreachable.withLock { table in
            isFresh(host, table) && !isFresh(twinHost, table)
        }
        return useTwin ? twin : url
    }
}
