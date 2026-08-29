#if os(macOS)
import Foundation
import KumoneCore

// AutoMix tuning loop, offline. See docs/audition.md.
//
//   swift run audition plan   <fileA> <fileB>
//   swift run audition render <fileA> <fileB> [-o out.wav] [--style …] [--fade N]
//   swift run audition batch  <corpusDir> [-o outDir] [--pairs a.flac:b.flac,…]

// MARK: - Argument plumbing

struct Arguments {
    var positional: [String] = []
    var flags: [String: String] = [:]

    init(_ raw: [String]) {
        var i = 0
        while i < raw.count {
            let token = raw[i]
            if token.hasPrefix("--") {
                let name = String(token.dropFirst(2))
                if let eq = name.firstIndex(of: "=") {
                    flags[String(name[name.startIndex..<eq])] = String(name[name.index(after: eq)...])
                } else if i + 1 < raw.count, !raw[i + 1].hasPrefix("-") {
                    flags[name] = raw[i + 1]
                    i += 1
                } else {
                    flags[name] = "true"
                }
            } else if token == "-o", i + 1 < raw.count {
                flags["output"] = raw[i + 1]
                i += 1
            } else {
                positional.append(token)
            }
            i += 1
        }
    }

    func double(_ name: String) -> Double? { flags[name].flatMap(Double.init) }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("audition: " + message + "\n").utf8))
    exit(1)
}

func url(_ path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
}

let usage = """
usage:
  audition plan   <fileA> <fileB> [--json] [--stems on|off] [--set name=value,...]
  audition render <fileA> <fileB> [-o out.wav] [--style plain|sweep|echo|staged] [--fade N]
                                  [--stem acapella|instrumental|duck[:9]|exchange]
                                  [--score] [--pre N] [--post N] [--ride-release N]
                                  [--set name=value,...]
  audition batch  <corpusDir> [-o outDir] [--pairs a.flac:b.flac,...]
                              [--style ...] [--fade N] [--pre N] [--post N]
                              [--set name=value,...]
  audition serve  [--corpus DIR] [--port 8766] [--host 127.0.0.1,10.147.19.10]
                  [--state DIR]
  audition sweep  <corpusDir> [-o report.md] [--mode structure|tempo|gates]
                  [--set name=value,...]
  audition order  <cacheOrCorpusDir> [-o report.md] [--window 4] [--limit N]
                  [--candidates 6] [--low-dir DIR] [--bench]
                  [--set ...] [--order-set ...]
  audition knobs  [--json]

  order     run the AutoMix queue-reorder greedy over a directory of locally
            cached, already analyzed tracks and table what it did to the tier
            distribution: original order vs `greedy W=<window>` (only the next
            W listed entries are in the pool) vs `escalation` (the shipping
            policy: start from what is already analyzed, buy 1 more track, then
            4, then 16, stopping the moment one is good enough — reported with
            its downloads-per-pick cost) vs `greedy (all cached)` (every
            remaining track is in the pool, the ceiling a fully cached playlist
            gives the selector). Every row is also cut into thirds — first,
            middle, last — because greedy's quality is front-loaded and one
            overall percentage averages that collapse away.
            Offline and read-only — it never analyzes and never hits
            the network, so a file without an `.analysis.json` sidecar is
            skipped. Point it straight at ~/Library/Caches/Kumone/Audio.
            --window      pool size for the windowed schedule (default 4)
            --limit       use only the first N tracks of each group
            --candidates  rows per pick in the candidate table (default 6)
            --low-dir     a directory of low-bitrate copies of the same tracks,
                          matched by track ID; enables the low-vs-playback tier
                          agreement check. Without it the check runs on any
                          track the corpus itself holds at two quality levels,
                          and is skipped when there are none.
            --bench       report what the scoring costs in ms at this pool size
                          (one plan, one rank = a pick, one chain = a lookahead
                          refresh) and stop. The selector runs on the main
                          actor, so these decide what may run there.
            --order-set   queue-order weights, e.g. --order-set agingEpsilon=0.5
                          (`audition knobs` lists them under "queue order").
                          `futureMode=0|1|2` toggles the future-richness term
                          (off / degree / rollout) — it ships off, and this is
                          how the negative result in predev §5.2 is reproduced.

  sweep     plan every adjacent seam inside each `p<N>-…` playlist twice — once
            with a layer off and once with it on — and table what moved. Plans
            only: no audio is rendered.
            --mode structure (default): the structure layer off (the pre-P3
            decision) vs on — out/in points, the section each landed in, and
            whether the lyric snap or the climax guard fired.
            --mode tempo: `tempoRampEnabled=0` (the ±8 %/±4 % stepped gate) vs
            on (±11.5 %/±6.5 % with the glide) — which seams are newly
            beat-matched, and what each deck bends to get there.
            --mode gates: the four loosened admission gates (ride cut cap,
            neutral overlap cap, single-section steadiness bar, ramped bend
            cap) at their old values vs the shipped ones — which seams changed
            tier/plan/length, and which single knob is responsible for each.

  --style   force one technique, to hear it in isolation
  --stems   on|off (default off) — tell the planner a vocal separator is
            available, so it may choose vocalExchange / acapellaOver itself. Off is
            the product default and reproduces the pre-stem decision exactly.
  --stem    layer a stem technique on top of the chosen style (render only):
            acapella      the outgoing vocal floats over the incoming mix
            instrumental  the outgoing vocal is wiped, it leaves instrumental
            duck[:9]      the outgoing vocal held N dB down (default 9)
            exchange      the orchestrated hand-off: the incoming bed lays down
                          first, the outgoing bed leaves early, the outgoing
                          vocal finishes its line (located from the .lrc
                          sidecar) and the incoming vocal takes over. Splits
                          both decks, so it pays for two separation passes.
            First use downloads a 64 MiB model; the separated window is cached
            beside the audio as <file>.stems-v1-<start>-<len>.caf.
  --score   offer this pair a transition score (docs/automix-score-predev.md):
            正拍直切 + 末句甩延时, compiled onto the two beat grids and rendered
            through the whole-mix lanes. Shorthand for `--set scoreEnabled=1`;
            a pair whose grids are not confident enough is still refused, and a
            score that cannot be placed is thrown away whole (you get the blend,
            and the report says why). Separates nothing.
  --fade    override the overlap length (seconds)
  --pre/--post  context before / after the hand-over (default 12s each)
  --ride-release  dB/s the gain ride is let go of at, overriding the shipped
            slope (1.2 for a cut, 0.3 for a boost). Render only, and the one
            knob that is not a `--set` name: the player reaches that constant
            without a planner config, so this is how the two slopes are A/B'd
            out of one binary.
  --json    print the full decision — signals, thresholds, derivation chain — as JSON
  --set     override planner thresholds for this run, e.g.
            --set clashTimbreDistance=0.35,neutralLoudnessDB=4
            (`audition knobs` lists every name and its range)
"""

// MARK: - Formatting

func f(_ v: Double, _ digits: Int = 2) -> String {
    String(format: "%.\(digits)f", v)
}

func optional(_ v: Double?, _ digits: Int = 2) -> String {
    v.map { f($0, digits) } ?? "—"
}

