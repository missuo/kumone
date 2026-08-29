#if os(macOS)
import AppKit
import SwiftUI

// A developer window for listening tests: what AutoMix is doing, right now,
// without tailing a log while trying to hear a seam. macOS only — there is no
// AutoMix on iOS (every plan is `.gapless`), so there is nothing to watch.
//
// Deliberately **not** compiled out of release builds. The builds that go to
// the listening machine are made by `Scripts/build-app.sh`, which defaults to
// the `debug` configuration but is routinely run with `release` too, and a
// panel that vanishes depending on how the binary was built is a panel nobody
// trusts. It costs a closed window and one Bool test per playback tick; see
// `AutoMixDebugModel`.
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
                DebugRow("score", plan.score.map { "score=\($0)" }
                         ?? "none — today's blend")
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
            overrideToggle("Transition score (P1: cut-on-one)", \.enableScore)
            if model.overrides.enableScore {
                DebugRow("score", "offered on confident grids; the live path still blends"
                         + " unless the segment arms")
            }
            overrideToggle("Force live path (no stem pre-render)", \.forceLivePath)

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
            if seam == nil {
                // One field, shared by every mark button on the panel: type the
                // note, then press good/bad wherever the seam is. Cleared on
                // write so a note never rides along with a second seam.
                TextField(text: $markNote) {
                    Text(verbatim: "note (optional) — applies to the next mark")
                }
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
            }
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
                        } ?? "—")
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
