#if os(macOS)
import Foundation
import KumoneCore

// `audition serve` — the tuning console's back end.
//
// Everything is one process on purpose. The planner is a pure function over
// two cached analyses, so re-deciding under a moved threshold costs a few
// milliseconds; keeping the HTTP server in the same binary means a slider
// drag round-trips faster than it takes to launch a second process. Renders
// are the only slow path, and they still run ~100× real time.

final class Console: @unchecked Sendable {
    let corpus: URL
    let stateDir: URL
    var renderDir: URL { stateDir.appendingPathComponent("renders") }
    var configDir: URL { stateDir.appendingPathComponent("configs") }

    private let lock = NSLock()
    /// Standard-config decisions for the corpus's adjacent pairs, so the
    /// batch view can highlight what a config change actually moved. Computed
    /// once, on first use.
    private var standardBatch: [[String: Any]]?

    /// In-flight and finished render jobs, keyed by id. Renders used to be
    /// synchronous — a whole-mix one is ~0.3 s — but a stem render pays for a
    /// model pass, so the page starts a job and polls it instead of holding a
    /// socket open for twenty seconds.
    private var jobs: [String: RenderJob] = [:]
    /// Serial: two concurrent separations would fight over the GPU and over
    /// the resident checkpoint for no gain.
    private let renderQueue = DispatchQueue(label: "audition.console.render")

    /// Mutated only under `lock`.
    private final class RenderJob: @unchecked Sendable {
        var stage = "planning"
        var startedAt = Date()
        var result: [String: Any]?
        var error: String?
    }

