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
