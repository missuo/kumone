import Testing
@testable import KumoneCore

// AutoMix's opt-in layering, as two pure rules.
//
// Both are decisions the player makes constantly and neither needs a player to
// state: `analysisWanted` is what a whole-track decode costs get charged
// against, and the queue-order cycle is the one place the order of the three
// states is written down now that the standalone AutoMix-order buttons are
// gone.

@Suite @MainActor struct AutoMixSettingsTests {

    @Test(arguments: [6.0, 60, 120, 240, 3600])
    func ordinaryGaplessPreparationWaitsForTheTail(duration: Double) {
        let boundary = duration - min(30, duration * 0.25)
        #expect(!PlayerService.gaplessPrefetchReady(position: 0, duration: duration))
        #expect(!PlayerService.gaplessPrefetchReady(position: boundary - 0.01, duration: duration))
        #expect(PlayerService.gaplessPrefetchReady(position: boundary, duration: duration))
        #expect(PlayerService.gaplessPrefetchReady(position: duration - 0.01, duration: duration))
        // A backward seek leaves the window; an ended track cannot start work.
        #expect(!PlayerService.gaplessPrefetchReady(position: boundary - 1, duration: duration))
        #expect(!PlayerService.gaplessPrefetchReady(position: duration, duration: duration))
        #expect(!PlayerService.gaplessPrefetchReady(position: duration + 1, duration: duration))
    }

    @Test func anUnknownTimelineCannotStartGaplessPreparation() {
        for duration in [0.0, -1, .infinity, .nan] {
            #expect(!PlayerService.gaplessPrefetchReady(position: 0, duration: duration))
        }
        for position in [-1.0, .infinity, .nan] {
            #expect(!PlayerService.gaplessPrefetchReady(position: position, duration: 240))
        }
    }

    // MARK: - What buys an analysis

    @Test func theMasterSwitchIsNecessaryForAnalysis() {
        // Every sub-setting on and the master off is still nothing: the master
        // is the one switch that means "do not spend CPU on my library".
        #expect(!PlayerService.analysisWanted(master: false, transitions: true,
                                              order: true, loudness: true))
    }

    @Test func anySingleConsumerIsEnoughToBuyAnAnalysis() {
        // Three consumers, three independent reasons. Transitions is the
        // obvious one; the other two are the regression this exists to stop —
        // turning transitions off used to be the same thing as turning the
        // analysis off, which silently took the loudness trim and the AutoMix
        // order with it.
        #expect(PlayerService.analysisWanted(master: true, transitions: true,
                                             order: false, loudness: false))
        #expect(PlayerService.analysisWanted(master: true, transitions: false,
                                             order: true, loudness: false))
        #expect(PlayerService.analysisWanted(master: true, transitions: false,
                                             order: false, loudness: true))
    }

    @Test func aMasterOnWithNothingToSpendItOnAnalyzesNothing() {
        #expect(!PlayerService.analysisWanted(master: true, transitions: false,
                                              order: false, loudness: false))
    }

    // MARK: - The one queue-order control

    @Test func theShuffleButtonCyclesThroughAllThreeOrders() {
        #expect(PlayerService.nextQueueOrder(after: .listed,
                                             autoMixAvailable: true) == .shuffled)
        #expect(PlayerService.nextQueueOrder(after: .shuffled,
                                             autoMixAvailable: true) == .autoMix)
        #expect(PlayerService.nextQueueOrder(after: .autoMix,
                                             autoMixAvailable: true) == .listed)
    }

    @Test func withoutTheAutoMixOrderTheCycleIsTheTwoStateShuffleItAlwaysWas() {
        // iOS, AutoMix off, or the order sub-setting off. The button must
        // behave exactly as it did before the third state existed.
        #expect(PlayerService.nextQueueOrder(after: .listed,
                                             autoMixAvailable: false) == .shuffled)
        #expect(PlayerService.nextQueueOrder(after: .shuffled,
                                             autoMixAvailable: false) == .listed)
    }

    @Test func anAutoMixOrderThatIsNoLongerOfferedCyclesOutOfItself() {
        // The state can be entered and then have its setting turned off under
        // it; the cycle must still lead home rather than trapping the queue in
        // a mode nothing can reach any more.
        #expect(PlayerService.nextQueueOrder(after: .autoMix,
                                             autoMixAvailable: false) == .listed)
    }
}
