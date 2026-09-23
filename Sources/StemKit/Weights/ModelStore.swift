import CryptoKit
import Foundation

/// Errors raised while acquiring or validating the separation model.
public enum ModelStoreError: Error, CustomStringConvertible, Sendable {
    case downloadFailed(String)
    case digestMismatch(expected: String, actual: String)
    case sizeMismatch(expected: Int, actual: Int)
    case metalLibraryMissing(searched: [String])
    case conversionRequired(fileName: String, recipe: String, upstream: URL)

    public var description: String {
        switch self {
        case .downloadFailed(let detail):
            return "Model download failed: \(detail)"
        case .digestMismatch(let expected, let actual):
            return """
                Model SHA-256 mismatch — refusing to use the file.
                  expected \(expected)
                  actual   \(actual)
                """
        case .sizeMismatch(let expected, let actual):
            return "Model size mismatch: expected \(expected) B, got \(actual) B"
        case .conversionRequired(let fileName, let recipe, let upstream):
            return """
                \(fileName) is not in the models directory, and it is not something
                Kumone can fetch for you: upstream ships a PyTorch checkpoint, and
                converting one needs torch. Run

                    \(recipe)

                which downloads \(upstream.lastPathComponent) from
                \(upstream.host ?? "its original host"), checks it against a hardcoded
                SHA-256, converts it, and checks the result too.
                """
        case .metalLibraryMissing(let searched):
            return """
                mlx.metallib not found. MLX needs a precompiled Metal library, which SwiftPM
                can only build when Xcode's `metal` compiler is installed. On a Command Line
                Tools-only machine, fetch the prebuilt one that matches the pinned mlx-swift:

                    Scripts/fetch-mlx-metallib.sh <dir-containing-the-executable>

                Searched:
                \(searched.map { "  - " + $0 }.joined(separator: "\n"))
                """
        }
    }
}

/// Describes one downloadable checkpoint: where it comes from and what it must hash to.
///
/// Kumone never redistributes weights. The binary carries only this manifest — an
/// upstream URL plus a hardcoded digest — and pulls the file from the original host on
/// first use, so no third-party weights enter Kumone's own LGPL-3.0-only distribution.
public struct ModelDescriptor: Sendable {

    /// **How the bytes on disk come to be there.**
    ///
    /// Two answers, and the second one exists because of a fact about the
    /// world rather than a design preference: StemKit reads safetensors
    /// through MLX, and *every* published four-stem RoFormer checkpoint is a
    /// PyTorch pickle. There is no four-stem safetensors conversion on Hugging
    /// Face for a URL to point at, and publishing one ourselves would be
    /// redistributing weights — the one thing this whole manifest exists to
    /// avoid.
    public enum Acquisition: Sendable {
        /// Stream ``ModelDescriptor/url`` and verify it. The shipping path.
        case download
        /// The upstream file needs a conversion StemKit cannot perform (a
        /// PyTorch `.ckpt`, whose packed QKV projections have to be split and
        /// whose fp32 storage has to be halved). `ModelStore` will not fetch
        /// it; `Scripts/fetch-4stem-checkpoint.sh` does that, on the user's
        /// machine, with their own torch, and the manifest pins the digests of
        /// *both* ends so neither the download nor the conversion can drift
        /// unnoticed.
        case convertedLocally(sourceSHA256: String, sourceByteCount: Int, recipe: String)
    }

    /// Filename used on disk inside the models directory.
    public let fileName: String
    /// Upstream URL — of the file itself under ``Acquisition/download``, of the
    /// checkpoint it is converted from otherwise.
    public let url: URL
    /// Expected SHA-256 of the file on disk, hex-encoded lowercase. Hardcoded —
    /// never fetched from a server.
    public let sha256: String
    /// Expected size in bytes of the file on disk.
    public let byteCount: Int
    /// Model configuration this checkpoint was trained with.
    public let configuration: RoFormerConfiguration
    public let acquisition: Acquisition

    public init(
        fileName: String,
        url: URL,
        sha256: String,
        byteCount: Int,
        configuration: RoFormerConfiguration,
        acquisition: Acquisition = .download
    ) {
        self.fileName = fileName
        self.url = url
        self.sha256 = sha256
        self.byteCount = byteCount
        self.configuration = configuration
        self.acquisition = acquisition
    }

    /// **Where Kumone itself fetches this file from.**
    ///
    /// ``url`` is the provenance record — the original host, or the checkpoint a
    /// conversion started from — and it stays that, unchanged, for the scripts
    /// and the docs. But two of the three ways a machine can end up without
    /// weights (no torch for the conversion; a Hugging Face that is slow or
    /// blocked where the user lives) are not things a music player can ask its
    /// user to solve, so the app pulls both files, already converted, from one
    /// GitHub release: ``ModelStore/releaseBase`` + ``fileName``.
    ///
    /// The digest is the same digest either way. Nothing about this weakens the
    /// check that matters: the release is a delivery route, not a source of
    /// truth, and a file from it that hashes wrong is refused exactly like one
    /// from anywhere else.
    public var releaseURL: URL {
        ModelStore.releaseBase.appendingPathComponent(fileName)
    }

    /// Mel-Band RoFormer, ZFTurbo vocals v1 — the MIT-licensed 64 MiB checkpoint.
    ///
    /// Source: `mlx-community/mel-roformer-zfturbo-vocals-v1-mlx` on Hugging Face, an MLX
    /// conversion of `model_vocals_mel_band_roformer_sdr_8.42.ckpt` from
    /// ZFTurbo/Music-Source-Separation-Training v1.0.0. fp16 safetensors, single file.
    public static let zfturboVocalsV1 = ModelDescriptor(
        fileName: "mel_roformer_vocals.safetensors",
        url: URL(
            string: "https://huggingface.co/mlx-community/mel-roformer-zfturbo-vocals-v1-mlx"
                + "/resolve/main/model.safetensors"
        )!,
        sha256: "ef4aa052845a868cfaff93611477bd8f54d8081bc32f2742a9b3c738f0821191",
        byteCount: 67_402_202,
        configuration: .zfturboVocalsV1
    )

