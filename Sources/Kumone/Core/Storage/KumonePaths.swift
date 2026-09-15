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
}
