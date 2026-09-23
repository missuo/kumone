import Foundation

struct CacheUsage: Equatable, Sendable {
    let bytes: Int64

    static let zero = CacheUsage(bytes: 0)

    var formatted: String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