func mmss(_ t: TimeInterval) -> String {
    String(format: "%d:%05.2f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
}

/// The "why did this pair get this transition" block. Every threshold quoted
/// comes from the decision's own config, so a `--set` run explains itself
/// against the lines it actually used.
func explain(_ d: Audition.Decision) -> String {
    func th(_ name: String) -> Double { d.config[name] ?? 0 }
    var lines: [String] = []
    lines.append("\(d.outgoingName)  →  \(d.incomingName)")
    lines.append("  tier          \(d.tier)"
                 + (d.demotedByKey ? "  (demoted from compatible by the key gate)" : ""))
    lines.append("  loudness gap  \(f(d.loudnessGapDB)) dB"
                 + "   [neutral > \(f(th("neutralLoudnessDB"), 1)),"
                 + " clash > \(f(th("clashLoudnessDB"), 1))]")
    // The gap above is what survived both gain stages; show all three.
    lines.append("  loudness      \(optional(d.outgoingLoudnessLUFS, 1)) →"
                 + " \(optional(d.incomingLoudnessLUFS, 1)) LUFS"
                 + "   trim \(f(d.outgoingTrimDB)) / \(f(d.incomingTrimDB)) dB"
                 + "  (raw gap \(f(d.rawLoudnessGapDB)) dB)")
    lines.append("  gain ride     \(f(d.rideDB)) dB on the incoming deck"
                 // The two caps are not the same number any more, so quoting
                 // one of them as "±" would misreport whichever direction this
                 // seam actually took.
                 + "   [cut cap \(f(-th("rideMaxCutDB"), 1)),"
                 + " boost cap +\(f(th("rideMaxDB"), 1)),"
                 + " released over \(f(d.rideReleaseSeconds, 1))s]"
                 + "  \(f(d.rawLoudnessGapDB)) → \(f(d.trimmedLoudnessGapDB))"
                 + " → \(f(d.loudnessGapDB)) dB")
    lines.append("  timbre dist   \(f(d.timbreDistance, 3))"
                 + "      [neutral > \(f(th("neutralTimbreDistance"), 2)),"
                 + " clash > \(f(th("clashTimbreDistance"), 2))]")
    let bpm = "\(f(d.outgoingBPM, 1)) → \(f(d.incomingBPM, 1)) BPM"
        + " (conf \(f(d.outgoingBPMConfidence)) / \(f(d.incomingBPMConfidence)))"
    lines.append("  tempo         \(optional(d.tempoRatio, 3)) folded"
                 + "   [beat-match ≤ \(f(th("maxBPMDeltaRatio"), 2)),"
                 + " clash > \(f(th("clashTempoRatio"), 2))]  \(bpm)")
    lines.append("  key distance  \(d.keyDistance.map(String.init) ?? "—")"
                 + "           [demotes at ≥ \(Int(th("clashKeyDistance"))) fifths]")
    lines.append("  vocals        out \(optional(d.outgoingVocalScore))"
                 + " / in \(optional(d.incomingVocalScore))"
                 + "   [both > \(f(th("vocalClashRatio"), 2)) = clash]")
    var mechanics = "  → \(d.planKind), \(d.styleDescription)"
    if d.overlapDuration > 0 {
        mechanics += ", overlap \(f(d.overlapDuration))s"
        if let bars = d.overlapBars { mechanics += " (\(bars) bars)" }
    }
    if let outPoint = d.outPoint { mechanics += ", out @ \(mmss(outPoint))" }
    if let inPoint = d.inPoint { mechanics += ", in @ \(mmss(inPoint))" }
    if let outRate = d.outgoingRate, let inRate = d.incomingRate {
        mechanics += String(format: ", rates %.4f/%.4f", outRate, inRate)
    }
    if d.overridden { mechanics += "  [OVERRIDDEN by --style/--fade]" }
    if !d.scoreLines.isEmpty {
        mechanics += "\n  " + d.scoreLines.joined(separator: "\n  ")
    }
    lines.append(mechanics)
    // Which gate on the beat-match chain this pair lost, and by how much.
    if let blocker = d.planTrace.blocker {
        lines.append("  beat-match    blocked at \(blocker.label) — \(blocker.detail)")
        if let shadow = d.planTrace.shadowBlocker {
            lines.append("                and would then have failed \(shadow.label)"
                         + " — \(shadow.detail)")
        }
    } else {
        lines.append("  beat-match    every gate cleared"
                     + " (\(d.planTrace.chosenBars ?? 0) bars)")
    }
    if d.stemsReady {
        var stemLine = "  stems on      "
        if let technique = d.plannedStemTechnique {
            stemLine += "planner chose \(technique)"
            if let base = d.stemBaselineOutPoint, let baseOverlap = d.stemBaselineOverlap {
                stemLine += "  (without stems: out @ \(mmss(base)),"
                    + " overlap \(f(baseOverlap))s)"
            }
        } else {
            stemLine += "planner chose no stem technique"
                + "   [needs outgoing vocals > \(f(th("stemVocalActiveRatio")))"
                + " and either incoming > \(f(th("vocalClashRatio")))"
                + " (duck) or ≤ \(f(th("stemAcapellaIncomingVocalMax"))) at compatible (acapella)]"
        }
        lines.append(stemLine)
    }
    for miss in d.nearMisses {
        lines.append("  ⚠︎ borderline: \(miss)")
    }
    return lines.joined(separator: "\n")
}

/// `--set name=value,name=value` — the CLI's door onto the same knobs the
/// console's sliders move.
func configOverrides(_ args: Arguments) -> [String: Double] {
    guard let spec = args.flags["set"], spec != "true" else { return [:] }
    let known = Set(Audition.configFields.map(\.name))
    var out: [String: Double] = [:]
    for entry in spec.split(separator: ",") {
        let kv = entry.split(separator: "=", maxSplits: 1)
        guard kv.count == 2, let value = Double(kv[1]) else {
            fail("bad --set entry '\(entry)', expected name=value")
        }
        let name = String(kv[0])
        guard known.contains(name) else {
            fail("unknown knob '\(name)'; run `audition knobs` for the list")
        }
        out[name] = value
    }
    return out
}

func decide(_ args: Arguments, a: URL, b: URL) -> Audition.Decision {
    var style: Audition.StyleOverride?
    if let raw = args.flags["style"] {
        guard let parsed = Audition.StyleOverride(rawValue: raw) else {
            fail("unknown --style '\(raw)'; expected one of "
                 + Audition.StyleOverride.allCases.map(\.rawValue).joined(separator: "|"))
        }
        style = parsed
    }
    var stem: Audition.StemOverride?
    if let raw = args.flags["stem"], raw != "true" {
        guard let parsed = Audition.StemOverride.parse(raw) else {
            fail("unknown --stem '\(raw)'; expected one of "
                 + Audition.StemOverride.names.joined(separator: "|") + " (duck takes :N dB)")
        }
        stem = parsed
    }
    let stems: StemAvailability
    switch args.flags["stems"] ?? "off" {
    case "on", "ready", "true": stems = .ready
    case "off", "none", "false": stems = .none
    case let raw: fail("unknown --stems '\(raw)'; expected on|off")
    }
    for file in [a, b] where !Audition.hasCachedAnalysis(for: file) {
        FileHandle.standardError.write(Data("  analyzing \(file.lastPathComponent)…\n".utf8))
    }
    var overrides = configOverrides(args)
    // `--score` is exactly the planner knob, spelled as a flag: the score is a
    // planner decision, so forcing one here rather than through the config
    // would render something the planner would never have offered.
    if args.flags["score"] != nil { overrides["scoreEnabled"] = 1 }
    do {
        return try Audition.decide(outgoing: a, incoming: b,
                                   style: style, fade: args.double("fade"), stem: stem,
                                   stems: stems,
                                   config: overrides)
    } catch {
        fail("\(a.lastPathComponent) → \(b.lastPathComponent): \(error.localizedDescription)")
    }
}

func renderOptions(_ args: Arguments) -> (pre: TimeInterval, post: TimeInterval) {
    (args.double("pre") ?? 12, args.double("post") ?? 12)
}

// MARK: - Commands

func runPlan(_ args: Arguments) {
    guard args.positional.count == 2 else { fail(usage) }
    let d = decide(args, a: url(args.positional[0]), b: url(args.positional[1]))
    if args.flags["json"] != nil {
        guard let data = try? Audition.reportJSON(d) else { fail("could not encode the report") }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } else {
        print(explain(d))
    }
}

/// Every tunable, so `--set` names and console sliders are discoverable from
/// the terminal too.
func runKnobs(_ args: Arguments) {
    if args.flags["json"] != nil {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Audition.configFields) else { fail("encode failed") }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        return
    }
    var group = ""
    for field in Audition.configFields {
        if field.group != group {
            group = field.group
            print("\n[\(group)]")
        }
        let name = field.name.padding(toLength: max(26, field.name.count + 2),
                                      withPad: " ", startingAt: 0)
        print("  \(name)\(f(field.standard, field.digits))"
              + "   [\(f(field.min, field.digits))…\(f(field.max, field.digits))]")
        print("      \(field.blurb)")
    }
    // The queue-reorder weights are a second config, moved by `--order-set`
    // rather than `--set`, so they get their own group rather than being
    // silently mixed into the planner's.
    print("\n[queue order]  (--order-set)")
    for field in Audition.queueOrderFields {
        let name = field.name.padding(toLength: max(26, field.name.count + 2),
                                      withPad: " ", startingAt: 0)
        print("  \(name)\(f(field.standard, field.digits))"
              + "   [\(f(field.min, field.digits))…\(f(field.max, field.digits))]")
        print("      \(field.blurb)")
    }
}

func runServe(_ args: Arguments) {
    let corpus = url(args.flags["corpus"] ?? args.positional.first
                     ?? "~/Developer/kumone-audition-corpus")
    guard FileManager.default.fileExists(atPath: corpus.path) else {
        fail("no such corpus directory: \(corpus.path)")
    }
    let state = url(args.flags["state"] ?? corpus.appendingPathComponent("console").path)
    let port = UInt16(args.flags["port"].flatMap(Int.init) ?? 8766)
    let hosts = (args.flags["host"] ?? "127.0.0.1,10.147.19.10")
        .split(separator: ",").map(String.init)

    let console = Console(corpus: corpus, stateDir: state)
    let server = HTTPServer { console.handle($0) }
    let bound = server.listen(on: hosts, port: port)
    guard !bound.isEmpty else { fail("could not bind any of \(hosts.joined(separator: ", "))") }

    print("""
      AutoMix 决策台
        corpus  \(corpus.path)  (\(console.tracks.count) tracks, \
      \(console.adjacentPairs.count) adjacent pairs)
        state   \(state.path)
      \(bound.map { "  http://\($0):\(port)/" }.joined(separator: "\n"))
      """)
    fflush(stdout)
    dispatchMain()
}

