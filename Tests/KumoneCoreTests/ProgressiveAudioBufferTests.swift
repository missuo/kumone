import Foundation
import Testing
@testable import KumoneCore

struct ProgressiveAudioBufferTests {
    @Test func mirrorCanBeCommittedAndRemovedBeforeDecodingFinishes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let part = directory.appendingPathComponent("audio.part")
        let final = directory.appendingPathComponent("audio.flac")
        let buffer = try ProgressiveAudioBuffer(mirroringTo: part)
        let data = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0) })
        try buffer.append(data.prefix(16_384))
        #expect(try buffer.read(upToCount: 8192) == data.prefix(8192))
        try buffer.append(data.dropFirst(16_384))
        #expect(try buffer.finishWriting() == Int64(data.count))
        try FileManager.default.moveItem(at: part, to: final)
        #expect(try Data(contentsOf: final) == data)
        try FileManager.default.removeItem(at: final)
        var decoded = Data(data.prefix(8192))
        while buffer.hasUnreadBytes {
            let chunk = try buffer.read(upToCount: 32_768)
            #expect(chunk.count <= 32_768)
            decoded.append(chunk)
        }
        #expect(decoded == data)
        #expect(try buffer.finishWriting() == nil)
    }

    @Test func rangedStreamHasTemporaryBackingButNoCacheMirror() throws {
        let buffer = try ProgressiveAudioBuffer(mirroringTo: nil)
        let data = Data(repeating: 73, count: 100_000)
        try buffer.append(data)
        #expect(try buffer.finishWriting() == nil)
        var decoded = Data()
        while buffer.hasUnreadBytes { decoded.append(try buffer.read(upToCount: 32_768)) }
        #expect(decoded == data)
    }

    @Test func directlyParsedBytesAreSkippedWhenDrainingResumes() throws {
        let buffer = try ProgressiveAudioBuffer(mirroringTo: nil)
        try buffer.append(Data(repeating: 1, count: 4096), consuming: true)
        #expect(!buffer.hasUnreadBytes)
        let pending = Data(repeating: 2, count: 8192)
        try buffer.append(pending)
        #expect(try buffer.read(upToCount: 32_768) == pending)
        #expect(!buffer.hasUnreadBytes)
    }

    @Test func truncatedBackingFileIsReportedInsteadOfDroppingBytes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let buffer = try ProgressiveAudioBuffer(mirroringTo: url)
        try buffer.append(Data(repeating: 1, count: 100))
        let external = try FileHandle(forWritingTo: url)
        try external.truncate(atOffset: 0)
        try external.close()
        #expect(throws: (any Error).self) { try buffer.read(upToCount: 100) }
    }
}
