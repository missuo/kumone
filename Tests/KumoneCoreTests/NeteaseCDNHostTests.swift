import Testing
@testable import KumoneCore
import AVFoundation
import Foundation
import os

/// Serialized, and each test starts from `reset()`: the host table is
/// process-wide.
@Suite("NeteaseCDNHost", .serialized)
struct NeteaseCDNHostTests {

    private static let path = "/20260924/abcdef/obj/wo3DlMOGwrbDjj7DisKw/12345/6789/abcd/e1f2.mp3?vuutv=xyz"

    private func url(_ host: String, scheme: String = "https") -> URL {
        URL(string: "\(scheme)://\(host)\(Self.path)")!
    }

    private let dns = URLError(.cannotFindHost)

    init() {
        NeteaseCDNHost.reset()
    }

    @Test func swapsBetweenTwinHostsKeepingPathAndQuery() {
        #expect(NeteaseCDNHost.alternate(for: url("m801.music.126.net")) == url("m801c.music.126.net"))
        #expect(NeteaseCDNHost.alternate(for: url("m801c.music.126.net")) == url("m801.music.126.net"))
        #expect(NeteaseCDNHost.alternate(for: url("m7.music.126.net", scheme: "http"))
                == url("m7c.music.126.net", scheme: "http"))
    }

    @Test func leavesOtherHostsAlone() {
        for host in ["music.126.net", "p1.music.126.net", "m.music.126.net", "mc.music.126.net",
                     "m801x.music.126.net", "m801.music.163.com", "example.com"] {
            #expect(NeteaseCDNHost.alternate(for: url(host)) == nil, "\(host)")
        }
    }

    @Test func onlyConnectionFailuresCountAsUnreachable() {
        #expect(NeteaseCDNHost.isHostUnreachable(URLError(.cannotFindHost)))
        #expect(NeteaseCDNHost.isHostUnreachable(URLError(.dnsLookupFailed)))
        #expect(NeteaseCDNHost.isHostUnreachable(URLError(.cannotConnectToHost)))
        #expect(NeteaseCDNHost.isHostUnreachable(URLError(.timedOut)))
        // What a hijacking resolver produces.
        #expect(NeteaseCDNHost.isHostUnreachable(URLError(.serverCertificateUntrusted)))
        // What the URLSession delegate actually hands over: a bridged NSError.
        #expect(NeteaseCDNHost.isHostUnreachable(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)))
        // What AVPlayerItem.error looks like: AVFoundation -11800 over the
        // CFNetwork failure.
        let cfNetwork = NSError(domain: kCFErrorDomainCFNetwork as String, code: -1003)
        let wrapped = NSError(domain: AVFoundationErrorDomain, code: -11800,
                              userInfo: [NSUnderlyingErrorKey: cfNetwork])
        #expect(NeteaseCDNHost.isHostUnreachable(wrapped))
        // A getaddrinfo failure (kCFHostErrorUnknown).
        #expect(NeteaseCDNHost.isHostUnreachable(
            NSError(domain: kCFErrorDomainCFNetwork as String, code: 2)))
        // Several attempts, one of which is the DNS failure.
        let several = NSError(domain: NSURLErrorDomain, code: NSURLErrorUnknown, userInfo: [
            NSMultipleUnderlyingErrorsKey: [NSError(domain: NSPOSIXErrorDomain, code: 50),
                                            NSError(domain: NSURLErrorDomain, code: NSURLErrorDNSLookupFailed)],
        ])
        #expect(NeteaseCDNHost.isHostUnreachable(several))

        #expect(!NeteaseCDNHost.isHostUnreachable(NSError(domain: AVFoundationErrorDomain, code: -11800)))
        #expect(!NeteaseCDNHost.isHostUnreachable(URLError(.secureConnectionFailed)))
        #expect(!NeteaseCDNHost.isHostUnreachable(URLError(.networkConnectionLost)))
        #expect(!NeteaseCDNHost.isHostUnreachable(URLError(.cancelled)))
        #expect(!NeteaseCDNHost.isHostUnreachable(URLError(.badServerResponse)))
        #expect(!NeteaseCDNHost.isHostUnreachable(CocoaError(.fileNoSuchFile)))
    }

    @Test func failoverReturnsTheTwinOnlyForHostFailures() {
        let bad = url("m801.music.126.net")
        #expect(NeteaseCDNHost.failover(from: bad, after: URLError(.badServerResponse)) == nil)
        #expect(NeteaseCDNHost.preferred(for: bad) == bad)
        #expect(NeteaseCDNHost.failover(from: url("example.com"), after: dns) == nil)
        #expect(NeteaseCDNHost.failover(from: bad, after: dns) == url("m801c.music.126.net"))
    }

    @Test func prefersTwinWhileHostIsMarkedUnreachable() {
        let now: TimeInterval = 1000
        let bad = url("m801.music.126.net")
        #expect(NeteaseCDNHost.preferred(for: bad, now: now) == bad)
        _ = NeteaseCDNHost.failover(from: bad, after: dns, now: now)
        #expect(NeteaseCDNHost.preferred(for: bad, now: now) == url("m801c.music.126.net"))
        #expect(NeteaseCDNHost.preferred(for: bad, now: now + NeteaseCDNHost.unreachableTTL + 1) == bad)
    }

    @Test func answeringClearsTheMark() {
        let bad = url("m801.music.126.net")
        _ = NeteaseCDNHost.failover(from: bad, after: dns, now: 1000)
        NeteaseCDNHost.markReachable(bad, now: 1001)
        #expect(NeteaseCDNHost.preferred(for: bad, now: 1002) == bad)
    }

    /// The dead host failed, the twin worked for a while, then hiccuped once.
    /// Requests must stay on the twin, not go back to the dead host.
    @Test func bothMarkedPrefersTheOneThatAnsweredLast() {
        let dead = url("m801.music.126.net"), twin = url("m801c.music.126.net")
        #expect(NeteaseCDNHost.failover(from: dead, after: dns, now: 1000) == twin)
        NeteaseCDNHost.markReachable(twin, now: 1001)
        // The twin's own twin (the dead host) failed recently: no bounce back.
        #expect(NeteaseCDNHost.failover(from: twin, after: URLError(.timedOut), now: 1100) == nil)
        #expect(NeteaseCDNHost.preferred(for: dead, now: 1101) == twin)
        #expect(NeteaseCDNHost.preferred(for: twin, now: 1101) == twin)
    }

    @Test func bothMarkedWithNoHistoryStaysPut() {
        let host = url("m801.music.126.net"), twin = url("m801c.music.126.net")
        _ = NeteaseCDNHost.failover(from: host, after: dns, now: 1000)
        _ = NeteaseCDNHost.failover(from: twin, after: dns, now: 1000)
        #expect(NeteaseCDNHost.preferred(for: host, now: 1000) == host)
    }

    // MARK: - CachingAudioResourceLoader

    /// The iOS path end to end: AVFoundation asks the caching loader for
    /// byte ranges, the first host fails DNS, and the asset still loads, from
    /// the twin.
    @Test func cachingLoaderRetriesRangesOnTheTwin() async throws {
        let dead = URL(string: "https://m9301.music.126.net/x/song.caf")!
        CDNStub.configure(body: try Data(contentsOf: Fixtures.sixSecondCAF), deadHosts: [dead.host!])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CDNStub.self]
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NeteaseCDNHostTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let loader = try CachingAudioResourceLoader(
            remoteURL: dead, trackID: 9301, requestedQuality: "exhigh", servedQuality: "exhigh",
            source: .netease, maximumCacheSizeMB: 100,
            cache: AudioCache(cacheDirectory: directory), sessionConfiguration: configuration)
        defer { loader.cancel() }
        let asset = AVURLAsset(url: loader.assetURL)
        loader.attach(to: asset)

        let duration = try await asset.load(.duration)
        #expect(abs(duration.seconds - 6) < 0.1)
        let hosts = CDNStub.requestedHosts()
        #expect(hosts.first == "m9301.music.126.net")
        #expect(hosts.contains("m9301c.music.126.net"))
        #expect(NeteaseCDNHost.preferred(for: dead) == URL(string: "https://m9301c.music.126.net/x/song.caf")!)
    }
}

