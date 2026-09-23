import Foundation
import Testing
@testable import KumoneCore

@Suite("Offline metadata cleanup")
struct OfflineMetadataCleanupTests {
    @Test func removesOrphanMetadataButKeepsAudioCurrentAndPendingTracks() async throws {
        let fixture = try OfflineAudioFixture(), audio = fixture.store()
        let root = audio.directory.appendingPathComponent("metadata")
        let metadata = OfflineMetadataStore(directory: root)
        defer { try? FileManager.default.removeItem(at: audio.directory) }
        let picture = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a5XkAAAAASUVORK5CYII="))
        let lyrics = try JSONDecoder().decode(LyricResponse.self, from: Data("{\"lrc\":{\"lyric\":\"[00:00.00]Fixture\"}}".utf8))
        for (id, cover) in [(1, "shared"), (2, "shared"), (3, "orphan"), (4, "current"), (5, "pending")] {
            let track = try JSONDecoder().decode(Track.self, from: Data("{\"id\":\(id),\"name\":\"Track\",\"dt\":3000,\"al\":{\"id\":1,\"name\":\"Album\",\"picUrl\":\"https://fixture.test/\(cover).png\"}}".utf8))
            try await metadata.save(track: track, scope: "test-account")
            try await metadata.save(lyrics: lyrics, trackID: id, scope: "test-account")
            try await metadata.saveArtwork(picture, url: URL(string: "https://fixture.test/\(cover).png")!, scope: "test-account")
        }
        let input = audio.directory.appendingPathComponent("input")
        try fixture.data.write(to: input)
        try await audio.importDownload(at: input, descriptor: fixture.descriptor)
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        while let file = files.nextObject() as? URL {
            if (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
                try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: file.path)
            }
        }
        try await metadata.pruneUnused(audio: audio, protectedTracks: ["test-account": [4, 5]], force: true)
        #expect(await metadata.lyrics(trackID: 1, scope: "test-account") != nil)
        #expect(await metadata.lyrics(trackID: 2, scope: "test-account") == nil)
        #expect(await metadata.lyrics(trackID: 3, scope: "test-account") == nil)
        #expect(await metadata.lyrics(trackID: 4, scope: "test-account") != nil)
        #expect(await metadata.lyrics(trackID: 5, scope: "test-account") != nil)
        #expect(await metadata.artwork(url: URL(string: "https://fixture.test/shared.png")!, scope: "test-account") == picture)
        #expect(await metadata.artwork(url: URL(string: "https://fixture.test/orphan.png")!, scope: "test-account") == nil)

        try await metadata.save(lyrics: lyrics, trackID: 99, scope: "test-account")
        try await metadata.pruneUnused(audio: audio, protectedTracks: ["test-account": [4, 5]], force: true)
        #expect(await metadata.lyrics(trackID: 99, scope: "test-account") != nil)
        try await audio.remove(id: fixture.descriptor.identity.id)
        try await metadata.pruneUnused(audio: audio, protectedTracks: [:], force: true)
        #expect(await metadata.lyrics(trackID: 1, scope: "test-account") == nil)
        #expect(await metadata.artwork(url: URL(string: "https://fixture.test/shared.png")!, scope: "test-account") == nil)
    }
}
