import AVFoundation
import Foundation
import Testing
@testable import KumoneCore

private final class NetworkAudioProtocol: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var failures: [Int: URLError.Code] = [:]
        private var alwaysFail = false
        private var requests: [URLRequest] = []
        private var fallbackCount = 0

        func configure(_ data: Data, failures: [Int: URLError.Code], alwaysFail: Bool = false) {
            lock.lock(); defer { lock.unlock() }
            self.data = data; self.failures = failures; self.alwaysFail = alwaysFail
            requests = []; fallbackCount = 0
        }
        func response(to request: URLRequest) -> (Data, URLError.Code?) {
            lock.lock(); defer { lock.unlock() }
            requests.append(request)
            return (data, alwaysFail ? .notConnectedToInternet : failures[requests.count])
        }
        func fallback() { lock.lock(); fallbackCount += 1; lock.unlock() }
        func snapshot() -> (requests: [URLRequest], fallbacks: Int) {
            lock.lock(); defer { lock.unlock() }
            return (requests, fallbackCount)
        }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let (data, error) = Self.state.response(to: request)
        if let error { client?.urlProtocol(self, didFailWithError: URLError(error)); return }
        let bounds = request.value(forHTTPHeaderField: "Range")!.dropFirst(6).split(separator: "-").compactMap { Int($0) }
        let body = data.subdata(in: bounds[0]..<(bounds[1] + 1))
        let response = HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: nil, headerFields: [
            "Content-Type": request.url!.pathExtension == "flac" ? "audio/flac" : "audio/mpeg",
            "Content-Length": "\(body.count)", "Content-Range": "bytes \(bounds[0])-\(bounds[1])/\(data.count)",
            "ETag": "\"fixture\"",
        ])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite("Playback network recovery", .serialized, .timeLimit(.minutes(1)))
struct PlaybackNetworkRecoveryTests {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NetworkAudioProtocol.self]
        return URLSession(configuration: config)
    }

    @Test func failedWifiCompletionCanContinueThroughPlayback() async throws {
        let fixture = try OfflineAudioFixture(), store = fixture.store(), session = session()
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: store.directory) }
        NetworkAudioProtocol.state.configure(fixture.data, failures: [1: .dataNotAllowed])
        let transfer = AudioTransferCoordinator(resource: fixture.resource(url: URL(string: "https://fixture.test/audio.mp3")!), store: store, session: session)
        await #expect(throws: (any Error).self) { try await transfer.download(forCompletion: true) }
        #expect(NetworkAudioProtocol.state.snapshot().requests.first?.allowsCellularAccess == false)
        let prefix = try await transfer.read(at: 0, maximum: 1024)
        #expect(prefix == fixture.data.prefix(1024))
        try await transfer.download()
        #expect(try await store.record(id: fixture.descriptor.identity.id)?.state == .complete)
        #expect(NetworkAudioProtocol.state.snapshot().requests.last?.allowsCellularAccess == true)
        #expect(await transfer.receivedByteCount == fixture.descriptor.byteCount)
        await transfer.close()
    }

    @Test func playbackLoaderRecoversWithoutDiscardingItsAssetOrCachedBytes() async throws {
        let fixture = try OfflineAudioFixture(.flac), store = fixture.store(), session = session()
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: store.directory) }
        NetworkAudioProtocol.state.configure(fixture.data, failures: [2: .networkConnectionLost])
        let transfer = AudioTransferCoordinator(resource: fixture.resource(url: URL(string: "https://fixture.test/audio.flac")!), store: store, session: session)
        // Keep a received tail range, then lose the connection while reading the prefix.
        _ = try await transfer.read(at: fixture.descriptor.byteCount - 1000, maximum: 1000)
        let loader = CachingAssetResourceLoader(transfer: transfer, onFailure: { NetworkAudioProtocol.state.fallback() })
        let audioTrack = try #require(try await loader.asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: loader.asset)
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        reader.add(output)
        #expect(reader.startReading())
        var samples = 0
        while output.copyNextSampleBuffer() != nil { samples += 1 }
        #expect(samples > 0 && reader.status == .completed)
        #expect(NetworkAudioProtocol.state.snapshot().requests.count >= 3)
        #expect(NetworkAudioProtocol.state.snapshot().fallbacks == 0)
        try await transfer.download()
        #expect(await transfer.receivedByteCount == fixture.descriptor.byteCount)
        await loader.close()
    }

    @Test func leavingTheSongCancelsPendingNetworkRetries() async throws {
        let fixture = try OfflineAudioFixture(), store = fixture.store(), session = session()
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: store.directory) }
        NetworkAudioProtocol.state.configure(fixture.data, failures: [:], alwaysFail: true)
        let transfer = AudioTransferCoordinator(resource: fixture.resource(url: URL(string: "https://fixture.test/audio.mp3")!), store: store, session: session)
        let loader = CachingAssetResourceLoader(transfer: transfer, onFailure: { NetworkAudioProtocol.state.fallback() })
        let loading = Task { try await loader.asset.load(.isPlayable) }
        for _ in 0..<200 where NetworkAudioProtocol.state.snapshot().requests.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!NetworkAudioProtocol.state.snapshot().requests.isEmpty)
        await loader.close()
        _ = await loading.result
        let count = NetworkAudioProtocol.state.snapshot().requests.count
        try await Task.sleep(for: .milliseconds(1100))
        #expect(NetworkAudioProtocol.state.snapshot().requests.count == count)
        #expect(NetworkAudioProtocol.state.snapshot().fallbacks == 0)
    }
}
