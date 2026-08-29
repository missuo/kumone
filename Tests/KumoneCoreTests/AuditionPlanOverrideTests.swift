import Testing
@testable import KumoneCore
import Foundation

/// `Audition.PlanOverride` is the console's one per-pair instrument: it names
/// a seam in *these two* tracks rather than moving a global threshold. Its
/// whole contract is "parse leniently, refuse impossible geometry loudly", so
/// that is what these cover — plus the `.lrc` reader that gives the AI bundle
/// its words.
@Suite struct AuditionPlanOverrideTests {

    typealias PO = Audition.PlanOverride

    // MARK: - Time parsing

    @Test func plainSecondsParse() {
        #expect(PO.seconds(from: "199.5") == 199.5)
        #expect(PO.seconds(from: "0") == 0)
        #expect(PO.seconds(from: "  12  ") == 12)
    }

    @Test func clockTimesParse() {
        #expect(PO.seconds(from: "3:19.5") == 199.5)
        #expect(PO.seconds(from: "03:19") == 199)
        #expect(PO.seconds(from: "0:02") == 2)
        #expect(PO.seconds(from: "1:03:19.5") == 3799.5)
        // A leading field may run past its wheel: 90 minutes is a real time.
        #expect(PO.seconds(from: "90:00") == 5400)
    }

    @Test func malformedTimesAreRejectedNotGuessed() {
        // A typo must not silently become a number: 3:75 is not 4:15.
        #expect(PO.seconds(from: "3:75") == nil)
        #expect(PO.seconds(from: "-5") == nil)
        #expect(PO.seconds(from: "3:-5") == nil)
        #expect(PO.seconds(from: "1:2:3:4") == nil)
        #expect(PO.seconds(from: "abc") == nil)
        #expect(PO.seconds(from: "") == nil)
        #expect(PO.seconds(from: "3:") == nil)
        #expect(PO.seconds(from: "inf") == nil)
    }

    @Test func jsonValuesParseFromEitherSpelling() {
        #expect(PO.seconds(fromJSON: 199.5 as NSNumber) == 199.5)
        #expect(PO.seconds(fromJSON: "3:19.5") == 199.5)
        #expect(PO.seconds(fromJSON: -1 as NSNumber) == nil)
        #expect(PO.seconds(fromJSON: ["nope"]) == nil)
    }

    // MARK: - Shape

    @Test func emptyOverrideIsEmpty() {
        #expect(PO().isEmpty)
        #expect(!PO(overlap: 8).isEmpty)
        #expect(PO(outPoint: 1, overlap: 8).specifiedFields == ["outPoint", "overlap"])
        #expect(PO(inPoint: 2).specifiedFields == ["inPoint"])
    }

    // MARK: - Resolution

    /// A 200 s outgoing track handing over to a 180 s incoming one, as the
    /// planner left it: seam at 3:00, incoming from 0:10, 8 s together.
    private func resolve(_ o: PO,
                         baseOut: TimeInterval = 180, baseIn: TimeInterval = 10,
                         baseOverlap: TimeInterval = 8,
                         outDuration: TimeInterval = 200,
                         inDuration: TimeInterval = 180)
        throws -> (outPoint: TimeInterval, inPoint: TimeInterval, overlap: TimeInterval) {
        try o.resolve(baseOutPoint: baseOut, baseInPoint: baseIn, baseOverlap: baseOverlap,
                      outgoingDuration: outDuration, incomingDuration: inDuration)
    }

    @Test func omittedFieldsKeepThePlannersValues() throws {
        let g = try resolve(PO(inPoint: 2))
        #expect(g.outPoint == 180)
        #expect(g.inPoint == 2)
        #expect(g.overlap == 8)
    }

    @Test func allThreeFieldsTakeEffect() throws {
        let g = try resolve(PO(outPoint: 170, inPoint: 0, overlap: 12))
        #expect(g.outPoint == 170)
        #expect(g.inPoint == 0)
        #expect(g.overlap == 12)
    }

    /// A `.gapless` baseline has no overlap at all; an override on it still
    /// needs something to move, so the floor stands in.
    @Test func zeroBaselineOverlapFloorsAtTheMinimum() throws {
        let g = try resolve(PO(outPoint: 190), baseOverlap: 0)
        #expect(g.overlap == PO.minOverlap)
    }

