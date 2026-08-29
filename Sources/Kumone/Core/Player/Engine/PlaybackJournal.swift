import Foundation
import os

/// A one-line-per-event journal of the seam machinery, written to the unified
/// log so a field incident can be reconstructed after the fact.
///
///     log show --predicate 'subsystem == "im.missuo.Kumone"' --last 30m
///
/// **Why this exists.** The watery-playback bug is a deck left with its
/// time-pitch unit off unity and no transition to explain it. Nothing in the
/// system resolves that on its own — the music simply stays underwater until
/// the track ends — and by the time anyone hears it, every piece of state that
/// would say *which* teardown path dropped the plan is gone. The panel shows
/// the symptom live; this shows how the seam got there.
///
/// **Rules.** Every line is written from the engine's serial queue (or the main
/// actor), never from a render callback — we run no code on the realtime thread
/// and this must not become the first thing that does. Every line is a
/// lifecycle event, a handful per seam, never per tick: the string is built
/// eagerly, which is only acceptable because these are rare.
///
/// Values are logged `.public` on purpose. This is engineering telemetry about
/// tempo and gain, not about the listener; the only user data anywhere near it
/// is a track title, which is deliberately not included.
enum PlaybackJournal {

    static let log = Logger(subsystem: "im.missuo.Kumone", category: "automix")

    static func note(_ message: String) {
        log.log("\(message, privacy: .public)")
        tap.deliver(message)
    }

    // MARK: - Capture, for tests

    /// A tap on the journal, so a test can assert on the lines a seam wrote —
    /// including the ones it must *not* write.
    ///
    /// The journal is the only record of several things the engine does and
    /// nothing else observes (a ride release runs on a deck timer, outlives its
    /// transition and touches no state a snapshot exposes once it lands), so
    /// "did the engine say it did this, and did it say it exactly once" is a
    /// real assertion with no other way to make it. Locked rather than
    /// queue-confined because journal lines come from the engine's serial queue
    /// while the test reads from its own thread; nil is the shipping state and
    /// costs one uncontended lock per line, which is a handful per seam.
    final class Tap: @unchecked Sendable {
        private let lock = NSLock()
        private var sink: (([String]) -> Void)?
        private var lines: [String] = []

        fileprivate func deliver(_ message: String) {
            lock.lock()
            if sink != nil { lines.append(message) }
            lock.unlock()
        }

        /// Run `body` with the journal captured, and hand back everything it
        /// wrote. Not re-entrant, and deliberately not: two overlapping
        /// captures would each see the other's lines.
        func capture<T>(_ body: () throws -> T) rethrows -> (result: T, lines: [String]) {
            lock.lock()
            lines = []
            sink = { _ in }
            lock.unlock()
            defer {
                lock.lock()
                sink = nil
                lock.unlock()
            }
            let result = try body()
            lock.lock()
            let captured = lines
            lock.unlock()
            return (result, captured)
        }
    }

    static let tap = Tap()

    /// `a=×1.0000 b=×1.0630` — the two rates, on every line where a stuck one
    /// would be the story.
    static func rates(_ a: Float, _ b: Float) -> String {
        String(format: "a=×%.4f b=×%.4f", a, b)
    }
}
