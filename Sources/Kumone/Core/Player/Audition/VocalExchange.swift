#if os(macOS)
import Foundation

// The `vocalExchange` template: from "these two are both singing" to four
// scheduled gain curves.
//
// The planner can decide that a pair *wants* a vocal hand-off — that is a rule
// about two vocal-activity contours, and it has both. It cannot decide *where*
// the hand-off goes, because that is a question about a sung phrase: the
// outgoing singer should finish the line, and the line ends where the next
// lyric timestamp says it does. `TransitionPlanner` is a pure function of two
// `TrackAnalysis` values and has never heard a word. So the planner emits
// `.vocalExchange` as a marker and this compiles it, here in the decision
// layer, where the `.lrc` sidecar is one file read away.
//
// Everything it produces is a plain `StemEnvelope`. There is no
// "exchange renderer": the template is one producer of the general contract,
// exactly like an AI's hand-written `stemEnvelope`, and the renderer cannot
// tell them apart.

extension Audition {

    /// What compiling a `.vocalExchange` came to, in enough detail for the
    /// console to say *why* the hand-over landed where it did.
    public struct ExchangeCompilation: Sendable, Equatable {
        /// Seconds into the overlap where the vocal changes hands.
        public let handover: TimeInterval
        /// The same instant in the outgoing track's own timeline.
        public let handoverAbsolute: TimeInterval
        /// `"lyric"` — a lyric line ends here; `"vocalTrough"` — no usable
        /// lyrics, so the outgoing vocal contour's quietest mid-overlap second;
        /// `"duck"` — neither was available and the technique degraded.
        public let source: String
        /// The outgoing line the singer finishes on, when `source == "lyric"`.
        public let lyricLine: String?
        /// Where the clamp moved the raw candidate to, if it did.
        public let clampedFrom: TimeInterval?
        /// Why the compile degraded to `.vocalDuck`, phrased for the console.
        public let fallbackReason: String?
        /// The compiled curves; nil exactly when `fallbackReason` is set.
        public let envelope: StemEnvelope?
        /// Seconds into the overlap where the *floor* changes decks — the other
        /// clock. Reported alongside `handover` because the whole gesture is
        /// the relationship between the two, and a report that gives only L
        /// cannot say which gesture it is looking at.
        public var swapOffset: TimeInterval = 0
        /// Which of the two named gestures this compiled to, or nil when the
        /// two-clock rule never ran (knob off, or no lyric line-end to place
        /// against a swap — the contour and duck paths are unchanged).
        public var gesture: Gesture?
        /// The stretch over which the *incoming* vocal is held at
        /// `incomingVocalMutedDB` while the outgoing singer carries the line
        /// over the incoming deck's bed — `(S, L]`, and set only for
        /// `.carryover`. Nil for every other outcome.
        public var incomingDuckWindow: ClosedRange<TimeInterval>?
        /// The weakest level the carried outgoing vocal actually reaches, in dB
        /// relative to its pre-swap level. 0 means the compensation held the
        /// voice flat all the way to L; negative means it saturated at
        /// `compensationCeilingDB` and the last of the line rode the outgoing
        /// fader down by this much.
        ///
        /// Since `compensationCeilingDB` was lifted off `StemEnvelope.maxGainDB`
        /// this is 0 for every geometry the template can compile, and it stays
        /// here — and in the journal — as the standing check that it is.
        public var carryShortfallDB: Float = 0
        /// How long the two voices take to change places once the line is over
        /// — the whole of the gesture's gradualness, and at most one beat. The
        /// outgoing vocal is at full level up to `handover` and silent
        /// `handoverCrossSeconds` later; see `VocalExchange.exchangeDB`.
        public var handoverCrossSeconds: TimeInterval = 0

        /// Seconds into the overlap where the **incoming** vocal is released —
        /// the second clock this compile reads. Equal to `handover` whenever
        /// the incoming track has no `.lrc` (or none of its lines start inside
        /// the overlap), which is field-for-field the single-clock behaviour;
        /// later than `handover` when the new singer's own line starts later,
        /// so the incoming voice never enters mid-line.
        public var incomingRelease: TimeInterval = 0
        /// The incoming line the new singer enters on, when one was found.
        public var incomingLine: String?
        /// How the two instants were chosen:
        /// `"pair"` — an outgoing line end and an incoming line start were
        /// found within a beat of each other, so the exchange is one singer
        /// finishing as the other starts;
        /// `"nextLine"` — no such pair, so L is today's pick and the incoming
        /// voice waits for its own next line start;
        /// `"handover"` — no incoming lyric line to wait for, so the incoming
        /// voice is released at L exactly as it always was.
        public var pairSource: String = "handover"
    }

    /// The two named ways a vocal hand-over can sit against the floor swap.
    public enum Gesture: String, Sendable, Equatable, Codable {
        /// 人声唱完才走: L > S. The outgoing voice rides past the floor swap on
        /// the incoming deck's bed and retires when its line ends.
        case carryover = "vocalCarryover"
        /// 人声先行: L ≤ S. The outgoing voice retires first and the floor swap
        /// then lands on a bar nobody is singing over.
        case yield = "vocalYield"

        /// How the console says it.
        public var chineseLabel: String {
            switch self {
            case .carryover: return "人声唱完才走"
            case .yield: return "人声先行"
            }
        }
    }

    enum VocalExchange {

        // MARK: - Template shape
        //
        // The numbers below are the template's whole taste, so they are named
        // and justified rather than sprinkled through the builder.

