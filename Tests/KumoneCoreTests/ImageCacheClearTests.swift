import Foundation
import Testing
@testable import KumoneCore

private final class DeferredImageProtocol: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: DeferredImageProtocol?
        func set(_ value: DeferredImageProtocol?) { lock.lock(); pending = value; lock.unlock() }
        func get() -> DeferredImageProtocol? { lock.lock(); defer { lock.unlock() }; return pending }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.state.set(self) }
    override func stopLoading() {}
    func finish(_ data: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
        Self.state.set(nil)
    }
}

@Suite("Image cache clearing", .serialized)
struct ImageCacheClearTests {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a5XkAAAAASUVORK5CYII=")!

    private func pendingRequest() async throws -> DeferredImageProtocol {
        for _ in 0..<200 where DeferredImageProtocol.state.get() == nil { try await Task.sleep(for: .milliseconds(5)) }
        return try #require(DeferredImageProtocol.state.get())
    }

    @Test func lateRequestDoesNotRepopulateClearedDiskOrMemory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-image-clear-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DeferredImageProtocol.self]
        let cache = ImageCache(directory: root, session: URLSession(configuration: config), offlineArtwork: { _ in nil })
        let url = URL(string: "https://example.test/image.png")!
        let first = Task { await cache.image(for: url) }
        let pending = try await pendingRequest()
        try await cache.clear()
        pending.finish(png)
        #expect(await first.value != nil)
        #expect(cache.cachedImage(for: url) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)

        let second = Task { await cache.image(for: url) }
        try await pendingRequest().finish(png)
        #expect(await second.value != nil)
        #expect(cache.cachedImage(for: url) != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 1)
    }

    @Test func offlineArtworkSurvivesClearingOrdinaryImages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kumone-protected-art-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = OfflineMetadataStore(directory: root.appendingPathComponent("offline"))
        let url = URL(string: "https://example.test/cover.png")!
        try await metadata.saveArtwork(png, url: url, scope: "a")
        let cache = ImageCache(directory: root.appendingPathComponent("images"), offlineArtwork: { url in
            await metadata.artwork(url: url, scope: "a")
        })
        #expect(await cache.image(for: url) != nil)
        try await cache.clear()
        #expect(cache.cachedImage(for: url) == nil)
        #expect(await metadata.artwork(url: url, scope: "a") == png)
        #expect(await cache.image(for: url) != nil)
    }
}
