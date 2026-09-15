import AVFoundation
import Foundation
import Testing
@testable import KumoneCore

@Suite("Offline audio transfer", .timeLimit(.minutes(1)))
struct OfflineAudioTransferTests {
    @Test(arguments: OfflineAudioFormat.allCases)
    func downloadsRealAudioAndReusesBytes(_ format: OfflineAudioFormat) async throws {
        let fixture = try OfflineAudioFixture(format), store = fixture.store()
        let server = try await AudioFixtureServer(fixture: fixture)
        defer { server.stop(); try? FileManager.default.removeItem(at: store.directory) }
        let source = AudioTransferCoordinator(resource: fixture.resource(url: server.url), store: store)
        // Seek to the tail first, then complete the file. Already received tail
        // bytes must not be transferred again while filling the prefix.
        let tail = fixture.data.count - 1_000
        let data = try await source.read(at: Int64(tail), maximum: 1_000)
        #expect(data == fixture.data.suffix(1_000))
        try await source.download()
        #expect(await source.receivedByteCount == Int64(fixture.data.count))
        #expect(try await store.record(id: fixture.descriptor.identity.id)?.state == .complete)
        let before = server.ranges.count
        _ = try await source.read(at: 0, maximum: 1_000)
        #expect(server.ranges.count == before)
        await source.close()
    }

    @Test func sequentialResponseStartsBeforeDownloadCompletes() async throws {
        let fixture = try OfflineAudioFixture(.flac), store = fixture.store()
        let server = try await AudioFixtureServer(fixture: fixture, mode: .sequential, delay: 0.02)
        defer { server.stop(); try? FileManager.default.removeItem(at: store.directory) }
        let source = AudioTransferCoordinator(resource: fixture.resource(url: server.url), store: store)
        let first = try await source.read(at: 0, maximum: 1_024)
        #expect(first == fixture.data.prefix(1_024))
        #expect(await source.receivedByteCount < fixture.descriptor.byteCount)
        try await source.download()
        #expect(server.ranges.count == 1)
        await source.close()
    }

    @Test func concurrentConsumersShareOneRequest() async throws {
        let fixture = try OfflineAudioFixture(.flac), store = fixture.store()
        let server = try await AudioFixtureServer(fixture: fixture, delay: 0.01)
        defer { server.stop(); try? FileManager.default.removeItem(at: store.directory) }
        let source = AudioTransferCoordinator(resource: fixture.resource(url: server.url), store: store)
        async let first = source.read(at: 0, maximum: 8_192)
        async let second = source.read(at: 0, maximum: 8_192)
        let (firstData, secondData) = try await (first, second)
        #expect(firstData == secondData)
        #expect(server.ranges.count == 1)
        await source.close()
    }

    @Test func redirectsKeepStableIdentity() async throws {
        let fixture = try OfflineAudioFixture(), store = fixture.store()
        let server = try await AudioFixtureServer(fixture: fixture, mode: .redirect)
        defer { server.stop(); try? FileManager.default.removeItem(at: store.directory) }
        let source = AudioTransferCoordinator(resource: fixture.resource(url: server.url), store: store)
        try await source.download()
        #expect(try await store.record(id: fixture.descriptor.identity.id)?.state == .complete)
        await source.close()
    }

    @Test func interruptedResponseCannotPublishACompleteFile() async throws {
        let fixture = try OfflineAudioFixture(), store = fixture.store()
        let server = try await AudioFixtureServer(fixture: fixture, mode: .truncated)
        defer { server.stop(); try? FileManager.default.removeItem(at: store.directory) }
        let source = AudioTransferCoordinator(resource: fixture.resource(url: server.url), store: store)
        await #expect(throws: (any Error).self) { try await source.download() }
        #expect(try await store.record(id: fixture.descriptor.identity.id)?.state != .complete)
        await source.close()
    }

    @Test func changedETagRejectsContinuation() async throws {
        let fixture = try OfflineAudioFixture(.flac), store = fixture.store()
        let server = try await AudioFixtureServer(fixture: fixture, mode: .changedETag)
        defer { server.stop(); try? FileManager.default.removeItem(at: store.directory) }
        let source = AudioTransferCoordinator(resource: fixture.resource(url: server.url), store: store)
        _ = try await source.read(at: fixture.descriptor.byteCount - 100, maximum: 100)
        await #expect(throws: OfflineAudioError.changedResource) { try await source.download() }
        #expect(try await store.record(id: fixture.descriptor.identity.id)?.state != .complete)
        await source.close()
    }