        /// The outgoing bed steps back early so the incoming one has somewhere
        /// to go — a bed swap that waits for the vocal swap makes the middle of
        /// the overlap the loudest part of it.
        ///
        /// −3 dB rather than the −9 the first draft used, and −8 rather than
        /// −30 at the hand-over, because of what the corpus said. Measured on
        /// 恋愛サーキュレーション → 春を告げる at a 16 s overlap, the −9/−30
        /// shape put an 11 dB crater in the middle of the hand-over (against
        /// 3 dB for the plain crossfade of the same seam): the outgoing deck is
        /// already being faded, so −30 dB of bed on top of that is silence, and
        /// the incoming track's opening bars there are *vocal-dominated* — with
        /// the incoming vocal correctly muted until the hand-over, almost
        /// nothing was left holding the middle up. The bed's job before the
        /// hand-over is not to get out of the way (the fader does that); it is
        /// to keep a floor under the outgoing singer until the singer leaves.
        /// So it steps back audibly and only collapses once the vocal has gone.
        /// The ablation, worst 1 s window relative to the take's own opening:
        /// −9/−30 −11.1 dB, −3/−8 −9.8 dB, −3/−8 with the incoming bed lift
        /// below −8.8 dB, plain crossfade −3.2 dB.
        static let bedEarlyShare: Double = 0.4
        static let bedEarlyDB: Float = -3
        static let bedAtHandoverDB: Float = -8
        /// Once the outgoing vocal has retired the bed follows it out, −30 dB
        /// (under any bed) and then away.
        static let bedRetiredDB: Float = -30
        static let bedAfterHandoverDB: Float = -40
        /// How long *the bed* takes to follow the singer out once the line is
        /// done. A bed lane is allowed a slope — it is furniture, and collapsing
        /// it on the same instant the voice leaves would make the hand-over a
        /// hole. The **vocal** lane no longer uses this: see
        /// `handoverCrossMinSeconds`.
        static let bedRetireSeconds: TimeInterval = 0.8
        /// The incoming bed comes in at its own level — the incoming fader is
        /// near zero at the top of the overlap, so an extra attenuation there
        /// buys nothing and measurably costs energy later — and is then pushed
        /// `incomingBedLiftDB` up over the stretch where it is the *only* bed
        /// under the outgoing singer (the outgoing bed has stepped back and the
        /// incoming vocal is still muted), releasing back to its own level as
        /// soon as the new vocal arrives to sit on it. Worth 1–2 dB exactly
        /// where the corpus ablation found the hand-over thinnest.
        static let incomingBedLiftShare: Double = 0.5
        static let incomingBedLiftDB: Float = 3
        /// The incoming vocal is inaudible until the hand-over (−40 dB) and
        /// arrives inside the exchange window, not on a ramp of its own.
        static let incomingVocalMutedDB: Float = -40
        /// How long the *incoming bed* takes to release its lift once the new
        /// singer has landed on it. A bed number, like `bedRetireSeconds`; the
        /// incoming vocal is no longer faded in over it.
        static let incomingRiseSeconds: TimeInterval = 1.0

        // MARK: The hand-over window
        //
        // **人声不做渐弱.** The outgoing singer holds full audible level right
        // up to the end of the line and then leaves inside one short window,
        // rather than receding through the overlap. Everything gradual in this
        // template is a *bed*; the two vocal lanes are a plateau and an
        // exchange, and nothing else.
        //
        // The window is not zero, and the reason is arithmetic rather than
        // taste. The vocal stem carries real energy down to the fundamental of
        // a low voice — call it 80 Hz, a 12.5 ms period — and a gain that moves
        // across less than a cycle is a step discontinuity in the waveform,
        // which is a broadband click no matter how correct the level either
        // side of it is. It also has to cover the *tail* of the sung line: a
        // breath, a consonant release, the room. `handoverCrossMinSeconds` is
        // ten periods of that 80 Hz — the gain moves over whole cycles, and a
        // held syllable's decay is not chopped — while still being under a
        // seventh of the 0.8 s retire it replaces, which is what stops it
        // reading as a fade.

        /// Floor on the exchange window: ten cycles of an 80 Hz fundamental.
        static let handoverCrossMinSeconds: TimeInterval = 0.12
        /// Ceiling on it. Past about a third of a second a vocal exchange stops
        /// sounding like one line ending and the next beginning, and starts
        /// sounding like the crossfade this change exists to remove — so a very
        /// slow track does not get to spend a whole lazy beat on it.
        static let handoverCrossMaxSeconds: TimeInterval = 0.35

        /// The exchange window for one geometry: **half a beat**, clamped into
        /// `[handoverCrossMinSeconds, handoverCrossMaxSeconds]` and never longer
        /// than a whole beat, so the promise "the hand-over is over inside a
        /// beat" holds at any tempo. A plain crossfade has no grid to ask, and
        /// takes the ceiling.
        static func handoverCrossSeconds(beat: TimeInterval?) -> TimeInterval {
            guard let beat, beat > 0 else { return handoverCrossMaxSeconds }
            let half = Swift.min(handoverCrossMaxSeconds,
                                 Swift.max(handoverCrossMinSeconds, beat / 2))
            return Swift.min(beat, half)
        }

        /// The equal-power pair at fraction `u` of the exchange window, in dB.
        ///
        /// `cos`/`sin` so that `out² + in² == 1` right across the window: two
        /// voices meeting at −3 dB would read as a duet for those few
        /// milliseconds, and two voices meeting at −6 would put a hole where the
        /// line ends. Equal power is the one law under which the seam is neither.
        static func exchangeDB(_ u: Double) -> (out: Float, incoming: Float) {
            let angle = Swift.min(1, Swift.max(0, u)) * Double.pi / 2
            func dB(_ amplitude: Double) -> Float {
                amplitude <= 1e-6
                    ? StemEnvelope.minGainDB
                    : Swift.max(StemEnvelope.minGainDB, Float(20 * log10(amplitude)))
            }
            return (dB(cos(angle)), dB(sin(angle)))
        }