func runRender(_ args: Arguments) {
    guard args.positional.count == 2 else { fail(usage) }
    let a = url(args.positional[0]), b = url(args.positional[1])
    let d = decide(args, a: a, b: b)
    print(explain(d))
    let out = url(args.flags["output"] ?? "transition.wav")
    try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    let opts = renderOptions(args)
    do {
        let r = try Audition.render(d, to: out, preRoll: opts.pre, postRoll: opts.post,
                                    rideReleaseDBPerSecond: args.double("ride-release"),
                                    stemProvider: StemService.shared.provider)
        var stemLine = ""
        if let technique = r.stemTechnique {
            stemLine = "\n    stem \(technique) — separated "
                + "\(f(r.stemSeparatedSeconds ?? 0, 1))s in \(f(r.stemSeconds ?? 0))s"
                + (r.stemIncomingSeparatedSeconds.map {
                       " + \(f($0, 1))s of the incoming deck" } ?? "")
                + (r.stemCacheHit ? " (cached)" : "")
                + ", vocal/mix \(f(r.stemVocalEnergyRatio ?? 0, 3))"
            if (r.stemVocalEnergyRatio ?? 0) < 0.02 {
                stemLine += "\n    ⚠︎ that window is instrumental — the technique had no vocal"
                    + " to act on, so this will sound like the plain render"
            }
        }
        if let reason = r.stemFallbackReason {
            stemLine = "\n    stem NOT applied, rendered whole-mix: \(reason)"
        }
        // Where the vocal changed hands is the one thing about an exchange you
        // cannot read off the technique's name.
        if let x = d.stemExchange {
            if let reason = x.fallbackReason {
                stemLine += "\n    vocalExchange did not compile: \(reason)"
            } else {
                stemLine += "\n    hand-over at +\(f(x.handover, 2))s into the overlap"
                    + " (\(f(x.handoverAbsolute, 2))s in the outgoing track), from \(x.source)"
                    + (x.lyricLine.map { ": “\($0)”" } ?? "")
                // The other clock, and which side of it the voice landed on —
                // A/B-ing single- against two-clock is unreadable without it.
                if let gesture = x.gesture {
                    stemLine += "\n    \(gesture.rawValue) (\(gesture.chineseLabel)):"
                        + " floor swaps at +\(f(x.swapOffset, 2))s, voice at"
                        + " +\(f(x.handover, 2))s (\(f(x.handover - x.swapOffset, 2))s"
                        + " \(x.handover > x.swapOffset ? "after" : "before") it)"
                    if let window = x.incomingDuckWindow {
                        stemLine += "\n    incoming vocal ducked across"
                            + " (\(f(window.lowerBound, 2))s, \(f(window.upperBound, 2))s]"
                            + (x.carryShortfallDB < -0.05
                               ? ", carry loses \(f(-Double(x.carryShortfallDB), 1)) dB at the end"
                               : ", carried at full level throughout")
                    }
                }
            }
        }
        // The score: what it compiled to, or why the file you are about to
        // play is the plain blend after all.
        var scoreLine = ""
        if !d.scoreLines.isEmpty {
            scoreLine = "\n    " + d.scoreLines.joined(separator: "\n    ")
            if d.scoreCompiled, !r.scoreLanesApplied {
                scoreLine += "\n    ⚠︎ 乐谱编译了但渲染没有施加："
                    + (r.scoreFallbackReason ?? "未知原因")
            }
        } else if args.flags["score"] != nil {
            scoreLine = "\n    --score 没有生效：这一对没拿到乐谱"
                + "（不是 beatMatched，或者两侧的拍子把握不够，见 scoreMinBPMConfidence）。"
        }
        // The hand-over's gain ride, envelope and all — the render carries the
        // release too, so it is in the file you are about to play.
        var rideLine = ""
        if abs(r.rideDB) > 0.005 {
            rideLine = "\n    gain ride \(f(r.rideDB)) dB on the incoming deck across the "
                + "overlap, released over \(f(r.rideReleaseSeconds, 1))s afterwards"
        }
        // Blind-test level matching, applied to the finished file only.
        var normLine = ""
        if let target = r.normalizationTargetLUFS {
            normLine = "\n    blind-test normalization "
                + "\(optional(r.measuredLUFS, 1)) → \(f(target, 1)) LUFS "
                + "(\(f(r.normalizationGainDB)) dB applied to the file)"
        }
        print("""

          wrote \(r.outputURL.path)
            \(f(r.duration))s of audio, hand-over at \(mmss(r.overlapStart)) \
          (overlap \(f(r.overlapDuration))s)
            rendered in \(f(r.renderSeconds))s — \(f(r.realtimeFactor, 1))× real time
            deck trims \(f(r.outgoingTrimDB)) / \(f(r.incomingTrimDB)) dB (as the player would)\(rideLine)\(normLine)\(stemLine)\(scoreLine)
            afplay \(r.outputURL.path)
          """)
    } catch {
        fail("render failed: \(error.localizedDescription)")
    }
}

// MARK: - beatMatched elimination ledger
//
// `beatMatched` is a conjunction of a dozen gates, so "the real library almost
// never beat-matches" is not one fact but a distribution. The planner keeps a
// ledger of every gate it walked (`PlanTrace`); this turns the ledger over a
// whole corpus into the histogram that has to exist before anyone touches a
// threshold: which gate did the killing, how often, and by how much.
//
// Attribution is *first gate wins*: a pair the tier stopped is counted at the
// tier and nowhere else, never also blamed on the gates it never reached. The
// counterfactual those pairs would otherwise answer is kept separately, off the
// planner's shadow ledger.

/// A bar of blocks, capped so one dominant row cannot run off the page.
func bar(_ count: Int, of total: Int) -> String {
    let width = total > 0 ? Int((Double(count) / Double(total) * 40).rounded()) : 0
    return String(repeating: "█", count: max(count > 0 ? 1 : 0, width))
}

func eliminationSection(_ decisions: [Audition.Decision]) -> [String] {
    var out = ["## beatMatched 逐门淘汰", ""]
    let total = decisions.count
    let matched = decisions.filter { $0.planKind == "beatMatched" }
    out.append("\(total) 对里 \(matched.count) 对做成了 beatMatched，"
               + "\(total - matched.count) 对被淘汰。下面按**第一道拦住它的门**归因 —— "
               + "被档位（tier）拦下的一对只记在档位上，不重复计入它根本没走到的后续各门。")
    out.append("")

    // First-blocker histogram, in chain order.
    var counts: [String: Int] = [:]
    var labels: [String: String] = [:]
    var stages: [String: String] = [:]
    for d in decisions {
        guard let b = d.planTrace.blocker else { continue }
        counts[b.id, default: 0] += 1
        labels[b.id] = b.label
        stages[b.id] = b.stage.rawValue
    }
    out.append("**第一淘汰门**\n")
    for id in PlanTrace.gateOrder {
        let n = counts[id] ?? 0
        guard n > 0 else { continue }
        out.append("- `\(labels[id] ?? id)` (\(stages[id] ?? "")): \(n)  \(bar(n, of: total))")
    }
    if matched.count > 0 {
        out.append("- `— cleared every gate —`: \(matched.count)  \(bar(matched.count, of: total))")
    }
    out.append("")

    // Counterfactual: of the pairs the tier/key stopped, which would have died
    // further down anyway?
    let demoted = decisions.filter {
        guard let b = $0.planTrace.blocker else { return false }
        return b.stage == .tier || b.stage == .key
    }
    if !demoted.isEmpty {
        var shadow: [String: Int] = [:]
        var shadowLabels: [String: String] = [:]
        var clean = 0
        for d in demoted {
            if let s = d.planTrace.shadowBlocker {
                shadow[s.id, default: 0] += 1
                shadowLabels[s.id] = s.label
            } else {
                clean += 1
            }
        }
        out.append("**如果档位放行** — 被档位/调性拦下的 \(demoted.count) 对，"
                   + "接着会死在哪道门（planner 的影子账本，不影响上面的归因）\n")
        for id in PlanTrace.gateOrder {
            let n = shadow[id] ?? 0
            guard n > 0 else { continue }
            out.append("- `\(shadowLabels[id] ?? id)`: \(n)  \(bar(n, of: demoted.count))")
        }
        if clean > 0 {
            out.append("- `— would have beat-matched —`: \(clean)  \(bar(clean, of: demoted.count))")
        }
        out.append("")
    }

    // The bar-length search: never an elimination, only a shortening — so it
    // gets its own tally.
    let reachedBars = decisions.filter { d in
        d.planTrace.gates.contains { $0.stage == .barUpgrade }
    }
    if !reachedBars.isEmpty {
        var upgrade: [String: Int] = [:]
        var upgradeLabels: [String: String] = [:]
        var won = 0
        for d in reachedBars {
            if let bars = d.planTrace.chosenBars, bars > 4 { won += 1; continue }
            let eight = d.planTrace.gates.filter { $0.id.hasPrefix("bars8.") }
            let sixteen = d.planTrace.gates.filter { $0.id.hasPrefix("bars16.") }
            guard let first = (eight.first { !$0.passed } ?? sixteen.first { !$0.passed })
            else { continue }
            upgrade[first.id, default: 0] += 1
            upgradeLabels[first.id] = first.label
        }
        out.append("**16 / 8 小节升级** — 走到了小节搜索的 \(reachedBars.count) 对里，"
                   + "是哪道门把它们压回 4 小节兜底（这一步从不淘汰 beatMatched，只缩短叠加）\n")
        if won > 0 {
            out.append("- `— upgraded to 8 or 16 bars —`: \(won)  \(bar(won, of: reachedBars.count))")
        }
        for (id, n) in upgrade.sorted(by: { $0.value == $1.value ? $0.key < $1.key
                                            : $0.value > $1.value }) {
            out.append("- `\(upgradeLabels[id] ?? id)`: \(n)  \(bar(n, of: reachedBars.count))")
        }
        out.append("")
    }

    // Signal spread: whether a gate is a near miss corpus-wide or a structural
    // mismatch is the whole "tighten the line vs. rethink the rule" question.
    func spreadOf(_ xs: [Double]) -> String {
        guard !xs.isEmpty else { return "n/a" }
        let s = xs.sorted()
        return "min \(f(s.first!, 3)) · median \(f(s[s.count / 2], 3)) · "
            + "max \(f(s.last!, 3))  (n=\(s.count))"
    }
    out.append("**信号分布** — 门槛差一点，还是根本不在一个量级\n")
    out.append("- 音色距离（容忍线 \(f(Audition.standardConfig["neutralTimbreDistance"] ?? 0, 2))）："
               + spreadOf(decisions.map(\.timbreDistance)))
    out.append("- 节拍把握度（门槛 \(f(Audition.standardConfig["bpmConfidenceThreshold"] ?? 0, 2))）："
               + spreadOf(decisions.flatMap { [$0.outgoingBPMConfidence, $0.incomingBPMConfidence] }))
    out.append("- 折算速度差（对拍窗口 \(f(Audition.standardConfig["maxBPMDeltaRatio"] ?? 0, 2))）："
               + spreadOf(decisions.compactMap(\.tempoRatio)))
    out.append("")

    // One line per pair: where it died and by how much.
    out.append("**每一对的淘汰路径**\n")
    for d in decisions {
        let head = "- \(d.outgoingName) → \(d.incomingName): "
        guard let b = d.planTrace.blocker else {
            out.append(head + "**beatMatched** (\(d.planTrace.chosenBars ?? 0) bars)")
            continue
        }
        var line = head + "**\(b.label)** — \(b.detail)"
        if let m = b.margin, m.isFinite, abs(m) >= 0.005 {
            line += String(format: " (%@ %.0f%%)", m > 0 ? "over by" : "short by",
                           abs(m) * 100)
        }
        if let s = d.planTrace.shadowBlocker {
            line += "; would then have failed **\(s.label)** — \(s.detail)"
        } else if b.stage == .tier || b.stage == .key {
            line += "; every later gate would have passed"
        }
        out.append(line)
    }
    out.append("")
    return out
}

