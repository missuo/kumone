import CryptoKit
import Foundation
import Testing

@testable import KumoneCore

// The in-app model download, tested without a network and without 330 MB of
// weights: a `URLProtocol` stub plays the role of GitHub, and the specs under
// test are throwaway ones whose digests the test computes itself. What is
// actually being checked is the part that has to be right — that a file which
// hashes wrong never becomes an installed model — plus the state machine the
// settings page renders.

private final class StemStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var payload = Data()
    nonisolated(unsafe) static var statusCode = 200
    /// Seconds to hold each response back, so a test can act while a
    /// download is still in flight. Zero answers immediately.
    nonisolated(unsafe) static var delay: TimeInterval = 0
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _requestCount = 0
    /// How many requests reached the "server" — i.e. real transfers started.
    static var requestCount: Int {
        get { lock.lock(); defer { lock.unlock() }; return _requestCount }
        set { lock.lock(); _requestCount = newValue; lock.unlock() }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self._requestCount += 1
        Self.lock.unlock()
        guard Self.delay > 0 else { return respond() }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.delay) { self.respond() }
    }

    private func respond() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.statusCode, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(Self.payload.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func stubSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StemStubProtocol.self]
    return URLSession(configuration: configuration)
}

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("stem-models-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// `67402202` -> `67_402_202`, the way the digits are written in Swift source.
private func underscored(_ value: Int64) -> String {
    let digits = Array(String(value))
    var out = ""
    for (index, digit) in digits.enumerated() {
        if index > 0 && (digits.count - index) % 3 == 0 { out.append("_") }
        out.append(digit)
    }
    return out
}

private func spec(named name: String, payload: Data) -> StemModelSpec {
    StemModelSpec(
        fileName: name, displayName: name, sha256: digest(payload),
        byteCount: Int64(payload.count))
}

/// Wait for a main-actor condition, rather than sleeping a fixed amount and
/// hoping. Returns false on timeout so the caller can fail with its own message.
///
/// The timeout is generous on purpose: other suites in this target hold the
/// main actor for ten-plus seconds at a stretch (the loudness and analyzer
/// tests), and a stub download that finishes in milliseconds can still wait a
/// long time for a turn. It is only ever paid on an actual failure.
@MainActor
private func eventually(
    timeout: Duration = .seconds(60), _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@Suite(.serialized)
struct StemModelSpecTests {

    @Test func downloadURLIsTheReleaseAssetOfTheSameName() {
        let base = StemModelSpec.releaseBase
        defer { StemModelSpec.releaseBase = base }

        StemModelSpec.releaseBase = URL(
            string: "https://github.com/XerWandeRer/kumone/releases/download/stem-models-v1")!
        #expect(
            StemModelSpec.vocals.downloadURL.absoluteString
                == "https://github.com/XerWandeRer/kumone/releases/download/stem-models-v1"
                + "/mel_roformer_vocals.safetensors")
        #expect(
            StemModelSpec.fourStem.downloadURL.absoluteString
                == "https://github.com/XerWandeRer/kumone/releases/download/stem-models-v1"
                + "/bs_roformer_4stem.safetensors")
    }

    @Test func oneBaseRetargetsBothModels() {
        let base = StemModelSpec.releaseBase
        defer { StemModelSpec.releaseBase = base }

        StemModelSpec.releaseBase = URL(string: "https://example.invalid/models")!
        for model in StemModelSpec.all {
            #expect(model.downloadURL.absoluteString
                == "https://example.invalid/models/" + model.fileName)
        }
    }

    @Test func sizeLabelsAreWhatTheReleasePageShows() {
        #expect(StemModelSpec.vocals.sizeLabel == "67 MB")
        #expect(StemModelSpec.fourStem.sizeLabel == "264 MB")
    }

    /// The manifest here is a hand-copy of StemKit's `ModelDescriptor`, because
    /// KumoneCore cannot import StemKit (MLX is macOS-only). A hand-copy that
    /// nothing checks is a hand-copy that drifts, so: check it.
    @Test func manifestMatchesStemKitsDescriptors() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // KumoneCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let source = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/StemKit/Weights/ModelStore.swift"), encoding: .utf8)

        for model in StemModelSpec.all {
            #expect(source.contains("\"\(model.fileName)\""), "file name \(model.fileName)")
            #expect(source.contains("\"\(model.sha256)\""), "digest of \(model.fileName)")
            #expect(
                source.contains(underscored(model.byteCount)),
                "byte count of \(model.fileName)")
        }
    }
}

