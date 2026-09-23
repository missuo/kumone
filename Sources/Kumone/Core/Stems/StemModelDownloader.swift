#if os(macOS)
import Foundation
import CryptoKit

// Getting the separation weights onto the machine, from inside the app.
//
// Until now the two checkpoints arrived by shell script — one of them needing a
// Python torch install to convert a PyTorch pickle — which is a fine story for
// a developer and no story at all for a user who just turned on 增强过渡. So
// both files, already converted, live as assets of one GitHub release, and this
// is the thing that fetches, verifies and installs them.
//
// KumoneCore does not depend on StemKit (see `StemSeparation`: MLX is macOS-only
// and this module is the shared playback core), so the manifest below is a
// deliberate *mirror* of `ModelDescriptor` in Sources/StemKit/Weights/ModelStore.swift
// — same file names, same sizes, same digests, same install directory. A test
// reads that file and fails if the two ever drift apart.

/// One downloadable checkpoint, described without needing StemKit.
struct StemModelSpec: Identifiable, Sendable, Equatable {

    /// Base of the GitHub release both checkpoints are published under.
    /// Mirrors `ModelStore.releaseBase`. Overridable so tests never touch the network.
    nonisolated(unsafe) static var releaseBase = URL(
        string: "https://github.com/XerWandeRer/kumone/releases/download/stem-models-v1")!

    /// File name on disk, and the release asset's name — the two are the same
    /// on purpose, so the URL is derivable rather than stored twice.
    let fileName: String
    /// Shown in settings.
    let displayName: String
    /// Expected SHA-256 of the installed file, hex, lowercase. Hardcoded, never fetched.
    let sha256: String
    /// Expected size in bytes of the installed file.
    let byteCount: Int64

    var id: String { fileName }

    var downloadURL: URL { Self.releaseBase.appendingPathComponent(fileName) }

    /// "67 MB" / "264 MB" — decimal MB, matching what GitHub shows for the asset.
    var sizeLabel: String {
        "\(Int((Double(byteCount) / 1_000_000).rounded())) MB"
    }

    /// Mel-Band RoFormer vocals v1. The one every stem gesture needs.
    static let vocals = StemModelSpec(
        fileName: "mel_roformer_vocals.safetensors",
        displayName: String(localized: "两轨模型（人声）"),
        sha256: "ef4aa052845a868cfaff93611477bd8f54d8081bc32f2742a9b3c738f0821191",
        byteCount: 67_402_202)

    /// BS-RoFormer four-stem. Optional: without it four-lane gestures play
    /// their two-lane form, which is a supported state everywhere downstream.
    static let fourStem = StemModelSpec(
        fileName: "bs_roformer_4stem.safetensors",
        displayName: String(localized: "四轨模型（人声 / 鼓 / 贝斯 / 其他）"),
        sha256: "bc21feafc525b7431d9ad1006c4030b6ea953d0af05b0b5da4ba961eb41da141",
        byteCount: 263_558_304)

    static let all: [StemModelSpec] = [.vocals, .fourStem]

    /// `~/Library/Application Support/Kumone/Models/` — the directory
    /// `ModelStore` reads. Application Support, not Caches: the system must not
    /// be free to evict a download the user explicitly asked for.
    static var modelsDirectory: URL { KumoneDirectories.applicationSupport("Models") }
}

/// Where one model stands, as far as the settings page is concerned.
enum StemModelState: Equatable, Sendable {
    case notInstalled
    /// 0...1, best-effort: the delegate coalesces byte-count callbacks.
    case downloading(progress: Double)
    /// Hashing 264 MB takes a moment and the UI should say so rather than
    /// look frozen between "100%" and "已安装".
    case verifying
    case installed
    case failed(String)

    var isInstalled: Bool { self == .installed }

    var isBusy: Bool {
        switch self {
        case .downloading, .verifying: return true
        case .notInstalled, .installed, .failed: return false
        }
    }
}

enum StemModelError: LocalizedError, Equatable {
    case http(Int)
    case sizeMismatch(expected: Int64, actual: Int64)
    case digestMismatch