func runBatch(_ args: Arguments) {
    guard let dirArg = args.positional.first else { fail(usage) }
    // A stem render costs a model pass per pair; a corpus sweep is for
    // comparing planner decisions, not for auditioning one technique.
    var args = args
    if args.flags.removeValue(forKey: "stem") != nil {
        FileHandle.standardError.write(
            Data("audition: --stem is ignored by batch; use render for stem techniques\n".utf8))
    }
    let corpus = url(dirArg)
    let outDir = url(args.flags["output"] ?? corpus.appendingPathComponent("renders").path)
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

    // Pairs: either an explicit --pairs list, or every adjacent pair in
    // filename order (so a corpus gives N-1 hand-overs deterministically).
    var pairs: [(URL, URL)] = []
    if let spec = args.flags["pairs"] {
        for entry in spec.split(separator: ",") {
            let sides = entry.split(separator: ":")
            guard sides.count == 2 else { fail("bad --pairs entry '\(entry)', expected a:b") }
            pairs.append((corpus.appendingPathComponent(String(sides[0])),
                          corpus.appendingPathComponent(String(sides[1]))))
        }
    } else {
        let audioExtensions: Set<String> = ["flac", "mp3", "m4a", "wav", "aiff", "caf", "aac"]
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: corpus, includingPropertiesForKeys: nil)) ?? [])
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            // `render --stem` leaves vocal-stem sidecars in the corpus; they
            // are cache, not material.
            .filter { !StemService.isStemSidecar($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard files.count >= 2 else { fail("need at least two audio files in \(corpus.path)") }
        pairs = zip(files, files.dropFirst()).map { ($0, $1) }
    }

    var rows: [String] = []
    var decisions: [Audition.Decision] = []
    var renderFactors: [Double] = []

    for (index, pair) in pairs.enumerated() {
        let d = decide(args, a: pair.0, b: pair.1)
        decisions.append(d)
        let name = String(format: "%02d-%@__%@.wav", index + 1,
                          pair.0.deletingPathExtension().lastPathComponent,
                          pair.1.deletingPathExtension().lastPathComponent)
        let out = outDir.appendingPathComponent(name)
        let opts = renderOptions(args)
        var rendered = "—"
        do {
            let r = try Audition.render(d, to: out, preRoll: opts.pre, postRoll: opts.post)
            renderFactors.append(r.realtimeFactor)
            rendered = "[\(name)](\(name)) @ \(mmss(r.overlapStart))"
            print("[\(index + 1)/\(pairs.count)] \(name)  "
                  + "\(d.tier)/\(d.planKind)/\(d.styleDescription)  "
                  + "\(f(r.realtimeFactor, 1))×")
        } catch {
            rendered = "render failed: \(error.localizedDescription)"
            print("[\(index + 1)/\(pairs.count)] \(name)  RENDER FAILED: "
                  + error.localizedDescription)
        }
        rows.append("| \(d.outgoingName) → \(d.incomingName) | \(d.tier)"
                    + (d.demotedByKey ? " (key)" : "")
                    + " | \(f(d.loudnessGapDB)) | \(f(d.rawLoudnessGapDB))"
                    + " | \(f(d.trimmedLoudnessGapDB)) | \(f(d.rideDB))"
                    + " | \(f(d.outgoingTrimDB))/\(f(d.incomingTrimDB))"
                    + " | \(f(d.timbreDistance, 3))"
                    + " | \(optional(d.tempoRatio, 3)) | \(d.keyDistance.map(String.init) ?? "—")"
                    + " | \(optional(d.outgoingVocalScore))/\(optional(d.incomingVocalScore))"
                    + " | \(d.planTrace.blocker?.label ?? "—")"
                    + " | \(d.planKind) | \(d.styleDescription)"
                    + " | \(d.plannedStemTechnique ?? "—")"
                    + " | \(f(d.overlapDuration))s"
                    + " | \(d.outPoint.map(mmss) ?? "—") | \(rendered) |")
    }

    // Distribution: the thing to look at first after moving a threshold.
    func histogram(_ title: String, _ counts: [(String, Int)]) -> String {
        var out = ["**\(title)**", ""]
        for (label, count) in counts where count > 0 {
            out.append("- `\(label)`: \(count)  \(String(repeating: "█", count: count))")
        }
        out.append("")
        return out.joined(separator: "\n")
    }
    func tally(_ key: (Audition.Decision) -> String) -> [(String, Int)] {
        Dictionary(grouping: decisions, by: key)
            .map { ($0.key, $0.value.count) }
            .sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
    }

    let fades = decisions.map(\.overlapDuration).sorted()
    let fadeSummary: String
    if fades.isEmpty {
        fadeSummary = "n/a"
    } else {
        let mean = fades.reduce(0, +) / Double(fades.count)
        fadeSummary = "min \(f(fades.first!))s · median \(f(fades[fades.count / 2]))s · "
            + "mean \(f(mean))s · max \(f(fades.last!))s"
    }

    var summary = ["## Distribution", ""]
    summary.append(histogram("Tier", tally { $0.tier }))
    summary.append(histogram("Plan", tally { $0.planKind }))
    summary.append(histogram("Style", tally { $0.styleDescription }))
    if decisions.contains(where: \.stemsReady) {
        summary.append(histogram("Planner-chosen stem technique",
                                 tally { $0.plannedStemTechnique ?? "(none)" }))
    }
    summary.append("**Overlap length** — \(fadeSummary)\n")

    // Loudness compensation: what the per-track trims did to the gap the tier
    // gate reads, and how far the trims had to reach.
    func spread(_ xs: [Double]) -> String {
        guard !xs.isEmpty else { return "n/a" }
        let sorted = xs.sorted()
        let mean = sorted.reduce(0, +) / Double(sorted.count)
        return "min \(f(sorted.first!)) · median \(f(sorted[sorted.count / 2])) · "
            + "mean \(f(mean)) · max \(f(sorted.last!))"
    }
    let rawGaps = decisions.map(\.rawLoudnessGapDB)
    let trimmedGaps = decisions.map(\.trimmedLoudnessGapDB)
    let gaps = decisions.map(\.loudnessGapDB)
    let trims = decisions.flatMap { [$0.outgoingTrimDB, $0.incomingTrimDB] }
    let rides = decisions.map(\.rideDB)
    summary.append("**Loudness gap (dB)** — ① raw: \(spread(rawGaps))")
    summary.append("")
    summary.append("**Loudness gap (dB)** — ② after the whole-track trims: \(spread(trimmedGaps))")
    summary.append("")
    summary.append("**Loudness gap (dB)** — ③ after the transition gain ride "
                   + "(what the tier gate reads): \(spread(gaps))")
    summary.append("")
    summary.append("**Per-track playback trim (dB)** — \(spread(trims))")
    summary.append("")
    let ridden = rides.filter { abs($0) > 0.005 }
    summary.append("**Transition gain ride (dB, signed, on the incoming deck)** — "
                   + "\(ridden.count)/\(rides.count) pairs ride at all; "
                   + "over those: \(spread(ridden.map { abs($0) })) of |ride|")
    summary.append("")
    let neutralLine = Audition.standardConfig["neutralLoudnessDB"] ?? 0
    let clashLine = Audition.standardConfig["clashLoudnessDB"] ?? 0
    func over(_ xs: [Double], _ line: Double) -> Int { xs.filter { $0 > line }.count }
    summary.append("**Pairs the loudness signal alone would demote** (① → ② → ③) — "
                   + "over the tolerance line (\(f(neutralLine, 1)) dB): "
                   + "\(over(rawGaps, neutralLine)) → \(over(trimmedGaps, neutralLine))"
                   + " → \(over(gaps, neutralLine)); "
                   + "over the red line (\(f(clashLine, 1)) dB): "
                   + "\(over(rawGaps, clashLine)) → \(over(trimmedGaps, clashLine))"
                   + " → \(over(gaps, clashLine))")
    summary.append("")
    summary.append(contentsOf: eliminationSection(decisions))

    let borderline = decisions.filter { !$0.nearMisses.isEmpty }
    if !borderline.isEmpty {
        summary.append("**Borderline pairs** (a threshold nudge would reclassify these)\n")
        for d in borderline {
            for miss in d.nearMisses {
                summary.append("- \(d.outgoingName) → \(d.incomingName): \(miss)")
            }
        }
        summary.append("")
    }
    if !renderFactors.isEmpty {
        let mean = renderFactors.reduce(0, +) / Double(renderFactors.count)
        summary.append("**Offline render speed** — \(f(renderFactors.min()!, 1))×–"
                       + "\(f(renderFactors.max()!, 1))× real time (mean \(f(mean, 1))×)\n")
    }

    let document = ([
        "# AutoMix transition decisions",
        "",
        "Corpus: `\(corpus.path)` · \(pairs.count) pairs · "
            + "generated \(ISO8601DateFormatter().string(from: Date()))",
        "",
        summary.joined(separator: "\n"),
        "## Per-pair decisions",
        "",
        "| pair | tier | loudness dB | raw loudness dB | trimmed loudness dB | ride dB "
            + "| trim out/in dB "
            + "| timbre | tempo | key | vocals out/in | blocked at "
            + "| plan | style | stem | overlap | out point | render |",
        "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|",
    ] + rows).joined(separator: "\n") + "\n"

    let docURL = outDir.appendingPathComponent("decisions.md")
    do {
        try document.write(to: docURL, atomically: true, encoding: .utf8)
    } catch {
        fail("could not write \(docURL.path): \(error.localizedDescription)")
    }
    print("\n" + summary.joined(separator: "\n"))
    print("wrote \(docURL.path)")
}

