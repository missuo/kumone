#if os(macOS)
import AVFoundation
import Foundation

/// The process's vocal separator, if it has one.
///
/// KumoneCore does not depend on StemKit — separation is a macOS-only,
/// model-backed, seconds-per-window concern and this module is the shared
/// playback core. So the separator is *installed* from outside (the app's
/// launcher) as a plain closure, and everything here knows
/// is whether one showed up.
///
/// Nothing installed is the shipping default and the byte-identical path: the
/// planner still says `stems: .none`, no pre-render is ever started, and the
/// engine never sees a segment.
public enum StemSeparation {

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var provider: VocalStemProvider?
        var fullProvider: FullStemProvider?
        /// The runtime has reported an unrecoverable error; see
        /// `disarmRuntimeFatalHandler`.
        var runtimeFailed = false
        var handlerInstalled = false
    }
    private static let box = Box()

    /// Install (or, with nil, remove) the separator. Called once at startup,
    /// before anything can play.
    ///
    /// - Parameters:
    ///   - provider: the two-stem separator — vocals out, accompaniment by
    ///     subtraction. The shipping one.
    ///   - full: the four-lane separator, when this machine has the four-stem
    ///     checkpoint. Nil is a supported and common state: the checkpoint is
    ///     not auto-downloaded, so most installs have the vocals model and
    ///     nothing else, and every four-lane gesture degrades to its two-lane
    ///     form rather than being refused.
    public static func install(_ provider: VocalStemProvider?,
                               full: FullStemProvider? = nil) {
        box.lock.lock()
        box.provider = provider
        box.fullProvider = full
        box.lock.unlock()
        if provider != nil || full != nil { disarmRuntimeFatalHandler() }
    }

    public static var provider: VocalStemProvider? {
        box.lock.lock()
        defer { box.lock.unlock() }
        // A runtime that has already died once is not asked again: the answer
        // would be the same and the cost of asking is the whole process.
        return box.runtimeFailed ? nil : box.provider
    }

    /// The four-lane separator, if this machine has one.
    ///
    /// Retired by the same fatal-handler latch as `provider`, and deliberately
    /// so: the two models share one MLX runtime, and a runtime that has raised
    /// an error once is not to be asked anything again. One retirement, not two.
    public static var fullProvider: FullStemProvider? {
        box.lock.lock()
        defer { box.lock.unlock() }
        return box.runtimeFailed ? nil : box.fullProvider
    }

    /// Whether a four-lane gesture may be planned as more than its two-lane
    /// degradation.
    public static var hasFullSeparation: Bool { fullProvider != nil }

    // MARK: - The separation runtime's fatal error handler

    /// **Take the separator runtime's process-killing error handler off the
    /// app.**
    ///
    /// MLX's C API ships a default error handler that prints the message to
    /// stdout and calls `exit(-1)`. Anything the inference runtime does not like
    /// — a Metal pipeline it cannot build, a shape it cannot broadcast, a
    /// buffer allocation it cannot make under memory pressure — therefore
    /// *terminates the music player*, from a background thread, with no crash
    /// report and no chance to fall back to the plain hand-over that was armed
    /// and ready.
    ///
    /// Field case (2026-08-31 00:09:06, exit status 255 — which is `exit(-1)`):
    /// the app vanished 90 ms after `prerender start` on an `acapellaOver`
    /// seam, mid-song, with atexit handlers running cleanly and nothing else in
    /// the log. That signature is this handler and nothing else in the process.
    ///
    /// Installing our own handler makes the failure survivable rather than
    /// fixed: the C call that raised the error still returns into a runtime
    /// whose state we cannot trust, so the *first* error is not recovered from,
    /// it is merely not fatal to playback. What it buys is that no *further*
    /// separation is attempted — `provider` goes nil, so the planner stops
    /// offering stem techniques, the pre-render stops starting, and every seam
    /// from then on is the live hand-over, which is exactly what the app does
    /// on a machine with no separator installed at all.
    ///
    /// Found by `dlsym` rather than by importing: `Cmlx` is an internal target
    /// of the mlx-swift package with no library product, so it cannot be linked
    /// directly, and the symbol is C and statically linked into this binary. A
    /// runtime that does not export it (no separator built in) leaves this a
    /// no-op, which is the correct answer there too.
    public static func disarmRuntimeFatalHandler() {
        box.lock.lock()
        let already = box.handlerInstalled
        box.handlerInstalled = true
        box.lock.unlock()
        guard !already else { return }
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), // RTLD_DEFAULT
                                 "mlx_set_error_handler") else {
            PlaybackJournal.note("stem runtime handler absent (no mlx in this build)")
            return
        }
        typealias Handler = @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void
        typealias Destructor = @convention(c) (UnsafeMutableRawPointer?) -> Void
        typealias SetHandler = @convention(c) (Handler?, UnsafeMutableRawPointer?, Destructor?) -> Void
        let setHandler = unsafeBitCast(symbol, to: SetHandler.self)
        let handler: Handler = { message, _ in
            // No captures — this is a C function pointer, called from inside
            // the runtime on whatever thread raised the error.
            StemSeparation.recordRuntimeFailure(
                message.map { String(cString: $0) } ?? "unknown")
        }
        setHandler(handler, nil, nil)
        PlaybackJournal.note("stem runtime fatal handler disarmed")
    }

    /// The separation runtime raised an error. Retire it for the rest of the
    /// process and say so; playback carries on without stems.
    fileprivate static func recordRuntimeFailure(_ message: String) {
        box.lock.lock()
        let first = !box.runtimeFailed
        box.runtimeFailed = true
        box.lock.unlock()
        guard first else { return }
        PlaybackJournal.note("stem runtime failed, separation retired: \(message)")
    }

    /// Whether a hand-over may be planned with `StemAvailability.ready`.
    public static var isAvailable: Bool { provider != nil }

    /// Put a line about the separator's memory into the playback journal.
    ///
    /// The separator lives in StemKit and the journal lives here, and the
    /// dependency only runs one way, so this is the door: the host installs a
    /// `StemSeparator.onCacheTrim` hook that calls through to it. Narrower than
    /// making `PlaybackJournal` public, which would invite every module to
    /// write playback lines from wherever.
    public static func note(_ line: String) {
        PlaybackJournal.note(line)
    }
}

