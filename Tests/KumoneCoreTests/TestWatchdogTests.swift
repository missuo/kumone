import Foundation
import Testing

@Suite("TestWatchdog")
struct TestWatchdogTests {
    @Test func blockingWorkersAllowAsyncEventsToArrive() async {
        // Also run with LIBDISPATCH_COOPERATIVE_POOL_STRICT=1: even a single
        // executor thread must remain available to consume playback events.
        // Other suites can keep the pool busy for half a minute on CI, so the
        // event gets twice that; a blocking watchdog fails at any length.
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let result = await runWithWatchdog("async-event", timeout: 75) {
                        let event = DispatchSemaphore(value: 0)
                        Task { event.signal() }
                        return event.wait(timeout: .now() + 60) == .success
                    }
                    return result == true
                }
            }
            for await received in group {
                #expect(received, "The watchdog must not block async event delivery")
            }
        }
    }

    @Test func timeoutReturnsBeforeWorkerAndAcceptsLateCompletion() async {
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let result = await runWithWatchdog("blocked-worker", timeout: 0.05) {
            release.wait()
            finished.signal()
            return 42
        }
        #expect(result == nil)
        release.signal()
        // The released worker is an ordinary thread on a loaded runner.
        let completed = await runWithWatchdog("late-completion", timeout: 15) {
            finished.wait(timeout: .now() + 10) == .success
        }
        #expect(completed == true)
    }

    @Test func optionalNilIsACompletedResult() async {
        let result: Int?? = await runWithWatchdog("optional", timeout: 2) { nil as Int? }
        guard case .some(.none) = result else {
            Issue.record("A nil body result must remain distinguishable from a timeout")
            return
        }
    }
}
