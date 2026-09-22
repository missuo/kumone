import AppKit
import CryptoKit
import Foundation
import Testing
@testable import KumoneCore

private final class ArtworkProtocol: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var data: Data?
        private var urls: [URL] = []

        func reset(data: Data? = nil) {
            lock.lock(); defer { lock.unlock() }
            self.data = data
            urls = []
        }

        func response(for url: URL) -> Data? {
            lock.lock(); defer { lock.unlock() }
            urls.append(url)
            return data
        }

        func requests() -> [URL] {
            lock.lock(); defer { lock.unlock() }
            return urls
        }
    }

    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let data = Self.state.response(for: request.url!) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Offline artwork", .serialized)
struct OfflineArtworkTests {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a5XkAAAAASUVORK5CYII=")!
    private let cover = "https://example.test/noir.jpg"

    private func cache(at root: URL) -> ImageCache {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ArtworkProtocol.self]
        return ImageCache(directory: root, session: URLSession(configuration: config), offlineArtwork: { _ in nil })
    }

    // Write the existing URL-hashed disk format directly: these tests must work
    // with caches populated before the fix, without a new online playback.
    private func seed(_ url: URL, at root: URL, data: Data? = nil) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let key = Insecure.MD5.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        try (data ?? png).write(to: root.appendingPathComponent(key))
    }

    @Test(arguments: [96, 128, 160, 512, 1024])
    func coldOfflineDetailUsesPreviouslyCachedSize(size: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-art-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        ArtworkProtocol.state.reset()
        try seed(cover.resizedImageURL(size)!, at: root)
        let cache = cache(at: root)
        let detailURL = cover.resizedImageURL(768)!

        #expect(await cache.image(for: detailURL) != nil)
        #expect(cache.cachedImage(for: detailURL) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 1)
    }

    @Test func fallbackDoesNotCrossArtworkOrOtherQueryParameters() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-art-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        ArtworkProtocol.state.reset()
        try seed(cover.resizedImageURL(160)!, at: root)
        let cache = cache(at: root)

        #expect(await cache.image(for: "https://example.test/kafu.jpg".resizedImageURL(768)!) == nil)
        #expect(await cache.image(for: (cover + "?version=2").resizedImageURL(768)!) == nil)
    }

    @Test func fallbackPreservesOtherQueryParameters() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-art-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        ArtworkProtocol.state.reset()
        let versioned = cover + "?version=2"
        try seed(versioned.resizedImageURL(160)!, at: root)

        #expect(await cache(at: root).image(for: versioned.resizedImageURL(768)!) != nil)
    }

    @Test func reconnectStillFetchesRequestedResolution() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-art-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        ArtworkProtocol.state.reset()
        try seed(cover.resizedImageURL(160)!, at: root)
        let cache = cache(at: root)
        let detailURL = cover.resizedImageURL(768)!
        #expect(await cache.image(for: detailURL) != nil)

        ArtworkProtocol.state.reset(data: png)
        #expect(await cache.image(for: detailURL) != nil)
        #expect(ArtworkProtocol.state.requests() == [detailURL])
        #expect(cache.cachedImage(for: detailURL) != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 2)
    }

    @Test func clearingRemovesSizeFallbacks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-art-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        ArtworkProtocol.state.reset()
        try seed(cover.resizedImageURL(160)!, at: root)
        let cache = cache(at: root)
        let detailURL = cover.resizedImageURL(768)!
        #expect(await cache.image(for: detailURL) != nil)
        try await cache.clear()

        #expect(await cache.image(for: detailURL) == nil)
    }

    @Test func corruptLargerVariantDoesNotHideValidThumbnail() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-art-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        ArtworkProtocol.state.reset()
        try seed(cover.resizedImageURL(1024)!, at: root, data: Data("broken image".utf8))
        try seed(cover.resizedImageURL(160)!, at: root)

        #expect(await cache(at: root).image(for: cover.resizedImageURL(768)!) != nil)
    }

    @Test @MainActor func reusedViewNeverShowsPreviousSongsPixels() {
        let noir = cover.resizedImageURL(128)!
        let kafu = "https://example.test/kafu.jpg".resizedImageURL(128)!
        let oldImage = NSImage(size: NSSize(width: 2, height: 2))
        var state = CachedImageState(url: kafu, image: oldImage)

        // The URL can change before SwiftUI runs its replacement .task.
        #expect(state.image(for: noir) == nil)
        state = CachedImageState(url: noir)
        state.finish(nil, for: noir)
        #expect(state.image(for: noir) == nil)
        state.finish(oldImage, for: kafu)
        #expect(state.image(for: noir) == nil)
        #expect(state.image(for: nil) == nil)

        let newImage = NSImage(size: NSSize(width: 3, height: 3))
        state.finish(newImage, for: noir)
        state.finish(oldImage, for: kafu)
        #expect(state.image(for: noir) === newImage)
    }
}
