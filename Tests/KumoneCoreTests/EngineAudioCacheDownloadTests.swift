#if os(macOS)
import Foundation
import Testing
@testable import KumoneCore

/// A held transport makes consumer cancellation independent of HTTP timing.
private actor HeldAudioDownload {
    private var pending: [Int: CheckedContinuation<(URL, URLResponse), Error>] = [:]
    private(set) var requests = 0
    private(set) var cancelled = 0
    var ignoresCancellation = false

    func fetch(_ url: URL) async throws -> (URL, URLResponse) {
        try Task.checkCancellation()
        requests += 1
        let request = requests
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending[request] = $0 }
        } onCancel: {
            Task { await self.cancel(request) }
        }
    }

    private func cancel(_ request: Int) {
        cancelled += 1
        if !ignoresCancellation {
            pending.removeValue(forKey: request)?.resume(throwing: CancellationError())
        }
    }

    func ignoreCancellation() { ignoresCancellation = true }

    func finish(_ request: Int, status: Int = 200, contents: Data = Data([1, 2, 3, 4])) throws -> URL {
        let held = pending.removeValue(forKey: request)
        let continuation = try #require(held)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try contents.write(to: url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: status,
                                                  httpVersion: nil, headerFields: nil))
        continuation.resume(returning: (url, response))
        return url
    }
}

struct EngineAudioCacheDownloadTests {
    private let key = EngineAudioCache.Key(trackID: 1, level: "standard", source: Upstream.tag, fileExtension: "flac")
    private let remote = URL(fileURLWithPath: "/held-audio")

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(await condition())
    }

    @Test(arguments: [false, true])
    func cancellingOneConsumerKeepsTheOtherPlaying(cancelPlayback: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = HeldAudioDownload()
        let cache = EngineAudioCache(directory: directory, limitBytes: 0, fetch: { try await transport.fetch($0) })
        let prefetch = Task { try await cache.download(from: remote, key: key) }
        try await waitUntil { await cache.downloadConsumerCount(for: key) == 1 }
        let playback = Task { try await cache.waitForDownload(for: key) }
        try await waitUntil { await cache.downloadConsumerCount(for: key) == 2 }
        if cancelPlayback { playback.cancel() } else { prefetch.cancel() }
        if cancelPlayback {
            await #expect(throws: CancellationError.self) { try await playback.value }
        } else {
            await #expect(throws: CancellationError.self) { try await prefetch.value }
        }
        #expect(await cache.downloadConsumerCount(for: key) == 1)
        #expect(await transport.cancelled == 0)
        try await waitUntil { await transport.requests == 1 }
        _ = try await transport.finish(1)
        let file: URL
        if cancelPlayback { file = try await prefetch.value }
        else { file = try #require(await playback.value) }
        #expect(try Data(contentsOf: file) == Data([1, 2, 3, 4]))
        #expect(await transport.requests == 1)
        #expect(await cache.downloadConsumerCount(for: key) == 0)
    }

    @Test func lastConsumerCancellationStopsTheTransferAndAllowsRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = HeldAudioDownload()
        let cache = EngineAudioCache(directory: directory, limitBytes: 0, fetch: { try await transport.fetch($0) })
        let first = Task { try await cache.download(from: remote, key: key) }
        try await waitUntil { await transport.requests == 1 }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        try await waitUntil { await transport.cancelled == 1 }
        #expect(await cache.cachedFileURL(for: key) == nil)
        #expect(await cache.downloadConsumerCount(for: key) == 0)
        let retry = Task { try await cache.download(from: remote, key: key) }
        try await waitUntil { await transport.requests == 2 }
        _ = try await transport.finish(2)
        let file = try await retry.value
        #expect(try Data(contentsOf: file) == Data([1, 2, 3, 4]))
    }

    @Test(arguments: [false, true])
    func lateCancelledTransferCannotReplaceANewerTransfer(finishReplacementFirst: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = HeldAudioDownload()
        await transport.ignoreCancellation()
        let cache = EngineAudioCache(directory: directory, limitBytes: 0, fetch: { try await transport.fetch($0) })
        let first = Task { try await cache.download(from: remote, key: key) }
        try await waitUntil { await transport.requests == 1 }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        let retry = Task { try await cache.download(from: remote, key: key) }
        try await waitUntil { await transport.requests == 2 }
        if finishReplacementFirst {
            _ = try await transport.finish(2)
            _ = try await retry.value
        }
        let oldTemporaryFile = try await transport.finish(1, contents: Data([9, 8, 7]))
        try await waitUntil { !FileManager.default.fileExists(atPath: oldTemporaryFile.path) }
        if !finishReplacementFirst {
            #expect(await cache.downloadConsumerCount(for: key) == 1)
            #expect(await cache.cachedFileURL(for: key) == nil)
            _ = try await transport.finish(2)
        }
        let file = try await retry.value
        #expect(try Data(contentsOf: file) == Data([1, 2, 3, 4]))
        #expect(await cache.cachedFileURL(for: key) == file)
        #expect(await cache.downloadConsumerCount(for: key) == 0)
    }

    @Test func cancellationBeforeStartingIssuesNoRequest() async throws {
        let transport = HeldAudioDownload()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = EngineAudioCache(directory: directory, limitBytes: 0, fetch: { try await transport.fetch($0) })
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await cache.download(from: remote, key: key)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await transport.requests == 0)
        #expect(await cache.downloadConsumerCount(for: key) == 0)
        #expect(try await cache.waitForDownload(for: key) == nil)
    }

    @Test func failedResponseRemovesTemporaryFileAndWakesConsumers() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = HeldAudioDownload()
        let cache = EngineAudioCache(directory: directory, limitBytes: 0, fetch: { try await transport.fetch($0) })
        let task = Task { try await cache.download(from: remote, key: key) }
        try await waitUntil { await transport.requests == 1 }
        let temporary = try await transport.finish(1, status: 500)
        await #expect(throws: URLError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
        #expect(await cache.cachedFileURL(for: key) == nil)
        #expect(await cache.downloadConsumerCount(for: key) == 0)
    }

    @Test func joiningAfterCompletionReusesTheFinishedFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = HeldAudioDownload()
        let cache = EngineAudioCache(directory: directory, limitBytes: 0, fetch: { try await transport.fetch($0) })
        let prefetch = Task { try await cache.download(from: remote, key: key) }
        try await waitUntil { await transport.requests == 1 }
        _ = try await transport.finish(1)
        let completed = try await prefetch.value
        #expect(await cache.downloadConsumerCount(for: key) == 0)
        #expect(try await cache.waitForDownload(for: key) == completed)
        #expect(await transport.requests == 1)
    }
}
#endif