        /// Fractions of the exchange window the two vocal lanes are sampled on,
        /// besides its two ends. Three points hold linear-in-dB interpolation
        /// within ~0.3 dB of the continuous cosine, which over 120–350 ms is
        /// well under the level a listener could pick out — and it leaves the
        /// carried shape inside `StemEnvelope.maxBreakpoints`.
        static let exchangeFractions: [Double] = [1.0 / 3, 2.0 / 3]

        /// How many points the compensated outgoing-vocal plateau is sampled on.
        /// The compensation follows an equal-power cosine; six points across it
        /// hold the *audible* level within 0.08 dB of flat, which is what
        /// `theOutgoingVocalNeverRecedesBeforeTheLineEnds` pins. Five is
        /// visibly worse (0.12 dB) and there is room for six.
        static let holdSamples = 6

        /// Ceiling on how far a lane may be lifted to cancel the fade it is
        /// riding on.
        ///
        /// **This is not a taste, and it used to be one.** It was
        /// `StemEnvelope.maxGainDB` — 6 dB, the bound on what an *author* may
        /// ask for — and that made the promise of the technique false wherever
        /// the outgoing fader fell further than 6 dB before the line ended. On
        /// a plain equal-power exit that is 0.63 of the overlap, so a carryover
        /// whose L sits anywhere near the 0.85 share ceiling had the singer
        /// riding the fader down for the last several seconds of the phrase:
        /// measured on the field geometry (20 s overlap, S = 10 s, L = 16 s)
        /// the carried voice was 4.2 dB down by the last syllable, and 用户
        /// heard exactly that. **人声唱完之前不做任何衰减** is the rule, and a
        /// ceiling that clips `1/fader` cannot keep it.
        ///
        /// So the ceiling is now past any fader a hand-over can reach — the
        /// worst case the template allows is about 13 dB — and its only job is
        /// to be a number rather than an infinity when the fader reaches zero.
        /// `faderFloor` is what actually stops the division running away; this
        /// is its dB image, and the two are kept consistent by construction.
        static let compensationCeilingDB: Float = StemEnvelope.maxCompensatedGainDB

        /// The numerical guard: never divide by a fader below this. −40 dB is
        /// `compensationCeilingDB`, so the two limits are the same limit said
        /// twice, and a deck this far down is inaudible under the incoming one
        /// regardless of what the lane asks for.
        static let faderFloor: Float = 0.01

        // MARK: - Compilation

