import Foundation
import Testing

@testable import KumoneCore

// The lyrics bridge: what the app fetches from Netease has to land on disk in
// the exact shape `Audition.Lyrics.load` expects, because that read is the only
// thing standing between a `vocalExchange` and its vocal-trough fallback.
//
// No engine, no network: the helper is a pure "text + a file that exists" →
// "file next to it" function, so every case here is a directory and a string.
@Suite struct LyricsSidecarTests {

    private static func makeAudio(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LyricsSidecar-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).mp3")
        try Data("not really audio".utf8).write(to: url)
        // The temp directory outlives a run; a sidecar from the last one would
        // make "nothing was written" trivially false.
        try? FileManager.default.removeItem(
            at: url.deletingPathExtension().appendingPathExtension("lrc"))
        return url
    }

    /// A Netease body as it actually arrives: a credit header, a repeated line
    /// carrying two timestamps, and a rolling credit block on real timestamps
    /// at the close.
    private static let netease = """
        [00:00.00] 作词 : 佚名
        [00:01.00] 作曲 : 佚名
        [ti:测试]
        [00:10.00]第一句
        [00:20.50][01:05.25]副歌这一句
        [00:30.00]最后一句
        [03:40.00] 混音 : 某某
        """

    @Test func roundTripsCreditsAndMultiStampLines() throws {
        let audio = try Self.makeAudio("round-trip")
        #expect(LyricsSidecar.write(Self.netease, for: audio))

        let loaded = try #require(Audition.Lyrics.load(for: audio))
        #expect(loaded.map(\.time) == [10, 20.5, 30, 65.25])
        #expect(loaded.map(\.text) == ["第一句", "副歌这一句", "最后一句", "副歌这一句"])
    }

    @Test func writesBesideTheAudioWithTheLrcExtension() throws {
        let audio = try Self.makeAudio("naming")
        #expect(LyricsSidecar.write(Self.netease, for: audio))
        let sidecar = audio.deletingPathExtension().appendingPathExtension("lrc")
        #expect(FileManager.default.fileExists(atPath: sidecar.path))
        // Verbatim: the parser downstream owns the interpretation.
        #expect(try String(contentsOf: sidecar, encoding: .utf8) == Self.netease)
    }

    @Test func skipsInstrumentalAndUntimedAndAbsentBodies() throws {
        let audio = try Self.makeAudio("skipped")
        let sidecar = audio.deletingPathExtension().appendingPathExtension("lrc")

        #expect(!LyricsSidecar.write(nil, for: audio))
        #expect(!LyricsSidecar.write("", for: audio))
        // Untimed dump — nothing to hand over at.
        #expect(!LyricsSidecar.write("第一句\n第二句", for: audio))
        // Credits only: parsed away to nothing.
        #expect(!LyricsSidecar.write("[00:00.00] 作词 : 佚名", for: audio))
        // Netease's instrumental answer.
        #expect(!LyricsSidecar.write("[00:00.00]纯音乐，请欣赏", for: audio))
        #expect(!FileManager.default.fileExists(atPath: sidecar.path))
    }

    @Test func writesNothingWhenThereIsNoLocalFile() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("LyricsSidecar-nonexistent-\(UUID().uuidString).mp3")
        #expect(!LyricsSidecar.write(Self.netease, for: missing))
        let sidecar = missing.deletingPathExtension().appendingPathExtension("lrc")
        #expect(!FileManager.default.fileExists(atPath: sidecar.path))
    }

    @Test func identicalContentIsNotRewritten() throws {
        let audio = try Self.makeAudio("idempotent")
        #expect(LyricsSidecar.write(Self.netease, for: audio))
        let sidecar = audio.deletingPathExtension().appendingPathExtension("lrc")
        let stamp = Date(timeIntervalSince1970: 1)
        try FileManager.default.setAttributes([.modificationDate: stamp],
                                              ofItemAtPath: sidecar.path)

        #expect(LyricsSidecar.write(Self.netease, for: audio))
        let after = try FileManager.default.attributesOfItem(atPath: sidecar.path)[.modificationDate]
        #expect(after as? Date == stamp)

        // A different body does replace it.
        #expect(LyricsSidecar.write("[00:12.00]换了一句", for: audio))
        #expect(Audition.Lyrics.load(for: audio)?.map(\.text) == ["换了一句"])
    }
}
