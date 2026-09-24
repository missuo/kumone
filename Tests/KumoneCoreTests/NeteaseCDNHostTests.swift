import Testing
@testable import KumoneCore
import Foundation

@Suite("NeteaseCDNHost")
struct NeteaseCDNHostTests {

    private static let path = "/20260924/abcdef/obj/wo3DlMOGwrbDjj7DisKw/12345/6789/abcd/e1f2.mp3?vuutv=xyz"

    private func url(_ host: String, scheme: String = "https") -> URL {
        URL(string: "\(scheme)://\(host)\(Self.path)")!
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
        // What the URLSession delegate actually hands over: a bridged NSError.
        #expect(NeteaseCDNHost.isHostUnreachable(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)))
        #expect(!NeteaseCDNHost.isHostUnreachable(URLError(.cancelled)))
        #expect(!NeteaseCDNHost.isHostUnreachable(URLError(.badServerResponse)))
        #expect(!NeteaseCDNHost.isHostUnreachable(CocoaError(.fileNoSuchFile)))
    }

    // Distinct host numbers per test: the unreachable table is process-wide.

    @Test func prefersTwinWhileHostIsMarkedUnreachable() {
        let now = Date()
        let bad = url("m9101.music.126.net")
        #expect(NeteaseCDNHost.preferred(for: bad, now: now) == bad)
        NeteaseCDNHost.markUnreachable(bad, now: now)
        #expect(NeteaseCDNHost.preferred(for: bad, now: now) == url("m9101c.music.126.net"))
        #expect(NeteaseCDNHost.preferred(for: bad, now: now + NeteaseCDNHost.unreachableTTL + 1) == bad)
    }

    @Test func staysPutWhenBothTwinsFailed() {
        let now = Date()
        let host = url("m9102.music.126.net")
        NeteaseCDNHost.markUnreachable(host, now: now)
        NeteaseCDNHost.markUnreachable(url("m9102c.music.126.net"), now: now)
        #expect(NeteaseCDNHost.preferred(for: host, now: now) == host)
    }
}