/// Sidecar cache for separated vocals, shared by the app's pre-render and any
/// offline render so a window separated by one is instant for the other.
///
/// Two costs shape it: a separation pass is ~1× realtime on an M4, and the
/// same window is asked for again every time the same pair of songs meets.
/// The stem is written next to the audio it came from, keyed by the window
/// bounds, so a different cue point misses rather than returning the wrong
/// audio.
public enum VocalStemCache {

    /// Bump when anything that changes a stem's *content* changes — the
    /// checkpoint, the resampling, the window convention. Stale sidecars are
    /// then never looked up rather than silently reused.
    public static let version = 1

    /// Marks a stem sidecar in a filename. Sidecars are themselves audio files
    /// living next to the audio they came from, so anything that walks a
    /// directory of songs has to skip them.
    public static let marker = ".stems-v"

    public static func isSidecar(_ url: URL) -> Bool {
        url.lastPathComponent.contains(marker)
    }

    /// Wrap a raw separator — "these samples in, the vocal stem out" — in the
    /// sidecar cache, producing the provider the renderers take.
    public static func caching(
        _ separate: @escaping @Sendable (VocalStemRequest) throws -> [[Float]]
    ) -> VocalStemProvider {
        { request in
            let url = cacheURL(for: request)
            if let cached = read(url, channels: request.samples.count,
                                 frames: request.samples.first?.count ?? 0,
                                 sampleRate: request.sampleRate) {
                return VocalStem(channels: cached, cached: true)
            }
            let vocals = try separate(request)
            write(url, channels: vocals, sampleRate: request.sampleRate)
            return VocalStem(channels: vocals, cached: false)
        }
    }

    /// `<audio file>.stems-v1-<startMs>-<durationMs>.caf`, holding the vocal
    /// stem only: the accompaniment is `mixture − vocals`, so storing it too
    /// would double the disk for nothing. `rm *.stems-*` clears the lot.
    public static func cacheURL(for request: VocalStemRequest) -> URL {
        let start = Int((request.start * 1000).rounded())
        let duration = Int((request.duration * 1000).rounded())
        return URL(fileURLWithPath: request.source.path
                   + "\(marker)\(version)-\(start)-\(duration).caf")
    }

    // MARK: - Four lanes

    /// Version marker for four-lane sidecars.
    ///
    /// **A second version, not a bump.** Bumping `version` to 2 would have
    /// invalidated every `…stems-v1-…` file on every machine that has ever run
    /// a stem transition — for a change that does not alter what a v1 file
    /// contains. A v1 sidecar is still exactly the vocal stem of exactly that
    /// window, and the two-stem path still reads it. So four-lane sidecars get
    /// their own generation and the two live side by side; `rm *.stems-*` still
    /// clears both.
    public static let fullVersion = 2