    init(corpus: URL, stateDir: URL) {
        self.corpus = corpus
        self.stateDir = stateDir
        for dir in [renderDir, configDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - Corpus

    static let audioExtensions: Set<String> = ["flac", "mp3", "m4a", "wav", "aiff", "caf", "aac"]

    var tracks: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: corpus,
                                                       includingPropertiesForKeys: nil)) ?? [])
            .filter { Self.audioExtensions.contains($0.pathExtension.lowercased()) }
            // Stem sidecars are audio files sitting next to the corpus; they
            // are not tracks.
            .filter { !StemService.isStemSidecar($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Every adjacent pair in filename order — the same 15 the `batch`
    /// command renders, so the console and the markdown report agree.
    var adjacentPairs: [(URL, URL)] {
        let files = tracks
        guard files.count >= 2 else { return [] }
        return Array(zip(files, files.dropFirst()))
    }

    // MARK: - Routing

    func handle(_ request: HTTPRequest) -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/"), ("HEAD", "/"):
            return .html(consolePage)
        case ("GET", "/api/bootstrap"):
            return bootstrap()
        case ("POST", "/api/plan"):
            return plan(request.json)
        case ("POST", "/api/batch"):
            return batch(request.json)
        case ("POST", "/api/render"):
            return render(request.json)
        case ("GET", "/api/configs"):
            return .json(["configs": savedConfigNames()])
        case ("POST", "/api/configs"):
            return saveConfig(request.json)
        default:
            if request.path.hasPrefix("/api/render-status/") {
                return renderStatus(String(request.path.dropFirst("/api/render-status/".count)))
            }
            if request.path.hasPrefix("/api/configs/") {
                let name = String(request.path.dropFirst("/api/configs/".count))
                if request.method == "GET" { return loadConfig(name) }
                if request.method == "DELETE" { return deleteConfig(name) }
            }
            if request.path.hasPrefix("/render/") {
                let name = String(request.path.dropFirst("/render/".count))
                guard !name.contains("/"), !name.contains("..") else {
                    return .error("bad render name", status: 400)
                }
                return FileServing.serve(renderDir.appendingPathComponent(name),
                                         request: request, contentType: "audio/wav")
            }
            return .error("no route for \(request.method) \(request.path)", status: 404)
        }
    }

    // MARK: - Bootstrap

    private func bootstrap() -> HTTPResponse {
        let encoder = JSONEncoder()
        let fields = (try? encoder.encode(Audition.configFields))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? []
        return .json([
            "corpus": corpus.path,
            "stateDir": stateDir.path,
            "tracks": tracks.map { ["name": $0.lastPathComponent, "path": $0.path] },
            "pairs": adjacentPairs.map { ["outgoing": $0.0.path, "incoming": $0.1.path] },
            "fields": fields,
            "standard": Audition.standardConfig,
            "styles": Audition.StyleOverride.allCases.map(\.rawValue),
            "stems": Audition.StemOverride.names,
            "duckDefaultDB": Audition.StemOverride.defaultDuckDepthDB,
            "maxManualOverlap": Audition.PlanOverride.maxOverlap,
            "minManualOverlap": Audition.PlanOverride.minOverlap,
            "configs": savedConfigNames(),
        ])
    }

    // MARK: - Plan

    /// `{outgoing, incoming, config: {name: value}, style?, fade?}`
    private func plan(_ body: [String: Any]) -> HTTPResponse {
        guard let a = body["outgoing"] as? String, let b = body["incoming"] as? String else {
            return .error("need outgoing and incoming paths")
        }
        do {
            let decision = try decide(outgoing: a, incoming: b, body: body)
            return .json(try withLyrics(Audition.reportJSON(decision),
                                        outgoing: expand(a), incoming: expand(b)))
        } catch let failure as Audition.StemEnvelopeInput.Failure {
            return .error(failure.errorDescription ?? "stemEnvelope 不合法", status: 400)
        } catch let failure as StemEnvelope.ValidationFailure {
            return .error(failure.errorDescription ?? "stemEnvelope 不合法", status: 400)
        } catch let failure as Audition.PlanOverride.Failure {
            // A rejected hand-written plan is a user mistake, not a server
            // fault, and the page shows the message verbatim.
            return .error(failure.errorDescription ?? "planOverride 不合法", status: 400)
        } catch {
            return .error(error.localizedDescription, status: 500)
        }
    }

    /// Staple the two tracks' timed lyrics onto an encoded decision report.
    ///
    /// They are not part of `DecisionReport` because nothing in the decision
    /// turns on them — they exist so the page's AI bundle can quote what is
    /// actually being sung on either side of the seam.
    private func withLyrics(_ report: Data, outgoing: URL, incoming: URL) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: report) as? [String: Any]
        else { return report }
        func lines(_ url: URL) -> Any {
            guard let all = Audition.Lyrics.load(for: url) else { return NSNull() }
            return [
                "count": all.count,
                "head": Audition.Lyrics.head(all, count: 12).map { ["t": $0.time, "text": $0.text] },
                "tail": Audition.Lyrics.tail(all, count: 12).map { ["t": $0.time, "text": $0.text] },
                // Every line's timestamp, words dropped: the timeline draws them
                // as ticks under the section band, which is how a section
                // boundary gets checked against where the singing actually is.
                "times": all.map(\.time),
            ] as [String: Any]
        }
        object["lyrics"] = ["outgoing": lines(outgoing), "incoming": lines(incoming)]
        return try JSONSerialization.data(withJSONObject: object,
                                          options: [.prettyPrinted, .sortedKeys])
    }

    private func decide(outgoing a: String, incoming b: String,
                        body: [String: Any]) throws -> Audition.Decision {
        let config = (body["config"] as? [String: Any] ?? [:])
            .compactMapValues { ($0 as? NSNumber)?.doubleValue }
        var style: Audition.StyleOverride?
        if let raw = body["style"] as? String, !raw.isEmpty, raw != "auto" {
            style = Audition.StyleOverride(rawValue: raw)
        }
        let fade = (body["fade"] as? NSNumber)?.doubleValue
        var stem: Audition.StemOverride?
        let namedStem = (body["stem"] as? String).flatMap {
            $0.isEmpty || $0 == "none" ? nil : $0
        }
        let rawEnvelope = body["stemEnvelope"].flatMap { $0 is NSNull ? nil : $0 }
        // Two ways of saying the same thing, meaning different things: one
        // picks a ready-made technique, the other writes the curves by hand.
        // Taking both would silently drop one of them.
        if namedStem != nil, rawEnvelope != nil {
            throw Audition.StemEnvelopeInput.Failure.conflictsWithStem
        }
        if let raw = namedStem {
            // The page sends the duck depth as its own slider value, so
            // "duck" + duckDB rejoin into the CLI's own `duck:N` spelling.
            var spec = raw
            if raw == "duck", let depth = (body["duckDB"] as? NSNumber)?.floatValue {
                spec = "duck:\(depth)"
            }
            stem = Audition.StemOverride.parse(spec)
        } else if let rawEnvelope {
            stem = .custom(try Audition.StemEnvelopeInput.parse(rawEnvelope))
        }
        // The page's "stems 可用" switch. Absent (the baseline batch run, and
        // any older client) means off, which is the product default.
        let stems: StemAvailability =
            (body["stems"] as? Bool ?? false) ? .ready : .none
        return try Audition.decide(
            outgoing: expand(a), incoming: expand(b),
            style: style, fade: fade.flatMap { $0 > 0 ? $0 : nil }, stem: stem,
            plan: try planOverride(body["planOverride"]),
            stems: stems, config: config)
    }

    /// `{"outPoint": 199.5, "inPoint": "0:02", "overlap": 12}` — every field
    /// optional, each one either a number of seconds or an `mm:ss(.xx)` string.
    /// An unparseable value is rejected rather than dropped: silently ignoring
    /// half of a hand-written plan is worse than refusing it.
    private func planOverride(_ raw: Any?) throws -> Audition.PlanOverride? {
        guard let dict = raw as? [String: Any] else { return nil }
        var override = Audition.PlanOverride()
        for (key, path) in [("outPoint", \Audition.PlanOverride.outPoint),
                            ("inPoint", \Audition.PlanOverride.inPoint),
                            ("overlap", \Audition.PlanOverride.overlap)] {
            guard let value = dict[key], !(value is NSNull) else { continue }
            guard let seconds = Audition.PlanOverride.seconds(fromJSON: value) else {
                throw Audition.PlanOverride.Failure.notANumber(field: key,
                                                               given: String(describing: value))
            }
            override[keyPath: path] = seconds
        }
        return override.isEmpty ? nil : override
    }

    private func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }

    // MARK: - Batch

    /// Run every adjacent corpus pair under the posted config and pair each
    /// row with what `.standard` would have decided, so the table can mark
    /// the rows a threshold move actually reclassified.
    private func batch(_ body: [String: Any]) -> HTTPResponse {
        // The corpus sweep stays whole-mix: it is about where the planner's
        // thresholds land, and a stem pass per pair would cost minutes.
        var body = body
        body["stem"] = nil
        // A hand-written envelope is written against one pair's overlap; on any
        // other pair its times mean nothing (and would simply be rejected).
        body["stemEnvelope"] = nil
        // A plan override names one seam in one pair; it means nothing for the
        // other pairs, so the sweep never sees it.
        body["planOverride"] = nil
        let pairs = adjacentPairs
        guard !pairs.isEmpty else { return .error("corpus has fewer than two tracks") }

        let baseline = standardRows(pairs)
        var rows: [[String: Any]] = []
        for (index, pair) in pairs.enumerated() {
            guard var row = summarize(pair, body: body) else { continue }
            let base = index < baseline.count ? baseline[index] : [:]
            row["standard"] = base
            row["changed"] = ["tier", "plan", "style", "overlap", "stem"].contains {
                !equalField(row[$0], base[$0])
            }
            rows.append(row)
        }
        return .json(["pairs": rows])
    }

    private func equalField(_ a: Any?, _ b: Any?) -> Bool {
        if let x = a as? String, let y = b as? String { return x == y }
        if let x = (a as? NSNumber)?.doubleValue, let y = (b as? NSNumber)?.doubleValue {
            return abs(x - y) < 0.005
        }
        return false
    }

    private func standardRows(_ pairs: [(URL, URL)]) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        if let standardBatch { return standardBatch }
        let rows = pairs.compactMap { summarize($0, body: [:]) }
        standardBatch = rows
        return rows
    }

    private func summarize(_ pair: (URL, URL), body: [String: Any]) -> [String: Any]? {
        guard let d = try? decide(outgoing: pair.0.path, incoming: pair.1.path, body: body)
        else { return nil }
        var row: [String: Any] = [
            "outgoing": d.outgoingName, "incoming": d.incomingName,
            "outgoingPath": pair.0.path, "incomingPath": pair.1.path,
            "tier": d.tier, "rawTier": d.rawTier, "plan": d.planKind,
            "style": d.styleDescription, "overlap": d.overlapDuration,
            "loudness": d.loudnessGapDB, "timbre": d.timbreDistance,
            "demotedByKey": d.demotedByKey,
            "nearMisses": d.nearMisses,
            // Planned, not rendered: the batch sweep stays whole-mix (a stem
            // pass per pair would cost minutes), so this column says what the
            // planner *would* ask for.
            "stem": d.plannedStemTechnique ?? "—",
        ]
        if let t = d.tempoRatio { row["tempo"] = t }
        if let k = d.keyDistance { row["key"] = k }
        if let o = d.outPoint { row["outPoint"] = o }
        if let bars = d.overlapBars { row["bars"] = bars }
        return row
    }

    // MARK: - Render

    /// Start a render and hand back a job id. A whole-mix render finishes in a
    /// few hundred milliseconds and a cache hit is instant, but the page polls
    /// the same way for all of them — one code path, and a stem render's
    /// twenty seconds do not sit on an open socket.
    private func render(_ body: [String: Any]) -> HTTPResponse {
        guard let a = body["outgoing"] as? String, let b = body["incoming"] as? String else {
            return .error("need outgoing and incoming paths")
        }
        let decision: Audition.Decision
        do {
            decision = try decide(outgoing: a, incoming: b, body: body)
        } catch let failure as Audition.StemEnvelopeInput.Failure {
            return .error(failure.errorDescription ?? "stemEnvelope 不合法", status: 400)
        } catch let failure as StemEnvelope.ValidationFailure {
            return .error(failure.errorDescription ?? "stemEnvelope 不合法", status: 400)
        } catch let failure as Audition.PlanOverride.Failure {
            return .error(failure.errorDescription ?? "planOverride 不合法", status: 400)
        } catch {
            return .error(error.localizedDescription, status: 500)
        }

        // Name the file after everything that shapes it, so re-rendering the
        // same knobs reuses the WAV and the browser's audio element does not
        // refetch. `styleDescription` carries the stem technique, so a duck
        // depth change is a different file.
        var hasher = Hasher()
        hasher.combine(a); hasher.combine(b)
        hasher.combine(decision.styleDescription)
        hasher.combine(decision.overlapDuration)
        hasher.combine(decision.planKind)
        // A moved seam is a different render even when nothing else changed.
        hasher.combine(decision.outPoint ?? -1)
        hasher.combine(decision.inPoint ?? -1)
        for (k, v) in decision.config.sorted(by: { $0.key < $1.key }) {
            hasher.combine(k); hasher.combine(v)
        }
        let name = String(format: "console-%016llx.wav",
                          UInt64(bitPattern: Int64(hasher.finalize())))
        let out = renderDir.appendingPathComponent(name)
        let pre = (body["pre"] as? NSNumber)?.doubleValue ?? 12
        let post = (body["post"] as? NSNumber)?.doubleValue ?? 12
        // Either the picker asked for one, or the planner chose one itself —
        // both mean the job will pay for a separation pass, which is what the
        // progress line is for.
        let wantsStem = decision.plannedStemTechnique != nil
            || decision.stemEnvelope != nil
            || ((body["stem"] as? String).map { !$0.isEmpty && $0 != "none" } ?? false)

        let id = UUID().uuidString
        let job = RenderJob()
        lock.lock(); jobs[id] = job; lock.unlock()

        if FileManager.default.fileExists(atPath: out.path),
           let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size])
               as? Int, size > 1024 {
            finish(job, ["url": "/render/\(name)", "cached": true,
                         "overlapStart": pre,
                         "overlapDuration": decision.overlapDuration,
                         "style": decision.styleDescription])
            return .json(["job": id, "stage": "done"])
        }

        renderQueue.async { [weak self] in
            guard let self else { return }
            self.set(job, stage: wantsStem ? "separating" : "rendering")
            let provider = StemService.stageReporting(StemService.shared.provider) {
                [weak self] separating in
                self?.set(job, stage: separating ? "separating" : "rendering")
            }
            do {
                let r = try Audition.render(decision, to: out, preRoll: pre, postRoll: post,
                                            stemProvider: provider)
                var payload: [String: Any] = [
                    "url": "/render/\(name)", "cached": false,
                    "duration": r.duration,
                    "overlapStart": r.overlapStart,
                    "overlapDuration": r.overlapDuration,
                    "renderSeconds": r.renderSeconds,
                    "realtimeFactor": r.realtimeFactor,
                    "style": decision.styleDescription,
                    "stemCacheHit": r.stemCacheHit,
                    "outgoingTrimDB": r.outgoingTrimDB,
                    "incomingTrimDB": r.incomingTrimDB,
                    "rideDB": r.rideDB,
                    "rideReleaseSeconds": r.rideReleaseSeconds,
                    "normalizationGainDB": r.normalizationGainDB,
                ]
                if let m = r.measuredLUFS { payload["measuredLUFS"] = m }
                if let t = r.normalizationTargetLUFS { payload["normalizationTargetLUFS"] = t }
                if let t = r.stemTechnique { payload["stemTechnique"] = t }
                if let s = r.stemSeconds { payload["stemSeconds"] = s }
                if let s = r.stemSeparatedSeconds { payload["stemSeparatedSeconds"] = s }
                if let s = r.stemIncomingSeparatedSeconds {
                    payload["stemIncomingSeparatedSeconds"] = s
                }
                if !r.stemSeparatedSides.isEmpty {
                    payload["stemSeparatedSides"] = r.stemSeparatedSides
                }
                if let s = r.stemVocalEnergyRatio { payload["stemVocalEnergyRatio"] = s }
                if let reason = r.stemFallbackReason { payload["stemFallbackReason"] = reason }
                self.finish(job, payload)
            } catch {
                self.fail(job, "render failed: \(error.localizedDescription)")
            }
        }
        return .json(["job": id, "stage": "rendering"])
    }

    private func renderStatus(_ id: String) -> HTTPResponse {
        lock.lock()
        let job = jobs[id]
        lock.unlock()
        guard let job else { return .error("no such render job", status: 404) }
        lock.lock()
        defer { lock.unlock() }
        var payload: [String: Any] = ["elapsed": Date().timeIntervalSince(job.startedAt)]
        if let error = job.error {
            payload["status"] = "failed"
            payload["error"] = error
        } else if let result = job.result {
            payload["status"] = "done"
            payload.merge(result) { _, new in new }
        } else {
            payload["status"] = "running"
            payload["stage"] = job.stage
        }
        return .json(payload)
    }

    private func set(_ job: RenderJob, stage: String) {
        lock.lock(); job.stage = stage; lock.unlock()
    }

    private func finish(_ job: RenderJob, _ result: [String: Any]) {
        lock.lock(); job.result = result; lock.unlock()
    }

    private func fail(_ job: RenderJob, _ message: String) {
        lock.lock(); job.error = message; lock.unlock()
    }

    // MARK: - Saved presets

    private func savedConfigNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(at: configDir,
                                                       includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    private func configURL(_ name: String) -> URL? {
        let safe = name.filter { $0.isLetter || $0.isNumber || "-_ ".contains($0) }
        guard !safe.isEmpty else { return nil }
        return configDir.appendingPathComponent(safe + ".json")
    }

    private func saveConfig(_ body: [String: Any]) -> HTTPResponse {
        guard let name = body["name"] as? String, let url = configURL(name),
              let config = body["config"] as? [String: Any]
        else { return .error("need a name and a config") }
        guard let data = try? JSONSerialization.data(withJSONObject: config,
                                                     options: [.prettyPrinted, .sortedKeys])
        else { return .error("config is not JSON") }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return .error("could not write \(url.path): \(error.localizedDescription)", status: 500)
        }
        return .json(["saved": url.deletingPathExtension().lastPathComponent,
                      "configs": savedConfigNames()])
    }

    private func loadConfig(_ name: String) -> HTTPResponse {
        guard let url = configURL(name), let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return .error("no saved config '\(name)'", status: 404) }
        return .json(["name": name, "config": object])
    }

    private func deleteConfig(_ name: String) -> HTTPResponse {
        guard let url = configURL(name) else { return .error("bad name") }
        try? FileManager.default.removeItem(at: url)
        return .json(["configs": savedConfigNames()])
    }
}
#endif