    var errorDescription: String? {
        switch self {
        case .http(let code):
            return String(localized: "下载失败（HTTP \(code)）")
        case .sizeMismatch(let expected, let actual):
            return String(localized: "文件大小不符：应为 \(expected) 字节，实际 \(actual) 字节")
        case .digestMismatch:
            return String(localized: "校验未通过，文件可能已损坏")
        }
    }
}

/// Downloads, verifies and installs the stem checkpoints.
///
/// One shared instance so the settings page and anything gating on
/// ``anyInstalled`` see the same states without being wired together.
@MainActor
public final class StemModelDownloader: ObservableObject {

    public static let shared = StemModelDownloader()

    /// Keyed by ``StemModelSpec/id`` (the file name). Absent means `.notInstalled`.
    @Published private(set) var states: [String: StemModelState] = [:]

    let directory: URL
    /// Runs on the main actor after a model lands on disk verified. The
    /// launcher points this at `StemSetup.install()` so a separator is wired
    /// in the same session — without it, a freshly downloaded model would be
    /// usable only after a relaunch.
    public var onInstalled: (@MainActor () -> Void)?
    /// The models this instance manages — the two real ones in the app; a
    /// single throwaway spec in tests, which is the only reason it is a
    /// property and not `StemModelSpec.all` spelled out everywhere.
    let specs: [StemModelSpec]
    private let session: URLSession
    private var tasks: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    /// Files already hashed this session. Re-hashing 264 MB every time the
    /// settings page appears would be a second of disk for no new information.
    private var verified: Set<String> = []

    init(directory: URL = StemModelSpec.modelsDirectory,
         session: URLSession = .shared,
         specs: [StemModelSpec] = StemModelSpec.all) {
        self.directory = directory
        self.session = session
        self.specs = specs
        refresh()
    }

    // MARK: - Reading

    func state(for spec: StemModelSpec) -> StemModelState {
        states[spec.id] ?? .notInstalled
    }

    func localURL(for spec: StemModelSpec) -> URL {
        directory.appendingPathComponent(spec.fileName)
    }

    /// The two-stem model is on disk — i.e. stem transitions can run at all.
    var vocalsInstalled: Bool { state(for: .vocals).isInstalled }

    /// Any checkpoint at all. What the 增强过渡 toggle should gate on: the
    /// four-stem model is a bonus, not a requirement.
    var anyInstalled: Bool { specs.contains { state(for: $0).isInstalled } }

    var allInstalled: Bool { specs.allSatisfy { state(for: $0).isInstalled } }

    // MARK: - Refreshing

    /// Re-read disk. Cheap: existence and size only, so it is safe to call on
    /// every `.task`. A file of the right size is *assumed* good until
    /// ``verifyInstalled()`` says otherwise.
    func refresh() {
        for spec in specs where !state(for: spec).isBusy {
            states[spec.id] = diskState(for: spec)
        }
    }

    private func diskState(for spec: StemModelSpec) -> StemModelState {
        let url = localURL(for: spec)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? Int64
        else { return .notInstalled }
        guard size == spec.byteCount else {
            // Half a download, or a file from another release. Not installed,
            // and saying so out loud beats a mysterious runtime failure later.
            return .failed(String(localized: "文件不完整，请重新下载"))
        }
        return .installed
    }

    /// Hash what is on disk and demote anything that does not match its
    /// manifest — the "installed but wrong SHA" case, which otherwise surfaces
    /// as an incomprehensible MLX crash mid-transition. The bad file is deleted
    /// so the retry button starts from nothing.
    func verifyInstalled(force: Bool = false) async {
        let pending = specs.filter {
            state(for: $0).isInstalled && (force || !verified.contains($0.id))
        }
        guard !pending.isEmpty else { return }

        // Both checkpoints hash at once: 264 MB and 67 MB in sequence is a
        // second of wall clock the settings page would spend looking idle.
        let results = await withTaskGroup(of: (String, Bool).self) { group in
            for spec in pending {
                let url = localURL(for: spec)
                let id = spec.id
                let expected = spec.sha256
                group.addTask(priority: .utility) {
                    (id, (try? Self.sha256(of: url)) == expected)
                }
            }
            var found: [String: Bool] = [:]
            for await (id, ok) in group { found[id] = ok }
            return found
        }

        for spec in pending {
            guard let ok = results[spec.id], state(for: spec).isInstalled else { continue }
            if ok {
                verified.insert(spec.id)
                continue
            }
            verified.remove(spec.id)
            try? FileManager.default.removeItem(at: localURL(for: spec))
            states[spec.id] = .failed(String(localized: "校验未通过，请重新下载"))
        }
    }

