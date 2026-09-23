#if os(macOS)
import AVFoundation
import Foundation

/// **How late the segment has to be released so the head crossfade is an
/// identity again** — a number the engine learns from its own output rather
/// than one anybody gets to assume.
///
/// The head of a spliced hand-over crossfades a *live* deck into a
/// *pre-rendered* one over half a second of the same music. The live deck's
/// audio has been through an engaged `AVAudioUnitTimePitch`; the segment's has
/// not (its player goes to the mixer at unity). Offline, that unit reports zero
/// latency and measures as a pass-through — which is why nothing in the code
/// ever compensated for it. In the *live* engine it has been rendering since
/// launch and its output arrives about two I/O quanta behind its player clock:
/// the field measured the segment sitting +17…+19 ms ahead of the deck it was
/// supposed to be identical to, which is a comb filter half a second long and
/// exactly the doubled beat the listener reported.
///
/// The number is not a constant of the software. It depends on the device's
/// buffer size and sample rate, so it is stored, defaulted to the field value,
/// and then *re-measured by every seam that plays* — see `SeamOffsetMeter`.
/// A manual pin (`AutoMixOverrides.headLatencyCompensationMS`) overrides it
/// outright, for the A/B that has to hold one regime still.
struct SeamLatencyCalibration: Codable, Equatable, Sendable {

    /// The measurement the compensation was first shipped with: the live
    /// engine's engaged time-pitch latency as measured in the field on
    /// 2026-09-02, against output-tap captures aligned sample-accurately to
    /// their source files. Two 512-frame quanta is 21 ms at 48 kHz and 23 at
    /// 44.1, so ~19 ms is the right order for "one buffer of unit plus one of
    /// graph" — but the default is the *measurement*, not that arithmetic.
    static let fieldDefaultMilliseconds: Double = 19

    /// Both correlations a measurement must clear before it is allowed to move
    /// the estimate. Below this the correlator did not find the same music on
    /// both sides of the seam, and its offset is a number about noise.
    static let minCorrelation: Double = 0.9

    /// The estimate can never leave this range, whatever a measurement claims.
    /// Zero because a *negative* compensation would release the segment before
    /// the deck reaches the splice, which no latency can justify; 60 ms because
    /// nothing plausible on a Core Audio output path is slower than that and a
    /// runaway estimate would tear open the seam it exists to close.
    static let bounds: ClosedRange<Double> = 0...60

    /// How much of each new measurement is folded in. Slow enough that one bad
    /// seam (a sparse intro, a correlator that found the wrong bar but scored
    /// well) moves the applied compensation by under a millisecond; fast enough
    /// that a device change is absorbed in a handful of hand-overs.
    static let smoothing: Double = 0.3

    /// The compensation the next head splice will apply, in milliseconds.
    var headMilliseconds: Double = SeamLatencyCalibration.fieldDefaultMilliseconds
    /// How many trusted measurements have been folded into it.
    var headCount: Int = 0

    /// The tail's running estimate — **kept, and never applied**.
    ///
    /// The tail hands the segment back to a deck whose time-pitch unit is at
    /// exactly ×1.0, i.e. a pass-through with no latency to compensate, and the
    /// field measures it at −0.5 and +4.7 ms: inside the half-millisecond-per-
    /// sample noise of the method plus one file seek. Compensating a residual
    /// that small would be fitting the measurement's own error into the audio.
    /// So the number is journalled, shown in the panel, and left alone; if a
    /// device ever puts it consistently outside ±`tailConcern` ms, the record
    /// to act on will already exist.
    var tailMilliseconds: Double = 0
    var tailCount: Int = 0

    /// Where a tail offset stops being noise and starts being a finding.
    /// Nothing acts on it; it decides whether the journal says so out loud.
    static let tailConcern: Double = 3

    /// Fold a trusted head measurement in.
    ///
    /// The argument is the **implied latency**, not the raw offset: a seam that
    /// already applied 19 ms of compensation and still measured +0.3 ms implies
    /// 19.3 ms, and it is that total the next seam needs. Feeding the residual
    /// in directly would drive the estimate to zero over a few seams and bring
    /// the flam back.
    mutating func foldHead(impliedMilliseconds: Double) {
        headMilliseconds = Self.folded(headMilliseconds, impliedMilliseconds,
                                       first: headCount == 0)
        headCount += 1
    }

    /// The same bookkeeping for the tail, which is observation only.
    mutating func foldTail(impliedMilliseconds: Double) {
        tailMilliseconds = Self.folded(tailMilliseconds, impliedMilliseconds,
                                       first: tailCount == 0, clamped: false)
        tailCount += 1
    }

    /// The EMA, with one deliberate exception: the *first* trusted measurement
    /// on a machine replaces the estimate outright instead of nudging the
    /// shipped default 30 % of the way. The default is a number from somebody
    /// else's audio device; the first measurement is a number from this one,
    /// and there is no reason to spend six seams crawling towards it.
    private static func folded(_ current: Double, _ measured: Double,
                               first: Bool, clamped: Bool = true) -> Double {
        let next = first ? measured : current + smoothing * (measured - current)
        guard clamped else { return next }
        return min(max(next, bounds.lowerBound), bounds.upperBound)
    }
}

