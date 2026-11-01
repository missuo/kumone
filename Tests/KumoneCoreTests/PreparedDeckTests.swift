import Foundation
import Testing
@testable import KumoneCore

@Suite(.serialized) struct PreparedDeckTests {
    @Test func withdrawingPreparationCancelsTheWaitingTransition() throws {
        let engine = PlaybackEngine()
        defer { engine.stopAll() }
        _ = try engine.loadFile(at: Fixtures.sixSecondStereoCAF, on: .a)
        _ = try engine.loadFile(at: Fixtures.sixSecondStereoCAF, on: .b)
        engine.scheduleTransition(.plain(.gapless), from: .a, to: .b)
        #expect(engine.hasPendingTransition)
        #expect(engine.discardPreparedDeck(.b))
        #expect(!engine.hasPendingTransition)
        #expect(engine.duration(of: .b) == nil)
        #expect(engine.duration(of: .a) != nil)
    }

    @Test func withdrawingPreparationCannotStopAPlayingDeck() throws {
        let engine = PlaybackEngine()
        defer { engine.stopAll() }
        engine.outputVolume = 0
        _ = try engine.loadFile(at: Fixtures.sixSecondStereoCAF, on: .b)
        engine.play(deck: .b, from: 0)
        #expect(!engine.discardPreparedDeck(.b))
        #expect(engine.duration(of: .b) != nil)
    }
}
