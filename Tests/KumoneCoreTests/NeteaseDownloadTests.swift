import CryptoKit
import Foundation
import Network
import Testing
@testable import KumoneCore

@Suite("NetEase download eligibility")
struct NeteaseDownloadTests {
    private struct ProbeFailure: Error, CustomStringConvertible {
        let domain: String
        let code: Int
        var description: String { "Live audio probe failed (\(domain), \(code)); URL and credentials omitted" }
    }
    @Test func separatesFullDownloadsFromTrialsAndDeniedResources() throws {
        let track = try JSONDecoder().decode(Track.self, from: Data("""
        {"id":1,"name":"Fixture","dt":180000}
        """.utf8))
        func response(code: Int = 200, trial: Bool = false, time: Int = 180_000) throws -> SongURLData {
            try JSONDecoder().decode(SongURLData.self, from: Data("""
            {"id":1,"url":"http://example.test/audio.mp3?expires=old","size":100,"type":"MP3","level":"exhigh",
            "md5":"0123456789abcdef0123456789abcdef","time":\(time),"code":\(code),
            "freeTrialInfo":\(trial ? "{\"start\":0,\"end\":30}" : "null")}
            """.utf8))
        }
        let full = try NeteaseAPI.downloadResource(data: response(), track: track, accountScope: "test")
        #expect(full.url.scheme == "https")
        #expect(throws: OfflineAudioError.unavailable) {
            try NeteaseAPI.downloadResource(data: response(trial: true), track: track, accountScope: "test")
        }
        #expect(throws: OfflineAudioError.unavailable) {
            try NeteaseAPI.downloadResource(data: response(code: 403), track: track, accountScope: "test")
        }
        #expect(throws: OfflineAudioError.invalidAudio) {
            try NeteaseAPI.downloadResource(data: response(time: 30_000), track: track, accountScope: "test")
        }
    }

    @Test func aSongWithoutItsOwnDurationTakesTheResponseTime() throws {
        // Cloud drive and simplified entries can omit dt.
        let track = try JSONDecoder().decode(Track.self, from: Data("""
        {"id":1,"name":"Fixture"}
        """.utf8))
        func response(time: Int) throws -> SongURLData {
            try JSONDecoder().decode(SongURLData.self, from: Data("""
            {"id":1,"url":"https://example.test/audio.mp3","size":100,"type":"mp3","level":"exhigh",
            "md5":"0123456789abcdef0123456789abcdef","time":\(time),"code":200,"freeTrialInfo":null}
            """.utf8))
        }
        let resource = try NeteaseAPI.downloadResource(data: response(time: 180_000), track: track, accountScope: "test")
        #expect(resource.descriptor.duration == 180)
        #expect(throws: OfflineAudioError.unavailable) {
            try NeteaseAPI.downloadResource(data: response(time: 0), track: track, accountScope: "test")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["KUMONE_LIVE_AUDIO_PROBE"] == "1"), .timeLimit(.minutes(3)))
    func liveDownloadProbe() async throws {
        let encryptedDNS = ProcessInfo.processInfo.environment["KUMONE_PROBE_ENCRYPTED_DNS"] == "1"
        if encryptedDNS {
            // A probe-only, process-scoped resolver for networks whose DNS
            // cannot resolve the CDN. This does not change system DNS settings.
            let resolver = try #require(URL(string: "https://cloudflare-dns.com/dns-query"))
            NWParameters.PrivacyContext.default.requireEncryptedNameResolution(true, fallbackResolver: .https(
                resolver, serverAddresses: [.hostPort(host: "1.1.1.1", port: 443)]))
        }
        defer {
            if encryptedDNS { NWParameters.PrivacyContext.default.requireEncryptedNameResolution(false, fallbackResolver: nil) }
        }
        let trackID = Int(ProcessInfo.processInfo.environment["KUMONE_PROBE_TRACK_ID"] ?? "347230") ?? 347230
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-live-probe-\(UUID())")
        let originalCookieFile = ProcessInfo.processInfo.environment["KUMONE_PROBE_COOKIE_FILE"].map { URL(fileURLWithPath: $0) }
        let originalFingerprint = try originalCookieFile.map { SHA256.hash(data: try Data(contentsOf: $0)) }
        defer {
            do {
                if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
                let temporaryFilesRemoved = !FileManager.default.fileExists(atPath: root.path)
                #expect(temporaryFilesRemoved)
                if let originalCookieFile, let originalFingerprint {
                    // Compare privately: assertion diagnostics must never contain
                    // the cookie bytes or their fingerprint.
                    let originalUnchanged = try SHA256.hash(data: Data(contentsOf: originalCookieFile)) == originalFingerprint
                    #expect(originalUnchanged)
                    print("Offline probe cleanup: temporaryFilesRemoved=\(temporaryFilesRemoved) originalLoginUnchanged=\(originalUnchanged)")
                }
            } catch { Issue.record(error, "Failed to verify probe cleanup") }
        }
        let cookieDirectory = root.appendingPathComponent("cookies")
        try FileManager.default.createDirectory(at: cookieDirectory, withIntermediateDirectories: true)
        if let originalCookieFile {
            try FileManager.default.copyItem(at: originalCookieFile, to: cookieDirectory.appendingPathComponent("cookies.json"))
        }
        let client = NeteaseClient(cookieDirectory: cookieDirectory)
        do {
            let body = try await client.weapi("/v3/song/detail", ["c": "[{\"id\":\(trackID)}]"])
            let details = try client.decoded(NeteaseAPI.SongDetailResponse.self, from: body)
            let track = try #require(details.songs.first)
            let data = try await NeteaseAPI.songDownloadURL(id: track.id, level: "exhigh", client: client)
            print("Download eligibility: authenticated=\(client.isLoggedIn) id=\(data.id) code=\(data.code.map(String.init) ?? "missing") url=\(data.url != nil) trial=\(data.freeTrialInfo != nil) format=\(data.type ?? "missing") quality=\(data.level ?? "missing") checksum=\(data.md5 != nil) bytes=\(data.size)")
            if data.code != 200 || data.url == nil {
                #expect(throws: OfflineAudioError.unavailable) {
                    try NeteaseAPI.downloadResource(data: data, track: track, accountScope: "probe")
                }
                print("Offline probe: download denied; full CDN transfer was not exercised")
                return
            }
            let resource = try NeteaseAPI.downloadResource(data: data, track: track, accountScope: "probe")
            let store = OfflineStore(directory: root.appendingPathComponent("offline"), minimumFreeBytes: 0)
            let (file, _) = try await URLSession.shared.download(from: resource.url)
            try await store.importDownload(at: file, descriptor: resource.descriptor)
            let record = try #require(try await store.record(id: resource.descriptor.identity.id))
            #expect(record.state == .complete)
            print("Offline probe: track=\(trackID) format=\(resource.descriptor.identity.format.rawValue) quality=\(resource.descriptor.identity.quality) bytes=\(resource.descriptor.byteCount) duration=\(resource.descriptor.duration) complete=\(record.state == .complete)")
        } catch {
            let error = error as NSError
            // URLSession errors include signed media URLs in userInfo. Keep
            // them out of Swift Testing's automatic error diagnostics.
            throw ProbeFailure(domain: error.domain, code: error.code)
        }
    }
}
