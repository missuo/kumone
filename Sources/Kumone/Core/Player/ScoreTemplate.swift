#if os(macOS)
import Foundation

// 乐谱模板 — the P4 layer of docs/automix-score-predev.md (§2.5).
//
// P1 through P3 built a vocabulary and a way of choosing *whether* to speak it.
// What they did not build is a way of choosing **which sentence**, because
// there was only ever one: `cutOnOne`, optionally with a throw on the front.
// P4 adds three more gestures, and the moment there is more than one the
// interesting question stops being "may this pair have a score" and becomes
// "which score, and why not the bigger one".
//
// The answer is deliberately **not** a bag of independent event switches. A
// score assembled by asking five yes/no questions can produce a slam with
// nothing cut, a beat of silence in the middle of a crossfade, or an echo
// throw ringing through a tension cut — three sounds that are not gestures at
// all, only combinations. So the planner picks one **template**: a named,
// whole, musically coherent score whose qualification rules are checked
// together, arranged as a ladder from most to least impactful. The first rung
// that qualifies is the one that plays, and the rungs it walked past are
// reported, because "why did this pair not get the tension cut" is the question
// a listening session actually asks.
//
// Three properties are load-bearing, and they are P3's, one level up:
//
//   * **Pure.** Two analyses, the plan the gates already passed, the aim, a
//     little context, a config. No files, no clock. The same pair picks the
//     same template every time.
//   * **Subtractive.** Nothing here can hand a pair a geometry the tier, the
//     climax guard or the beat-match search refused. A template is chosen from
//     among the gestures that fit a hand-over that has *already been decided*.
//   * **All-or-nothing downstream.** The planner emits one template's score;
//     `ScoreCompiler` either places the whole thing or throws the whole thing
//     away with a sentence. There is no half-template.

/// One named, whole score the planner may offer, and the rules it has to pass
/// to be offered.
enum ScoreTemplate: Equatable, Sendable {

    /// **cutCulture, escalated.** `beats` beats of nothing, then the cut and
    /// the slam on the same frame. The most impactful thing in the library and
    /// the most conditional: silence only reads as tension if the listener can
    /// feel what is about to land in it, which is why it is offered nowhere but
    /// into a drop or a chorus.
    case tensionCut(beats: Double)
    /// **cutCulture, with the last line thrown.** The cut, with the outgoing
    /// singer's final line rung on into a beat-synced delay over the top of the
    /// new track.
    case throwCut
    /// **cutCulture, plain.** Cut on the one, slam in on the one.
    case cut
    /// **The slam's control arm.** The same cut with the incoming track coming
    /// up over a bar instead of arriving on the frame. The planner never picks
    /// this — it exists so the slam can be A/B'd against its own absence rather
    /// than against a blend, which is a different comparison entirely.
    case cutOnly
    /// **dropAlign, decorated.** `bars` bars of the incoming track's
    /// accompaniment under the outgoing exit, its singer joining on the drop.
    /// The blend underneath is untouched.
    case bedIntro(bars: Int)

    /// How the console, the trace and the A/B filenames name it.
    var name: String {
        switch self {
        case .tensionCut: return "tensionCut"
        case .throwCut: return "throwCut"
        case .cut: return "cut"
        case .cutOnly: return "cutOnly"
        case .bedIntro: return "bedIntro"
        }
    }

    /// The score this template is.
    var score: TransitionScore {
        switch self {
        // No throw inside a tension cut, and the exclusion is musical rather
        // than technical: a delay tail ringing through the silence is exactly
        // the thing the silence exists to remove. Asking for both is asking for
        // neither.
        case .tensionCut(let beats): return .tensionCut(beats: beats)
        case .throwCut: return .cutOnOne(throwingEcho: true)
        case .cut: return .cutOnOne()
        case .cutOnly: return .cutOnly()
        case .bedIntro(let bars): return .bedIntro(bars: bars)
        }
    }

    /// Which intent class may offer this template. `cutCulture` is still the
    /// only class that cuts (P3's rule, untouched); `dropAlign` gained exactly
    /// one gesture, and it is one that does not cut.
    var family: Family {
        switch self {
        case .tensionCut, .throwCut, .cut, .cutOnly: return .cutCulture
        case .bedIntro: return .dropAlign
        }
    }

    /// The two families of score, named after the intent classes that authorize
    /// them.
    enum Family: String, Sendable, Equatable {
        case cutCulture
        case dropAlign
    }

