import Foundation
import Testing

@testable import StemKit

// Where the app fetches weights from, now that both checkpoints are published
// as assets of one GitHub release. Nothing here downloads anything — the only
// interesting claims are that the URL is derived from a single base plus the
// file name, and that the digest check still refuses a file that hashes wrong,
// which is the whole reason a delivery route is allowed to change at all.

@Suite(.serialized)
struct ModelReleaseTests {

    @Test func releaseURLIsTheBasePlusTheFileName() {
        let base = ModelStore.releaseBase
        defer { ModelStore.releaseBase = base }

        ModelStore.releaseBase = URL(
            string: "https://github.com/XerWandeRer/kumone/releases/download/stem-models-v1")!
        #expect(
            ModelDescriptor.zfturboVocalsV1.releaseURL.absoluteString
                == "https://github.com/XerWandeRer/kumone/releases/download/stem-models-v1"
                + "/mel_roformer_vocals.safetensors")
        #expect(
            ModelDescriptor.bsRoformerFourStem.releaseURL.absoluteString
                == "https://github.com/XerWandeRer/kumone/releases/download/stem-models-v1"
                + "/bs_roformer_4stem.safetensors")
    }

    /// The four-stem model has no downloadable safetensors upstream — that is
    /// the entire point of `Acquisition.convertedLocally` — so its release URL
    /// must not be derived from `url`.
    @Test func theFourStemReleaseURLIsNotItsUpstreamCheckpoint() {
        let descriptor = ModelDescriptor.bsRoformerFourStem
        #expect(descriptor.releaseURL != descriptor.url)
        #expect(descriptor.url.lastPathComponent.hasSuffix(".ckpt"))
        #expect(descriptor.releaseURL.lastPathComponent == descriptor.fileName)
    }

    @Test func retargetingTheBaseMovesBothModelsAtOnce() {
        let base = ModelStore.releaseBase
        defer { ModelStore.releaseBase = base }

        ModelStore.releaseBase = URL(string: "https://example.invalid/mirror")!
        for descriptor in [ModelDescriptor.zfturboVocalsV1, .bsRoformerFourStem] {
            #expect(descriptor.releaseURL.absoluteString
                == "https://example.invalid/mirror/" + descriptor.fileName)
        }
    }

    @Test func theDefaultBaseIsTheStemModelsV1Release() {
        #expect(
            ModelStore.releaseBase.absoluteString
                == "https://github.com/XerWandeRer/kumone/releases/download/stem-models-v1")
    }

    @Test func verifyAcceptsAFileThatMatchesItsDescriptor() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stemkit-release-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let payload = Data((0..<8192).map { UInt8($0 % 241) })
        let file = directory.appendingPathComponent("fake.safetensors")
        try payload.write(to: file)

        let descriptor = ModelDescriptor(
            fileName: "fake.safetensors",
            url: URL(string: "https://example.invalid/fake.safetensors")!,
            sha256: try ModelStore.sha256(of: file),
            byteCount: payload.count,
            configuration: .zfturboVocalsV1)

        try ModelStore.verify(file, against: descriptor)
    }

    @Test func verifyRefusesAFileOfTheRightSizeWithTheWrongBytes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stemkit-release-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("fake.safetensors")
        try Data(repeating: 0x5A, count: 8192).write(to: file)

        let descriptor = ModelDescriptor(
            fileName: "fake.safetensors",
            url: URL(string: "https://example.invalid/fake.safetensors")!,
            sha256: String(repeating: "0", count: 64),
            byteCount: 8192,
            configuration: .zfturboVocalsV1)

        #expect(throws: ModelStoreError.self) {
            try ModelStore.verify(file, against: descriptor)
        }
    }

    /// A file already sitting in the models directory that hashes wrong is not
    /// quietly used: `ensureAvailable` deletes it and tries again — which, with
    /// an unreachable host, must surface as a failure rather than as a
    /// silently kept bad file.
    @Test func aBadInstalledFileIsRemovedRatherThanUsed() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stemkit-release-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let descriptor = ModelDescriptor(
            fileName: "fake.safetensors",
            url: URL(string: "https://127.0.0.1:1/fake.safetensors")!,
            sha256: String(repeating: "0", count: 64),
            byteCount: 8192,
            configuration: .zfturboVocalsV1)
        let installed = directory.appendingPathComponent(descriptor.fileName)
        try Data(repeating: 0x5A, count: 8192).write(to: installed)

        let store = ModelStore(directory: directory)
        await #expect(throws: (any Error).self) {
            _ = try await store.ensureAvailable(descriptor)
        }
        #expect(!FileManager.default.fileExists(atPath: installed.path))
    }
}
