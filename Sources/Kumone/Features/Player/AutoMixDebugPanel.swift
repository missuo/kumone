#if os(macOS) && DEBUG
import AppKit
import SwiftUI

// A developer window for listening tests: what AutoMix is doing, right now,
// without tailing a log while trying to hear a seam. macOS only — there is no
// AutoMix on iOS (every plan is `.gapless`), so there is nothing to watch.
//
// DEBUG builds only (as is its menu and window scene in `KumoneApp`).
// `Scripts/build-app.sh` defaults to the `debug` configuration, so the builds
// that go to the listening machine keep it; release builds never show it.
// `AutoMixDebugModel` itself stays compiled everywhere and is inert unless
// this panel opens it.
//
// Labels are hardcoded English. The app is zh-Hans-first and every user-facing
// string is a Chinese key in `Localizable.strings`, so each label here goes
// through `Text(verbatim:)` — that is the convention-compliant way to say "this
// string is not for translation" rather than leaking developer jargon into the
// string tables.

struct AutoMixDebugPanel: View {

    static let windowID = "automix-debug"
    /// A `String` rather than a literal on purpose: `Window(_:id:)`'s literal
    /// overload takes a `LocalizedStringKey`, and this title must not become
    /// one of those keys.
    static let windowTitle = String("AutoMix Debug")
    /// Same reason: `CommandMenu`'s literal overload localizes its name.
    static let menuTitle = String("Debug")

