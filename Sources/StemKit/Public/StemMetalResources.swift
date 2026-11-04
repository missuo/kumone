#if os(macOS)
import Foundation

/// MLX 0.30.6 discovers loaded frameworks, but cannot take an arbitrary kernel
/// path. Keep the signed resource framework alive after extracting it outside
/// the app. The serial utility queue owns both installation and bundle loading.
final class StemMetalResources: @unchecked Sendable {
    static let shared = StemMetalResources(
        archive: Bundle.main.url(forResource: "KumoneStemResources", withExtension: "zip"),
        directory: StemKitDirectories.applicationSupport.appendingPathComponent("Metal", isDirectory: true),
        version: Bundle.main.object(forInfoDictionaryKey: "KumoneResourceVersion") as? String)

    let archive: URL?
    private let directory: URL
    private let version: String?
    private let queue = DispatchQueue(label: "sb.moe.kumone.stem-resources", qos: .utility)
    private var loadedBundle: Bundle?

    init(archive: URL?, directory: URL, version: String?) {
        self.archive = archive
        self.directory = directory
        self.version = version
    }

    func load() async throws {
        // A bare SwiftPM executable uses the existing colocated kernel path.
        guard let archive else { return }
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    if self.loadedBundle != nil {
                        continuation.resume()
                        return
                    }
                    guard let version = self.version else { throw ResourceError.invalidBundle }
                    try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
                    // A terminated extraction cannot execute its defer. Reclaim its staging files on retry.
                    for item in try FileManager.default.contentsOfDirectory(
                        at: self.directory, includingPropertiesForKeys: nil) where item.pathExtension == "partial" {
                        try FileManager.default.removeItem(at: item)
                    }
                    let destination = self.directory.appendingPathComponent("KumoneStemResources.framework")
                    if !self.isCurrentFramework(destination, version: version) {
                        let staged = self.directory.appendingPathComponent("\(UUID().uuidString).partial")
                        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
                        defer { try? FileManager.default.removeItem(at: staged) }
                        let unpack = Process()
                        unpack.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                        unpack.arguments = ["-x", "-k", "--noqtn", archive.path, staged.path]
                        try unpack.run()
                        unpack.waitUntilExit()
                        guard unpack.terminationStatus == 0 else {
                            throw ResourceError.extractionFailed(unpack.terminationStatus)
                        }
                        let framework = staged.appendingPathComponent("KumoneStemResources.framework")
                        guard self.isCurrentFramework(framework, version: version) else {
                            throw ResourceError.invalidBundle
                        }
                        // Only the signed framework from our bundled archive is installed here.
                        // --noqtn does not remove quarantine stored inside the archive itself.
                        let quarantine = Process()
                        quarantine.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
                        quarantine.arguments = ["-r", "-d", "com.apple.quarantine", framework.path]
                        try quarantine.run()
                        quarantine.waitUntilExit()
                        guard quarantine.terminationStatus == 0 else {
                            throw ResourceError.quarantineRemovalFailed(quarantine.terminationStatus)
                        }
                        if FileManager.default.fileExists(atPath: destination.path) {
                            _ = try FileManager.default.replaceItemAt(destination, withItemAt: framework)
                        } else {
                            try FileManager.default.moveItem(at: framework, to: destination)
                        }
                    }
                    guard let bundle = Bundle(url: destination) else { throw ResourceError.invalidBundle }
                    try bundle.loadAndReturnError()
                    self.loadedBundle = bundle
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        try Task.checkCancellation()
    }

    private func isCurrentFramework(_ framework: URL, version: String) -> Bool {
        // Read the file directly: Bundle caches metadata even after replacement at the same URL.
        // Missing or invalid cached metadata requires reinstallation from the bundled archive.
        guard let data = try? Data(contentsOf: framework.appendingPathComponent("Resources/Info.plist")),
              let metadata = try? PropertyListDecoder().decode(Metadata.self, from: data) else { return false }
        return metadata.bundleIdentifier == "mlx-swift_Cmlx" && metadata.version == version
            && FileManager.default.fileExists(atPath: framework.appendingPathComponent("Resources/default.metallib").path)
    }

    private struct Metadata: Decodable {
        let bundleIdentifier: String
        let version: String

        enum CodingKeys: String, CodingKey {
            case bundleIdentifier = "CFBundleIdentifier"
            case version = "KumoneResourceVersion"
        }
    }

    enum ResourceError: Error {
        case invalidBundle
        case extractionFailed(Int32)
        case quarantineRemovalFailed(Int32)
    }
}
#endif