    /// **BS-RoFormer four-stem, ZFTurbo v1.0.12 — drums / bass / other / vocals.**
    ///
    /// Source: `model_bs_roformer_ep_17_sdr_9.6568.ckpt` from
    /// ZFTurbo/Music-Source-Separation-Training v1.0.12, **MIT** (the
    /// repository's own licence, in force since 2024-11-04, well before this
    /// release). 527,385,512 bytes of fp32 PyTorch pickle, SHA-256
    /// `3e9daecd…`; `Scripts/convert-roformer-checkpoint.py` turns it into the
    /// 263,558,304-byte fp16 safetensors this descriptor names, deterministically
    /// — same input, same script, same digest.
    ///
    /// Not auto-downloaded, and the reason is in ``Acquisition``. A machine
    /// without the converted file simply has no four-stem separator, which is a
    /// supported state everywhere downstream: the two-stem vocals model keeps
    /// working and every four-lane gesture degrades to its two-lane form.
    public static let bsRoformerFourStem = ModelDescriptor(
        fileName: "bs_roformer_4stem.safetensors",
        url: URL(
            string: "https://github.com/ZFTurbo/Music-Source-Separation-Training"
                + "/releases/download/v1.0.12/model_bs_roformer_ep_17_sdr_9.6568.ckpt"
        )!,
        sha256: "bc21feafc525b7431d9ad1006c4030b6ea953d0af05b0b5da4ba961eb41da141",
        byteCount: 263_558_304,
        configuration: .bsRoformerFourStem,
        acquisition: .convertedLocally(
            sourceSHA256: "3e9daecd70aaed5b5a0d1f861cc4d77eaa45afb3fc6301b1cf32c1be0f5868fb",
            sourceByteCount: 527_385_512,
            recipe: "Scripts/fetch-4stem-checkpoint.sh")
    )
}

/// Resolves model files on disk, downloading them from upstream on first use.
public struct ModelStore: Sendable {

    /// Default location: `~/Library/Application Support/Kumone/Models/`.
    ///
    /// Application Support rather than Caches — the system must not be free to evict a
    /// 64 MB download the user explicitly opted into.
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("Kumone/Models", isDirectory: true)
    }

    /// Base of the release both checkpoints are published under, converted.
    ///
    /// One knob, deliberately: every descriptor's ``ModelDescriptor/releaseURL``
    /// is this plus the file name, so a fork, a mirror, or a test stub retargets
    /// both models at once and no descriptor carries a second URL to keep in
    /// sync. Assign it before anything downloads (tests do; the app does not).
    public nonisolated(unsafe) static var releaseBase = URL(
        string: "https://github.com/XerWandeRer/kumone/releases/download/stem-models-v1")!

    /// Directory the store reads and writes.
    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory
    }

    /// Local path the descriptor's file occupies (whether or not it exists yet).
    public func localURL(for descriptor: ModelDescriptor) -> URL {
        directory.appendingPathComponent(descriptor.fileName)
    }

    /// Return a verified local copy of the model, downloading it if absent.
    ///
    /// A file that is present but fails verification is deleted and re-downloaded once —
    /// a truncated or corrupted download should heal itself rather than wedge the feature.
    ///
    /// - Parameter progress: Called with a 0...1 fraction during download (best effort).
    public func ensureAvailable(
        _ descriptor: ModelDescriptor = .zfturboVocalsV1,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let destination = localURL(for: descriptor)

        if FileManager.default.fileExists(atPath: destination.path) {
            if (try? Self.verify(destination, against: descriptor)) != nil {
                return destination
            }
            try? FileManager.default.removeItem(at: destination)
        }

        if case .convertedLocally(_, _, let recipe) = descriptor.acquisition {
            throw ModelStoreError.conversionRequired(
                fileName: descriptor.fileName, recipe: recipe, upstream: descriptor.url)
        }

        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        let temporary = try await download(descriptor, from: descriptor.url, progress: progress)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Self.verify(temporary, against: descriptor)

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    // MARK: - Private

    private func download(
        _ descriptor: ModelDescriptor,
        from url: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ModelStoreError.downloadFailed("HTTP \(http.statusCode) from \(url)")
        }

        let expected = response.expectedContentLength > 0
            ? Double(response.expectedContentLength)
            : Double(descriptor.byteCount)

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("kumone-model-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var written = 0
        var lastReported = 0.0

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= (1 << 20) {
                try handle.write(contentsOf: buffer)
                written += buffer.count
                buffer.removeAll(keepingCapacity: true)
                let fraction = min(1.0, Double(written) / max(expected, 1))
                if fraction - lastReported >= 0.01 {
                    lastReported = fraction
                    progress?(fraction)
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }
        progress?(1.0)
        return temporary
    }

    /// Verify a file against its descriptor's size and digest.
    public static func verify(_ url: URL, against descriptor: ModelDescriptor) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? Int) ?? -1
        guard size == descriptor.byteCount else {
            throw ModelStoreError.sizeMismatch(expected: descriptor.byteCount, actual: size)
        }

        let digest = try sha256(of: url)
        guard digest == descriptor.sha256 else {
            throw ModelStoreError.digestMismatch(expected: descriptor.sha256, actual: digest)
        }
    }

    /// Streaming SHA-256 so a 64 MB file never has to be resident twice.
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