/// The calibration, and the last thing measured, in the one place both the
/// engine (which writes them from its serial queue and from a measurement hop)
/// and the debug panel (which reads them on the main actor) can reach.
///
/// A lock rather than an actor because the engine's callers are synchronous
/// queue-confined code that must not await, and the payload is three doubles:
/// the contention is a hand-over every few minutes against a panel redraw.
final class SeamLatencyStore: @unchecked Sendable {

    static let shared = SeamLatencyStore()

    /// What the panel draws and a feedback line quotes.
    struct Report: Equatable, Sendable {
        var calibration = SeamLatencyCalibration()
        /// The most recent head offset, as `+0.3ms (corr 0.98/0.97)` or an
        /// `unmeasured(...)` reason. Nil before the first splice of a session.
        var lastHead: String?
        var lastTail: String?
        /// What the last armed splice actually applied, in milliseconds, and
        /// whether it came from the manual pin.
        var appliedMilliseconds: Double?
        var pinned = false
    }

    private static let key = "automix.seam.latency"

    private let lock = NSLock()
    private var report: Report
    private var observer: (@Sendable (Report) -> Void)?

    private init() {
        var restored = Report()
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode(SeamLatencyCalibration.self, from: data) {
            restored.calibration = stored
        }
        report = restored
    }

    var current: Report {
        lock.lock(); defer { lock.unlock() }
        return report
    }

    /// The compensation to apply to the next head splice: the manual pin when
    /// one is set, otherwise what the machine has learned. Clamped either way —
    /// a pin typed into the panel is still not allowed to invert the seam.
    func headCompensationSeconds(pin: Double?) -> TimeInterval {
        let bounds = SeamLatencyCalibration.bounds
        let milliseconds = pin ?? current.calibration.headMilliseconds
        return min(max(milliseconds, bounds.lowerBound), bounds.upperBound) / 1000
    }

    /// Called by the service so the panel can mirror this without the engine
    /// having to know the panel exists.
    func observe(_ block: (@Sendable (Report) -> Void)?) {
        lock.lock()
        observer = block
        let snapshot = report
        lock.unlock()
        block?(snapshot)
    }

    func noteArmed(milliseconds: Double, pinned: Bool) {
        mutate {
            $0.appliedMilliseconds = milliseconds
            $0.pinned = pinned
        }
    }

    func noteHead(_ description: String) { mutate { $0.lastHead = description } }
    func noteTail(_ description: String) { mutate { $0.lastTail = description } }

    /// Fold a trusted measurement in and persist. Returns the calibration as it
    /// now stands, for the journal line.
    @discardableResult
    func foldHead(impliedMilliseconds: Double) -> SeamLatencyCalibration {
        var result = SeamLatencyCalibration()
        mutate {
            $0.calibration.foldHead(impliedMilliseconds: impliedMilliseconds)
            result = $0.calibration
        }
        persist(result)
        return result
    }

    @discardableResult
    func foldTail(impliedMilliseconds: Double) -> SeamLatencyCalibration {
        var result = SeamLatencyCalibration()
        mutate {
            $0.calibration.foldTail(impliedMilliseconds: impliedMilliseconds)
            result = $0.calibration
        }
        persist(result)
        return result
    }

    private func mutate(_ body: (inout Report) -> Void) {
        lock.lock()
        body(&report)
        let snapshot = report
        let observer = self.observer
        lock.unlock()
        observer?(snapshot)
    }

    private func persist(_ calibration: SeamLatencyCalibration) {
        guard let data = try? JSONEncoder().encode(calibration) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
/// The splice arm's clock arithmetic, in one pure function because it is the
/// only thing standing between a measured latency and audible audio — and
/// because every term in it was got wrong at least once in the field.
enum SeamRelease {

    /// When to release the segment, as seconds from `now`.
    ///
    /// - `rawLead` is what `nodeTime(forPlayerTime:)` said: the interval until
    ///   the outgoing deck's `spliceStart` frame, extrapolated at the player
    ///   node's own sample rate.
    /// - `deckRate` corrects that. The node's sample time advances in *source*
    ///   frames, and a deck the tempo glide has bent to ×1.02 consumes them
    ///   2 % faster than wall clock, so the real interval is `rawLead / rate`.
    ///   Identity at unity, which is every plan without a ramp.
    /// - `compensation` is the new term: the live deck's audio comes out of the
    ///   graph this much *after* its player clock says it did, so the segment —
    ///   which has no such delay — has to be held back by the same amount for
    ///   the two to be the same audio at the same instant.
    ///
    /// Never negative: a lead that has already passed is released immediately
    /// rather than in the past, which is what `play(at:)` does with a stale host
    /// time anyway and is the caller's cue that the arm was too late.
    static func lead(rawLead: TimeInterval, deckRate: Double,
                     compensation: TimeInterval) -> TimeInterval {
        let rate = deckRate.isFinite && deckRate > 0.001 ? deckRate : 1
        return max(0, rawLead / rate + compensation)
    }
}
#endif
