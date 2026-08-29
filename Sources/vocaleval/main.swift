import AVFoundation
import Foundation
import KumoneCore
import MLX
import StemKit

// vocaleval — S0.5 validation harness (offline, macOS). Not part of the app.
//
// Answers one question with data: does the v5 vocal-activity detector (five
// cues, incl. mid/side centre ratio and HPSS harmonic share) track real vocal
// presence better than the v4 three-cue heuristic it replaces?
//
// Two independent ground truths:
//   A. StemKit separation. For sampled 30 s windows, per-second
//      RMS(vocals)/RMS(mixture) is the reference; v4 and v5 are correlated
//      against it (Pearson + Spearman). Expensive, so windows are sampled and
//      every separation result is cached on disk — a crashed or interrupted run
//      resumes without redoing any GPU work.
//   B. Lyric timestamps. The corpus ships .lrc files; seconds covered by a
//      sung line are a coarse but *free* vocal label available for every track,
//      so this runs over the whole corpus rather than a sample. Reported as the
//      mean score on sung vs unsung seconds, plus point-biserial r.
//
// Both v4 and v5 come from one decode via `VocalActivityEval` — identical
// features, so any difference is the fusion and the two new cues alone.
//
// Usage:
//   swift run -c release vocaleval --corpus DIR [--per-playlist 2] [--windows 3]
//       [--cache DIR] [--dump cues.csv] [--lyrics-only]

// MARK: - Args

