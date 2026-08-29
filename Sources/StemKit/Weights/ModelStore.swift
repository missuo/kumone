import CryptoKit
import Foundation

/// Errors raised while acquiring or validating the separation model.
public enum ModelStoreError: Error, CustomStringConvertible, Sendable {
    case downloadFailed(String)
    case digestMismatch(expected: String, actual: String)
    case sizeMismatch(expected: Int, actual: Int)
    case metalLibraryMissing(searched: [String])

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
    /// Filename used on disk inside the models directory.
    public let fileName: String
    /// Upstream download URL.
    public let url: URL
    /// Expected SHA-256, hex-encoded lowercase. Hardcoded — never fetched from a server.
    public let sha256: String
    /// Expected size in bytes.
    public let byteCount: Int
    /// Model configuration this checkpoint was trained with.
    public let configuration: RoFormerConfiguration

    public init(
        fileName: String,
        url: URL,
        sha256: String,
        byteCount: Int,
        configuration: RoFormerConfiguration
    ) {
        self.fileName = fileName
        self.url = url
        self.sha256 = sha256
        self.byteCount = byteCount
        self.configuration = configuration
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

        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        let temporary = try await download(descriptor, progress: progress)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Self.verify(temporary, against: descriptor)

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    // MARK: - Private

    private func download(
        _ descriptor: ModelDescriptor,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        let (bytes, response) = try await URLSession.shared.bytes(from: descriptor.url)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ModelStoreError.downloadFailed("HTTP \(http.statusCode) from \(descriptor.url)")
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
