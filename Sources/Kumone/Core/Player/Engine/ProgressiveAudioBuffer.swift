#if os(macOS)
import Foundation

/// Encoded bytes waiting for the streaming decoder. The cache mirror is also
/// the backing store, so backpressure needs neither a second copy nor a large
/// in-memory queue. All access is confined to the loader's work queue.
final class ProgressiveAudioBuffer {
    private let reader: FileHandle
    private var writer: FileHandle?
    private let mirrorsCache: Bool
    private(set) var byteCount: UInt64 = 0
    private var readOffset: UInt64 = 0

    var hasUnreadBytes: Bool { readOffset < byteCount }

    init(mirroringTo mirrorURL: URL?) throws {
        let url = mirrorURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("kumone-stream-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let writer = try FileHandle(forWritingTo: url)
        do {
            reader = try FileHandle(forReadingFrom: url)
            // A ranged stream cannot become a cache entry. Unlink its backing
            // file now; open descriptors keep it alive until playback releases
            // it, including when the process exits unexpectedly.
            if mirrorURL == nil { try FileManager.default.removeItem(at: url) }
        } catch {
            try? writer.close()
            throw error
        }
        self.writer = writer
        mirrorsCache = mirrorURL != nil
    }

    deinit {
        try? reader.close()
        try? writer?.close()
    }

    /// Bytes parsed directly from the network callback need no disk read.
    func append(_ data: Data, consuming: Bool = false) throws {
        guard let writer else { throw CocoaError(.fileWriteUnknown) }
        try writer.write(contentsOf: data)
        byteCount += UInt64(data.count)
        if consuming { readOffset = byteCount }
    }

    func read(upToCount count: Int) throws -> Data {
        guard hasUnreadBytes else { return Data() }
        let count = min(count, Int(byteCount - readOffset))
        try reader.seek(toOffset: readOffset)
        guard let data = try reader.read(upToCount: count), data.count == count else {
            throw CocoaError(.fileReadCorruptFile)
        }
        readOffset += UInt64(data.count)
        return data
    }

    /// The reader stays open across cache promotion, removal and eviction.
    /// Closing the writer is the only prerequisite for publishing the mirror.
    func finishWriting() throws -> Int64? {
        guard let writer else { return nil }
        try writer.close()
        self.writer = nil
        return mirrorsCache ? Int64(byteCount) : nil
    }
}
#endif