let args = Array(CommandLine.arguments.dropFirst())
func value(for flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func flag(_ name: String) -> Bool { args.contains(name) }

let corpusDir = value(for: "--corpus") ?? "/Users/xerwanderer/Developer/kumone-corpus"
let perPlaylist = Int(value(for: "--per-playlist") ?? "2") ?? 2
let windowSeconds = Double(value(for: "--window") ?? "30") ?? 30
let windowsPerTrack = Int(value(for: "--windows") ?? "3") ?? 3
let cacheDir = value(for: "--cache")
    ?? NSString(string: "~/.cache/kumone-vocaleval").expandingTildeInPath
let dumpPath = value(for: "--dump")
let lyricsOnly = flag("--lyrics-only")
let onlyList = value(for: "--tracks")
try? FileManager.default.createDirectory(
    atPath: cacheDir, withIntermediateDirectories: true)

func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

// MARK: - Stats

func mean(_ x: [Double]) -> Double { x.isEmpty ? 0 : x.reduce(0, +) / Double(x.count) }

func pearson(_ a: [Double], _ b: [Double]) -> Double {
    guard a.count == b.count, a.count >= 3 else { return .nan }
    let ma = mean(a), mb = mean(b)
    var num = 0.0, da = 0.0, db = 0.0
    for i in 0..<a.count {
        let u = a[i] - ma, v = b[i] - mb
        num += u * v; da += u * u; db += v * v
    }
    guard da > 1e-12, db > 1e-12 else { return .nan }
    return num / (da * db).squareRoot()
}

/// Fractional ranks with tie averaging.
func ranks(_ x: [Double]) -> [Double] {
    let order = x.indices.sorted { x[$0] < x[$1] }
    var r = [Double](repeating: 0, count: x.count)
    var i = 0
    while i < order.count {
        var j = i
        while j + 1 < order.count, x[order[j + 1]] == x[order[i]] { j += 1 }
        let avg = Double(i + j) / 2 + 1
        for k in i...j { r[order[k]] = avg }
        i = j + 1
    }
    return r
}

func spearman(_ a: [Double], _ b: [Double]) -> Double {
    guard a.count == b.count, a.count >= 3 else { return .nan }
    return pearson(ranks(a), ranks(b))
}

/// Probability that a random sung second outscores a random unsung one
/// (Mann–Whitney U / ROC AUC). 0.5 = no discrimination.
func auc(scores: [Double], labels: [Bool]) -> Double {
    let pos = labels.filter { $0 }.count
    let neg = labels.count - pos
    guard pos > 0, neg > 0 else { return .nan }
    let r = ranks(scores)
    var sumPos = 0.0
    for i in 0..<labels.count where labels[i] { sumPos += r[i] }
    return (sumPos - Double(pos) * Double(pos + 1) / 2) / (Double(pos) * Double(neg))
}

func pad(_ s: String, _ w: Int) -> String {
    let n = s.count
    return n >= w ? s : s + String(repeating: " ", count: w - n)
}

// MARK: - Audio window loader (44.1 kHz stereo)

func loadWindow(from url: URL, start: Double, length: Double) throws -> [[Float]] {
    let targetRate = 44_100.0
    let file = try AVAudioFile(forReading: url)
    let src = file.processingFormat
    guard let readFormat = AVAudioFormat(
        standardFormatWithSampleRate: src.sampleRate, channels: src.channelCount)
    else { throw NSError(domain: "vocaleval", code: 1) }
    let srcRate = src.sampleRate
    let startFrame = max(0, AVAudioFramePosition(start * srcRate))
    let endFrame = min(file.length, AVAudioFramePosition((start + length) * srcRate))
    guard startFrame < endFrame else { throw NSError(domain: "vocaleval", code: 2) }
    let frameCount = AVAudioFrameCount(endFrame - startFrame)
    file.framePosition = startFrame
    guard let buffer = AVAudioPCMBuffer(pcmFormat: readFormat, frameCapacity: frameCount)
    else { throw NSError(domain: "vocaleval", code: 3) }
    try file.read(into: buffer, frameCount: frameCount)

    let working: AVAudioPCMBuffer
    if srcRate == targetRate && src.channelCount == 2 {
        working = buffer
    } else {
        guard let dst = AVAudioFormat(standardFormatWithSampleRate: targetRate, channels: 2),
              let converter = AVAudioConverter(from: readFormat, to: dst)
        else { throw NSError(domain: "vocaleval", code: 4) }
        let cap = AVAudioFrameCount(ceil(Double(buffer.frameLength) * targetRate / srcRate) + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: cap)
        else { throw NSError(domain: "vocaleval", code: 5) }
        nonisolated(unsafe) var consumed = false
        nonisolated(unsafe) let source = buffer
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true; status.pointee = .haveData; return source
        }
        if let err { throw err }
        working = out
    }
    guard let data = working.floatChannelData else { throw NSError(domain: "vocaleval", code: 6) }
    let frames = Int(working.frameLength)
    let ch = Int(working.format.channelCount)
    let channels = (0..<min(ch, 2)).map {
        Array(UnsafeBufferPointer(start: data[$0], count: frames))
    }
    return channels.count == 1 ? [channels[0], channels[0]] : channels
}

/// Per-second RMS of a deinterleaved buffer at `sampleRate`.
func perSecondRMS(_ channels: [[Float]], sampleRate: Double) -> [Double] {
    let sps = Int(sampleRate)
    let frames = channels.first?.count ?? 0
    var out: [Double] = []
    var i = 0
    while i < frames {
        let hi = min(frames, i + sps)
        var sum = 0.0
        var n = 0
        for ch in channels {
            for s in i..<hi { sum += Double(ch[s]) * Double(ch[s]); n += 1 }
        }
        out.append(n > 0 ? (sum / Double(n)).squareRoot() : 0)
        i += sps
    }
    return out
}

// MARK: - Lyrics (.lrc) → per-second sung labels

/// Seconds covered by a sung lyric line. A line's span runs from its timestamp
/// to the next line's, capped at `maxLineSeconds` (a long gap after a line is a
/// gap, not held singing), and blank/metadata lines mark no coverage. Coarse —
/// it labels whole lines, not phonemes — but independent of any DSP.
func lyricCoverage(lrcPath: String, seconds: Int, maxLineSeconds: Double = 6) -> [Bool]? {
    guard let raw = try? String(contentsOfFile: lrcPath, encoding: .utf8) else {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: lrcPath)),
              let s = String(data: d, encoding: .isoLatin1) else { return nil }
        return parseLRC(s, seconds: seconds, maxLineSeconds: maxLineSeconds)
    }
    return parseLRC(raw, seconds: seconds, maxLineSeconds: maxLineSeconds)
}