        /// Compile `.vocalExchange` for one hand-over.
        ///
        /// Returns the technique the render should actually use — `.custom`
        /// with the compiled curves, or `.vocalDuck` when there was nothing to
        /// aim at — together with the story of how it got there.
        ///
        /// `incomingURL` is the **second clock**: the incoming track's `.lrc`,
        /// read the same way the outgoing one is, so the hand-over can be a
        /// pair of instants (one line ending, the next beginning) rather than
        /// one. Nil — or a track with no sidecar — is exactly the single-clock
        /// compile this function has always produced.
        static func compile(outgoingURL: URL, incomingURL: URL? = nil,
                            outgoing: TrackAnalysis,
                            planned: PlannedTransition,
                            config: TransitionPlanner.Config)
            -> (technique: StemTechnique, compilation: ExchangeCompilation) {
            let geometry = TransitionAutomation.Geometry(plan: planned.plan)
            let overlap = geometry.overlapDuration
            let outPoint = planned.plan.outPoint ?? 0

            func degrade(_ reason: String) -> (StemTechnique, ExchangeCompilation) {
                (.vocalDuck(depthDB: Float(-abs(config.stemDuckDepthDB))),
                 ExchangeCompilation(handover: 0, handoverAbsolute: outPoint,
                                     source: "duck", lyricLine: nil, clampedFrom: nil,
                                     fallbackReason: reason, envelope: nil,
                                     swapOffset: geometry.swapOffset))
            }

            guard overlap > 1 else {
                return degrade("这次叠加只有 \(String(format: "%.2f", overlap)) 秒，"
                               + "排不下一次人声交接，已降级为 vocal duck。")
            }

            let low = overlap * min(config.stemExchangeHandoverMin,
                                    config.stemExchangeHandoverMax)
            let high = overlap * max(config.stemExchangeHandoverMin,
                                     config.stemExchangeHandoverMax)

            var handover: TimeInterval
            var source: String
            var line: String?
            var clampedFrom: TimeInterval?
            var gesture: Gesture?

            // The floor clock. Everything below asks where L sits relative to
            // this, and nothing below moves it: the swap is the plan's, decided
            // by the low end and the staged EQ, and the vocal is the thing that
            // gets to disagree with it.
            let swap = geometry.swapOffset

            let ends = twoClockExchangeAvailable(config)
                ? lyricLineEnds(outgoingURL: outgoingURL, outgoing: outgoing,
                                outPoint: outPoint, overlap: overlap)
                : []

            // The second clock. The incoming deck runs at its own rate, so its
            // lyric stamps are mapped through `(t − inPoint) / rateIn` before
            // anything compares them with the outgoing side's.
            let starts = incomingLineStarts(incomingURL: incomingURL,
                                            plan: planned.plan, overlap: overlap)
            // How far apart "one line ends" and "the next begins" may be and
            // still be the same gesture: a beat, or the exchange window itself
            // when the grid is faster than that.
            let crossWindow = handoverCrossSeconds(beat: geometry.outgoingBeatDuration)
            let pairTolerance = Swift.max(geometry.outgoingBeatDuration ?? crossWindow,
                                          crossWindow)
            var release: TimeInterval?
            var incomingLine: String?
            var pairSource = "handover"

            if let pair = pairPick(ends, starts: starts, swap: swap, low: low, high: high,
                                   carryWindow: config.vocalCarryWindowSeconds,
                                   tolerance: pairTolerance) {
                // Both clocks agreed: the old singer's line ends where the new
                // singer's begins, which is the whole gesture in one instant.
                handover = pair.end
                source = "lyric"
                line = pair.line
                gesture = pair.gesture
                release = pair.start
                incomingLine = pair.startLine
                pairSource = "pair"
            } else if let pick = twoClockPick(ends, swap: swap, low: low, high: high,
                                              carryWindow: config.vocalCarryWindowSeconds) {
                handover = pick.seconds
                source = "lyric"
                line = pick.line
                gesture = pick.gesture
            } else if let pick = lyricHandover(outgoingURL: outgoingURL, outgoing: outgoing,
                                               outPoint: outPoint, overlap: overlap) {
                // Either the knob is off, or the two-clock rule found nothing on
                // *either* side of the swap inside the window. Today's pick —
                // the line-end nearest the middle — and then the gesture is
                // read off wherever it happened to land, which is exactly the
                // accidental behaviour this change makes deliberate elsewhere.
                handover = pick.seconds
                source = "lyric"
                line = pick.line
            } else if let trough = vocalTrough(outgoing, outPoint: outPoint,
                                               from: low, to: high) {
                handover = trough
                source = "vocalTrough"
            } else {
                return degrade("这首出曲既没有 .lrc 歌词，也没有可用的人声活跃度曲线，"
                               + "定不出交接句，已降级为 vocal duck。")
            }

            let clamped = Swift.min(Swift.max(handover, low), high)
            if abs(clamped - handover) > 1e-6 { clampedFrom = handover }
            handover = clamped

            // A gesture the two-clock rule did not name (fallback pick, or the
            // contour) still gets labelled once L is final — but only when the
            // rule was allowed to run at all, so the knob-off compile and the
            // contour/duck degradations report exactly what they always did.
            if gesture == nil, twoClockExchangeAvailable(config), source == "lyric" {
                gesture = handover > swap + 1e-6 ? .carryover : .yield
            }

            // The incoming vocal's own instant. Never before L — the two voices
            // must not overlap — and never *inside* a line the new singer has
            // already begun, which is the seam the field recording caught: an
            // incoming rap track singing every 1.6 s from its in-point had its
            // first 8.4 s of vocal muted and was then released mid-line. When
            // no pair was found, the release therefore walks forward to the
            // first incoming line start at or after L; when the incoming track
            // has no words inside the overlap it stays at L, exactly as before.
            let crossAtL = Swift.min(crossWindow, overlap - handover)
            let releaseCeiling = Swift.max(handover, overlap - crossAtL)
            var incomingRelease = Swift.max(handover, release ?? handover)
            if release == nil,
               let next = starts.first(where: {
                   $0.start >= handover - 1e-6 && $0.start <= releaseCeiling + 1e-6
               }) {
                incomingRelease = next.start
                incomingLine = next.text
                pairSource = "nextLine"
            }
            incomingRelease = Swift.min(Swift.max(incomingRelease, handover), releaseCeiling)

            // Only a carryover splits the clocks; a yield *is* the single-clock
            // shape, because a hand-over that finishes before the swap has
            // nothing to carry across it.
            let carryFrom = gesture == .carryover ? swap : nil
            let envelope = template(overlap: overlap, handover: handover,
                                    plan: planned.plan, style: planned.style,
                                    geometry: geometry, carryFrom: carryFrom,
                                    incomingRelease: incomingRelease)
            let cross = handoverCrossSeconds(beat: geometry.outgoingBeatDuration)
            let shortfall = carryFrom.map {
                carryShortfallDB(from: $0, to: handover, plan: planned.plan,
                                 style: planned.style, geometry: geometry)
            } ?? 0
            // What the journal has to be able to say, now that the vocal lane
            // is a plateau rather than a fade: *where* the line ends and how
            // little of a beat the voices spend changing places. A `plan armed
            // … stem=custom(<digest>)` line cannot say either.
            //
            // And, since the carried voice's flatness is now a claim rather
            // than a hope: `hold=` is the biggest lift the plateau asks for and
            // `shortfall=` is what it could not get. `shortfall=0.0dB` is the
            // whole promise, checkable in the field from one line of log; a
            // negative number there is the singer receding, and the number is
            // by how much.
            //
            // And, since the *incoming* voice now has a clock of its own,
            // `in@…s (<pairSource>)`: the one field that says whether deck B's
            // singer was let in on its own line or on the outgoing track's.
            PlaybackJournal.note(String(
                format: "vocalExchange vocal hold-to-line-end @%.2fs (%@) "
                    + "cross=%.0fms swap=%.2fs hold=%.1fdB shortfall=%.1fdB%@"
                    + " in@%.2fs (%@)",
                handover, source, Swift.min(cross, overlap - handover) * 1000, swap,
                peakCompensationDB(envelope, upTo: handover), shortfall,
                gesture.map { " \($0.rawValue)" } ?? "",
                incomingRelease, pairSource))
            return (.custom(envelope),
                    ExchangeCompilation(handover: handover,
                                        handoverAbsolute: outPoint + handover,
                                        source: source, lyricLine: line,
                                        clampedFrom: clampedFrom,
                                        fallbackReason: nil, envelope: envelope,
                                        swapOffset: swap, gesture: gesture,
                                        incomingDuckWindow: carryFrom.map { $0...handover },
                                        carryShortfallDB: shortfall,
                                        handoverCrossSeconds:
                                            Swift.min(cross, overlap - handover),
                                        incomingRelease: incomingRelease,
                                        incomingLine: incomingLine,
                                        pairSource: pairSource))
        }

        /// The rule only has anything to say when there is a swap to be on
        /// either side of. A degenerate geometry (swap at 0, or at the very end)
        /// leaves both windows empty anyway, so this is a readability guard
        /// rather than a behavioural one.
        static func twoClockExchangeAvailable(_ config: TransitionPlanner.Config) -> Bool {
            config.twoClockExchange
        }

