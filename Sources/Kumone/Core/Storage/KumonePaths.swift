import Foundation

enum KumonePaths {
    static var applicationSupport: URL {
        #if DEBUG
        if let path = Bundle.main.object(forInfoDictionaryKey: "KumoneTestingDirectory") as? String {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kumone", isDirectory: true)
    }

    static var imageCache: URL {
        #if DEBUG
        if isOfflineUITest { return applicationSupport.appendingPathComponent("images", isDirectory: true) }
        #endif
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("im.missuo.Kumone/images", isDirectory: true)
    }

    static var isOfflineUITest: Bool {
        #if DEBUG
        return Bundle.main.object(forInfoDictionaryKey: "KumoneTestingDirectory") is String
            && Bundle.main.object(forInfoDictionaryKey: "KumoneOfflineUITest") as? Bool == true
        #else
        return false
        #endif
    }

    static var networkCache: URL {
        if isOfflineUITest { return applicationSupport.appendingPathComponent("network-cache") }
        let identifier = Bundle.main.bundleIdentifier ?? "im.missuo.Kumone"
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(identifier, isDirectory: true)
    }

    static var storageRoots: [URL] {
        if isOfflineUITest { return [applicationSupport] }
        #if os(iOS)
        // These are inside this app's sandbox, including preferences,
        // URLSession data and any update IPA saved to Files.
        return FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            + FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            + [FileManager.default.temporaryDirectory]
        #else
        return [applicationSupport, networkCache]
        #endif
    }
}