func parseLRC(_ text: String, seconds: Int, maxLineSeconds: Double) -> [Bool]? {
    var stamps: [(Double, String)] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let s = String(line)
        var idx = s.startIndex
        var times: [Double] = []
        while idx < s.endIndex, s[idx] == "[" {
            guard let close = s[idx...].firstIndex(of: "]") else { break }
            let body = String(s[s.index(after: idx)..<close])
            let parts = body.split(separator: ":")
            if parts.count == 2, let m = Double(parts[0]), let sec = Double(parts[1]) {
                times.append(m * 60 + sec)
            }
            idx = s.index(after: close)
        }
        let content = String(s[idx...]).trimmingCharacters(in: .whitespaces)
        for t in times { stamps.append((t, content)) }
    }
    guard stamps.count >= 4 else { return nil }
    stamps.sort { $0.0 < $1.0 }
    var out = [Bool](repeating: false, count: seconds)
    for (i, entry) in stamps.enumerated() {
        guard !entry.1.isEmpty else { continue }
        let next = i + 1 < stamps.count ? stamps[i + 1].0 : entry.0 + maxLineSeconds
        let end = min(next, entry.0 + maxLineSeconds)
        var s = Int(entry.0.rounded())
        while Double(s) < end {
            if s >= 0 && s < seconds { out[s] = true }
            s += 1
        }
    }
    return out
}

// MARK: - Ground-truth cache

struct GTWindow: Codable {
    let start: Int
    /// Per-second RMS(vocals)/RMS(mixture).
    let ratio: [Double]
    /// Per-second RMS of the mixture, for the silence filter.
    let mixRMS: [Double]
}

func cacheURL(track: String, start: Int) -> URL {
    let safe = track.replacingOccurrences(of: "/", with: "_")
    return URL(fileURLWithPath: cacheDir)
        .appendingPathComponent("\(safe)@\(start)+\(Int(windowSeconds)).json")
}

// MARK: - Track selection

/// Corpus filenames are `p<N>-<index>-<artist>-<title>-<id>.mp3`; the leading
/// `p<N>` is the source playlist.
func playlist(of name: String) -> String { String(name.prefix(while: { $0 != "-" })) }

let allMP3 = ((try? FileManager.default.contentsOfDirectory(atPath: corpusDir)) ?? [])
    .filter { $0.hasSuffix(".mp3") }.sorted()

var byPlaylist: [String: [String]] = [:]
for f in allMP3 { byPlaylist[playlist(of: f), default: []].append(f) }

var stemTracks: [String]
if let onlyList {
    let want = Set(onlyList.split(separator: ",").map(String.init))
    stemTracks = allMP3.filter { want.contains($0) }
} else {
    // Spread the StemKit budget evenly across playlists.
    stemTracks = byPlaylist.keys.sorted().flatMap { Array(byPlaylist[$0]!.prefix(perPlaylist)) }
}

guard !allMP3.isEmpty else { log("no mp3 in \(corpusDir)"); exit(1) }
log("corpus \(corpusDir): \(allMP3.count) tracks, \(byPlaylist.count) playlists; "
    + "stem sample: \(stemTracks.count)")

// MARK: - Run

struct StemRow {
    let name: String, playlist: String, seconds: Int, stereo: Bool
    let oldP: Double, oldS: Double, newP: Double, newS: Double
}
struct LyricRow {
    let name: String, playlist: String, sung: Int, unsung: Int, stereo: Bool
    let oldGap: Double, newGap: Double
    let oldAUC: Double, newAUC: Double
    let oldR: Double, newR: Double
}

