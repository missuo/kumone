import CryptoKit
import Foundation
import ImageIO
import Testing
@testable import KumoneCore

private final class ThumbnailFailureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

@Suite("Image thumbnails")
struct ImageThumbnailTests {
    private let cover = "https://example.test/large-cover.jpg"

    @Test func resizingReplacesAnExistingSizeAndPreservesOtherParameters() throws {
        let url = try #require("http://example.test/cover.jpg?param=2048y2048&version=2".resizedImageURL(96))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.queryItems?.filter { $0.name == "param" }.map(\.value) == ["96y96"])
        #expect(components.queryItems?.first { $0.name == "version" }?.value == "2")
    }

    @Test(arguments: [false, true])
    func originalArtworkIsDecodedAtTheRequestedSize(fromDisk: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try largeCover()
        let url = try #require(cover.resizedImageURL(96))
        if fromDisk { try seed(data, url: url, root: root) }
        let cache = ImageCache(directory: root, offlineArtwork: { _ in data })

        let image = try #require(await cache.image(for: url))
        let pixels = try cgImage(image)
        #expect(pixels.width == 96 && pixels.height == 48)
        #expect(pixels.bytesPerRow * pixels.height <= 96 * 48 * 8)
        #expect(try cgImage(#require(cache.cachedImage(for: url))).width == 96)

        // A row thumbnail must not replace the larger detail rendition.
        let detailURL = try #require(cover.resizedImageURL(768))
        let detail = try #require(await cache.image(for: detailURL))
        #expect(try cgImage(detail).width == 768)
        #expect(try cgImage(#require(cache.cachedImage(for: url))).width == 96)
    }

    @Test(arguments: [false, true])
    func largerFallbackIsBoundedWithoutBeingCachedAsAnExactAnswer(warmMemory: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let largeURL = try #require(cover.resizedImageURL(768))
        try seed(largeCover(), url: largeURL, root: root)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ThumbnailFailureProtocol.self]
        let cache = ImageCache(directory: root, session: URLSession(configuration: config), offlineArtwork: { _ in nil })
        if warmMemory { _ = await cache.image(for: largeURL) }
        let smallURL = try #require(cover.resizedImageURL(96))
        let image = try #require(await cache.image(for: smallURL, onCachedImage: { preview in
            #expect(preview.size.width == 96 && preview.size.height == 48)
        }))
        #expect(try cgImage(image).width == 96)
        #expect(cache.cachedImage(for: smallURL) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 1)
    }

    @Test func smallOriginalIsNotUpscaled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try largeCover(width: 32, height: 16)
        let cache = ImageCache(directory: root, offlineArtwork: { _ in data })
        let url = try #require(cover.resizedImageURL(96))
        let image = try #require(await cache.image(for: url))
        #expect(try cgImage(image).width == 32)
    }

    private func largeCover(width: Int = 2_048, height: Int = 1_024) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func seed(_ data: Data, url: URL, root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let key = Insecure.MD5.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        try data.write(to: root.appendingPathComponent(key))
    }

    private func cgImage(_ image: PlatformImage) throws -> CGImage {
        #if os(macOS)
        return try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #else
        return try #require(image.cgImage)
        #endif
    }
}