// MARK: - Structure sweep
//
// P3's before/after evidence. The structure layer only ever changes *where* a
// hand-over lands, never whether one happens, so the question it has to answer
// is not a histogram of tiers — it is one row per seam: did the out point move,
// onto what, did the lyric snap fire, did the climax guard fire, and did the
// plan shape change as a side effect.
//
// Both readings come from the same binary and the same cached analyses, a
// microsecond apart: "old" is this planner with all four structure knobs turned
// off, which is byte-identical to the pre-P3 decision, and "new" is the shipped
// defaults. So a difference in the table is the layer and nothing else.

/// The knobs that, all off, reproduce the pre-structure decision exactly.
let structureOffOverrides: [String: Double] = [
    "useStructureOutPoints": 0,
    "useStructureInPoint": 0,
    "lyricSnapMaxSeconds": 0,
    "climaxGuardBarsBefore": 0,
    "climaxGuardBarsAfter": 0,
]

/// One structure gate's number off a decision's ledger.
func structureGate(_ d: Audition.Decision, _ id: String) -> PlanGate? {
    d.planTrace.gates.last { $0.stage == .structure && $0.id == id }
}

/// One beat-match gate's row, for the tempo-ramp sweep.
func beatMatchGate(_ d: Audition.Decision, _ id: String) -> PlanGate? {
    d.planTrace.gates.last { $0.stage == .beatMatch && $0.id == id }
}

/// The knob that, off, reproduces the pre-ramp decision exactly: the old caps
/// come back and the plan carries no ramp fields.
let tempoRampOffOverrides: [String: Double] = ["tempoRampEnabled": 0]

/// The four admission gates that were loosened together, each at the value it
/// held before. Applied all at once they reproduce the tighter planner; applied
/// one at a time they are what lets a changed seam be *attributed* to one of
/// them rather than to "the release".
let tightGateOverrides: [(knob: String, was: Double, label: String)] = [
    ("rideMaxCutDB", 4, "ride"),
    ("neutralOverlapCap", 6, "cap"),
    ("sectionSteadyCV", 0.4, "CV"),
    ("rampMaxRateDeviation", 0.06, "rate"),
]

/// P4's before/after evidence, and the mirror image of the structure sweep
/// above: the tempo ramp only ever changes *whether* a seam can be beat-matched
/// at all (a wider gate the glide pays for), so the question is one row per
/// seam — what did it get before, what does it get now, and what does each deck
/// have to bend to earn it.
func runTempoSweep(_ args: Arguments, pairs: [(playlist: String, a: URL, b: URL)],
                   corpus: URL, playlists: Int) {
    let extra = configOverrides(args)
    // Read back off the decision's own resolved config rather than re-deriving
    // it here, so a `--set rampLeadSeconds=…` run reports the lead it used.
    var lead = 0.0
    var rows: [String] = []
    var upgraded = 0, alreadyMatched = 0, stillNot = 0
    var bends: [Double] = []
    var blockers: [String: Int] = [:]

    for (index, pair) in pairs.enumerated() {
        var oldArgs = args
        oldArgs.flags["set"] = (tempoRampOffOverrides.merging(extra) { a, _ in a })
            .map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        let old = decide(oldArgs, a: pair.a, b: pair.b)
        let new = decide(args, a: pair.a, b: pair.b)
        lead = new.config["rampLeadSeconds"] ?? lead

        let wasMatched = old.planKind == "beatMatched"
        let isMatched = new.planKind == "beatMatched"
        if isMatched && !wasMatched { upgraded += 1 }
        else if isMatched { alreadyMatched += 1 }
        else {
            stillNot += 1
            blockers[new.planTrace.blocker?.id ?? "—", default: 0] += 1
        }

        // The bend each deck takes, and the gap it is closing. Read off the new
        // decision's own ledger so the numbers are the ones the gate compared.
        let delta = beatMatchGate(new, "bpmDelta")?.value
        let outBend = new.outgoingRate.map { (Double($0) - 1) * 100 }
        let inBend = new.incomingRate.map { (Double($0) - 1) * 100 }
        if isMatched && !wasMatched, let outBend { bends.append(abs(outBend)) }

        let marker = (isMatched && !wasMatched) ? "  ← newly beat-matched" : ""
        print("[\(index + 1)/\(pairs.count)] \(pair.playlist) · \(old.outgoingName) → "
              + "\(old.incomingName)  \(old.planKind) → \(new.planKind)"
              + (delta.map { String(format: "  (Δ%.1f %%)", $0 * 100) } ?? "") + marker)
        rows.append("| \(pair.playlist) | \(old.outgoingName) → \(old.incomingName)"
                    + " | \(f(old.outgoingBPM, 1)) → \(f(old.incomingBPM, 1))"
                    + " | \(delta.map { f($0 * 100, 1) + " %" } ?? "—")"
                    + " | \(old.planKind) → \(new.planKind)"
                    + " | \(outBend.map { String(format: "%+.2f %%", $0) } ?? "—")"
                    + " | \(inBend.map { String(format: "%+.2f %%", $0) } ?? "—")"
                    + " | \(isMatched ? f(lead, 1) + " s" : "—")"
                    + " | \(f(old.overlapDuration)) → \(f(new.overlapDuration)) s"
                    + " | \(isMatched && !wasMatched ? "**yes**" : "—")"
                    // Why *this* seam is not beat-matched. Without it a table
                    // of unchanged rows says nothing: a pair blocked at the
                    // tempo-confidence gate was never a candidate for the
                    // widening, and must not be read as evidence against it.
                    + " | \(new.planTrace.blocker?.id ?? "—") |")
    }

    var summary = ["## Tempo-ramp sweep", "",
                   "Corpus: `\(corpus.path)` · \(pairs.count) seams across \(playlists) "
                   + "playlists · generated "
                   + ISO8601DateFormatter().string(from: Date()),
                   "",
                   "`old` = `tempoRampEnabled=0` (byte-identical to the pre-ramp planner: "
                   + "±8 % gap, ±4 % bend, stepped) · `new` = shipped defaults "
                   + "(±11.5 % gap, ±6 % bend, "
                   + String(format: "%.1f s glide).", lead), ""]
    summary.append("- newly beat-matched (was crossfade/gapless for tempo reasons): "
                   + "\(upgraded)/\(pairs.count)")
    summary.append("- already beat-matched under the old caps: \(alreadyMatched)/\(pairs.count)")
    summary.append("- still not beat-matched: \(stillNot)/\(pairs.count)")
    if !blockers.isEmpty {
        summary.append("  - blocked at: "
                       + blockers.sorted { $0.value > $1.value }
                           .map { "`\($0.key)` ×\($0.value)" }.joined(separator: ", "))
    }
    if !bends.isEmpty {
        let sorted = bends.sorted()
        summary.append(String(format: "  - outgoing bend on the new ones: min %.2f %% · "
                              + "median %.2f %% · max %.2f %%",
                              sorted.first!, sorted[sorted.count / 2], sorted.last!))
    }
    summary.append("")

    let document = (summary + [
        "| playlist | pair | BPM out → in | folded gap | plan | out bend | in bend "
            + "| ramp lead | overlap | new | blocked at |",
        "|---|---|---|---|---|---|---|---|---|---|---|",
    ] + rows).joined(separator: "\n") + "\n"
    emitSweep(document, args)
}