let semaphore = DispatchSemaphore(value: 0)
nonisolated(unsafe) var stemRows: [StemRow] = []
nonisolated(unsafe) var lyricRows: [LyricRow] = []
nonisolated(unsafe) var gGT: [Double] = [], gOld: [Double] = [], gNew: [Double] = []
nonisolated(unsafe) var pGT: [String: [Double]] = [:]
nonisolated(unsafe) var pOld: [String: [Double]] = [:]
nonisolated(unsafe) var pNew: [String: [Double]] = [:]
/// Pooled rows for offline weight fitting: cues + ground truth.
nonisolated(unsafe) var dumpRows: [String] = []

Task {
    defer { semaphore.signal() }
    do {
        // ---- Pass B: lyric agreement over the whole corpus (no GPU) ----
        log("lyric pass over \(allMP3.count) tracks…")
        nonisolated(unsafe) var lyOldScores: [Double] = []
        nonisolated(unsafe) var lyNewScores: [Double] = []
        nonisolated(unsafe) var lyLabels: [Bool] = []
        var curvesCache: [String: VocalActivityEval.Curves] = [:]

        for name in allMP3 {
            let url = URL(fileURLWithPath: corpusDir).appendingPathComponent(name)
            guard let c = try? VocalActivityEval.curves(fileAt: url) else {
                log("skip (analyze failed): \(name)"); continue
            }
            if stemTracks.contains(name) { curvesCache[name] = c }
            let lrc = URL(fileURLWithPath: corpusDir)
                .appendingPathComponent(String(name.dropLast(4)) + ".lrc").path
            guard FileManager.default.fileExists(atPath: lrc),
                  let cover = lyricCoverage(lrcPath: lrc, seconds: c.v5.count)
            else { continue }
            // Drop near-silent seconds: neither detector nor lyric file is
            // meaningful there, and they would inflate the separation.
            let maxRMS = max(c.rmsEnvelope.max() ?? 0, 1e-9)
            var o: [Double] = [], n: [Double] = [], lab: [Bool] = []
            for s in 0..<c.v5.count where c.rmsEnvelope[s] / maxRMS > 0.15 {
                o.append(Double(c.v4[s])); n.append(Double(c.v5[s])); lab.append(cover[s])
            }
            let sung = lab.filter { $0 }.count
            guard sung >= 10, lab.count - sung >= 10 else { continue }
            func gap(_ v: [Double]) -> Double {
                let a = zip(v, lab).filter { $0.1 }.map(\.0)
                let b = zip(v, lab).filter { !$0.1 }.map(\.0)
                return mean(a) - mean(b)
            }
            let labD = lab.map { $0 ? 1.0 : 0.0 }
            lyricRows.append(LyricRow(
                name: name, playlist: playlist(of: name),
                sung: sung, unsung: lab.count - sung, stereo: c.hadStereo,
                oldGap: gap(o), newGap: gap(n),
                oldAUC: auc(scores: o, labels: lab), newAUC: auc(scores: n, labels: lab),
                oldR: pearson(o, labD), newR: pearson(n, labD)))
            lyOldScores += o; lyNewScores += n; lyLabels += lab
        }

        // ---- Pass A: StemKit ground truth on sampled windows ----
        if !lyricsOnly {
            log("preparing separator…")
            let separator = try await StemSeparator.prepare()

            for name in stemTracks {
                let url = URL(fileURLWithPath: corpusDir).appendingPathComponent(name)
                let c: VocalActivityEval.Curves
                if let hit = curvesCache[name] { c = hit }
                else if let fresh = try? VocalActivityEval.curves(fileAt: url) { c = fresh }
                else { log("skip (analyze failed): \(name)"); continue }
                guard !c.v5.isEmpty else { continue }

                // Windows spread across the track, skipping head/tail edges, so
                // intro, verse and chorus material all get sampled.
                var starts: [Int] = []
                let usable = max(0, c.duration - windowSeconds - 5)
                if usable > 5 {
                    for k in 0..<windowsPerTrack {
                        starts.append(Int(5 + (Double(k) + 0.5) / Double(windowsPerTrack) * usable))
                    }
                } else {
                    starts = [0]
                }

                var gt: [Double] = [], ov: [Double] = [], nv: [Double] = []
                for startSec in starts {
                    let cu = cacheURL(track: name, start: startSec)
                    var win: GTWindow
                    if let d = try? Data(contentsOf: cu),
                       let hit = try? JSONDecoder().decode(GTWindow.self, from: d) {
                        win = hit
                    } else {
                        let mixture: [[Float]]
                        do {
                            mixture = try loadWindow(
                                from: url, start: Double(startSec), length: windowSeconds)
                        } catch { continue }
                        let stems = try await separator.separate(
                            samples: mixture, sampleRate: 44_100)
                        let vocalRMS = perSecondRMS(stems.vocals, sampleRate: 44_100)
                        let mixRMS = perSecondRMS(mixture, sampleRate: 44_100)
                        let count = min(vocalRMS.count, mixRMS.count)
                        win = GTWindow(
                            start: startSec,
                            ratio: (0..<count).map {
                                mixRMS[$0] > 1e-6 ? vocalRMS[$0] / mixRMS[$0] : 0
                            },
                            mixRMS: Array(mixRMS.prefix(count)))
                        if let d = try? JSONEncoder().encode(win) { try? d.write(to: cu) }
                        log("  separated \(name) @\(startSec)s")
                    }

                    let maxMix = win.mixRMS.max() ?? 0
                    for j in 0..<win.ratio.count {
                        let sec = win.start + j
                        guard sec < c.v5.count, sec < c.v4.count else { continue }
                        // Drop silence: the ratio is meaningless there.
                        guard win.mixRMS[j] > 0.05 * maxMix, win.mixRMS[j] > 1e-6 else { continue }
                        gt.append(win.ratio[j])
                        ov.append(Double(c.v4[sec]))
                        nv.append(Double(c.v5[sec]))
                        if dumpPath != nil, sec < c.cues.count {
                            let cue = c.cues[sec].map { String(format: "%.5f", $0) }
                                .joined(separator: ",")
                            dumpRows.append(
                                "\(name),\(sec),\(cue),\(c.hadStereo ? 1 : 0),"
                                + String(format: "%.5f", win.ratio[j]))
                        }
                    }
                }
                guard gt.count >= 5 else { log("skip (too few secs): \(name)"); continue }
                let g = playlist(of: name)
                stemRows.append(StemRow(
                    name: name, playlist: g, seconds: gt.count, stereo: c.hadStereo,
                    oldP: pearson(ov, gt), oldS: spearman(ov, gt),
                    newP: pearson(nv, gt), newS: spearman(nv, gt)))
                gGT += gt; gOld += ov; gNew += nv
                pGT[g, default: []] += gt
                pOld[g, default: []] += ov
                pNew[g, default: []] += nv
                log(String(format: "done %@ n=%d  v4 r=%.2f/rho=%.2f  v5 r=%.2f/rho=%.2f",
                           name, gt.count, pearson(ov, gt), spearman(ov, gt),
                           pearson(nv, gt), spearman(nv, gt)))
            }
        }

        // ---- Report ----
        if !stemRows.isEmpty {
            print("\n=== A. StemKit ground truth: per-track (r / rho vs vocal-to-mix RMS) ===")
            print(pad("track", 46) + pad("n", 6) + pad("st", 4)
                + pad("v4 (before)", 20) + "v5 (after)")
            for r in stemRows.sorted(by: { $0.name < $1.name }) {
                print(pad(String(r.name.prefix(44)), 46) + pad(String(r.seconds), 6)
                    + pad(r.stereo ? "Y" : "n", 4)
                    + pad(String(format: "r%+.2f rho%+.2f", r.oldP, r.oldS), 20)
                    + String(format: "r%+.2f rho%+.2f", r.newP, r.newS))
            }
            print("\n=== A. By playlist (pooled seconds) ===")
            print(pad("playlist", 10) + pad("n", 7) + pad("v4 (before)", 20) + "v5 (after)")
            for g in pGT.keys.sorted() {
                let t = pGT[g]!, o = pOld[g]!, n = pNew[g]!
                print(pad(g, 10) + pad(String(t.count), 7)
                    + pad(String(format: "r%+.2f rho%+.2f", pearson(o, t), spearman(o, t)), 20)
                    + String(format: "r%+.2f rho%+.2f", pearson(n, t), spearman(n, t)))
            }
            print("\n=== A. Overall pooled ===")
            print(String(format: "n=%d seconds over %d tracks", gGT.count, stemRows.count))
            print(String(format: "  v4 (before):  Pearson %+.3f   Spearman %+.3f",
                         pearson(gOld, gGT), spearman(gOld, gGT)))
            print(String(format: "  v5 (after):   Pearson %+.3f   Spearman %+.3f",
                         pearson(gNew, gGT), spearman(gNew, gGT)))
            let meanP = mean(stemRows.map(\.newP)) - mean(stemRows.map(\.oldP))
            let wins = stemRows.filter { $0.newP > $0.oldP }.count
            print(String(format: "  mean per-track Pearson delta %+.3f; improved on %d/%d tracks",
                         meanP, wins, stemRows.count))
        }

        if !lyricRows.isEmpty {
            print("\n=== B. Lyric-timestamp agreement (whole corpus, sung vs unsung seconds) ===")
            print(pad("track", 46) + pad("sung", 7) + pad("unsung", 8)
                + pad("v4 gap/AUC", 20) + "v5 gap/AUC")
            for r in lyricRows.sorted(by: { $0.name < $1.name }) {
                print(pad(String(r.name.prefix(44)), 46) + pad(String(r.sung), 7)
                    + pad(String(r.unsung), 8)
                    + pad(String(format: "%+.3f %.3f", r.oldGap, r.oldAUC), 20)
                    + String(format: "%+.3f %.3f", r.newGap, r.newAUC))
            }
            let labD = lyLabels.map { $0 ? 1.0 : 0.0 }
            print("\n=== B. Pooled over \(lyricRows.count) tracks, \(lyLabels.count) seconds ===")
            print(String(format: "  v4 (before):  AUC %.3f   point-biserial r %+.3f   "
                         + "mean sung-minus-unsung %+.3f",
                         auc(scores: lyOldScores, labels: lyLabels),
                         pearson(lyOldScores, labD), mean(lyricRows.map(\.oldGap))))
            print(String(format: "  v5 (after):   AUC %.3f   point-biserial r %+.3f   "
                         + "mean sung-minus-unsung %+.3f",
                         auc(scores: lyNewScores, labels: lyLabels),
                         pearson(lyNewScores, labD), mean(lyricRows.map(\.newGap))))
            let aucWins = lyricRows.filter { $0.newAUC > $0.oldAUC }.count
            print("  v5 AUC higher on \(aucWins)/\(lyricRows.count) tracks")
            let mono = lyricRows.filter { !$0.stereo }
            if !mono.isEmpty {
                print("  (\(mono.count) mono master(s) — mid/side cue inert there)")
            }
        }

        if let dumpPath, !dumpRows.isEmpty {
            let header = "track,second," + VocalActivityEval.cueNames.joined(separator: ",")
                + ",stereo,gt\n"
            try? (header + dumpRows.joined(separator: "\n") + "\n")
                .write(toFile: dumpPath, atomically: true, encoding: .utf8)
            log("wrote \(dumpRows.count) cue rows to \(dumpPath)")
        }
    } catch {
        log("error: \(error)")
        exit(1)
    }
}
semaphore.wait()