        // MARK: - Two clocks

        /// Pick L against S, and name the gesture.
        ///
        /// Carryover wins outright when it is available, because it is the
        /// gesture with something to say: the voice outliving the floor under
        /// it is the DJ move, and yielding is what you do when the phrasing
        /// will not let you. Among several line-ends past the swap the
        /// **earliest** wins — carrying longer than the phrase requires only
        /// spends more of the compensation headroom (`compensationCeilingDB`)
        /// for no extra gesture.
        ///
        /// Yield takes the **latest** line-end at or before S for the mirror
        /// reason: the voice should hold the floor for as long as it still owns
        /// it, and only then hand a vocal-free bar to the swap.
        static func twoClockPick(_ ends: [(end: TimeInterval, text: String)],
                                 swap: TimeInterval, low: TimeInterval, high: TimeInterval,
                                 carryWindow: TimeInterval)
            -> (seconds: TimeInterval, line: String, gesture: Gesture)? {
            // The carry window is bounded on both sides by things that are not
            // it: below by the share floor (a swap earlier than 0.30 of the
            // overlap would otherwise let L sit before the window opens) and
            // above by the share ceiling, which on a typical geometry is the
            // binding one long before `carryWindow` is.
            let carryLow = Swift.max(swap, low)
            let carryHigh = Swift.min(swap + Swift.max(0, carryWindow), high)
            let carried = ends.filter { $0.end > carryLow + 1e-6 && $0.end <= carryHigh + 1e-6 }
            if let first = carried.min(by: { $0.end < $1.end }) {
                return (first.end, first.text, .carryover)
            }
            let yielded = ends.filter { $0.end >= low - 1e-6 && $0.end <= swap + 1e-6 }
            if let last = yielded.max(by: { $0.end < $1.end }) {
                return (last.end, last.text, .yield)
            }
            return nil
        }

        /// Pick L from **both** clocks: the earliest outgoing line end that has
        /// an incoming line start landing on it.
        ///
        /// The eligible ends are exactly `twoClockPick`'s — the carry window
        /// past S and the yield window before it, both inside `[low, high]` —
        /// so this rule can never aim somewhere the single-clock rule was not
        /// already allowed to aim. What it adds is the second condition:
        /// `0 ≤ Li − Lo ≤ tolerance`, the new singer's line starting as the old
        /// one's ends. Among the pairs that qualify the **earliest** Lo wins,
        /// which is the shortest stretch with deck B's voice muted — the exact
        /// complaint the field seams produced ("deck B 的人声接入太迟了").
        ///
        /// Nil when no pair exists, and then `compile` falls back to today's
        /// single-clock pick with the incoming release walked to its own next
        /// line.
        static func pairPick(_ ends: [(end: TimeInterval, text: String)],
                             starts: [(start: TimeInterval, text: String)],
                             swap: TimeInterval, low: TimeInterval, high: TimeInterval,
                             carryWindow: TimeInterval, tolerance: TimeInterval)
            -> (end: TimeInterval, line: String, start: TimeInterval,
                startLine: String, gesture: Gesture)? {
            guard !ends.isEmpty, !starts.isEmpty else { return nil }
            let carryLow = Swift.max(swap, low)
            let carryHigh = Swift.min(swap + Swift.max(0, carryWindow), high)
            // One eligible set, ordered by time: the earliest Lo wins outright,
            // whichever window it came from. (`twoClockPick` prefers a carry
            // over a yield because it is choosing between two *gestures* with
            // nothing else to separate them; here the second clock is the
            // separator, and "the shortest mute" is the rule the user asked
            // for.)
            let eligible = ends
                .filter {
                    ($0.end > carryLow + 1e-6 && $0.end <= carryHigh + 1e-6)
                        || ($0.end >= low - 1e-6 && $0.end <= swap + 1e-6)
                }
                .sorted { $0.end < $1.end }
            for candidate in eligible {
                guard let match = starts.first(where: {
                    $0.start >= candidate.end - 1e-6
                        && $0.start <= candidate.end + tolerance + 1e-6
                }) else { continue }
                return (candidate.end, candidate.text, Swift.max(match.start, candidate.end),
                        match.text,
                        candidate.end > swap + 1e-6 ? .carryover : .yield)
            }
            return nil
        }

        /// The lift, in dB, that exactly cancels `fader` — clamped at zero
        /// below (the lane never *ducks* the voice to follow a fader up) and at
        /// `compensationCeilingDB` above, which after the ceiling change is a
        /// numerical guard rather than a musical limit.
        static func compensationDB(_ fader: Float) -> Float {
            let db = Float(-20 * log10(Double(Swift.max(fader, faderFloor))))
            return Swift.min(compensationCeilingDB, Swift.max(0, db))
        }

        /// How much level the carried voice loses at L, once the compensation
        /// has hit its ceiling.
        ///
        /// The compensated lane holds `vocal × (1/fader)`, and the ceiling it
        /// is capped at now sits past any fader a hand-over reaches — so this
        /// is 0 for every geometry the template can be asked for, and stays in
        /// the report (and now in the journal) as the assertion that it is:
        /// a non-zero number here means the fader went somewhere
        /// `compensationCeilingDB` did not follow, and the singer receded.
        static func carryShortfallDB(from swap: TimeInterval, to handover: TimeInterval,
                                     plan: TransitionPlan, style: TransitionStyle,
                                     geometry: TransitionAutomation.Geometry) -> Float {
            let fader = TransitionAutomation.frame(plan: plan, style: style,
                                                   elapsed: handover, geometry: geometry)
                .outgoing.fader
            let wanted = Float(-20 * log10(Double(Swift.max(fader, faderFloor))))
            return Swift.min(0, compensationCeilingDB - wanted)
        }