    @Test func outPointPastTheEndIsRefused() {
        #expect(throws: PO.Failure.pastEnd(field: "outPoint", value: 210,
                                           duration: 200, track: "出曲")) {
            try resolve(PO(outPoint: 210))
        }
        // The end itself is past the end: there is nothing left to play.
        #expect(throws: PO.Failure.self) { try resolve(PO(outPoint: 200)) }
    }

    @Test func inPointPastTheEndIsRefused() {
        #expect(throws: PO.Failure.pastEnd(field: "inPoint", value: 181,
                                           duration: 180, track: "入曲")) {
            try resolve(PO(inPoint: 181))
        }
    }

    @Test func overlapCeilingAndFloorHold() {
        #expect(throws: PO.Failure.overlapTooLong(40.5)) {
            try resolve(PO(outPoint: 0, inPoint: 0, overlap: 40.5))
        }
        // Exactly at the ceiling is fine.
        #expect(throws: Never.self) {
            try resolve(PO(outPoint: 0, inPoint: 0, overlap: PO.maxOverlap))
        }
        #expect(throws: PO.Failure.overlapTooShort(0.2)) {
            try resolve(PO(overlap: 0.2))
        }
    }

    @Test func overlapMustFitAfterTheOutPoint() {
        #expect(throws: PO.Failure.tailTooShort(outPoint: 195, available: 5, wanted: 12)) {
            try resolve(PO(outPoint: 195, overlap: 12))
        }
        // Landing exactly on the last sample is allowed.
        #expect(throws: Never.self) { try resolve(PO(outPoint: 188, overlap: 12)) }
    }

    @Test func overlapMustFitAfterTheInPoint() {
        #expect(throws: PO.Failure.intakeTooShort(inPoint: 175, available: 5, wanted: 12)) {
            try resolve(PO(inPoint: 175, overlap: 12))
        }
        #expect(throws: Never.self) { try resolve(PO(inPoint: 168, overlap: 12)) }
    }

    @Test func failuresExplainThemselvesInTheConsolesWords() {
        let message = PO.Failure.tailTooShort(outPoint: 195, available: 5, wanted: 12)
            .errorDescription ?? ""
        #expect(message.contains("3:15.00"))
        #expect(message.contains("放不下"))
    }

    // MARK: - Applying it to a plan

    /// 8 bars of 120 BPM = 16 s, i.e. a 0.5 s beat.
    private func beatMatched(overlap: TimeInterval = 16, bars: Int = 8) -> PlannedTransition {
        PlannedTransition(
            plan: .beatMatched(BeatMatchedPlan(
                outPoint: 180, inPoint: 10, overlapBars: bars,
                outgoingRate: 1.01, incomingRate: 0.99,
                bassSwapOffset: overlap / 2, overlapDuration: overlap)),
            style: TransitionStyle(outroEffect: .fade, stagedEQ: true))
    }

    /// The kind is what the style and the bass swap are written against, so a
    /// moved seam must not silently demote a beat-matched hand-over.
    @Test func beatMatchedStaysBeatMatchedAndKeepsItsBeat() throws {
        let moved = try Audition.apply(PO(outPoint: 150, overlap: 8), to: beatMatched(),
                                       outgoingDuration: 200, incomingDuration: 180)
        guard case .beatMatched(let p) = moved.plan else {
            Issue.record("override demoted a beat-matched plan"); return
        }
        #expect(p.outPoint == 150)
        #expect(p.inPoint == 10)              // untouched
        #expect(p.overlapDuration == 8)
        #expect(p.overlapBars == 4)           // half the window, same 0.5 s beat
        #expect(p.bassSwapOffset == 4)
        #expect(p.outgoingRate == 1.01)       // the tempo match survives
        #expect(moved.style.stagedEQ)
    }

    @Test func crossfadeKeepsItsKind() throws {
        let base = PlannedTransition(plan: .crossfade(duration: 4, outPoint: 100, inPoint: 5),
                                     style: .plain)
        let moved = try Audition.apply(PO(inPoint: 20), to: base,
                                       outgoingDuration: 200, incomingDuration: 180)
        guard case .crossfade(let d, let o, let i) = moved.plan else {
            Issue.record("crossfade changed kind"); return
        }
        #expect(d == 4)
        #expect(o == 100)
        #expect(i == 20)
    }

    /// `.gapless` has no geometry at all; asking for one is asking for the
    /// crossfade it implies.
    @Test func gaplessBecomesTheCrossfadeItImplies() throws {
        let moved = try Audition.apply(PO(overlap: 6), to: PlannedTransition(plan: .gapless,
                                                                             style: .plain),
                                       outgoingDuration: 200, incomingDuration: 180)
        guard case .crossfade(let d, let o, let i) = moved.plan else {
            Issue.record("gapless did not become a crossfade"); return
        }
        #expect(d == 6)
        // The implied seam: the asked-for overlap, landing on the track's end.
        #expect(o == 194)
        #expect(i == 0)
    }

    @Test func anImpossibleOverrideNeverProducesAPlan() {
        #expect(throws: PO.Failure.self) {
            try Audition.apply(PO(outPoint: 199, overlap: 16), to: beatMatched(),
                               outgoingDuration: 200, incomingDuration: 180)
        }
    }

    // MARK: - Lyrics

    private static let lrc = """
    [ti:断气]
    [00:00.00] 作词 : 刘西蒙
    [00:01.00] 作曲 : 刘西蒙
    [00:30.87]当他能顺利赶到
    [00:34.45]我头纱都快要戴好

    [01:00.50][02:10.25]我宁愿死在战壕里面
    [03:19.50]最后一句
    [04:21.64]厂牌 : 池沼ChiZhao
    [04:28.34]封面设计 : 贝贝
    [04:31.00]录音工程& MIDI制作：韦力文
    """

    @Test func lrcLinesParseInTimeOrder() {
        let lines = Audition.Lyrics.parse(Self.lrc)
        #expect(lines.map(\.time) == [30.87, 34.45, 60.5, 130.25, 199.5])
        #expect(lines.first?.text == "当他能顺利赶到")
    }

    /// Netease `.lrc` files bury a rolling credit list at the *end*, on real
    /// timestamps — right where the bundle quotes the outgoing track's last
    /// sung lines, so dropping them matters more than dropping the header.
    @Test func creditsAndMetadataAreNotLyrics() {
        let lines = Audition.Lyrics.parse(Self.lrc)
        #expect(!lines.contains { $0.text.contains("作词") })
        #expect(!lines.contains { $0.text.contains("ti:") })
        #expect(!lines.contains { $0.text.contains("厂牌") })
        #expect(!lines.contains { $0.text.contains("封面设计") })
        // Too long a label for the length test; the role list catches it.
        #expect(!lines.contains { $0.text.contains("MIDI制作") })
        #expect(lines.last?.text == "最后一句")
    }

    @Test func repeatedTimestampsBecomeSeparateLines() {
        let lines = Audition.Lyrics.parse(Self.lrc).filter { $0.text == "我宁愿死在战壕里面" }
        #expect(lines.count == 2)
    }

    @Test func headAndTailPickTheEnds() {
        let lines = Audition.Lyrics.parse(Self.lrc)
        #expect(Audition.Lyrics.head(lines, count: 2).map(\.text)
                == ["当他能顺利赶到", "我头纱都快要戴好"])
        #expect(Audition.Lyrics.tail(lines, count: 1).map(\.text) == ["最后一句"])
        // Asking for more than there is yields everything, not a crash.
        #expect(Audition.Lyrics.tail(lines, count: 99).count == lines.count)
    }

    @Test func lyricsSidecarSitsBesideTheTrack() {
        let track = URL(fileURLWithPath: "/corpus/p1-5-回春丹-断气-1997293311.mp3")
        #expect(Audition.Lyrics.sidecarURL(for: track).lastPathComponent
                == "p1-5-回春丹-断气-1997293311.lrc")
        #expect(Audition.Lyrics.load(for: URL(fileURLWithPath: "/nope/missing.mp3")) == nil)
    }
}
