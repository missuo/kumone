import Foundation
import Testing
@testable import KumoneCore

@Suite("Lyrics parser back-deployment regression")
struct LyricsParserTests {
    @Test func multipleTimestampsAndUnicode() {
        let lines = LyricsParser.parseLRCBackport("[00:02.50][01:03:125] 你好👨‍👩‍👧‍👦 e\u{301}かな \n[00:01]first")
        #expect(lines.map(\.time) == [1, 2.5, 63.125])
        #expect(lines.map(\.text) == ["first", "你好👨‍👩‍👧‍👦 e\u{301}かな", "你好👨‍👩‍👧‍👦 e\u{301}かな"])
    }

    @Test func metadataAndMalformedLines() {
        let lines = LyricsParser.parseLRCBackport("[ar:artist]\n[bad]ignored\n[00:03.1]text\n[00:04.001]\n[00:05]末尾")
        #expect(lines.map(\.time) == [3.1, 4.001, 5])
        #expect(lines.map(\.text) == ["text", "", "末尾"])
        #expect(LyricsParser.parseLRCBackport("").isEmpty)
    }

    @Test func wordTimingsPreserveUnicodeAndWhitespace() {
        let lines = LyricsParser.parseYRCBackport("{\"t\":0}\n[1000,1500](1000,500,0) 你好🎵(1500,1000,0)e\u{301} 世界 \n[3000,500](3000,500,0)かな")
        #expect(lines.count == 2)
        #expect(lines[0].text == "你好🎵e\u{301} 世界")
        #expect(lines[0].words?.map(\.text) == [" 你好🎵", "e\u{301} 世界"])
        #expect(lines[0].words?.map(\.start) == [1, 1.5])
        #expect(lines[0].words?.map(\.duration) == [0.5, 1])
        #expect(lines.map(\.time) == [1, 3])
        #expect(lines.map(\.id) == [0, 1])
    }

    @Test func malformedYRCIsIgnored() {
        #expect(LyricsParser.parseYRCBackport("[100,200]no words\n[1,2](1,2,0)   \n[bad](1,2,0)text").isEmpty)
    }
    @Test func nativeAndBackportParsersAgree() {
        let texts = ["中文", "かな漢字", "hello world", "👨‍👩‍👧‍👦e\u{301}", "", " leading and trailing "]
        for (index, text) in texts.enumerated() {
            for fraction in ["", ".1", ":25", ".125", ".0001"] {
                let lrc = "[ar:metadata]\n[00:03\(fraction)][01:12]\(text)\n[00:00]intro"
                let native = LyricsParser.parseLRC(lrc)
                let backport = LyricsParser.parseLRCBackport(lrc)
                #expect(native.map(\.time) == backport.map(\.time))
                #expect(native.map(\.text) == backport.map(\.text))
            }
            let yrc = "[\(index * 1000),800](\(index * 1000),200,0)\(text)(\(index * 1000 + 200),600,0)かな"
            #expect(LyricsParser.parseYRC(yrc) == LyricsParser.parseYRCBackport(yrc))
        }
    }

}