@Suite(.serialized)
struct StemModelVerificationTests {

    @Test func aMatchingFilePasses() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let payload = Data((0..<4096).map { UInt8($0 % 251) })
        let file = directory.appendingPathComponent("good.bin")
        try payload.write(to: file)

        try StemModelDownloader.verify(file, against: spec(named: "good.bin", payload: payload))
    }

    @Test func aFileOfTheRightSizeButTheWrongBytesIsRejected() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let expected = Data(repeating: 0xAB, count: 4096)
        let actual = Data(repeating: 0xCD, count: 4096)
        let file = directory.appendingPathComponent("bad.bin")
        try actual.write(to: file)

        #expect(throws: StemModelError.digestMismatch) {
            try StemModelDownloader.verify(
                file, against: spec(named: "bad.bin", payload: expected))
        }
    }

    @Test func aTruncatedFileFailsOnSizeBeforeItIsEverHashed() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let expected = Data(repeating: 0xAB, count: 4096)
        let file = directory.appendingPathComponent("short.bin")
        try expected.prefix(1000).write(to: file)

        #expect(throws: StemModelError.self) {
            try StemModelDownloader.verify(
                file, against: spec(named: "short.bin", payload: expected))
        }
    }

    @Test func streamingDigestMatchesOneShotHashing() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Larger than the 1 MiB read chunk, so the incremental path is exercised.
        let payload = Data((0..<(3 << 20)).map { UInt8($0 % 256) })
        let file = directory.appendingPathComponent("big.bin")
        try payload.write(to: file)

        #expect(try StemModelDownloader.sha256(of: file) == digest(payload))
    }
}

@Suite(.serialized)
@MainActor
struct StemModelDownloaderStateTests {

    @Test func aGoodDownloadEndsInstalledAndOnDisk() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let payload = Data((0..<200_000).map { UInt8($0 % 253) })
        let model = spec(named: "model.safetensors", payload: payload)
        StemStubProtocol.payload = payload
        StemStubProtocol.statusCode = 200

        let downloader = StemModelDownloader(
            directory: directory, session: stubSession(), specs: [model])
        #expect(downloader.state(for: model) == .notInstalled)
        #expect(!downloader.anyInstalled)

        downloader.download(model)
        #expect(downloader.state(for: model).isBusy)

        let reached = await eventually { downloader.state(for: model) == .installed }
        #expect(reached, "state was \(downloader.state(for: model))")
        #expect(downloader.allInstalled)

