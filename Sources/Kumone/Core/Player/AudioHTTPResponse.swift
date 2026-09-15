import Foundation

struct AudioHTTPResponse {
    let offset: Int64
    let length: Int64
    let etag: String?

    init(response: HTTPURLResponse, requested: Range<Int64>, descriptor: OfflineAudioDescriptor,
         previousETag: String?) throws {
        guard descriptor.identity.format.accepts(mimeType: response.mimeType),
              response.value(forHTTPHeaderField: "Content-Encoding").map({ $0 == "identity" }) ?? true else {
            throw OfflineAudioError.invalidResponse
        }
        etag = response.value(forHTTPHeaderField: "ETag")
        if let previousETag, etag != previousETag { throw OfflineAudioError.changedResource }
        if response.statusCode == 206 {
            guard let header = response.value(forHTTPHeaderField: "Content-Range"), header.hasPrefix("bytes ") else {
                throw OfflineAudioError.invalidResponse
            }
            let fields = header.dropFirst(6).split(separator: "/")
            guard fields.count == 2, Int64(fields[1]) == descriptor.byteCount else { throw OfflineAudioError.changedResource }
            let bounds = fields[0].split(separator: "-")
            guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
                  start == requested.lowerBound, end >= start, end < requested.upperBound else {
                throw OfflineAudioError.invalidResponse
            }
            offset = start
            length = end - start + 1
        } else if response.statusCode == 200 {
            // A server ignoring Range sends the whole representation from zero.
            offset = 0
            length = descriptor.byteCount
        } else { throw OfflineAudioError.invalidResponse }
        if let rawLength = response.value(forHTTPHeaderField: "Content-Length") {
            guard Int64(rawLength) == length else { throw OfflineAudioError.invalidResponse }
        }
    }
}
