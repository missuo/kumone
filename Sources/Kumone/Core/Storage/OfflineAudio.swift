import CryptoKit
import Foundation
import UniformTypeIdentifiers

enum OfflineAudioError: Error, Equatable {
    case invalidResource, unavailable, incomplete, invalidResponse, changedResource
    case checksumMismatch, invalidAudio, busy, retained, insufficientSpace
    case database(String)
}

enum OfflineAudioFormat: String, Codable, CaseIterable {
    case mp3, m4a, flac

    var contentType: String {
        UTType(filenameExtension: rawValue)?.identifier ?? "public.audio"
    }

    func accepts(mimeType: String?) -> Bool {
        guard let mimeType else { return false }
        switch mimeType.lowercased().split(separator: ";").first.map(String.init) {
        case "application/octet-stream": return true
        case "audio/mpeg", "audio/mp3": return self == .mp3
        case "audio/mp4", "audio/x-m4a", "video/mp4": return self == .m4a
        case "audio/flac", "audio/x-flac": return self == .flac
        default: return false
        }
    }
}

/// Stable identity excludes signed/expiring CDN URLs. An MD5 from the source
/// identifies the expected representation; SHA256 is used for local filenames.
struct OfflineAudioIdentity: Codable, Hashable {
    let accountScope: String
    let trackID: Int
    let source: String
    let quality: String
    let format: OfflineAudioFormat
    let contentMD5: String

    var id: String {
        let fields = [accountScope, String(trackID), source, quality, format.rawValue, contentMD5]
        let data = Data(fields.map { "\($0.utf8.count):\($0)" }.joined().utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    var scopeDirectory: String {
        SHA256.hash(data: Data(accountScope.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct OfflineAudioDescriptor: Codable, Equatable {
    let identity: OfflineAudioIdentity
    let byteCount: Int64
    let duration: TimeInterval

    func validate() throws {
        guard !identity.accountScope.isEmpty, identity.trackID > 0,
              !identity.source.isEmpty, !identity.quality.isEmpty,
              identity.contentMD5.count == 32,
              identity.contentMD5.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              byteCount > 0, byteCount <= 2_000_000_000,
              duration.isFinite, duration > 0 else { throw OfflineAudioError.invalidResource }
    }
}

struct OfflineAudioResource {
    let descriptor: OfflineAudioDescriptor
    let url: URL
}

struct OfflineAudioRecord: Codable {
    /// `partial` only appears in indexes written by earlier builds, which
    /// streamed audio into the store; it is retired on the next launch.
    enum State: String, Codable { case partial, verifying, complete, missing, deleting }
    let descriptor: OfflineAudioDescriptor
    var state: State = .verifying
    var retainedBy: Set<String> = []
    /// Orders the offline "recently played" list.
    var lastPlayed: Date?
    var verifiedModificationDate: Date?
    var id: String { descriptor.identity.id }
}

struct OfflinePlaybackLease {
    let token: UUID
    let descriptor: OfflineAudioDescriptor
    let url: URL
}