    // MARK: - Downloading

    /// Start (or restart) one model's download. A second call while it runs is
    /// ignored rather than racing a duplicate task onto the same destination.
    ///
    /// Every download owns its slot through a fresh token. A cancelled task
    /// keeps running until it notices the cancellation, and by then the user
    /// may already have started a new one; everything the old task does to
    /// shared state — progress, `.verifying`, the final move onto the
    /// destination, clearing the slot — first checks it still holds the
    /// token, so a stale task can neither unregister its successor (which
    /// would let a third download start) nor overwrite what it publishes.
    func download(_ spec: StemModelSpec) {
        guard tasks[spec.id] == nil else { return }
        states[spec.id] = .downloading(progress: 0)

        let token = UUID()
        let destination = localURL(for: spec)
        let directory = self.directory
        let session = self.session
        // Beside the destination, so the final install is a same-volume
        // rename done on the main actor, where ownership can be checked
        // atomically. Unique per download, so two tasks never share it.
        let staged = directory.appendingPathComponent(
            ".\(spec.fileName).\(token.uuidString).partial")

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let temporary = try await StemModelFetcher.download(
                    from: spec.downloadURL,
                    expectedBytes: spec.byteCount,
                    session: session
                ) { received, total in
                    Task { @MainActor in
                        self.report(spec, token: token, received: received, total: total)
                    }
                }
                defer {
                    try? FileManager.default.removeItem(at: temporary)
                    try? FileManager.default.removeItem(at: staged)
                }

                try Task.checkCancellation()
                guard self.owns(spec, token) else { return }
                self.states[spec.id] = .verifying
                try await Task.detached(priority: .utility) {
                    try Self.verify(temporary, against: spec)
                    try FileManager.default.createDirectory(
                        at: directory, withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: temporary, to: staged)
                }.value

                // Back on the main actor: install only if this download still
                // owns the slot. A cancel (and maybe a new download) during
                // the hash leaves the staged file to the `defer` above.
                try Task.checkCancellation()
                guard self.owns(spec, token) else { return }
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
                } else {
                    try FileManager.default.moveItem(at: staged, to: destination)
                }

                self.finish(spec, token: token, state: .installed)
            } catch is CancellationError {
                self.finish(spec, token: token, state: .notInstalled)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                self.finish(spec, token: token, state: .failed(message))
            }
        }
        tasks[spec.id] = (token, task)
    }

    func cancel(_ spec: StemModelSpec) {
        tasks[spec.id]?.task.cancel()
        tasks[spec.id] = nil
        states[spec.id] = diskState(for: spec)
    }

    /// Whether the download started with `token` is still the registered one.
    private func owns(_ spec: StemModelSpec, _ token: UUID) -> Bool {
        tasks[spec.id]?.token == token
    }

    private func report(_ spec: StemModelSpec, token: UUID, received: Int64, total: Int64) {
        guard owns(spec, token), case .downloading = state(for: spec) else { return }
        let fraction = total > 0 ? min(1, Double(received) / Double(total)) : 0
        states[spec.id] = .downloading(progress: fraction)
    }

    private func finish(_ spec: StemModelSpec, token: UUID, state: StemModelState) {
        // A task that was cancelled (and possibly replaced) no longer owns the
        // slot or the row; `cancel` already published the disk state.
        guard owns(spec, token) else { return }
        tasks[spec.id] = nil
        // Just downloaded means just hashed; no need to hash it again on the
        // next visit to the settings page.
        if state == .installed { verified.insert(spec.id) } else { verified.remove(spec.id) }
        states[spec.id] = state == .notInstalled ? diskState(for: spec) : state
        if state == .installed { onInstalled?() }
    }

    // MARK: - Verification

    /// Size then digest, in that order — a truncated download is the common
    /// failure and costs nothing to catch.
    nonisolated static func verify(_ url: URL, against spec: StemModelSpec) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? Int64) ?? -1
        guard size == spec.byteCount else {
            throw StemModelError.sizeMismatch(expected: spec.byteCount, actual: size)
        }
        guard try sha256(of: url) == spec.sha256 else {
            throw StemModelError.digestMismatch
        }
    }

    /// Streaming, so a 264 MB checkpoint is never resident just to be hashed.
    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// The URLSession half, kept off the main actor and out of the state machine.