/// Serves `body` with byte ranges for every host except the dead ones, which
/// fail as an unresolvable name does.
final class CDNStub: URLProtocol {
    private struct State {
        var body = Data()
        var deadHosts: Set<String> = []
        var requestedHosts: [String] = []
    }
    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func configure(body: Data, deadHosts: Set<String>) {
        state.withLock { $0 = State(body: body, deadHosts: deadHosts) }
    }

    static func requestedHosts() -> [String] {
        state.withLock { $0.requestedHosts }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let host = url.host else { return }
        let (body, dead) = Self.state.withLock { state in
            state.requestedHosts.append(host)
            return (state.body, state.deadHosts.contains(host))
        }
        if dead {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        var lower = 0, upper = body.count - 1
        if let range = request.value(forHTTPHeaderField: "Range"),
           range.hasPrefix("bytes=") {
            let bounds = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            lower = Int(bounds[0]) ?? 0
            if bounds.count > 1, let end = Int(bounds[1]) { upper = min(end, body.count - 1) }
        }
        let slice = body.subdata(in: lower..<(upper + 1))
        let response = HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": "audio/x-caf",
            "Content-Length": "\(slice.count)",
            "Content-Range": "bytes \(lower)-\(upper)/\(body.count)",
            "Accept-Ranges": "bytes",
        ])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: slice)
        client?.urlProtocolDidFinishLoading(self)
    }
}