    /// Which lanes are written to disk.
    ///
    /// Three, not four: `other` is `mixture − vocals − drums − bass` by
    /// definition (see ``StemLane/other``), so storing it would be a third more
    /// disk for a subtraction. Worth spelling out that this is *not* the usual
    /// "the residual is close enough" hand-wave — the residual **is** the
    /// definition, and deriving it is what guarantees the four lanes sum back
    /// to the mixture bit-exactly after a cache round trip, which reading four
    /// separately-quantised files would not.
    public static let storedLanes: [StemLane] = [.vocals, .drums, .bass]

    /// `<audio file>.stems-v2-<startMs>-<durationMs>-<lane>.caf`.
    public static func cacheURL(for request: StemRequest, lane: StemLane) -> URL {
        let start = Int((request.start * 1000).rounded())
        let duration = Int((request.duration * 1000).rounded())
        return URL(fileURLWithPath: request.source.path
                   + "\(marker)\(fullVersion)-\(start)-\(duration)-\(lane.rawValue).caf")
    }

    /// Wrap a raw four-lane separator in the sidecar cache.
    ///
    /// All three stored lanes hit or the window is separated again: a partial
    /// hit is a sidecar set someone deleted half of, and re-separating is
    /// cheaper to reason about than mixing one fresh lane with two old ones.
    public static func cachingFull(
        _ separate: @escaping @Sendable (StemRequest) throws -> [StemLane: [[Float]]]
    ) -> FullStemProvider {
        { request in
            let channels = request.samples.count
            let frames = request.samples.first?.count ?? 0
            var hits: [StemLane: [[Float]]] = [:]
            for lane in storedLanes {
                guard let cached = read(cacheURL(for: request, lane: lane),
                                        channels: channels, frames: frames,
                                        sampleRate: request.sampleRate) else { break }
                hits[lane] = cached
            }
            if hits.count == storedLanes.count {
                return Stems(lanes: completing(hits, mixture: request.samples), cached: true)
            }

            let separated = try separate(request)
            for lane in storedLanes {
                guard let channels = separated[lane] else { continue }
                write(cacheURL(for: request, lane: lane), channels: channels,
                      sampleRate: request.sampleRate)
            }
            return Stems(lanes: completing(separated, mixture: request.samples), cached: false)
        }
    }

    /// Fill in `other` as `mixture − vocals − drums − bass`, overwriting
    /// whatever the model called by that name.
    ///
    /// Done here rather than left to each caller so there is exactly one place
    /// the partition property is established, on both the cache-hit and the
    /// cache-miss path.
    public static func completing(_ lanes: [StemLane: [[Float]]],
                                  mixture: [[Float]]) -> [StemLane: [[Float]]] {
        var result = lanes
        let channels = mixture.count
        var other = mixture
        for lane in storedLanes {
            guard let stem = lanes[lane], stem.count == channels else { return result }
            for channel in 0..<channels {
                let frames = min(other[channel].count, stem[channel].count)
                for i in 0..<frames { other[channel][i] -= stem[channel][i] }
            }
        }
        result[.other] = other
        return result
    }

    public static func read(_ url: URL, channels: Int, frames: Int,
                            sampleRate: Double) -> [[Float]]? {
        guard frames > 0, FileManager.default.fileExists(atPath: url.path),
              let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        guard Int(format.channelCount) == channels,
              format.sampleRate == sampleRate,
              file.length == AVAudioFramePosition(frames),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames)),
              (try? file.read(into: buffer)) != nil,
              buffer.frameLength == AVAudioFrameCount(frames),
              let data = buffer.floatChannelData
        else { return nil }
        return (0..<channels).map { Array(UnsafeBufferPointer(start: data[$0], count: frames)) }
    }

    public static func write(_ url: URL, channels: [[Float]], sampleRate: Double) {
        guard let frames = channels.first?.count, frames > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channels.count)),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames))
        else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        for (index, samples) in channels.enumerated() {
            samples.withUnsafeBufferPointer {
                buffer.floatChannelData![index].update(from: $0.baseAddress!, count: frames)
            }
        }
        // Float CAF: lossless, and the stem is an intermediate — quantising it
        // to 16 bit here would show up in the acapella, which gets boosted.
        var settings = format.settings
        settings[AVFormatIDKey] = kAudioFormatLinearPCM
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).caf")
        do {
            let file = try AVAudioFile(forWriting: temporary, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: temporary, to: url)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
        }
    }
}
#endif