        /// The largest lift the compiled outgoing-vocal plateau asks for, in dB
        /// — how hard the compensation had to work to keep the promise. Read
        /// off the lane rather than recomputed, so the journal reports the
        /// curve that will actually be rendered.
        static func peakCompensationDB(_ envelope: StemEnvelope,
                                       upTo handover: TimeInterval) -> Float {
            envelope.outgoingVocal
                .filter { $0.t <= handover + 1e-6 }
                .reduce(Float(0)) { Swift.max($0, $1.gainDB) }
        }

        // MARK: - Where the phrase ends

        /// The outgoing lyric line-end nearest the middle of the overlap.
        ///
        /// A line *ends* where the next one starts — an `.lrc` only stamps
        /// beginnings — so this walks pairs. The final line has no successor,
        /// and gets the point where the vocal contour has fallen away instead,
        /// which is the same question asked of a different signal.
        static func lyricHandover(outgoingURL: URL, outgoing: TrackAnalysis,
                                  outPoint: TimeInterval, overlap: TimeInterval)
            -> (seconds: TimeInterval, line: String)? {
            let inside = lyricLineEnds(outgoingURL: outgoingURL, outgoing: outgoing,
                                       outPoint: outPoint, overlap: overlap)
            let middle = overlap / 2
            guard let best = inside.min(by: {
                abs($0.end - middle) < abs($1.end - middle)
            }) else { return nil }
            return (best.end, best.text)
        }

        /// Every outgoing lyric line-end inside this overlap, in
        /// overlap-relative seconds.
        ///
        /// Only ends that actually fall inside the overlap are candidates:
        /// clamping a line-end from a minute away would produce a number that
        /// is not a phrase boundary at all, which is worse than saying "no
        /// lyrics here" and letting the contour decide.
        static func lyricLineEnds(outgoingURL: URL, outgoing: TrackAnalysis,
                                  outPoint: TimeInterval, overlap: TimeInterval)
            -> [(end: TimeInterval, text: String)] {
            guard let lines = Lyrics.load(for: outgoingURL), !lines.isEmpty else { return [] }
            var ends: [(end: TimeInterval, text: String)] = []
            for (index, line) in lines.enumerated() {
                if index + 1 < lines.count {
                    ends.append((lines[index + 1].time, line.text))
                } else if let decay = vocalDecay(outgoing, after: line.time) {
                    ends.append((decay, line.text))
                }
            }
            return ends
                .filter { $0.end >= outPoint && $0.end <= outPoint + overlap }
                .map { (end: $0.end - outPoint, text: $0.text) }
        }

        /// Where the **incoming** track's lines begin, in overlap-relative
        /// seconds.
        ///
        /// The mirror of `lyricLineEnds`, with the one difference the geometry
        /// forces: the incoming deck is played at `incomingRate`, so a stamp a
        /// second into the song does not arrive a second into the overlap. The
        /// map is `(lyricT − inPoint) / rateIn`, and only stamps that land
        /// inside the overlap are candidates — a line start from elsewhere in
        /// the song is not an instant this hand-over can aim at.
        static func incomingLineStarts(incomingURL: URL?, plan: TransitionPlan,
                                       overlap: TimeInterval)
            -> [(start: TimeInterval, text: String)] {
            guard let incomingURL, let lines = Lyrics.load(for: incomingURL), !lines.isEmpty
            else { return [] }
            let inPoint: TimeInterval
            var rate: Double = 1
            switch plan {
            case .beatMatched(let p):
                inPoint = p.inPoint
                if p.incomingRate > 0 { rate = Double(p.incomingRate) }
            case .crossfade(_, _, let point): inPoint = point
            case .gapless: return []
            }
            return lines
                .map { (start: ($0.time - inPoint) / rate, text: $0.text) }
                .filter { $0.start >= 0 && $0.start <= overlap }
                .sorted { $0.start < $1.start }
        }

        /// Where the vocal contour has dropped to 60 % of its level at `time` —
        /// the last line's stand-in for "the next line's timestamp".
        static func vocalDecay(_ a: TrackAnalysis, after time: TimeInterval,
                               within limit: TimeInterval = 12) -> TimeInterval? {
            let grid = a.vocalActivity
            guard !grid.isEmpty else { return nil }
            let start = Int(time.rounded())
            guard start >= 0, start < grid.count else { return nil }
            let reference = grid[start]
            guard reference > 0 else { return time }
            let last = Swift.min(grid.count - 1, start + Int(limit))
            guard start < last else { return nil }
            for i in (start + 1)...last where grid[i] < reference * 0.6 {
                return TimeInterval(i)
            }
            return nil
        }

        /// The quietest second of the outgoing vocal contour inside the
        /// hand-over window — where a singer is least likely to be mid-word.
        static func vocalTrough(_ a: TrackAnalysis, outPoint: TimeInterval,
                                from low: TimeInterval, to high: TimeInterval) -> TimeInterval? {
            let grid = a.vocalActivity
            guard !grid.isEmpty, high > low else { return nil }
            // Walk the contour's own 1 s grid rather than a window-relative
            // one, so the answer is an instant the signal actually has a
            // measurement for.
            let first = Swift.max(0, Int((outPoint + low).rounded(.up)))
            let last = Swift.min(grid.count - 1, Int((outPoint + high).rounded(.down)))
            guard first <= last else { return nil }
            var best: (t: TimeInterval, v: Float)?
            for i in first...last where best == nil || grid[i] < best!.v {
                best = (TimeInterval(i) - outPoint, grid[i])
            }
            return best?.t
        }

        // MARK: - The curves