        let installed = directory.appendingPathComponent(model.fileName)
        #expect(try Data(contentsOf: installed) == payload)
    }

    @Test func aCorruptedDownloadFailsAndInstallsNothing() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let payload = Data(repeating: 0x11, count: 50_000)
        let model = spec(named: "model.safetensors", payload: payload)
        // Same length, different bytes: passes the size check, fails the digest.
        StemStubProtocol.payload = Data(repeating: 0x22, count: 50_000)
        StemStubProtocol.statusCode = 200

        let downloader = StemModelDownloader(
            directory: directory, session: stubSession(), specs: [model])
        downloader.download(model)

        #expect(await eventually {
            if case .failed = downloader.state(for: model) { return true }
            return false
        })
        #expect(!downloader.anyInstalled)
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(model.fileName).path))
    }

    @Test func anHTTPErrorSurfacesAsAFailedRowThatCanBeRetried() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let payload = Data(repeating: 0x33, count: 20_000)
        let model = spec(named: "model.safetensors", payload: payload)
        StemStubProtocol.payload = Data("Not Found".utf8)
        StemStubProtocol.statusCode = 404

        let downloader = StemModelDownloader(
            directory: directory, session: stubSession(), specs: [model])
        downloader.download(model)
        #expect(await eventually {
            if case .failed = downloader.state(for: model) { return true }
            return false
        })

        // Retry, now that the "server" has the file.
        StemStubProtocol.payload = payload
        StemStubProtocol.statusCode = 200
        downloader.download(model)
        #expect(await eventually { downloader.state(for: model) == .installed })
    }

    @Test func cancellingReturnsTheRowToNotInstalled() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let payload = Data((0..<400_000).map { UInt8($0 % 249) })
        let model = spec(named: "model.safetensors", payload: payload)
        StemStubProtocol.payload = payload
        StemStubProtocol.statusCode = 200

        let downloader = StemModelDownloader(
            directory: directory, session: stubSession(), specs: [model])
        downloader.download(model)
        downloader.cancel(model)

        #expect(downloader.state(for: model) == .notInstalled)
        // And it stays that way — a cancelled transfer must not land later.
        try? await Task.sleep(for: .milliseconds(200))
        #expect(downloader.state(for: model) == .notInstalled)
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(model.fileName).path))
    }

    /// Cancel, then download again straight away. The cancelled task still
    /// runs to its `catch` afterwards; it must not unregister the new
    /// download (which would let a third one start onto the same file) nor
    /// publish its own `.notInstalled` over the new download's progress.
    @Test func aStaleCancelledTaskCannotClobberTheNextDownload() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let payload = Data((0..<300_000).map { UInt8($0 % 241) })
        let model = spec(named: "model.safetensors", payload: payload)
        StemStubProtocol.payload = payload
        StemStubProtocol.statusCode = 200
        StemStubProtocol.requestCount = 0
        StemStubProtocol.delay = 1.5
        defer { StemStubProtocol.delay = 0 }

        let downloader = StemModelDownloader(
            directory: directory, session: stubSession(), specs: [model])
        downloader.download(model)
        downloader.cancel(model)
        downloader.download(model)

        // The second download reaches the server; give the first, cancelled
        // task time to hit its catch and try to finish.
        #expect(await eventually { StemStubProtocol.requestCount >= 1 })
        try? await Task.sleep(for: .milliseconds(300))
        #expect(downloader.state(for: model).isBusy,
                "stale task overwrote the row: \(downloader.state(for: model))")

        // Still registered, so a third call is ignored rather than racing.
        downloader.download(model)
        #expect(await eventually { downloader.state(for: model) == .installed })
        #expect(StemStubProtocol.requestCount == 1)
        #expect(try Data(contentsOf: directory.appendingPathComponent(model.fileName)) == payload)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(leftovers == [model.fileName])
    }

    @Test func refreshReadsInstalledStateFromDisk() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let payload = Data(repeating: 0x44, count: 8192)
        let model = spec(named: "model.safetensors", payload: payload)

        let downloader = StemModelDownloader(
            directory: directory, session: stubSession(), specs: [model])
        #expect(downloader.state(for: model) == .notInstalled)

        try payload.write(to: directory.appendingPathComponent(model.fileName))
        downloader.refresh()
        #expect(downloader.state(for: model) == .installed)
    }

    @Test func aHalfWrittenFileIsNotInstalled() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let payload = Data(repeating: 0x55, count: 8192)
        let model = spec(named: "model.safetensors", payload: payload)
        try payload.prefix(100).write(to: directory.appendingPathComponent(model.fileName))

        let downloader = StemModelDownloader(
            directory: directory, session: stubSession(), specs: [model])
        #expect(!downloader.anyInstalled)
        if case .failed = downloader.state(for: model) {} else {
            Issue.record("a short file must not read as installed")
        }
    }

    /// The nastiest case: right size, wrong bytes, already sitting in the
    /// models directory. Cheap `refresh()` believes it; the deep check must
    /// not, and must clear it out so the row's button starts from zero.
    @Test func installedButWrongDigestIsDemotedAndDeleted() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let expected = Data(repeating: 0x66, count: 8192)
        let model = spec(named: "model.safetensors", payload: expected)
        let file = directory.appendingPathComponent(model.fileName)
        try Data(repeating: 0x77, count: 8192).write(to: file)

        let downloader = StemModelDownloader(
            directory: directory, session: stubSession(), specs: [model])
        #expect(downloader.state(for: model) == .installed)

        await downloader.verifyInstalled()

        if case .failed = downloader.state(for: model) {} else {
            Issue.record("a file that hashes wrong must not stay installed")
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))

        // And the retry works from there.
        StemStubProtocol.payload = expected
        StemStubProtocol.statusCode = 200
        downloader.download(model)
        #expect(await eventually { downloader.state(for: model) == .installed })
    }

    @Test func verifyingAGoodFileLeavesItInstalled() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let payload = Data(repeating: 0x88, count: 8192)
        let model = spec(named: "model.safetensors", payload: payload)
        try payload.write(to: directory.appendingPathComponent(model.fileName))

        let downloader = StemModelDownloader(
            directory: directory, session: stubSession(), specs: [model])
        await downloader.verifyInstalled()
        #expect(downloader.state(for: model) == .installed)
        #expect(downloader.allInstalled)
    }
}
