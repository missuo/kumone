import Foundation
import Testing
@testable import KumoneCore

/// The eapi device ID is made once per install and kept, so NetEase sees the
/// same device each time.
@Suite struct NeteaseDeviceIDTests {
    private func scratchDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    @Test func deviceIDIsMadeOnceAndKept() throws {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = NeteaseClient.loadDeviceID(in: dir)
        #expect(first.count == 52)
        #expect(first.allSatisfy { "0123456789ABCDEF".contains($0) })
        #expect(NeteaseClient.loadDeviceID(in: dir) == first)
        let stored = try String(contentsOf: dir.appendingPathComponent("device-id"), encoding: .utf8)
        #expect(stored == first)
    }

    @Test func malformedDeviceIDIsReplaced() throws {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("device-id")
        try Data("kumone".utf8).write(to: file)
        let id = NeteaseClient.loadDeviceID(in: dir)
        #expect(id.count == 52)
        #expect(try String(contentsOf: file, encoding: .utf8) == id)
    }

    @Test func deviceIDWithoutStorageStillHasTheShape() {
        let id = NeteaseClient.loadDeviceID(in: nil)
        #expect(id.count == 52)
        #expect(id.allSatisfy { $0.isHexDigit })
    }
}