    // MARK: - Selection

    /// What the planner chose, and what it walked past on the way.
    struct Selection: Sendable, Equatable {
        var template: ScoreTemplate
        var score: TransitionScore
        /// The sentence justifying this rung.
        var why: String
        /// One line per more-impactful rung that did not qualify, in ladder
        /// order. Never silent: "no tension cut" is the report a listening
        /// session reads, and a missing line reads as a missing feature.
        var passedOver: [String]

        /// `template=tensionCut(1) — the incoming lands on a drop` plus the
        /// rungs above it, for the trace and the console.
        var label: String {
            ([ "template=\(score.label) — \(why)" ] + passedOver.map { "· \($0)" })
                .joined(separator: "\n")
        }
    }

    /// Everything the ladder is allowed to look at. Grouped into a struct
    /// rather than eight parameters because every rung reads a different three
    /// of them and a call site with eight positional arguments is a bug
    /// waiting for a refactor.
    struct Material: Sendable {
        var outgoing: TrackAnalysis
        var incoming: TrackAnalysis
        /// The plan the gates already passed — after aiming, so the entry
        /// window a bed is judged on is the window the bed would actually run
        /// over.
        var plan: BeatMatchedPlan
        /// What the seam (or the overlap end) was aimed at, nil when aiming
        /// found nothing or a gate refused the aimed entry.
        var aim: TransitionAim?
        /// The outgoing track has lyrics to throw.
        var hasLyrics: Bool
        /// A separator is available for this hand-over.
        var stemsReady: Bool
        /// The hand-over already carries a stem technique of its own.
        var hasStemTechnique: Bool
    }

    /// **The ladder.** Walk the family's templates from most impactful to
    /// least, take the first that qualifies, and report the rest.
    ///
    /// Returns nil when nothing qualifies, which for `dropAlign` is the normal
    /// case and means the pair gets the aimed blend it was already getting.
    static func select(family: Family, material: Material,
                       config: TransitionPlanner.Config) -> Selection? {
        var passedOver: [String] = []
        for template in ladder(family, config: config) {
            switch template.qualify(material, config: config) {
            case .yes(let why):
                return Selection(template: template, score: template.score,
                                 why: why, passedOver: passedOver)
            case .no(let why):
                passedOver.append("\(template.name): \(why)")
            }
        }
        return nil
    }

    /// The rungs of one family, most impactful first. `cutOnly` is not on any
    /// ladder: it is reachable only by hand (an offline render that names the
    /// template), because a control arm the planner could choose on its own is
    /// not a control arm.
    static func ladder(_ family: Family,
                       config: TransitionPlanner.Config) -> [ScoreTemplate] {
        switch family {
        case .cutCulture:
            return [.tensionCut(beats: config.scoreTensionCutBeats), .throwCut, .cut]
        case .dropAlign:
            return [.bedIntro(bars: config.scoreBedIntroBars)]
        }
    }

    enum Qualification: Equatable {
        case yes(String)
        case no(String)
    }