        /// The four lanes, for one overlap and one hand-over instant.
        ///
        /// The two vocal lanes are **fade-compensated**: an envelope stacks on
        /// top of the deck fader, and the whole point of the technique is that
        /// the outgoing singer finishes the line at full voice rather than
        /// receding through an equal-power fade while doing it. So the lane
        /// carries the inverse of the fader it will be multiplied by, sampled
        /// here at compile time where the plan, the style and therefore the
        /// exact fade law are all known. The cap it carries,
        /// `compensationCeilingDB`, sits past any fader a hand-over reaches, so
        /// it never bends the gesture — it exists so a fader of zero produces a
        /// number.
        ///
        /// **The two vocal lanes have exactly two states and one event.** Full
        /// level, or nothing, and an exchange between them at the line end that
        /// is over inside `handoverCrossSeconds`. There is no vocal ramp
        /// anywhere in this template. Everything that moves gradually here is a
        /// bed — the outgoing one stepping back, the incoming one lifting and
        /// releasing — because a bed is furniture and a voice is the thing the
        /// listener is following. A singer who recedes mid-phrase is the one
        /// artefact this whole technique exists to avoid, and a slow vocal fade
        /// re-introduces it from the other side.
        ///
        /// The extra compensation samples spent on the carried stretch `(S, L]`.
        ///
        /// The pre-swap fader is nearly flat (unity down to the courtesy dip),
        /// so six points cover it; the post-swap fader is a compressed
        /// equal-power collapse, and six points across `[0, L]` would straddle
        /// it with two. Six of their own are what keep the compensated plateau
        /// flat now that the ceiling no longer flattens it for free: the lane
        /// interpolates linearly in dB and `-20log10(fader)` is convex, so
        /// every gap costs level in the *middle* of the gap. Five was enough
        /// while the ceiling clipped the steep end; with the clip gone the
        /// steep end is the part being carried, and the worst mid-gap error
        /// across every geometry the template can be asked for goes from
        /// 0.45 dB at five samples to 0.23 dB at six.
        ///
        /// 6 + 6 plateau + 2 exchange + 2 tail is exactly
        /// `StemEnvelope.maxBreakpoints`, which is the reason it is six and not
        /// eight.
        static let carrySamples = 6

