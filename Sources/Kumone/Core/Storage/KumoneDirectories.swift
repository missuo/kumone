import Foundation

/// The app's on-disk homes, so every store spells the `Kumone/…` folder once.
enum KumoneDirectories {
    /// `~/Library/Application Support/Kumone/<sub>`, created on first use.
    static func applicationSupport(_ sub: String? = nil) -> URL {
        directory(for: .applicationSupportDirectory, sub: sub)
    }

    /// `~/Library/Caches/Kumone/<sub>`, created on first use.
    static func caches(_ sub: String? = nil) -> URL {
        directory(for: .cachesDirectory, sub: sub)
    }

    private static func directory(for base: FileManager.SearchPathDirectory, sub: String?) -> URL {
        var url = FileManager.default.urls(for: base, in: .userDomainMask)[0]
            .appendingPathComponent("Kumone", isDirectory: true)
        if let sub { url.appendPathComponent(sub, isDirectory: true) }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
