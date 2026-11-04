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
///
/// Every audio request path reports here: ``failover(from:after:)`` when a
/// request failed before any response, ``markReachable(_:)`` when a host
/// answered. ``preferred(for:now:)`` then steers new requests.
enum NeteaseCDNHost {

    private static let suffix = ".music.126.net"
    private static let log = Logger(subsystem: "im.missuo.kumone", category: "audio-source")

    /// How long a host that failed to connect is skipped in favour of its
    /// twin. Short enough that moving to a network where it works again
    /// costs nothing noticeable (the twin serves the same file anyway).
    static let unreachableTTL: TimeInterval = 10 * 60

    /// Seconds on a monotonic clock, so changing the system time cannot
    /// stretch or cut short a host's ``unreachableTTL``.
    static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private struct HostState {
        /// When the host last failed to connect; cleared when it answers.
        var failedAt: TimeInterval?
        var answeredAt: TimeInterval?
    }

    private static let hosts = OSAllocatedUnfairLock(initialState: [String: HostState]())

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
    /// only ones the twin can fix. Only meaningful for a request that failed
    /// before any response: after one, a timeout is the network, not the host.
    ///
    /// Searches the whole error tree: AVPlayer wraps the network failure
    /// (AVFoundation -11800 over NSURLError or CFNetwork), and Network.framework
    /// may list several attempts under `NSMultipleUnderlyingErrorsKey`.
    static func isHostUnreachable(_ error: Error) -> Bool {
        var queue = [error as NSError]
        var visited = 0
        while !queue.isEmpty, visited < 16 {
            let error = queue.removeFirst()
            visited += 1
            let codes = error.domain == NSURLErrorDomain ? unreachableURLCodes
                : error.domain == cfNetworkDomain ? unreachableURLCodes.union(unreachableHostCodes)
                : []
            if codes.contains(error.code) { return true }
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
                queue.append(underlying)
            }
            if let several = error.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] {
                queue.append(contentsOf: several)
            }
        }
        return false
    }

    /// DNS failures, refused or unanswered connections, and the certificate
    /// mismatch a hijacking resolver produces. Not `SecureConnectionFailed`:
    /// a TLS handshake that breaks is as likely the network as the host.
    private static let unreachableURLCodes: Set<Int> = [
        NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed, NSURLErrorCannotConnectToHost,
        NSURLErrorTimedOut, NSURLErrorServerCertificateUntrusted,
    ]

    /// `kCFHostErrorHostNotFound` and `kCFHostErrorUnknown` (a getaddrinfo
    /// failure), as CFNetwork reports a lookup that went nowhere.
    private static let unreachableHostCodes: Set<Int> = [1, 2]
    private static let cfNetworkDomain = kCFErrorDomainCFNetwork as String

    /// A request to `url` failed before any response. When the host could not
    /// be reached, records that and returns the twin to retry on; nil when
    /// the failure is not the host's, `url` has no twin, or the twin failed
    /// recently too (retrying it would only add another stall).
    static func failover(from url: URL, after error: Error, now: TimeInterval = uptime) -> URL? {
        guard isHostUnreachable(error),
              let twin = alternate(for: url),
              let host = url.host?.lowercased(),
              let twinHost = twin.host else { return nil }
        let twinFailed = hosts.withLock { table in
            table[host, default: HostState()].failedAt = now
            return isFresh(table[twinHost], now: now)
        }
        log.notice("CDN host \(host, privacy: .public) unreachable\(twinFailed ? ", twin too" : ", switching to its twin", privacy: .public)")
        return twinFailed ? nil : twin
    }

    /// `url`'s host answered: it is reachable again.
    static func markReachable(_ url: URL, now: TimeInterval = uptime) {
        guard alternate(for: url) != nil, let host = url.host?.lowercased() else { return }
        hosts.withLock { table in
            table[host] = HostState(failedAt: nil, answeredAt: now)
        }
    }

    /// `url`, or its twin when `url`'s host failed recently and the twin has
    /// not. When both did, the one that answered more recently: a host that
    /// has worked on this network beats one that never has, so a single
    /// hiccup on the working twin does not send requests back to the dead one.
    static func preferred(for url: URL, now: TimeInterval = uptime) -> URL {
        guard let twin = alternate(for: url),
              let host = url.host?.lowercased(),
              let twinHost = twin.host else { return url }
        let useTwin = hosts.withLock { table in
            let state = table[host], twinState = table[twinHost]
            guard isFresh(state, now: now) else { return false }
            guard isFresh(twinState, now: now) else { return true }
            return (twinState?.answeredAt ?? -.infinity) > (state?.answeredAt ?? -.infinity)
        }
        return useTwin ? twin : url
    }

    private static func isFresh(_ state: HostState?, now: TimeInterval) -> Bool {
        guard let failedAt = state?.failedAt else { return false }
        return now - failedAt < unreachableTTL
    }

    /// Forgets every host, for tests.
    static func reset() {
        hosts.withLock { $0.removeAll() }
    }
}
