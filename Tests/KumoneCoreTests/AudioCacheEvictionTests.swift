#if os(macOS)
import Foundation
import Testing

@testable import KumoneCore

// LRU eviction, on a private cache directory. Each file's mtime is set by
// hand so "least recently used" is spelled out rather than raced.

private func makeDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("audio-cache-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@discardableResult
private func write(_ name: String, bytes: Int, age: TimeInterval, in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try Data(repeating: 0x5A, count: bytes).write(to: url)
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
    return url
}

private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}

@Suite struct AudioCacheEvictionTests {

    @Test func evictsOldestFirstUntilUnderTheLimit() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldest = try write("1-a-netease.mp3", bytes: 1000, age: 300, in: directory)
        let middle = try write("2-a-netease.mp3", bytes: 1000, age: 200, in: directory)
        let newest = try write("3-a-netease.mp3", bytes: 1000, age: 100, in: directory)

        let cache = EngineAudioCache(directory: directory, limitBytes: 2000)
        await cache.evictIfNeeded(sparing: nil)

        #expect(!exists(oldest))
        #expect(exists(middle))
        #expect(exists(newest))
    }

    /// The oldest file is what a deck is playing (AutoMix candidate prefetches
    /// have made every other file newer). Eviction must pass over it.
    @Test func neverEvictsAFileInUse() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let playing = try write("1-a-netease.flac", bytes: 1000, age: 500, in: directory)
        let armed = try write("2-a-netease.mp3", bytes: 1000, age: 400, in: directory)
        let candidate = try write("3-a-netease.mp3", bytes: 1000, age: 300, in: directory)
        let fresh = try write("4-a-netease.mp3", bytes: 1000, age: 100, in: directory)

        let cache = EngineAudioCache(directory: directory, limitBytes: 3000)
        cache.setFilesInUse([playing, armed])
        await cache.evictIfNeeded(sparing: nil)

        #expect(exists(playing))
        #expect(exists(armed))
        #expect(!exists(candidate))
        #expect(exists(fresh))

        // Released: the next pass may take it like any other file.
        cache.setFilesInUse([armed])
        try write("5-a-netease.mp3", bytes: 1000, age: 0, in: directory)
        await cache.evictIfNeeded(sparing: nil)
        #expect(!exists(playing))
        #expect(exists(armed))
    }

    /// `/var/...` vs `/private/var/...`: the player's URL and the one read
    /// back from the directory must still be recognised as the same file.
    @Test func inUseMatchesAcrossSymlinkedSpellings() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let playing = try write("1-a-netease.mp3", bytes: 1000, age: 500, in: directory)
        try write("2-a-netease.mp3", bytes: 1000, age: 100, in: directory)

        let cache = EngineAudioCache(directory: directory, limitBytes: 1000)
        cache.setFilesInUse([playing.resolvingSymlinksInPath()])
        await cache.evictIfNeeded(sparing: nil)
        #expect(exists(playing))
    }

    /// A live `.part` is neither deletable nor counted. Counting it used to
    /// make every pass strip the whole cache chasing a total it could not
    /// reach; now the committed files that fit stay.
    @Test func aLivePartFileIsNeitherCountedNorEvicted() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let part = try write("9-a-netease.mp3.part", bytes: 5000, age: 1, in: directory)
        let older = try write("1-a-netease.mp3", bytes: 1000, age: 300, in: directory)
        let newer = try write("2-a-netease.mp3", bytes: 1000, age: 200, in: directory)

        let cache = EngineAudioCache(directory: directory, limitBytes: 2500)
        await cache.evictIfNeeded(sparing: nil)

        #expect(exists(part))
        #expect(exists(older))
        #expect(exists(newer))
    }

    @Test func aStalePartFileIsCountedAndEvictable() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let abandoned = try write(
            "9-a-netease.mp3.part", bytes: 2000,
            age: EngineAudioCache.stalePartAge + 600, in: directory)
        let kept = try write("1-a-netease.mp3", bytes: 1000, age: 300, in: directory)

        let cache = EngineAudioCache(directory: directory, limitBytes: 1500)
        await cache.evictIfNeeded(sparing: nil)

        #expect(!exists(abandoned))
        #expect(exists(kept))
    }

    @Test func lyricsFollowTheirAudioOutAndSpareIsKept() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spare = try write("1-a-netease.mp3", bytes: 1000, age: 500, in: directory)
        let evicted = try write("2-a-netease.mp3", bytes: 1000, age: 400, in: directory)
        let lyrics = try write("2-a-netease.lrc", bytes: 10, age: 400, in: directory)

        let cache = EngineAudioCache(directory: directory, limitBytes: 1500)
        await cache.evictIfNeeded(sparing: spare)

        #expect(exists(spare))
        #expect(!exists(evicted))
        #expect(!exists(lyrics))
    }
}
#endif