    @Test func rejectsHTMLAndIncorrectRange() throws {
        let fixture = try OfflineAudioFixture()
        let url = URL(string: "https://example.test/audio")!
        let html = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!
        #expect(throws: OfflineAudioError.invalidResponse) {
            try AudioHTTPResponse(response: html, requested: 0..<100, descriptor: fixture.descriptor, previousETag: nil)
        }
        let wrong = HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil,
                                    headerFields: ["Content-Type": "audio/mpeg", "Content-Range": "bytes 1-100/\(fixture.data.count)"])!
        #expect(throws: OfflineAudioError.invalidResponse) {
            try AudioHTTPResponse(response: wrong, requested: 0..<100, descriptor: fixture.descriptor, previousETag: nil)
        }
    }

    @Test func newCoordinatorResumesAStoppedTransferWithoutRepeatingBytes() async throws {
        let fixture = try OfflineAudioFixture(.flac), store = fixture.store()
        let server = try await AudioFixtureServer(fixture: fixture, delay: 0.01)
        defer { server.stop(); try? FileManager.default.removeItem(at: store.directory) }
        let resource = fixture.resource(url: server.url)
        let first = AudioTransferCoordinator(resource: resource, store: store)
        _ = try await first.read(at: 0, maximum: 1_024)
        await first.close()
        let saved = try #require(try await store.record(id: fixture.descriptor.identity.id)).ranges.byteCount
        #expect(saved > 0 && saved < fixture.descriptor.byteCount)
        let resumed = AudioTransferCoordinator(resource: resource, store: store)
        try await resumed.download()
        #expect(await resumed.receivedByteCount == fixture.descriptor.byteCount - saved)
        await resumed.close()
    }
}

@Suite("AVFoundation caching compatibility", .serialized, .timeLimit(.minutes(1)))
struct OfflineAVFoundationTests {
    @Test(arguments: OfflineAudioFormat.allCases)
    func assetLoadsAndDecodesAfterSeek(_ format: OfflineAudioFormat) async throws {
        let fixture = try OfflineAudioFixture(format), store = fixture.store()
        let server = try await AudioFixtureServer(fixture: fixture)
        defer { server.stop(); try? FileManager.default.removeItem(at: store.directory) }
        let source = AudioTransferCoordinator(resource: fixture.resource(url: server.url), store: store)
        let loader = CachingAssetResourceLoader(transfer: source)
        let tracks = try await loader.asset.loadTracks(withMediaType: .audio)
        let track = try #require(tracks.first)
        let duration = try await loader.asset.load(.duration).seconds
        #expect(abs(duration - 3) < 0.2)
        let reader = try AVAssetReader(asset: loader.asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: 1.5, preferredTimescale: 44_100),
                                       duration: CMTime(seconds: 0.2, preferredTimescale: 44_100))
        #expect(reader.startReading())
        #expect(output.copyNextSampleBuffer() != nil)
        reader.cancelReading()
        try await source.download()
        await loader.close()
    }

    @Test @MainActor func resourceLoaderSupportsSpectrumTapAndPlayerSeek() async throws {
        let fixture = try OfflineAudioFixture(.m4a), store = fixture.store()
        let server = try await AudioFixtureServer(fixture: fixture)
        defer { server.stop(); try? FileManager.default.removeItem(at: store.directory) }
        let source = AudioTransferCoordinator(resource: fixture.resource(url: server.url), store: store)
        let loader = CachingAssetResourceLoader(transfer: source)
        let track = try #require(try await loader.asset.loadTracks(withMediaType: .audio).first)
        AudioSpectrum.shared.beginPreparing()
        let mix = try #require(AudioSpectrum.shared.makeAudioMix(for: track))
        let item = AVPlayerItem(asset: loader.asset)
        item.audioMix = mix
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.play()
        for _ in 0..<100 where !AudioSpectrum.shared.isLive { try await Task.sleep(for: .milliseconds(50)) }
        #expect(AudioSpectrum.shared.isLive)
        let sought = await player.seek(to: CMTime(seconds: 1, preferredTimescale: 44_100), toleranceBefore: .zero, toleranceAfter: .zero)
        #expect(sought)
        player.pause()
        player.replaceCurrentItem(with: nil)
        AudioSpectrum.shared.markIdle()
        await loader.close()
    }
}