    @ObservedObject private var model = AutoMixDebugModel.shared
    @State private var alwaysOnTop = false
    @State private var showAllCandidates = false
    /// The note that will ride along with the next mark. Cleared on write, so
    /// a note is never silently attached to two different seams.
    @State private var markNote = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    nowGroup
                    orderGroup
                    nextGroup
                    planGroup
                    prerenderGroup
                    controlsGroup
                    seamsGroup
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Toggle(isOn: $alwaysOnTop) { Text(verbatim: "Always on top") }
                    .toggleStyle(.checkbox)
                    .onChange(of: alwaysOnTop) { _, on in setFloating(on) }
                Spacer()
                Text(verbatim: "mirror of PlayerService — read only")
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .font(.system(size: 11, design: .monospaced))
        // Wide enough for the queue-order candidate table's ten columns; the
        // ScrollView only scrolls vertically, so a narrower window would clip
        // the totals rather than wrap them.
        .frame(minWidth: 560, minHeight: 460)
        // The model only publishes while a window is open; nothing ticks for a
        // panel nobody has asked for.
        .onAppear { model.activate() }
        .onDisappear {
            model.deactivate()
            alwaysOnTop = false
        }
    }

    // MARK: - Groups

    private var nowGroup: some View {
        let now = model.snapshot.now
        return DebugGroup("Now") {
            DebugRow("track", now.title ?? "—")
            DebugRow("phase", now.phase)
            DebugRow("deck", now.deck)
            DebugRow("position", "\(AutoMixDebugFormat.clock(now.position))"
                     + " / \(AutoMixDebugFormat.clock(now.duration))")
            DebugRow("trim", String(format: "%+.2f dB", now.trimDB))
            DebugRow("analysis", now.analyzed ? "in hand" : "none")
            deckRow("deck A", now.deckA)
            deckRow("deck B", now.deckB)
        }
    }

    /// One deck's rate and gain stages. The rate goes red when it is bent with
    /// no transition to account for it — that combination *is* the watery-
    /// playback bug, and it is the reason this row exists.
    private func deckRow(_ label: String, _ deck: AutoMixDebugDeck) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: label)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            Text(verbatim: String(format: "×%.4f", deck.rate))
                .fontWeight(deck.rateIsSuspect ? .bold : .regular)
                .foregroundStyle(deck.rateIsSuspect ? Color.red : Color.primary)
            Text(verbatim: String(format: "pad %+.2f · ride %+.2f · trim %+.2f dB · %@",
                                  deck.ratePadDB, deck.rideDB, deck.trimDB, deck.role))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private var nextGroup: some View {
        let next = model.snapshot.next
        return DebugGroup("Next (prefetch)") {
            DebugRow("track", next.title ?? "—")
            DebugRow("stage", next.stage.label)
            if let bpm = next.bpm {
                DebugRow("bpm", String(format: "%.2f (conf %.2f)", bpm, next.bpmConfidence ?? 0))
            }
            if let key = next.key { DebugRow("key", key) }
            if let lufs = next.lufs {
                DebugRow("loudness", String(format: "%.1f LUFS", lufs))
            }
            if let count = next.sectionCount {
                DebugRow("sections", "\(count) (conf "
                         + String(format: "%.2f", next.structureConfidence ?? 0) + ")")
            }
            if next.title != nil {
                DebugRow(".lrc", next.hasLyricSidecar ? "present" : "missing")
            }
        }
    }

    /// The queue-order pick: what the selector is choosing between, and the
    /// arithmetic that decided it.
    ///
    /// Present in every mode — reading "mode listed" is how you find out the
    /// switch is off — but the table only exists once there is something to
    /// choose between.
    @ViewBuilder
    private var orderGroup: some View {
        let order = model.snapshot.order
        DebugGroup("Queue order") {
            DebugRow("mode", order.mode)
            if order.mode == "autoMix" {
                DebugRow("state", order.state)
                DebugRow("pool", "\(order.analyzed)/\(order.poolSize) analyzed")
                DebugRow("escalation",
                         "round \(order.rounds) · \(order.downloads)/"
                         + "\(order.downloadBudget) downloads")
                DebugRow("lookahead", order.lookahead.isEmpty
                         ? "—"
                         : "provisional · " + order.lookahead.joined(separator: "  →  "))
                DebugRow("deadline", order.deadline.map {
                    AutoMixDebugFormat.clock($0) + String(format: " (%.0fs)", $0)
                } ?? "—")
                if order.candidates.isEmpty {
                    DebugRow("candidates", "none scored yet")
                } else {
                    candidateHeader
                    // Best-first, so the chosen candidate is always in the
                    // visible five; the rest is detail on demand.
                    ForEach(showAllCandidates
                            ? order.candidates
                            : Array(order.candidates.prefix(5))) { candidate in
                        candidateRow(candidate)
                    }
                    if order.candidates.count > 5 {
                        Button(showAllCandidates
                               ? "show top 5"
                               : "show all (\(order.candidates.count))") {
                            showAllCandidates.toggle()
                        }
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }
                    Text(verbatim: "tempo / key / style / energy are 0–1 and only sort "
                         + "inside a tier; aging is unbounded, which is what keeps a "
                         + "track from starving.")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
        }
    }

    private var candidateHeader: some View {
        HStack(spacing: 6) {
            Text(verbatim: "candidate").frame(width: 128, alignment: .leading)
            Text(verbatim: "tier").frame(width: 92, alignment: .leading)
            ForEach(["tmp", "key", "sty", "enr", "age", "art", "fut"], id: \.self) { column in
                Text(verbatim: column).frame(width: 34, alignment: .trailing)
            }
            Text(verbatim: "total").frame(width: 44, alignment: .trailing)
            Spacer(minLength: 0)
        }
        .font(.system(size: 9, weight: .semibold, design: .monospaced))
        .foregroundStyle(.secondary)
    }

    private func candidateRow(_ c: AutoMixDebugCandidate) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: c.title)
                .lineLimit(1).truncationMode(.tail)
                .frame(width: 128, alignment: .leading)
            Text(verbatim: c.tier).frame(width: 92, alignment: .leading)
            ForEach(Array([c.tempo, c.key, c.style, c.energy, c.aging, c.samePenalty, c.future]
                          .enumerated()), id: \.offset) { _, value in
                Text(verbatim: String(format: "%.2f", value))
                    .frame(width: 34, alignment: .trailing)
            }
            Text(verbatim: String(format: "%.2f", c.total))
                .frame(width: 44, alignment: .trailing)
            Spacer(minLength: 0)
        }
        .font(.system(size: 10, weight: c.chosen ? .bold : .regular, design: .monospaced))
        .foregroundStyle(c.chosen ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
    }

    @ViewBuilder
    private var planGroup: some View {
        DebugGroup("Plan (armed)") {
            if let note = model.snapshot.forceNote {
                Text(verbatim: note)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let plan = model.snapshot.plan {
                DebugRow("kind", plan.kind)
                DebugRow("out point", AutoMixDebugFormat.clock(plan.outPoint)
                         + (plan.outPoint.map { String(format: " (%.2fs)", $0) } ?? ""))
                DebugRow("in point", plan.inPoint.map { String(format: "%.2fs", $0) } ?? "—")
                DebugRow("overlap", String(format: "%.2fs", plan.overlap)
                         + (plan.overlapBars.map { " / \($0) bars" } ?? ""))
                if let out = plan.outgoingRate, let incoming = plan.incomingRate {
                    DebugRow("rates", String(format: "out ×%.4f · in ×%.4f", out, incoming))
                }
                DebugRow("style", plan.outroEffect
                         + (plan.stagedEQ ? " · stagedEQ" : "")
                         + (plan.stemTechnique.map { " · \($0)" } ?? ""))
                // Only ever present with the score toggle on, and only ever
                // *offered*: the live path blends, so what this row promises is
                // conditional on the pre-render row below it.
                //
                // A score the compiler refused at arming time says so **here**,
                // with the compiler's sentence. It is a planning verdict about
                // this seam, not a pre-render failure, and it used to be printed
                // as the latter.
                DebugRow("score", model.snapshot.scoreRow)
                // What that score is *aimed at* (P2): the drop, the chorus or
                // the start of the song proper. Only ever present with a score,
                // and it says `aim=none` out loud when the incoming track had
                // no structure to aim at — the degradation is the interesting
                // half of the A/B.
                if let aim = plan.aim { DebugRow("aim", aim) }
                // **What the pair was for** (P3): the class and every reason
                // that chose it, in the planner's own sentences. Present only
                // with `intentEnabled` on, which is never on a shipped build —
                // and when it is on, this row is the acceptance gate: the
                // listener checks the class before checking the sound.
                if let intent = plan.intent { DebugRow("intent", intent) }
                DebugRow("ride", String(format: "%+.2f dB", plan.rideDB))
                DebugRow("out section", plan.outSection ?? "no structure")
                DebugRow("in source", plan.inPointSource ?? "—")
                DebugRow("countdown", countdown(to: plan.outPoint))
            } else {
                DebugRow("state", "nothing armed")
            }
        }
    }

    // MARK: - Controls
    //
    // Everything below *changes* what the player does, which is why it lives in
    // one group under a heading that says so, and why every active override is
    // badged: a listening note must never record an overridden seam as an
    // organic one. Buttons are disabled with their reason showing rather than
    // hidden — "why can't I press this" is itself diagnostic.

    @ViewBuilder
    private var controlsGroup: some View {
        DebugGroup("Controls (debug overrides)") {
            if model.overrides.isActive {
                HStack(spacing: 4) {
                    ForEach(model.overrides.badges, id: \.self) { badge in
                        Text(verbatim: badge)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.25),
                                        in: RoundedRectangle(cornerRadius: 3))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 2)
            }

            overrideToggle("Force beat switch", \.forceBeatMatch)
            if model.overrides.forceBeatMatch {
                DebugRow("gates", "loudness / timbre / tempo-clash / key / vocal-clash: off")
                DebugRow("window", String(
                    format: "bpm Δ ≤ %.0f %% · rate ≤ ±%.0f %%",
                    AutoMixDebugOverrides.forcedBPMDeltaCap * 100,
                    AutoMixDebugOverrides.forcedRateCap * 100))
            }
            overrideToggle("Disable tempo ramp", \.disableTempoRamp)
            overrideToggle("Disable dominant-deck blend", \.disableDominantDeckBlend)
            overrideToggle("Disable two-clock exchange", \.disableTwoClockExchange)
            overrideToggle("Transition score (cut / throw / tension cut / bed)", \.enableScore)
            overrideToggle("Intent layer (material decides the family)", \.enableIntent)
            if model.overrides.enableScore {
                DebugRow("score", "one template off the ladder its intent class allows;"
                         + " the live path still blends unless the segment arms")
            }
            overrideToggle("Body level (trim to −11 LUFS, not −14)", \.enableBodyLevel)
            if model.overrides.enableBodyLevel {
                DebugRow("bodyLevel", String(
                    format: "house level %.0f LUFS — median trim −2.0 dB over the"
                        + " cached corpus, against −5.0 dB at −14",
                    AutoMixDebugOverrides.bodyLevelTargetLUFS))
            }
            overrideToggle("Seam level (ride capped to the body's level)", \.enableSeamLevel)
            if model.overrides.enableSeamLevel {
                DebugRow("seamLevel", String(
                    format: "ride ≤ +%.0f dB / −%.0f dB (was ±4) — a seam never louder"
                        + " than a body, a song never opening more than %.0f dB under it",
                    AutoMixDebugOverrides.seamRideMaxDB,
                    AutoMixDebugOverrides.seamRideMaxCutDB,
                    AutoMixDebugOverrides.seamRideMaxCutDB))
            }
            overrideToggle("Master limiter (−1 dBFS, retires the bent-rate pad)",
                           \.enableMasterLimiter)
            if model.overrides.enableMasterLimiter {
                DebugRow("limiter", String(
                    format: "peak limiter at %+.0f dBFS after the mixer — the outgoing"
                        + " deck is no longer ducked 4–7 dB for the 15–25 s before a seam",
                    DeckChain.masterCeilingDBFS))
            }
            overrideToggle("Force live path (no stem pre-render)", \.forceLivePath)
            overrideToggle("Verbose engine trace (knob ring + stall watchdog)",
                           \.verboseEngineTrace)
            if model.overrides.verboseEngineTrace {
                DebugRow("trace", "every fader / rate / schedule write, dumped to"
                         + " Application Support/Kumone/seamtraces at each seam,"
                         + " stall or alarm")
                Button {
                    PlayerService.shared.dumpEngineTrace(reason: "manual")
                } label: {
                    Text(verbatim: "Dump trace now")
                }
                Button {
                    PlayerService.shared.captureOutputNow()
                } label: {
                    Text(verbatim: "Capture 8 s now")
                }
            }

            Divider().padding(.vertical, 3)
            seamLatencyControls
            Divider().padding(.vertical, 3)
            jumpControl
            Divider().padding(.vertical, 3)
            markControl(seam: nil, label: "Mark the armed seam")
        }
    }

    private func overrideToggle(_ label: String,
                                _ key: WritableKeyPath<AutoMixOverrides, Bool>) -> some View {
        Toggle(isOn: Binding(
            get: { model.overrides[keyPath: key] },
            set: { on in
                var next = model.overrides
                next[keyPath: key] = on
                PlayerService.shared.setOverrides(next)
            })) {
                Text(verbatim: label)
            }
            .toggleStyle(.checkbox)
    }

    /// **Did the splice's two identity crossfades line up?** — the head and
    /// tail offsets the engine measures from its own output taps, next to the
    /// compensation it is applying to the head because of them.
    ///
    /// These rows are the acceptance test for the whole seam-alignment story:
    /// a session in which `head offset` reads within a millisecond of zero
    /// *while* `head latency` says the compensation is +19 ms is a session in
    /// which the flam was real and is being cancelled. Both reading zero with
    /// no compensation would mean it never existed on this hardware.
    ///
    /// Blank until the first splice of the session has played — a live overlap
    /// has no identity crossfade and nothing to measure.
    @ViewBuilder
    private var seamLatencyControls: some View {
        let latency = model.snapshot.seamLatency
        let calibration = latency.calibration
        DebugRow("head offset", latency.lastHead ?? "— no splice yet this session")
        DebugRow("tail offset", latency.lastTail ?? "— no splice yet this session")
        DebugRow("head latency", String(
            format: "applied %@ · calibration %+.1f ms (n=%d)%@",
            latency.appliedMilliseconds.map {
                String(format: "%+.1f ms%@", $0, latency.pinned ? " (pinned)" : "")
            } ?? "—",
            calibration.headMilliseconds, calibration.headCount,
            calibration.tailCount > 0
                ? String(format: " · tail %+.1f ms (n=%d, observed only)",
                         calibration.tailMilliseconds, calibration.tailCount)
                : ""))
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { model.overrides.headLatencyCompensationMS != nil },
                set: { on in
                    var next = model.overrides
                    // Pinning starts from wherever the calibration has got to,
                    // so turning it on never moves the seam by itself — it only
                    // stops it moving on its own afterwards.
                    next.headLatencyCompensationMS =
                        on ? calibration.headMilliseconds.rounded() : nil
                    PlayerService.shared.setOverrides(next)
                })) {
                    Text(verbatim: "Pin head latency compensation")
                }
                .toggleStyle(.checkbox)
            if let pin = model.overrides.headLatencyCompensationMS {
                Stepper(value: Binding(
                    get: { pin },
                    set: { value in
                        var next = model.overrides
                        next.headLatencyCompensationMS = value
                        PlayerService.shared.setOverrides(next)
                    }),
                        in: SeamLatencyCalibration.bounds, step: 1) {
                    Text(verbatim: String(format: "%+.0f ms", pin))
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var jumpControl: some View {
        let blocker = PlayerService.shared.seamJumpBlocker
        let jump = PlayerService.shared.seamJumpPlan()
        HStack(spacing: 8) {
            Button {
                PlayerService.shared.jumpToArmedSeam()
            } label: {
                Text(verbatim: "Jump to seam")
            }
            .disabled(blocker != nil)
            if let blocker {
                Text(verbatim: blocker).foregroundStyle(.secondary)
            } else if let jump {
                Text(verbatim: String(format: "→ %@ (lead %.0fs)",
                                      AutoMixDebugFormat.clock(jump.target), jump.lead))
            }
            Spacer(minLength: 0)
        }
        if let jump {
            DebugRow("lead set by", jump.reason)
            if jump.losesPrerender {
                Text(verbatim: "the track cannot hold the pre-render's runway — "
                     + "this seam will take the live fallback")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Good / bad plus the shared note field. `seam` nil marks whatever is
    /// armed right now; a history entry passes itself.
    @ViewBuilder
    private func markControl(seam: AutoMixDebugSeam?, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(verbatim: label).foregroundStyle(.secondary)
                Button { mark(.good, seam) } label: { Text(verbatim: "good") }
                Button { mark(.bad, seam) } label: { Text(verbatim: "bad") }
                Spacer(minLength: 0)
                Text(verbatim: "\(model.markCount) marked this session")
                    .foregroundStyle(.tertiary)
            }
            // One field, shared by every mark button on the panel — history
            // entries included: type the note, then press good/bad wherever
            // the seam is. Cleared on write so a note never rides along with
            // a second seam.
            TextField(text: $markNote) {
                Text(verbatim: "note (optional) — applies to the next mark")
            }
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
        }
    }

    private func mark(_ verdict: AutoMixFeedbackEntry.Verdict, _ seam: AutoMixDebugSeam?) {
        PlayerService.shared.markSeam(verdict: verdict, note: markNote, seam: seam)
        markNote = ""
    }

    private var prerenderGroup: some View {
        DebugGroup("Stem pre-render") {
            DebugRow("state", model.snapshot.prerender.label)
        }
    }

    private var seamsGroup: some View {
        DebugGroup("Last transitions") {
            if model.snapshot.seams.isEmpty {
                DebugRow("state", "none this session")
            } else {
                ForEach(model.snapshot.seams) { seam in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "\(seam.from ?? "—")  →  \(seam.to ?? "—")")
                            .fontWeight(.semibold)
                        DebugRow("path", seam.path)
                        DebugRow("executed", "\(seam.executedKind) · out "
                                 + AutoMixDebugFormat.clock(seam.executedOutPoint)
                                 + String(format: " · overlap %.2fs", seam.executedOverlap))
                        DebugRow("planned", seam.planned.map {
                            "\($0.kind) · out " + AutoMixDebugFormat.clock($0.outPoint)
                                + String(format: " · overlap %.2fs", $0.overlap)
                                + ($0.stemTechnique.map { " · \($0)" } ?? "")
                                + ($0.score.map { " · score=\($0)" } ?? "")
                                + ($0.aim.map { " · \($0)" } ?? "")
                        } ?? "—")
                        // The intent gets its own row rather than being folded
                        // into `planned`: it is a paragraph, not a chip, and it
                        // is the thing a mark on this seam is mostly about.
                        if let intent = seam.planned?.intent { DebugRow("intent", intent) }
                        DebugRow("fallback", seam.fallback ?? "none — ran as planned")
                        DebugRow("pre-render", seam.prerender)
                        if !seam.overrides.isEmpty {
                            DebugRow("overrides", seam.overrides.joined(separator: " "))
                        }
                        DebugRow("config", seam.configFingerprint)
                        if seam.id == model.snapshot.seams.first?.id {
                            replayControl(seam)
                        }
                        markControl(seam: seam, label: "mark")
                    }
                    .padding(.vertical, 3)
                    if seam.id != model.snapshot.seams.last?.id { Divider() }
                }
            }
        }
    }

    /// Re-queue the recorded pair and jump to just before the seam. Only
    /// offered on the newest entry — replaying an older one would have to
    /// discard the two seams heard since, and "replay the thing I just heard"
    /// is the whole use.
    @ViewBuilder
    private func replayControl(_ seam: AutoMixDebugSeam) -> some View {
        let blocker = PlayerService.shared.seamReplayBlocker(seam)
        HStack(spacing: 8) {
            Button {
                PlayerService.shared.replaySeam(seam)
            } label: {
                Text(verbatim: "Replay this seam")
            }
            .disabled(blocker != nil)
            Text(verbatim: blocker ?? "replaces the queue with these two tracks")
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        if let diff = model.replayDiff {
            Text(verbatim: "re-planned differently: \(diff)")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Helpers

    /// "T−mm:ss to out point", or why there is no countdown to give.
    private func countdown(to outPoint: TimeInterval?) -> String {
        guard let outPoint else { return "— (no out point: gapless)" }
        let remaining = outPoint - model.snapshot.now.position
        guard remaining > 0 else { return "T+00:00 (out point passed)" }
        return String(format: "T−%02d:%02d", Int(remaining) / 60, Int(remaining) % 60)
    }

    /// SwiftUI has no window-level API, so the pin goes through AppKit — the
    /// same way `DesktopLyrics` floats its overlay.
    private func setFloating(_ on: Bool) {
        guard let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue.contains(Self.windowID) ?? false
        }) else { return }
        window.level = on ? .floating : .normal
    }
}

private struct DebugGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct DebugRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    @State private var copied = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: label)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            Text(verbatim: value)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(copied ? "copied" : "copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(label)\t\(value)", forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            }
            .buttonStyle(.plain)
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }
}
#endif