/// The four-gate counterfactual. `old` is every loosened gate back at its
/// previous value, `new` is the shipped defaults — and for each seam that
/// changed, the knobs are re-tightened **one at a time** to find which one was
/// actually responsible.
///
/// Attribution by single-knob revert rather than by reading the trace: several
/// of these gates feed each other (a deeper ride changes the tier, which
/// changes the overlap cap that applies, which changes the length the
/// steadiness bar is asked about), so "which gate's number moved" is not the
/// same question as "which knob caused this". Reverting one and re-planning
/// answers the second one directly.
func runGateSweep(_ args: Arguments, pairs: [(playlist: String, a: URL, b: URL)],
                  corpus: URL, playlists: Int) {
    let extra = configOverrides(args)
    func spec(_ overrides: [String: Double]) -> String {
        overrides.merging(extra) { a, _ in a }
            .map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    }
    let allTight = Dictionary(uniqueKeysWithValues:
        tightGateOverrides.map { ($0.knob, $0.was) })

    var rows: [String] = []
    var changed = 0
    var byKnob: [String: Int] = [:]
    var tierChanged = 0, kindChanged = 0

    for (index, pair) in pairs.enumerated() {
        var oldArgs = args
        oldArgs.flags["set"] = spec(allTight)
        let old = decide(oldArgs, a: pair.a, b: pair.b)
        let new = decide(args, a: pair.a, b: pair.b)

        let movedTier = old.tier != new.tier
        let movedKind = old.planKind != new.planKind
        let movedLength = abs(old.overlapDuration - new.overlapDuration) > 0.01
        guard movedTier || movedKind || movedLength else { continue }
        changed += 1
        if movedTier { tierChanged += 1 }
        if movedKind { kindChanged += 1 }

        // Which single knob, put back, undoes the change?
        var culprits: [String] = []
        for gate in tightGateOverrides {
            var probeArgs = args
            probeArgs.flags["set"] = spec([gate.knob: gate.was])
            let probe = decide(probeArgs, a: pair.a, b: pair.b)
            if probe.tier == old.tier && probe.planKind == old.planKind
                && abs(probe.overlapDuration - old.overlapDuration) <= 0.01 {
                culprits.append(gate.label)
            }
        }
        // No single revert reproduces the old decision: the gates combined.
        let attribution = culprits.isEmpty ? "combined" : culprits.joined(separator: "+")
        for label in (culprits.isEmpty ? ["combined"] : culprits) {
            byKnob[label, default: 0] += 1
        }

        print("[\(index + 1)/\(pairs.count)] \(pair.playlist) · \(old.outgoingName) → "
              + "\(old.incomingName)  \(old.tier)→\(new.tier)  "
              + "\(old.planKind)→\(new.planKind)  "
              + String(format: "%.2f→%.2f s", old.overlapDuration, new.overlapDuration)
              + "  [\(attribution)]")
        rows.append("| \(pair.playlist) | \(old.outgoingName) → \(old.incomingName)"
                    + " | \(old.tier) → \(new.tier)"
                    + " | \(old.planKind) → \(new.planKind)"
                    + " | \(f(old.overlapDuration)) → \(f(new.overlapDuration)) s"
                    + " | \(f(old.rideDB, 1)) → \(f(new.rideDB, 1)) dB"
                    + " | \(f(old.loudnessGapDB, 1)) → \(f(new.loudnessGapDB, 1)) dB"
                    + " | **\(attribution)** |")
    }

    var summary = ["## Admission-gate sweep", "",
                   "Corpus: `\(corpus.path)` · \(pairs.count) seams across \(playlists) "
                   + "playlists · generated "
                   + ISO8601DateFormatter().string(from: Date()),
                   "",
                   "`old` = all four gates at their previous values ("
                   + tightGateOverrides.map { "`\($0.knob)`=\(f($0.was, 3))" }
                       .joined(separator: ", ")
                   + ") · `new` = shipped defaults.",
                   "",
                   "Attribution is by single-knob revert: a seam is credited to "
                   + "every knob that, put back on its own, restores the old decision. "
                   + "`combined` means no single revert does — the gates only move it "
                   + "together.", ""]
    summary.append("- seams whose decision changed: \(changed)/\(pairs.count)")
    summary.append("  - tier changed: \(tierChanged) · plan kind changed: \(kindChanged)")
    if !byKnob.isEmpty {
        summary.append("  - attributed to: "
                       + byKnob.sorted { $0.value > $1.value }
                           .map { "`\($0.key)` ×\($0.value)" }.joined(separator: ", "))
    }
    summary.append("")

    let document = (summary + [
        "| playlist | pair | tier | plan | overlap | ride | residual gap | knob |",
        "|---|---|---|---|---|---|---|---|",
    ] + (rows.isEmpty ? ["| — | *no seam changed* | | | | | | |"] : rows))
        .joined(separator: "\n") + "\n"
    emitSweep(document, args)
}

