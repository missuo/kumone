import Testing
@testable import KumoneCore

/// The player drops an armed hand-over the moment "stop after this track" is
/// chosen and re-arms when it is cancelled or consumed, through
/// `SleepTimer.onStateChange`. These pin that the hook fires on exactly the
/// transitions the player reacts to, and not on a no-op re-schedule.
@MainActor
@Suite struct SleepTimerTests {

    @Test func endOfTrackReportsEnterAndLeave() {
        let timer = SleepTimer()
        var seen: [SleepTimer.State] = []
        timer.onStateChange = { seen.append($0) }

        timer.scheduleAtEndOfCurrentTrack()
        #expect(timer.consumeEndOfCurrentTrack())
        #expect(seen == [.endOfCurrentTrack, .inactive])
    }

    @Test func reschedulingTheSameModeIsSilent() {
        let timer = SleepTimer()
        var count = 0
        timer.onStateChange = { _ in count += 1 }

        timer.scheduleAtEndOfCurrentTrack()
        timer.scheduleAtEndOfCurrentTrack()
        #expect(count == 1)
        timer.cancel()
        timer.cancel()
        #expect(count == 2)
    }

    @Test func consumingIsOnlyForTheEndOfTrackMode() {
        let timer = SleepTimer()
        timer.schedule(afterMinutes: 30)
        #expect(!timer.consumeEndOfCurrentTrack())
        #expect(timer.state.isActive)
        timer.cancel()
    }
}