    /// **Per-gesture qualification.** Each rung's own rules, and only its own:
    /// the family gate (P3's intent class) and the score gates (P1's grid
    /// confidence) have already been applied by the caller, so what is left
    /// here is what makes *this* gesture musical rather than merely possible.
    func qualify(_ m: Material, config: TransitionPlanner.Config) -> Qualification {
        switch self {

        // --- Tension cut. A beat of nothing is a promise, and the qualification
        // is entirely about whether the material can keep it.
        //
        // **Only into a drop or a chorus.** This is the rule the gesture lives
        // or dies by. Silence before a landing the listener was waiting for is
        // the oldest move in the club; silence before the second verse is the
        // player having a fault. The predev calls a tension cut into a verse a
        // malfunction, and since P2 there is a layer that knows the difference:
        // the aim names what the seam was pointed at, so the rule is one field
        // read rather than a new piece of structural reasoning.
        case .tensionCut(let beats):
            guard config.scoreTensionCutEnabled else {
                return .no("switched off (scoreTensionCutEnabled)")
            }
            guard beats > 0, beats <= Double(TransitionScore.beatsPerBar) else {
                return .no(String(format: "%.2f beats of silence is not a gesture", beats))
            }
            guard let aim = m.aim else {
                return .no("the seam is not aimed at anything — a tension cut into "
                           + "whatever bar line was nearest is a malfunction")
            }
            guard aim.target == .drop || aim.target == .chorus else {
                return .no("the seam lands on the \(aim.target.rawValue), not on a drop or a "
                           + "chorus — nothing is coming that the silence could promise")
            }
            guard aim.landing == .seam else {
                return .no("the aim lands on \(aim.landing.label), so there is no cut for "
                           + "the silence to sit in front of")
            }
            return .yes(String(format: "%g beat(s) of silence into the %@ at %.2f s",
                               beats, aim.target.rawValue, aim.time))

        // --- Echo throw. P2's rule, unchanged and restated here so the ladder
        // reads in one place: the compiler is the one that checks the line
        // *lands* on the seam, and it degrades to a plain cut when it does not.
        case .throwCut:
            guard m.hasLyrics else {
                return .no("no lyrics for the outgoing track — nothing to throw")
            }
            return .yes("the outgoing track has lines the compiler can throw the last of")

        case .cut:
            return .yes("cut on the one, slam in on the one")

        case .cutOnly:
            return .yes("the cut without the slam — the slam's control arm")

        // --- Accompaniment bed. Two rules, and both of them are about whether
        // anybody would hear it.
        //
        // **The entry window has to be sung.** This is the one that matters. A
        // bed is made by muting the incoming track's vocal lane, so on an
        // instrumental intro the bed *is* the mix: the gesture runs, costs a
        // separation pass, and produces a file identical to the one it would
        // have produced without it. Not a wrong sound — no sound at all, which
        // is worse, because it is invisible in a blind test and expensive in
        // the runway.
        //
        // **And it has to be a bed under something.** The blend's own overlap
        // is the bed's length: no overlap, no bed. The compiler does the exact
        // arithmetic against the bar grid; what is checked here is only that
        // the plan is in the right order of magnitude, so a hopeless pair never
        // reaches a separator.
        case .bedIntro(let bars):
            guard config.scoreBedIntroEnabled else {
                return .no("switched off (scoreBedIntroEnabled)")
            }
            guard bars >= 1, bars <= TransitionScore.maxBedIntroBars else {
                return .no("\(bars) bars is not a bed")
            }
            guard m.stemsReady else {
                return .no("no separator on this machine — a bed is the incoming track "
                           + "minus its singer, and there is no other way to have one")
            }
            guard !m.hasStemTechnique else {
                return .no("this hand-over already carries a stem technique; two of them "
                           + "would be writing the same lane twice")
            }
            guard let aim = m.aim, aim.landing == .overlapEnd else {
                return .no("the overlap does not end on anything in particular — a bed "
                           + "whose singer joins at no landmark is just a quiet intro")
            }
            let entry = m.plan.inPoint
            let overlap = m.plan.overlapDuration
            guard let vocal = TransitionPlanner.vocalScore(
                m.incoming, from: entry, length: overlap) else {
                return .no("no usable vocal contour on the incoming track's entry window")
            }
            guard vocal >= config.scoreBedIntroMinIncomingVocal else {
                return .no(String(format: "the incoming entry window is already instrumental "
                                  + "(vocal %.2f of the track's own mean, against a %.2f "
                                  + "line) — muting a lane nobody is singing on is a "
                                  + "separation pass for silence", vocal,
                                  config.scoreBedIntroMinIncomingVocal))
            }
            // The bed's window *is* the overlap — the incoming deck has nothing
            // to hold down before it starts — so the bar count is a cap on the
            // hand-over, and it is checked here as well as in the compiler so
            // the refusal shows up in the plan report rather than only in a
            // compile nobody ran.
            let bar = 60 / max(m.incoming.bpm, 1) * Double(TransitionScore.beatsPerBar)
            guard overlap >= bar else {
                return .no(String(format: "the %.1f s overlap is shorter than one bar", overlap))
            }
            guard overlap <= Double(bars) * bar + ScoreCompiler.bedOverrunBars * bar else {
                return .no(String(format: "the %.1f s overlap is %.1f bars, longer than the %d "
                                  + "this bed may cover — holding a singer down from the top "
                                  + "would be a different, longer gesture wearing this one's "
                                  + "name", overlap, overlap / bar, bars))
            }
            return .yes(String(format: "%d bars of bed under the exit, the incoming singer "
                               + "joining on the %@ at %.2f s (entry window vocal %.2f)",
                               bars, aim.target.rawValue, aim.time, vocal))
        }
    }
}
#endif