func emitSweep(_ document: String, _ args: Arguments) {
    if let out = args.flags["output"] {
        let docURL = url(out)
        try? FileManager.default.createDirectory(at: docURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        do { try document.write(to: docURL, atomically: true, encoding: .utf8) }
        catch { fail("could not write \(docURL.path): \(error.localizedDescription)") }
        print("\nwrote \(docURL.path)")
    } else {
        print("\n" + document)
    }
}

func runSweep(_ args: Arguments) {
    guard let dirArg = args.positional.first else { fail(usage) }
    let corpus = url(dirArg)
    let audioExtensions: Set<String> = ["flac", "mp3", "m4a", "wav", "aiff", "caf", "aac"]
    let files = ((try? FileManager.default.contentsOfDirectory(
        at: corpus, includingPropertiesForKeys: nil)) ?? [])
        .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
        .filter { !StemService.isStemSidecar($0) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard files.count >= 2 else { fail("need at least two audio files in \(corpus.path)") }

    // The corpus is one flat directory of `p<playlist>-<index>-…` files. Seams
    // only make sense *inside* a playlist — pairing the last track of one with
    // the first of the next is a seam no listener will ever hear.
    var playlists: [String: [URL]] = [:]
    for file in files {
        let name = file.lastPathComponent
        let key = name.split(separator: "-").first.map(String.init) ?? "all"
        playlists[key, default: []].append(file)
    }
    var pairs: [(playlist: String, a: URL, b: URL)] = []
    for key in playlists.keys.sorted() {
        let group = playlists[key]!
        for (a, b) in zip(group, group.dropFirst()) { pairs.append((key, a, b)) }
    }

    // Same corpus walk, two questions. `--mode tempo` asks the P4 one (did the
    // ramp widen the beat-match gate onto this seam); the default asks P3's.
    switch args.flags["mode"] ?? "structure" {
    case "structure": break
    case "tempo":
        runTempoSweep(args, pairs: pairs, corpus: corpus, playlists: playlists.count)
        return
    case "gates":
        runGateSweep(args, pairs: pairs, corpus: corpus, playlists: playlists.count)
        return
    case let other: fail("unknown --mode '\(other)'; expected structure|tempo|gates")
    }

    let extra = configOverrides(args)
    var rows: [String] = []
    var moved = 0, snapped = 0, guarded = 0, inMoved = 0, shapeChanged = 0
    var shifts: [Double] = []

    for (index, pair) in pairs.enumerated() {
        var oldArgs = args
        oldArgs.flags["set"] = (structureOffOverrides.merging(extra) { a, _ in a })
            .map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        let old = decide(oldArgs, a: pair.a, b: pair.b)
        let new = decide(args, a: pair.a, b: pair.b)

        let outOld = old.outPoint, outNew = new.outPoint
        let inOld = old.inPoint, inNew = new.inPoint
        let outShift = (outNew ?? 0) - (outOld ?? 0)
        if abs(outShift) > 0.01 { moved += 1; shifts.append(outShift) }
        if abs((inNew ?? 0) - (inOld ?? 0)) > 0.01 { inMoved += 1 }
        if old.planKind != new.planKind
            || abs(old.overlapDuration - new.overlapDuration) > 0.01 { shapeChanged += 1 }

        let snap = structureGate(new, "lyricSnap")?.value ?? 0
        if snap > 0.005 { snapped += 1 }
        let guardGate = structureGate(new, "climaxGuard")
        let rejected = Int(guardGate?.value ?? 0)
        let guardFired = rejected > 0
        if guardFired { guarded += 1 }
        let candidates = structureGate(new, "structureCandidates")
        var guardCell = "—"
        if guardFired {
            guardCell = "\(rejected) rejected"
            // `passed == false` on this gate means every candidate was inside
            // the window, so the guard gave way rather than block the seam.
            if guardGate?.passed == false { guardCell += " (stood down)" }
        }

        let name = "\(pair.playlist) · \(old.outgoingName) → \(old.incomingName)"
        print("[\(index + 1)/\(pairs.count)] \(name)  "
              + "out \(optional(outOld)) → \(optional(outNew))"
              + (abs(outShift) > 0.01 ? String(format: "  (%+.1f s)", outShift) : "  (=)"))
        rows.append("| \(pair.playlist) | \(old.outgoingName) → \(old.incomingName)"
                    + " | \(outOld.map(mmss) ?? "—") | \(outNew.map(mmss) ?? "—")"
                    + " | \(abs(outShift) > 0.01 ? String(format: "%+.1f", outShift) : "=")"
                    + " | \(new.outPointSection ?? "—")"
                    + " | \(inOld.map(mmss) ?? "—") | \(inNew.map(mmss) ?? "—")"
                    + " | \(new.inPointSection ?? "—")"
                    + " | \(snap > 0.005 ? String(format: "−%.2fs", snap) : "—")"
                    + " | \(guardCell)"
                    + " | \(Int(candidates?.value ?? 0))"
                    + " | \(f(old.outgoingStructureConfidence, 2))"
                    + "/\(f(new.incomingStructureConfidence, 2))"
                    + " | \(old.planKind) → \(new.planKind)"
                    + " | \(f(old.overlapDuration)) → \(f(new.overlapDuration)) s |")
    }

    var summary = ["## Structure sweep", "",
                   "Corpus: `\(corpus.path)` · \(pairs.count) seams across "
                   + "\(playlists.count) playlists · generated "
                   + ISO8601DateFormatter().string(from: Date()),
                   "",
                   "`old` = every structure knob off (byte-identical to the pre-P3 "
                   + "planner) · `new` = shipped defaults.", ""]
    summary.append("- out point moved: \(moved)/\(pairs.count)")
    if !shifts.isEmpty {
        let sorted = shifts.sorted()
        summary.append(String(format: "  - shift: min %+.1f s · median %+.1f s · max %+.1f s",
                              sorted.first!, sorted[sorted.count / 2], sorted.last!))
    }
    summary.append("- in point moved: \(inMoved)/\(pairs.count)")
    summary.append("- lyric snap fired: \(snapped)/\(pairs.count)")
    summary.append("- climax guard rejected at least one candidate: \(guarded)/\(pairs.count)")
    summary.append("- plan kind or overlap changed: \(shapeChanged)/\(pairs.count)")
    summary.append("")

    let document = (summary + [
        "| playlist | pair | out old | out new | Δ | out section (new) | in old | in new "
            + "| in section (new) | lyric snap | climax guard | structural candidates "
            + "| structure conf out/in | plan | overlap |",
        "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|",
    ] + rows).joined(separator: "\n") + "\n"
    emitSweep(document, args)
}

// MARK: - order

/// Quality levels the app can serve, cheapest first — the same ladder
/// `AudioQuality` spells, kept here as strings because a cache file name is
/// the only place the CLI ever meets one.
let qualityLadder = ["standard", "higher", "exhigh", "lossless", "hires",
                     "jyeffect", "sky", "jymaster"]

/// `<trackID>-<level>-<source>.<ext>` — the app's cache naming. Nil for a file
/// that does not follow it (a hand-made corpus), which simply opts that file
/// out of the low-bitrate comparison.
func cacheKeyParts(_ url: URL) -> (trackID: String, level: String)? {
    let stem = url.deletingPathExtension().lastPathComponent
    let parts = stem.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
    guard parts.count == 3, !parts[0].isEmpty, parts[0].allSatisfy(\.isNumber) else { return nil }
    return (String(parts[0]), String(parts[1]))
}

func levelRank(_ level: String) -> Int {
    qualityLadder.firstIndex(of: level) ?? qualityLadder.count
}

/// Audio in a directory that already has a usable analysis sidecar.
///
/// `order` is an offline, read-only tool: it never analyzes and never touches
/// the network, so a file without a sidecar is simply not material. That is
/// what lets it be pointed straight at the live cache.
func analyzedCorpus(_ dir: URL) -> [URL] {
    let audioExtensions: Set<String> = ["flac", "mp3", "m4a", "wav", "aiff", "caf", "aac"]
    return ((try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: nil)) ?? [])
        .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
        .filter { !StemService.isStemSidecar($0) }
        .filter { Audition.hasCachedAnalysis(for: $0) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

/// Split a corpus into playlists the way `sweep` does (`p<N>-…`), or hand back
/// one group when the names carry no playlist marker — the live cache does not.
func orderGroups(_ files: [URL]) -> [(name: String, files: [URL])] {
    var groups: [String: [URL]] = [:]
    for file in files {
        let head = file.lastPathComponent.split(separator: "-").first.map(String.init) ?? ""
        let isPlaylistMarker = head.count > 1 && head.hasPrefix("p")
            && head.dropFirst().allSatisfy(\.isNumber)
        groups[isPlaylistMarker ? head : "all", default: []].append(file)
    }
    return groups.keys.sorted().map { ($0, groups[$0]!) }
}

func tierBar(_ schedule: Audition.OrderSchedule) -> String {
    guard schedule.pairs > 0 else { return "—" }
    let counts = schedule.tierCounts
    return Audition.orderTierLabels.reversed().compactMap { label -> String? in
        guard let n = counts[label], n > 0 else { return nil }
        return "\(label) \(n)"
    }.joined(separator: " · ")
}

func orderShare(_ part: Int, _ whole: Int) -> Double {
    whole == 0 ? 0 : 100 * Double(part) / Double(whole)
}

/// The beat-matched share of the first / middle / last third of a schedule.
///
/// The overall share is an average, and an average hides exactly the failure
/// this column exists to catch: greedy spending its compatible pairs early and
/// leaving the tail to escape clusters on aging alone.
func thirdsBar(_ schedule: Audition.OrderSchedule) -> String {
    guard schedule.pairs > 0 else { return "—" }
    return "thirds " + schedule.thirds.map {
        String(format: "%.0f %%", $0.share)
    }.joined(separator: " / ")
}

func thirdsDetail(_ schedule: Audition.OrderSchedule) -> String {
    schedule.thirds.map { "\($0.beatMatched)/\($0.pairs)" }.joined(separator: " · ")
}

/// The escalation's price tag, in one line: what a pick costs on average, what
/// the worst one cost, and how often "good enough" was actually reached.
func escalationCostLine(_ e: Audition.OrderEscalation) -> String {
    guard e.picks > 0 else { return "escalation: no picks" }
    return String(
        format: "%.2f downloads/pick (max %d of %d allowed, %d total over %d picks) · "
            + "≤%d rounds · satisfied %d/%d (%.0f %%) at %@ · budget-stopped %d",
        e.averageDownloads, e.maxDownloads, e.budget, e.totalDownloads, e.picks, e.maxRounds,
        e.satisfied, e.picks, orderShare(e.satisfied, e.picks), e.satisfyingTier, e.budgeted)
}

func runOrder(_ args: Arguments) {
    guard let dirArg = args.positional.first else { fail(usage) }
    let corpus = url(dirArg)
    let all = analyzedCorpus(corpus)
    guard all.count >= 2 else {
        fail("need at least two analyzed tracks in \(corpus.path) (found \(all.count)); "
             + "`order` never analyzes — it reads `.analysis.json` sidecars")
    }

    // A cache holds several quality levels of the same track. The schedule is
    // built from the *best* level present per track; the extra copies are the
    // material for the low-bitrate agreement check further down.
    var byTrack: [String: [(level: String, url: URL)]] = [:]
    var unkeyed: [URL] = []
    for file in all {
        if let parts = cacheKeyParts(file) {
            byTrack[parts.trackID, default: []].append((parts.level, file))
        } else {
            unkeyed.append(file)
        }
    }
    var playback: [URL] = unkeyed
    var lowQuality: [String: URL] = [:]
    for (_, entries) in byTrack {
        let sorted = entries.sorted { levelRank($0.level) < levelRank($1.level) }
        let best = sorted.last!.url
        playback.append(best)
        if sorted.count > 1 { lowQuality[best.path] = sorted.first!.url }
    }
    // An explicit second directory of low-bitrate copies, matched by track ID.
    if let lowArg = args.flags["low-dir"] {
        var lowByTrack: [String: URL] = [:]
        for file in analyzedCorpus(url(lowArg)) {
            guard let parts = cacheKeyParts(file) else { continue }
            lowByTrack[parts.trackID] = file
        }
        for file in playback {
            guard let parts = cacheKeyParts(file),
                  let low = lowByTrack[parts.trackID] else { continue }
            lowQuality[file.path] = low
        }
    }
    playback.sort { $0.lastPathComponent < $1.lastPathComponent }

    // `--bench` answers one question and stops: what does the scoring itself
    // cost at this pool size, on the main actor, in milliseconds. The selector
    // runs on the main actor, so this is the number that decides whether the
    // chain can be computed there at all.
    if args.flags["bench"] != nil {
        do {
            let bench = try Audition.orderBench(
                files: playback, config: configOverrides(args),
                orderConfig: orderConfigOverrides(args))
            print(String(
                format: "\npool %d tracks\n  one plan+score   %8.3f ms"
                    + "\n  one rank (pool)  %8.1f ms"
                    + "\n  future (%@, K=%d, cap %d)  %8.1f ms"
                    + "\n  one pick         %8.1f ms   ← rank + future, against a 50 ms tripwire"
                    + "\n  chain (depth %d) %8.1f ms   ← what one lookahead refresh costs",
                bench.poolSize, bench.planMS, bench.rankMS,
                bench.futureMode, bench.futureTopK, bench.futurePoolCap, bench.futureMS,
                bench.pickMS, bench.depth, bench.chainMS))
        } catch {
            fail("bench: \(error.localizedDescription)")
        }
        exit(0)
    }

    let window = args.double("window").map { Int($0) } ?? 4
    let limit = args.double("limit").map { Int($0) }
    let candidateLimit = args.double("candidates").map { Int($0) } ?? 6
    let extra = configOverrides(args)
    let orderOverrides = orderConfigOverrides(args)

    var sections: [String] = []
    var totals: [(label: String, pairs: Int, beatMatched: Int,
                  thirds: [Audition.OrderSchedule.Third])] = []
    var rows: [String] = []
    var escalations: [Audition.OrderEscalation] = []

    for group in orderGroups(playback) {
        var files = group.files
        if let limit, files.count > limit { files = Array(files.prefix(limit)) }
        guard files.count >= 2 else { continue }
        print("\n## \(group.name) — \(files.count) analyzed tracks")

        let schedules: [Audition.OrderSchedule]
        let escalation: Audition.OrderEscalation
        do {
            escalation = try Audition.orderEscalating(
                files: files, config: extra, orderConfig: orderOverrides,
                candidateLimit: candidateLimit)
            schedules = [
                try Audition.orderBaseline(files: files, config: extra),
                try Audition.order(files: files, window: window, config: extra,
                                   orderConfig: orderOverrides, candidateLimit: candidateLimit),
                escalation.schedule,
                try Audition.order(files: files, window: nil, config: extra,
                                   orderConfig: orderOverrides, candidateLimit: candidateLimit),
            ]
        } catch {
            fail("\(group.name): \(error.localizedDescription)")
        }
        escalations.append(escalation)

        for schedule in schedules {
            print("  " + schedule.label.padding(toLength: 22, withPad: " ", startingAt: 0)
                  + String(format: "  beatMatched %d/%d (%.0f %%)   ",
                           schedule.beatMatched, schedule.pairs,
                           orderShare(schedule.beatMatched, schedule.pairs))
                  + thirdsBar(schedule) + "   " + tierBar(schedule))
            totals.append((schedule.label, schedule.pairs, schedule.beatMatched,
                           schedule.thirds))
            rows.append("| \(group.name) | \(schedule.label) | \(schedule.beatMatched)"
                        + "/\(schedule.pairs) | \(thirdsDetail(schedule)) "
                        + "| \(tierBar(schedule)) |")
        }

        print("  escalation cost         " + escalationCostLine(escalation))

        sections.append("### \(group.name)\n")
        sections.append("**escalation cost** — " + escalationCostLine(escalation) + "\n")
        for schedule in schedules {
            sections.append("**\(schedule.label)** — beatMatched \(schedule.beatMatched)"
                            + "/\(schedule.pairs) · \(thirdsBar(schedule)) "
                            + "(\(thirdsDetail(schedule))) · \(tierBar(schedule))\n")
            sections.append(schedule.names.enumerated().map { i, name in
                "\(i + 1). \(name)"
                    + (i < schedule.tiers.count ? "  →  _\(schedule.tiers[i])_" : "")
            }.joined(separator: "\n") + "\n")
        }
        // The pick table for the schedule that had the whole cache to choose
        // from — the one whose candidate list is worth reading.
        if let greedy = schedules.last, !greedy.steps.isEmpty {
            sections.append("<details><summary>candidate scores (\(greedy.label))</summary>\n")
            sections.append("| seam | candidate | tier | tempo | key | style | energy "
                            + "| aging | same artist | future | total |")
            sections.append("|---|---|---|---|---|---|---|---|---|---|---|")
            for step in greedy.steps {
                for c in step.candidates {
                    sections.append("| \(step.position). \(step.from) → | "
                                    + (c.chosen ? "**\(c.name)**" : c.name)
                                    + " | \(c.tier) | \(f(c.tempoAffinity)) | \(f(c.keyAffinity))"
                                    + " | \(f(c.styleAffinity)) | \(f(c.energyContinuity))"
                                    + " | \(f(c.aging)) | \(f(c.sameArtistPenalty))"
                                    + " | \(f(c.futureRichness)) | \(f(c.total)) |")
                }
            }
            sections.append("\n</details>\n")
        }
    }

    // Low-bitrate agreement (predev §2.2 and its risk row): only when the
    // corpus actually holds both levels of the same track. Skipped — loudly —
    // when it does not; that is a fact about the inputs, not a failure.
    var agreementLines: [String]
    if lowQuality.isEmpty {
        agreementLines = ["Low-bitrate tier agreement: **skipped** — no track in this corpus has "
                          + "both a low-bitrate and a playback-quality analysis. Point "
                          + "`--low-dir` at a directory of low-bitrate copies to measure it."]
        print("\nlow-bitrate tier agreement: skipped (no dual-level tracks in the corpus)")
    } else {
        do {
            let agreement = try Audition.orderTierAgreement(
                files: playback, lowQuality: lowQuality, config: extra)
            let share = orderShare(agreement.agreed, agreement.pairs)
            agreementLines = [String(
                format: "Low-bitrate tier agreement: **%d/%d** (%.0f %%) of adjacent pairs get "
                    + "the same tier from the low-bitrate analysis as from the playback file.",
                agreement.agreed, agreement.pairs, share)]
            print(String(format: "\nlow-bitrate tier agreement: %d/%d (%.0f %%)",
                         agreement.agreed, agreement.pairs, share))
            if !agreement.disagreements.isEmpty {
                agreementLines.append("")
                agreementLines += agreement.disagreements.map { "- \($0)" }
            }
        } catch {
            agreementLines = ["Low-bitrate tier agreement: failed — "
                              + error.localizedDescription]
        }
    }

    var summary = ["## Queue order", "",
                   "Corpus: `\(corpus.path)` · \(playback.count) analyzed tracks · generated "
                   + ISO8601DateFormatter().string(from: Date()),
                   "",
                   "`original order` walks the files as listed (filename order — for a live "
                   + "cache that is track-ID order, i.e. arbitrary with respect to the music, "
                   + "which is the point). `greedy W=\(window)` sees only the next \(window) "
                   + "listed entries at each pick; `greedy (all cached)` sees every remaining "
                   + "track, which is what a fully cached playlist really offers the selector. "
                   + "`escalation` is the shipping policy: it starts each pick from what it has "
                   + "already paid for and buys more — 1 track, then 4, then 16 — only until a "
                   + "candidate is good enough, so it is the only row here that comes with a "
                   + "cost.",
                   ""]
    var byLabel: [String: (pairs: Int, beatMatched: Int, thirds: [(Int, Int)])] = [:]
    var labelOrder: [String] = []
    for t in totals {
        if byLabel[t.label] == nil {
            labelOrder.append(t.label)
            byLabel[t.label] = (0, 0, [(0, 0), (0, 0), (0, 0)])
        }
        byLabel[t.label]!.pairs += t.pairs
        byLabel[t.label]!.beatMatched += t.beatMatched
        for i in 0..<3 {
            byLabel[t.label]!.thirds[i].0 += t.thirds[i].beatMatched
            byLabel[t.label]!.thirds[i].1 += t.thirds[i].pairs
        }
    }
    summary.append("Each schedule is also cut into **thirds** — the first, middle and last "
                   + "third of its seams. The overall share is an average, and it hides the "
                   + "failure mode this column exists to catch: a greedy that spends the "
                   + "compatible pairs while the pool is still rich and leaves the tail "
                   + "escaping clusters on aging alone.")
    summary.append("")
    summary.append("| schedule | beat-matched pairs | share | first third | middle | last third |")
    summary.append("|---|---|---|---|---|---|")
    for label in labelOrder {
        let t = byLabel[label]!
        let cells = t.thirds.map { third in
            String(format: "%d/%d (%.0f %%)", third.0, third.1,
                   orderShare(third.0, third.1))
        }
        summary.append(String(format: "| %@ | %d/%d | %.0f %% | %@ | %@ | %@ |",
                              label, t.beatMatched, t.pairs,
                              orderShare(t.beatMatched, t.pairs),
                              cells[0], cells[1], cells[2]))
    }
    summary.append("")
    if !escalations.isEmpty {
        let picks = escalations.reduce(0) { $0 + $1.picks }
        let downloads = escalations.reduce(0) { $0 + $1.totalDownloads }
        let worst = escalations.map(\.maxDownloads).max() ?? 0
        let rounds = escalations.map(\.maxRounds).max() ?? 0
        let satisfied = escalations.reduce(0) { $0 + $1.satisfied }
        let budgeted = escalations.reduce(0) { $0 + $1.budgeted }
        summary.append(String(
            format: "**Escalation cost** — %.2f low-bitrate downloads per pick on average "
                + "(worst pick %d against a budget of %d, %d in total over %d picks, at most "
                + "%d rounds). %d/%d picks (%.0f %%) ended because a candidate reached **%@**; "
                + "%d stopped on the budget and the rest ran the remaining queue out. "
                + "A budget stop is not a loss: the tracks that pick could not reach are still "
                + "unbought at the next one, which starts from a pool it just enriched — the "
                + "warming is amortised across songs rather than front-loaded onto the first. "
                + "Downloads leave analysis sidecars behind, so the cost is one-time per "
                + "playlist and the per-pick figure is an average over a run that begins cold.",
            picks == 0 ? 0 : Double(downloads) / Double(picks), worst,
            escalations[0].budget, downloads, picks, rounds,
            satisfied, picks, orderShare(satisfied, picks),
            escalations[0].satisfyingTier, budgeted))
        summary.append("")
    }
    summary += agreementLines
    summary.append("")

    let document = (summary
                    + ["| playlist | schedule | beat-matched | thirds (1st · mid · last) "
                       + "| tiers |", "|---|---|---|---|---|"]
                    + rows + [""] + sections).joined(separator: "\n") + "\n"
    emitSweep(document, args)
}

/// `--order-set name=value,…` — the queue-order weights, kept apart from
/// `--set` so a sweep can move the planner and the scorer independently.
func orderConfigOverrides(_ args: Arguments) -> [String: Double] {
    guard let spec = args.flags["order-set"], spec != "true" else { return [:] }
    let known = Set(Audition.queueOrderFields.map(\.name))
    var out: [String: Double] = [:]
    for entry in spec.split(separator: ",") {
        let kv = entry.split(separator: "=", maxSplits: 1)
        guard kv.count == 2, let value = Double(kv[1]) else {
            fail("bad --order-set entry '\(entry)', expected name=value")
        }
        let name = String(kv[0])
        guard known.contains(name) else {
            fail("unknown queue-order knob '\(name)'; run `audition knobs` for the list")
        }
        out[name] = value
    }
    return out
}

// MARK: - Entry

let raw = Array(CommandLine.arguments.dropFirst())
guard let command = raw.first else { fail(usage) }
let args = Arguments(Array(raw.dropFirst()))

switch command {
case "plan": runPlan(args)
case "render": runRender(args)
case "batch": runBatch(args)
case "serve": runServe(args)
case "sweep": runSweep(args)
case "order": runOrder(args)
case "knobs": runKnobs(args)
case "-h", "--help", "help": print(usage)
default: fail("unknown command '\(command)'\n\n" + usage)
}

#else
import Foundation
FileHandle.standardError.write(Data("audition is macOS-only\n".utf8))
exit(1)
#endif
