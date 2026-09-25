import Foundation

/// Keep blocking audio work and its deadline off Swift's cooperative executor.
/// A semaphore wait in the calling test can starve the Tasks delivering the
/// very events that the audio worker is waiting for, especially on small runners.
func runWithWatchdog<T>(_ label: String, timeout: TimeInterval,
                        _ body: @escaping () -> T) async -> T? {
    await withCheckedContinuation { continuation in
        let box = WatchdogResult<T>()
        let done = DispatchSemaphore(value: 0)
        let worker = Thread {
            box.value = body()
            done.signal()
        }
        worker.name = "watchdog-body-\(label)"
        worker.stackSize = 1 << 21
        worker.start()
        // Only read the result after the semaphore establishes that the worker
        // finished. A timed-out worker may still write its private box later.
        DispatchQueue.global().async {
            if done.wait(timeout: .now() + timeout) == .timedOut {
                continuation.resume(returning: nil)
            } else {
                continuation.resume(returning: box.value)
            }
        }
    }
}

private final class WatchdogResult<T>: @unchecked Sendable {
    var value: T?
}