        /// Non-nil `carryFrom` is the floor swap S, and switches the template
        /// to the two-clock shape: the two *bed* lanes hand the floor over on
        /// S, while the two *vocal* lanes hand the voice over on L > S. Nil is
        /// the single-clock shape, field-for-field what this template always
        /// produced — which is what `twoClockExchange = false` and every yield
        /// compile still get.
        static func template(overlap: TimeInterval, handover h: TimeInterval,
                             plan: TransitionPlan, style: TransitionStyle,
                             geometry: TransitionAutomation.Geometry,
                             carryFrom: TimeInterval? = nil,
                             incomingRelease: TimeInterval? = nil) -> StemEnvelope {
            func faders(_ t: TimeInterval) -> (out: Float, incoming: Float) {
                let f = TransitionAutomation.frame(plan: plan, style: style,
                                                   elapsed: Swift.min(Swift.max(t, 0), overlap),
                                                   geometry: geometry)
                return (f.outgoing.fader, f.incoming.fader)
            }
            let compensation = compensationDB
            typealias Point = StemEnvelope.Breakpoint

            // The two-clock shape only makes sense when the swap has room on
            // both sides of it inside this hand-over; anything degenerate falls
            // back to the single-clock curves below.
            let carry = carryFrom.flatMap { $0 > 0.05 && $0 < h - 0.05 ? $0 : nil }

            // The exchange window, and where it sits: the line ends at `h`, so
            // the window opens *there* rather than straddling it. Everything
            // before it is a plateau. Clamped so it always fits in the overlap.
            let cross = Swift.max(0.02,
                                  Swift.min(handoverCrossSeconds(
                                                beat: geometry.outgoingBeatDuration),
                                            overlap - h))

            // --- Outgoing vocal: hold the *audible* level to the hand-over,
            //     then leave inside the exchange window.
            //
            //     This lane is how the carried voice survives the floor swap.
            //     It is a stem gain *multiplied onto* the outgoing deck fader,
            //     and it already carries `1/fader` — so past S, where the
            //     dominant-deck law collapses that fader, the lane rises to
            //     cancel the collapse and the voice stays where it was. No
            //     restructuring of which layer carries the vocal was needed:
            //     the compensation that existed to keep the singer off the
            //     pre-swap fade is the same mechanism, asked to reach further.
            //     It reaches `compensationCeilingDB` far, which is past any
            //     fader a hand-over can reach — so on every geometry the
            //     template can be asked for the voice is *not* attenuated at
            //     all before L, and `carryShortfallDB` says 0. That number
            //     stays in the report and in the journal as the check: it was
            //     −4.2 dB on the field geometry when the ceiling was 6.
            var outgoingVocal: [Point] = []
            if let carry {
                for k in 0..<holdSamples {
                    let t = carry * Double(k) / Double(holdSamples - 1)
                    outgoingVocal.append(Point(t: t, gainDB: compensation(faders(t).out)))
                }
                for k in 1...carrySamples {
                    let t = carry + (h - carry) * Double(k) / Double(carrySamples)
                    outgoingVocal.append(Point(t: t, gainDB: compensation(faders(t).out)))
                }
            } else {
                for k in 0..<holdSamples {
                    let t = h * Double(k) / Double(holdSamples - 1)
                    outgoingVocal.append(Point(t: t, gainDB: compensation(faders(t).out)))
                }
            }
            //     And then the line is over, so the voice goes — inside `cross`,
            //     on the outgoing half of an equal-power exchange, *from* the
            //     plateau it was holding. Not a slope through the overlap: the
            //     singer is at full voice on the last syllable and gone a
            //     fraction of a beat later.
            let plateauDB = outgoingVocal.last?.gainDB ?? 0
            for u in exchangeFractions {
                outgoingVocal.append(Point(
                    t: h + cross * u,
                    gainDB: Swift.max(StemEnvelope.minGainDB,
                                      plateauDB + exchangeDB(u).out)))
            }
            let gone = Swift.min(overlap, h + cross)
            outgoingVocal.append(Point(t: gone, gainDB: StemEnvelope.minGainDB))
            if gone < overlap - 0.05 {
                outgoingVocal.append(Point(t: overlap, gainDB: StemEnvelope.minGainDB))
            }

            // The bed keeps its own, slower clock — see `bedRetireSeconds`.
            let retired = Swift.min(overlap, h + bedRetireSeconds)

            // --- Outgoing bed: steps back early so the incoming one can
            //     arrive, then follows the vocal out once it has gone.
            //
            //     On a carryover this lane keeps the *floor* clock: it is
            //     already at `bedAtHandoverDB` by S, because S is where the low
            //     end and the staged EQ change decks and a bed still holding on
            //     past its own swap is what makes the move read as a mix. From
            //     S to L it simply stays there and lets the deck fader take it
            //     the rest of the way out — the instrumental "follows the
            //     dominant-deck exit as it already does", uncompensated, which
            //     is precisely what decouples it from the vocal lane above.
            let bedSwap = carry ?? h
            var outgoingBed: [Point] = [
                Point(t: 0, gainDB: 0),
                Point(t: bedSwap * bedEarlyShare, gainDB: bedEarlyDB),
                Point(t: bedSwap, gainDB: bedAtHandoverDB),
            ]
            // Held flat across the carry: the stem gain has already said its
            // piece at S, and what takes the bed out from there is the deck
            // fader, not another stem move on top of it.
            if carry != nil { outgoingBed.append(Point(t: h, gainDB: bedAtHandoverDB)) }
            if retired > h + 0.05 { outgoingBed.append(Point(t: retired, gainDB: bedRetiredDB)) }
            if retired < overlap - 0.05 {
                outgoingBed.append(Point(t: overlap, gainDB: bedAfterHandoverDB))
            }

            // --- Incoming bed: in first, and pushed up while it is the only
            //     bed holding the middle of the hand-over together.
            //     On a carryover the lift is timed to arrive *by S*, not by L:
            //     from S onward this bed is the floor, and it is holding a
            //     singer who does not belong to it. It then stays lifted right
            //     across the carry and only releases once that singer has gone.
            var incomingBed: [Point] = [Point(t: 0, gainDB: 0)]
            let lift = (carry ?? h) * incomingBedLiftShare
            if lift > 0.05 {
                incomingBed.append(Point(t: lift, gainDB: incomingBedLiftDB))
                incomingBed.append(Point(t: h, gainDB: incomingBedLiftDB))
            }
            let released = Swift.min(overlap, h + incomingRiseSeconds)
            incomingBed.append(Point(t: released, gainDB: 0))
            if released < overlap - 0.05 { incomingBed.append(Point(t: overlap, gainDB: 0)) }

            // --- Incoming vocal: silent, then takes over.
            //
            //     On a carryover this lane is also the *duck*: across `(S, L]`
            //     the incoming deck owns the floor and would otherwise be free
            //     to sing over the outgoing singer still finishing a line on
            //     top of it. Holding it at `incomingVocalMutedDB` through that
            //     stretch is what keeps the carry a hand-over rather than a
            //     duet. It costs nothing extra to separate: this lane is
            //     already non-pass-through in every exchange, so the incoming
            //     window was being separated before the carry existed.
            //
            //     It does not *fade* in either. It is flat at
            //     `incomingVocalMutedDB` all the way to L — one shelf, no ramp,
            //     so that a new singer who happens to have a line running there
            //     stays out of the way of the one finishing — and then arrives
            //     on the incoming half of the same equal-power exchange. If the
            //     incoming song's own phrase does not start until later, that
            //     silence is the song's, and the lane at full level leaves it
            //     alone.
            //
            //     **And it has a clock of its own.** `incomingRelease` is where
            //     the new singer's own line starts; until then this lane is the
            //     shelf described above, whether that is L (the single-clock
            //     shape, and the default) or later. When it is later there is a
            //     short stretch with no voice at all between the two lines —
            //     a breath between singers, which is what the gesture sounds
            //     like when both clocks are read.
            let r = Swift.min(Swift.max(incomingRelease ?? h, h), overlap)
            let inCross = Swift.max(0.02,
                                    Swift.min(handoverCrossSeconds(
                                                  beat: geometry.outgoingBeatDuration),
                                              overlap - r))
            let inGone = Swift.min(overlap, r + inCross)
            var incomingVocal: [Point] = [
                Point(t: 0, gainDB: incomingVocalMutedDB),
                Point(t: r, gainDB: incomingVocalMutedDB),
            ]
            for u in exchangeFractions {
                let t = r + inCross * u
                incomingVocal.append(Point(
                    t: t,
                    gainDB: Swift.max(incomingVocalMutedDB,
                                      compensation(faders(t).incoming)
                                          + exchangeDB(u).incoming)))
            }
            incomingVocal.append(Point(t: inGone,
                                       gainDB: compensation(faders(inGone).incoming)))
            if inGone < overlap - 0.05 {
                incomingVocal.append(Point(t: overlap,
                                           gainDB: compensation(faders(overlap).incoming)))
            }

            // `compensated`: the two vocal lanes here are `1/fader`, not a
            // level choice, so they are judged against
            // `StemEnvelope.maxCompensatedGainDB` rather than the 6 dB an
            // author gets. Nothing else about the envelope changes.
            return StemEnvelope(outgoingVocal: outgoingVocal, outgoingBed: outgoingBed,
                                incomingVocal: incomingVocal, incomingBed: incomingBed,
                                compensated: true)
        }
    }
}
#endif