///
/// A download *task* rather than `bytes(from:)`: 264 MB through an
/// `AsyncSequence` of individual bytes is minutes of pointless work, and the
/// delegate hands over byte counts for free.
enum StemModelFetcher {

    /// Fetch into a temporary file the caller owns and must delete.
    ///
    /// Cancelling the surrounding `Task` cancels the transfer.
    static func download(
        from url: URL,
        expectedBytes: Int64,
        session: URLSession,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> URL {
        let delegate = Delegate(expectedBytes: expectedBytes, progress: progress)
        let task = session.downloadTask(with: url)
        task.delegate = delegate

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                if Task.isCancelled {
                    delegate.resume(with: .failure(CancellationError()))
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            task.cancel()
        }
    }

    private final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let expectedBytes: Int64
        private let progress: @Sendable (Int64, Int64) -> Void
        private let lock = NSLock()
        private var finished = false
        /// Progress coalescing. URLSession reports every written chunk — for a
        /// 264 MB download that is thousands of callbacks, each of which used
        /// to hop to the main actor to move a bar by a pixel it cannot show.
        private var lastFraction = -1.0
        private var lastReportedAt = Date.distantPast
        var continuation: CheckedContinuation<URL, Error>?

        init(expectedBytes: Int64, progress: @escaping @Sendable (Int64, Int64) -> Void) {
            self.expectedBytes = expectedBytes
            self.progress = progress
        }

        /// Resumes at most once — URLSession can report both a finished
        /// download and a completion error, and a continuation resumed twice
        /// traps.
        func resume(with result: Result<URL, Error>) {
            lock.lock()
            let pending = finished ? nil : continuation
            finished = true
            continuation = nil
            lock.unlock()
            pending?.resume(with: result)
        }

        func urlSession(_ session: URLSession,
                        downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedBytes
            let fraction = total > 0 ? min(1, Double(totalBytesWritten) / Double(total)) : 0

            lock.lock()
            let now = Date()
            // Half a percent or 100 ms, whichever comes first — and the last
            // one always lands, so the bar is never left short of full.
            let worth = fraction >= 1
                || fraction - lastFraction >= 0.005
                || now.timeIntervalSince(lastReportedAt) >= 0.1
            if worth {
                lastFraction = fraction
                lastReportedAt = now
            }
            lock.unlock()

            guard worth else { return }
            progress(totalBytesWritten, total)
        }

        func urlSession(_ session: URLSession,
                        downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            // The file is deleted the moment this returns, so it is moved
            // synchronously, here, before anything else can happen.
            if let response = downloadTask.response as? HTTPURLResponse,
                !(200..<300).contains(response.statusCode) {
                resume(with: .failure(StemModelError.http(response.statusCode)))
                return
            }
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("kumone-model-\(UUID().uuidString)")
            do {
                try FileManager.default.moveItem(at: location, to: temporary)
                resume(with: .success(temporary))
            } catch {
                resume(with: .failure(error))
            }
        }

        func urlSession(_ session: URLSession,
                        task: URLSessionTask,
                        didCompleteWithError error: Error?) {
            guard let error else { return }
            if (error as? URLError)?.code == .cancelled {
                resume(with: .failure(CancellationError()))
            } else {
                resume(with: .failure(error))
            }
        }
    }
}
#endif
