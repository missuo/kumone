import Foundation

/// The process's one separator, loaded on demand and kept warm.
///
/// Two callers need exactly this — the `audition` console and the app's
/// AutoMix pre-render — and both want the same three things: load the 64 MiB
/// checkpoint at most once, call the `async` separator from a synchronous pull
/// loop, and ask "could this machine separate at all?" without triggering a
/// download or a Metal failure.
public final class ResidentStemSeparator: @unchecked Sendable {

    public static let shared = ResidentStemSeparator()

    private let lock = NSLock()
    private var separator: StemSeparator?

    private init() {}

    /// Is separation actually possible here, right now, with no downloads and
    /// nothing that can fail fatally?
    ///
    /// Deliberately conservative, and deliberately *not* `prepare()`:
    /// - the checkpoint must already be on disk. `prepare` would fetch it, and
    ///   a music player must not start a 64 MiB download because a song is
    ///   coming to an end;
    /// - MLX loads its Metal kernels from a `mlx.metallib` that Command Line
    ///   Tools builds cannot produce (`Scripts/fetch-mlx-metallib.sh`), and
    ///   missing it is not a Swift error but a hard failure inside MLX. So the
    ///   file is looked for before MLX is ever touched.
    ///
    /// False simply means the caller keeps doing what it did before stems
    /// existed.
    public static func isRunnable(modelStore: ModelStore = ModelStore(),
                                  descriptor: ModelDescriptor = .zfturboVocalsV1) -> Bool {
        FileManager.default.fileExists(atPath: modelStore.localURL(for: descriptor).path)
            && metallibURL() != nil
    }

    /// Where MLX will find its kernels, if it can: beside the running binary
    /// (what `fetch-mlx-metallib.sh` installs), inside the app bundle, or in a
    /// resource bundle SwiftPM built with Xcode.
    public static func metallibURL() -> URL? {
        var candidates: [URL] = []
        if let executable = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(executable.appendingPathComponent("mlx.metallib"))
        }
        for bundle in Bundle.allBundles + Bundle.allFrameworks {
            if let url = bundle.url(forResource: "mlx", withExtension: "metallib") {
                candidates.append(url)
            }
        }
        // An Xcode-built SwiftPM package ships it inside its own resource
        // bundle, which is not loaded and so not in `allBundles`.
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("mlx.metallib"))
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: resources, includingPropertiesForKeys: nil)) ?? []
            for bundle in contents where bundle.pathExtension == "bundle" {
                candidates.append(bundle.appendingPathComponent("mlx.metallib"))
                candidates.append(bundle.appendingPathComponent("Contents/Resources/mlx.metallib"))
            }
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Separate one window, blocking until it is done. Never call this on the
    /// main thread: it is seconds of Metal work.
    public func vocals(samples: [[Float]], sampleRate: Double) throws -> [[Float]] {
        let separator = try resident()
        return try runBlocking {
            try await separator.separate(samples: samples, sampleRate: sampleRate)
        }.vocals
    }

    public func resident() throws -> StemSeparator {
        lock.lock()
        let existing = separator
        lock.unlock()
        if let existing { return existing }

        let prepared = try runBlocking { try await StemSeparator.prepare() }
        lock.lock()
        // Two callers racing here is harmless — the loser's copy is dropped.
        if let existing = separator {
            lock.unlock()
            return existing
        }
        separator = prepared
        lock.unlock()
        return prepared
    }

    /// `async` model, synchronous callers. Bridging here rather than making the
    /// renderers async keeps the offline graph exactly the shape the live
    /// engine's is.
    private func runBlocking<T: Sendable>(
        _ body: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var outcome: Result<T, Error>?
        Task.detached(priority: .userInitiated) {
            do { outcome = .success(try await body()) } catch { outcome = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        switch outcome! {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }
}
