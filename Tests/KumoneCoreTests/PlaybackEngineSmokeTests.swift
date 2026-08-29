import Testing
@testable import KumoneCore
import AVFoundation
import AudioToolbox
import Foundation
import Darwin

// Local, network-free smoke tests for PlaybackEngine.
//
// Fixtures are generated programmatically into a temp directory (nothing
// binary is committed):
// - File-deck fixtures: LPCM sine .caf written with AVAudioFile.
// - Streaming fixture: AAC in an ADTS container (.aac) written with
//   ExtAudioFile. Rationale: ProgressiveLoader rejects LPCM streams
//   (setUpConverter requires a compressed format), and AVAudioFile-written
//   .m4a puts the moov atom at the end of the file, which AudioFileStream
//   cannot parse progressively. ADTS is a self-framing stream format —
//   exactly what AudioFileStream is built for — so we go straight to it.
//
// The streaming fixture is served by a minimal POSIX-socket HTTP server on
// 127.0.0.1 (GET 200 with Content-Length; "bytes=N-" Range requests get 206).
//
// Every test runs its body under a watchdog: if it exceeds the timeout, the
// process samples itself with /usr/bin/sample so a deadlock leaves a thread
// stack in the log, then records a failure and abandons the (possibly stuck)
// worker thread instead of hanging the whole run.
//
// ENGINE BUGS THESE TESTS CAUGHT (both fixed; kept as regression coverage):
// 1. deliver() stale-accum spin (tests c/c2): binding `guard let accum` to a
//    LOCAL that went stale when flushAccum() swapped self.accum caused an
//    infinite busy-loop mid-chunk — only the first 0.5s buffer was ever
//    delivered, and on the original design (URLSession delegate queue == the
//    engine queue) the spin pinned the engine queue, so position(of:) blocked
//    forever: the reported "app not responding". Fixed by re-reading
//    self.accum every loop iteration.
// 2. AVAudioConverter poisoning AudioFileStream (test c2, flakily c/d):
//    whenever AVAudioConverter decoded AAC anywhere in the process, the next
//    AudioFileStreamParseBytes call failed with 'wht?', so a stream whose
//    bytes arrived in more than one didReceive callback died mid-parse. The
//    loader's fail() path then cancelled its own task, and the resulting
//    NSURLErrorCancelled completion was swallowed silently — no
//    .streamDownloadCompleted, no .streamFailed, position counting past the
//    track length. Reproduced standalone (per-packet, batched, deferred, and
//    cross-thread convert calls all poison the parser; macOS 26). Fixed by
//    decoding with the C AudioConverter API, between parse calls.

// MARK: - Fixtures

enum Fixtures {

    static let dir: URL = {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaybackEngineSmoke-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// 6 s 44.1 kHz mono sine .caf — file-deck fixture.
    static let sixSecondCAF: URL = try! writeSineCAF(seconds: 6, name: "six")

    /// 8 s variant for the gapless "A" deck.
    static let eightSecondCAF: URL = try! writeSineCAF(seconds: 8, name: "eight")

    /// 21 s AAC/ADTS — long enough for many 0.5 s stream buffers and to cross
    /// the engine's 40-buffer (≈20 s) high-water backpressure mark.
    static let streamADTS: URL = try! writeSineADTS(seconds: 21, name: "stream")

    /// 18 s AAC/ADTS — 36 buffers, stays below the 40-buffer high-water mark
    /// so the download is never suspended. Used by the happy-path streaming
    /// test; the 21 s fixture above deterministically reproduces a suspend /
    /// completion race (see streamBackpressureSwallowsCompletion).
    static let streamShortADTS: URL = try! writeSineADTS(seconds: 18, name: "stream18")

    /// 8 s 44.1 kHz *stereo* sine .caf — matches the graph format exactly, so
    /// the deck takes the sample-accurate `.file` / scheduleSegment path
    /// rather than the chunk-converted `.convertedFile` one the mono fixtures
    /// above go through.
    static let eightSecondStereoCAF: URL = try! writeSineCAF(seconds: 8, channels: 2, name: "eight-stereo")

    /// 6 s stereo twin of `sixSecondCAF` — the incoming deck of the
    /// seek-fallback test has to take the `.file` path too, or a `.gapless`
    /// hand-over cannot be armed on the host clock (armGaplessLocked).
    static let sixSecondStereoCAF: URL = try! writeSineCAF(seconds: 6, channels: 2, name: "six-stereo")

    /// 8 s 44.1 kHz *mono* sine that goes digitally silent after 4 s. Mono →
    /// the chunk-converted (buffer-fed) deck path. Used by the seek-residue
    /// test: seek from the loud half into the silent half and anything the
    /// monitor still hears is audio from the pre-seek position.
    static let loudThenSilentCAF: URL =
        try! writeSineCAF(seconds: 8, silentAfter: 4, name: "loud-silent")

    /// Stereo twin of the above → the sample-accurate `.file` deck path.
    static let loudThenSilentStereoCAF: URL =
        try! writeSineCAF(seconds: 8, channels: 2, silentAfter: 4, name: "loud-silent-stereo")

    static func writeSineCAF(seconds: Double, sampleRate: Double = 44_100,
                             channels: AVAudioChannelCount = 1,
                             silentAfter: Double? = nil, name: String) throws -> URL {
        let url = dir.appendingPathComponent("\(name).caf")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunkFrames: AVAudioFrameCount = 4096
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames)!
        var frame = 0
        let total = Int(seconds * sampleRate)
        let lastLoudFrame = silentAfter.map { Int($0 * sampleRate) } ?? total
        while frame < total {
            let n = min(Int(chunkFrames), total - frame)
            for channel in 0..<Int(channels) {
                let data = buffer.floatChannelData![channel]
                for i in 0..<n {
                    data[i] = frame + i < lastLoudFrame
                        ? 0.25 * sinf(2 * .pi * 440 * Float(frame + i) / Float(sampleRate))
                        : 0
                }
            }
            buffer.frameLength = AVAudioFrameCount(n)
            try file.write(from: buffer)
            frame += n
        }
        return url
    }

    /// AAC in ADTS framing via ExtAudioFile (hardware-independent encoder).
    static func writeSineADTS(seconds: Double, sampleRate: Double = 44_100, name: String) throws -> URL {
        let url = dir.appendingPathComponent("\(name).aac")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        var outDesc = AudioStreamBasicDescription()
        outDesc.mSampleRate = sampleRate
        outDesc.mFormatID = kAudioFormatMPEG4AAC
        outDesc.mChannelsPerFrame = 1
        // Leave the rest zero: the encoder fills them in.

        var extFile: ExtAudioFileRef?
        var status = ExtAudioFileCreateWithURL(url as CFURL, kAudioFileAAC_ADTSType,
                                               &outDesc, nil,
                                               AudioFileFlags.eraseFile.rawValue, &extFile)
        guard status == noErr, let ext = extFile else {
            throw NSError(domain: "Fixtures", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "ExtAudioFileCreateWithURL(ADTS) failed (\(status))"])
        }
        defer { ExtAudioFileDispose(ext) }

        // Client format: interleaved (packed) float32 mono LPCM.
        var clientDesc = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        status = ExtAudioFileSetProperty(ext, kExtAudioFileProperty_ClientDataFormat,
                                         UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                                         &clientDesc)
        guard status == noErr else {
            throw NSError(domain: "Fixtures", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "SetProperty(ClientDataFormat) failed (\(status))"])
        }

        let chunk = 4096
        var samples = [Float](repeating: 0, count: chunk)
        var frame = 0
        let total = Int(seconds * sampleRate)
        while frame < total {
            let n = min(chunk, total - frame)
            for i in 0..<n {
                samples[i] = 0.25 * sinf(2 * .pi * 440 * Float(frame + i) / Float(sampleRate))
            }
            status = samples.withUnsafeMutableBufferPointer { ptr -> OSStatus in
                var abl = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: 1,
                                          mDataByteSize: UInt32(n * 4),
                                          mData: UnsafeMutableRawPointer(ptr.baseAddress)))
                return ExtAudioFileWrite(ext, UInt32(n), &abl)
            }
            guard status == noErr else {
                throw NSError(domain: "Fixtures", code: Int(status),
                              userInfo: [NSLocalizedDescriptionKey: "ExtAudioFileWrite failed (\(status))"])
            }
            frame += n
        }
        return url
    }
}

// MARK: - Minimal local HTTP server (POSIX sockets)

final class TestHTTPServer: @unchecked Sendable {

    let port: UInt16
    private let data: Data
    private let listenFD: Int32
    private let thread: Thread

    init(serving data: Data) throws {
        self.data = data
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EMFILE) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // random port
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bindResult == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &len) }
        }
        listenFD = fd
        port = UInt16(bigEndian: bound.sin_port)

        let serveData = data
        let serveFD = fd
        thread = Thread {
            while true {
                let client = accept(serveFD, nil, nil)
                if client < 0 { break } // listen socket closed → stop
                TestHTTPServer.handle(client: client, data: serveData)
            }
        }
        thread.name = "TestHTTPServer"
        thread.start()
    }

    var url: URL { URL(string: "http://127.0.0.1:\(port)/fixture.aac")! }

    func stop() { close(listenFD) }

    private static func handle(client: Int32, data: Data) {
        defer { close(client) }
        var yes: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

        // Read until end of headers (tiny requests; one read is usually enough).
        var request = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        while !request.contains(0x0D) || request.range(of: Data("\r\n\r\n".utf8)) == nil {
            let n = read(client, &buf, buf.count)
            guard n > 0 else { return }
            request.append(contentsOf: buf[0..<n])
            if request.count > 65_536 { return }
        }
        let head = String(decoding: request, as: UTF8.self)

        // Range support: "Range: bytes=N-" and "bytes=N-M".
        var lo = 0
        var hi = data.count - 1
        var partial = false
        for line in head.split(separator: "\r\n") where line.lowercased().hasPrefix("range:") {
            let spec = line.dropFirst("range:".count).trimmingCharacters(in: .whitespaces)
            guard spec.lowercased().hasPrefix("bytes=") else { continue }
            let parts = spec.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
            if parts.count == 2, let start = Int(parts[0]), start < data.count {
                lo = start
                if let end = Int(parts[1]), end < data.count { hi = end }
                partial = true
            }
        }

        let body = data.subdata(in: lo..<(hi + 1))
        var header = partial
            ? "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \(lo)-\(hi)/\(data.count)\r\n"
            : "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: audio/aac\r\nAccept-Ranges: bytes\r\n"
        header += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"

        var out = Data(header.utf8)
        out.append(body)
        out.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = write(client, raw.baseAddress! + sent, raw.count - sent)
                if n <= 0 { return }
                sent += n
            }
        }
    }
}

// MARK: - Watchdog

/// Runs `body` on its own thread. If it does not finish within `timeout`,
/// samples this process (thread stacks land in the test log), records a
/// failure, and returns nil — leaking the stuck thread rather than hanging
/// the test run.
private final class ResultBox<T>: @unchecked Sendable { var value: T? }

private func withWatchdog<T>(_ label: String, timeout: TimeInterval,
                             _ body: @escaping () -> T) -> T? {
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        box.value = body()
        done.signal()
    }
    thread.name = "watchdog-body-\(label)"
    thread.stackSize = 1 << 21
    thread.start()
    if done.wait(timeout: .now() + timeout) == .timedOut {
        dumpProcessSample(label: label)
        Issue.record("Watchdog: '\(label)' did not finish within \(timeout)s — likely deadlock/blocked queue; see sample above")
        return nil
    }
    return box.value
}

private func dumpProcessSample(label: String) {
    print("=== WATCHDOG TIMEOUT (\(label)): sampling pid \(getpid()) ===")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
    p.arguments = ["\(getpid())", "2"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do {
        try p.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        print(String(decoding: out, as: UTF8.self))
    } catch {
        print("sample failed: \(error)")
    }
    print("=== END SAMPLE (\(label)) ===")
}

// MARK: - Event collection

/// Consumes the engine's single-consumer AsyncStream on a dedicated Task and
/// makes events poll-able from synchronous test code.
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [PlaybackEngineEvent] = []
    private var task: Task<Void, Never>?

    init(_ engine: PlaybackEngine) {
        task = Task {
            for await event in engine.events {
                self.append(event)
            }
        }
    }

    private func append(_ event: PlaybackEngineEvent) {
        lock.lock(); defer { lock.unlock() }
        events.append(event)
    }

    deinit { task?.cancel() }

    func snapshot() -> [PlaybackEngineEvent] {
        lock.lock(); defer { lock.unlock() }
        return events
    }

    func contains(_ predicate: (PlaybackEngineEvent) -> Bool) -> Bool {
        snapshot().contains(where: predicate)
    }

    /// Polls every 50 ms until an event matches or the timeout passes.
    @discardableResult
    func wait(timeout: TimeInterval, for predicate: (PlaybackEngineEvent) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if contains(predicate) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return contains(predicate)
    }
}

// MARK: - Shared helpers

/// Can AVAudioEngine reach an output device at all? (CI/headless machines may
/// have none; those environments skip the playback assertions.)
private let audioOutputAvailable: Bool = {
    let engine = AVAudioEngine()
    engine.mainMixerNode.outputVolume = 0
    engine.prepare()
    do {
        try engine.start()
        engine.stop()
        return true
    } catch {
        print("PlaybackEngineSmoke: no usable audio output (\(error)); playback tests will be skipped")
        return false
    }
}()

/// Poll `engine.position(of:)` until it exceeds `target` or `timeout` passes.
private func pollPosition(_ engine: PlaybackEngine, deck: Deck, past target: TimeInterval,
                          timeout: TimeInterval) -> TimeInterval {
    let deadline = Date().addingTimeInterval(timeout)
    var last: TimeInterval = 0
    while Date() < deadline {
        last = engine.position(of: deck)
        if last > target { return last }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return last
}

// MARK: - Tests

@Suite("PlaybackEngineSmoke", .serialized)
struct PlaybackEngineSmokeTests {

    // (a) Local file deck: position advances, deckFinished on natural end.
    @Test func filePlaybackAdvancesAndFinishes() throws {
        guard audioOutputAvailable else { return } // skipped: no audio device
        let result = withWatchdog("filePlayback", timeout: 25) { () -> (TimeInterval, Bool) in
            let engine = PlaybackEngine()
            let log = EventLog(engine)
            defer { engine.stopAll() }
            do {
                _ = try engine.loadFile(at: Fixtures.sixSecondCAF, on: .a)
            } catch {
                return (-1, false)
            }
            engine.outputVolume = 0
            engine.play(deck: .a, from: 0)
            let pos = pollPosition(engine, deck: .a, past: 1.0, timeout: 3)
            let finished = log.wait(timeout: 10) {
                if case .deckFinished(.a) = $0 { return true }
                return false
            }
            return (pos, finished)
        }
        guard let (position, finished) = result else { return } // watchdog already failed the test
        #expect(position > 1.0, "position should advance past 1s within 3s (got \(position))")
        #expect(finished, ".deckFinished(.a) should arrive after the 6s file drains")
    }

    // (b) seek / pause / resume semantics on a file deck.
    @Test func seekPauseResume() throws {
        guard audioOutputAvailable else { return }
        struct Outcome { var seekPos = TimeInterval(-1); var pausedA = TimeInterval(-1)
                         var pausedB = TimeInterval(-1); var resumed = TimeInterval(-1) }
        let result = withWatchdog("seekPauseResume", timeout: 25) { () -> Outcome in
            var o = Outcome()
            let engine = PlaybackEngine()
            _ = EventLog(engine)
            defer { engine.stopAll() }
            guard (try? engine.loadFile(at: Fixtures.sixSecondCAF, on: .a)) != nil else { return o }
            engine.outputVolume = 0
            engine.play(deck: .a, from: 0)
            Thread.sleep(forTimeInterval: 0.5)

            engine.seek(deck: .a, to: 3)
            // Seek is async on the engine queue; wait for it to land.
            o.seekPos = pollPosition(engine, deck: .a, past: 2.9, timeout: 1)

            engine.pause()
            Thread.sleep(forTimeInterval: 0.2) // let the async pause land
            o.pausedA = engine.position(of: .a)
            Thread.sleep(forTimeInterval: 0.5)
            o.pausedB = engine.position(of: .a)

            engine.resume()
            Thread.sleep(forTimeInterval: 1.0)
            o.resumed = engine.position(of: .a)
            return o
        }
        guard let o = result else { return }
        #expect(abs(o.seekPos - 3) <= 0.3, "position after seek(3) should be 3±0.3 (got \(o.seekPos))")
        #expect(abs(o.pausedB - o.pausedA) < 0.05,
                "position must freeze while paused (\(o.pausedA) → \(o.pausedB))")
        #expect(o.resumed > o.pausedB + 0.5,
                "position must advance after resume (\(o.pausedB) → \(o.resumed))")
    }

    // (c) Progressive streaming from a local HTTP server: position advances,
    // download completes, and the .part mirror matches the fixture bytes.
    @Test func streamingPlaybackAndPartFile() throws {
        guard audioOutputAvailable else { return }
        let fixtureData = try Data(contentsOf: Fixtures.streamShortADTS)
        let server = try TestHTTPServer(serving: fixtureData)
        defer { server.stop() }
        let partURL = Fixtures.dir.appendingPathComponent("stream-c.part")
        try? FileManager.default.removeItem(at: partURL)

        struct Outcome { var pos = TimeInterval(-1); var downloadDone = false
                         var failed: String?; var partSize = -1 }
        let serverURL = server.url
        // 18s fixture: below the high-water mark, the local download is never
        // suspended, so streamDownloadCompleted arrives within seconds.
        let result = withWatchdog("streaming", timeout: 30) { () -> Outcome in
            var o = Outcome()
            let engine = PlaybackEngine()
            let log = EventLog(engine)
            defer { engine.stopAll() }
            engine.outputVolume = 0
            engine.startStreaming(from: serverURL, formatHint: "aac", writingTo: partURL, on: .b)
            engine.play(deck: .b, from: 0)
            o.pos = pollPosition(engine, deck: .b, past: 1.0, timeout: 3)
            o.downloadDone = log.wait(timeout: 20) {
                if case .streamDownloadCompleted(.b) = $0 { return true }
                return false
            }
            for event in log.snapshot() {
                if case .streamFailed(_, let error) = event { o.failed = "\(error)" }
            }
            o.partSize = (try? FileManager.default.attributesOfItem(atPath: partURL.path)[.size] as? Int ?? -1) ?? -1
            return o
        }
        guard let o = result else { return }
        #expect(o.failed == nil, "stream failed: \(o.failed ?? "")")
        #expect(o.pos > 1.0, "stream position should advance past 1s within 3s (got \(o.pos))")
        #expect(o.downloadDone, ".streamDownloadCompleted(.b) should arrive")
        #expect(o.partSize == fixtureData.count,
                ".part size (\(o.partSize)) should equal fixture size (\(fixtureData.count))")
    }

    // (d) KEY: main-thread responsiveness. While a stream is spinning up and
    // decoding, position(of:) — a queue.sync hop, exactly what the UI thread
    // does — must never block for long. This is the "app not responding"
    // reproduction: if decode work floods the engine queue, single calls here
    // stall for hundreds of ms.
    @Test func positionCallLatencyDuringStreaming() throws {
        guard audioOutputAvailable else { return }
        let fixtureData = try Data(contentsOf: Fixtures.streamADTS)
        let server = try TestHTTPServer(serving: fixtureData)
        defer { server.stop() }
        let partURL = Fixtures.dir.appendingPathComponent("stream-d.part")
        try? FileManager.default.removeItem(at: partURL)

        struct Outcome { var maxMs = -1.0; var meanMs = -1.0; var calls = 0; var over100 = 0 }
        let serverURL = server.url
        let result = withWatchdog("positionLatency", timeout: 30) { () -> Outcome in
            var o = Outcome()
            let engine = PlaybackEngine()
            _ = EventLog(engine)
            defer { engine.stopAll() }
            engine.outputVolume = 0
            engine.startStreaming(from: serverURL, formatHint: "aac", writingTo: partURL, on: .b)
            engine.play(deck: .b, from: 0)

            // First 3 seconds after stream start: poll from this (non-engine)
            // thread at 10 Hz, timing each queue.sync round trip.
            var durations: [Double] = []
            let end = Date().addingTimeInterval(3.0)
            while Date() < end {
                let t0 = DispatchTime.now().uptimeNanoseconds
                _ = engine.position(of: .b)
                let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                durations.append(ms)
                Thread.sleep(forTimeInterval: 0.1)
            }
            o.calls = durations.count
            o.maxMs = durations.max() ?? -1
            o.meanMs = durations.reduce(0, +) / Double(max(durations.count, 1))
            o.over100 = durations.filter { $0 >= 100 }.count
            return o
        }
        guard let o = result else { return }
        print("positionCallLatency: calls=\(o.calls) max=\(String(format: "%.2f", o.maxMs))ms " +
              "mean=\(String(format: "%.3f", o.meanMs))ms callsOver100ms=\(o.over100)")
        #expect(o.maxMs < 100,
                "max single position(of:) latency must stay under 100ms; measured \(String(format: "%.2f", o.maxMs))ms over \(o.calls) calls (\(o.over100) calls ≥100ms) — a failure here reproduces the 'not responding' hang")
    }

    // (c2) Same as (c) but with a fixture LONGER than the 40-buffer (≈20s)
    // high-water mark, so a correct engine must exercise the backpressure
    // suspend/resume path before the download can complete. This test caught
    // engine bug #2 (see the suite header): with AVAudioConverter as the
    // decoder, any stream delivered in more than one didReceive chunk died on
    // the next parse call, and the failure was swallowed silently. It also
    // guards the backpressure design itself: suspension pauses parsing (bytes
    // keep arriving into a backlog and the .part mirror), never the
    // URLSession task, so the transfer's completion callback can't be lost
    // no matter how fast the download outruns playback.
    @Test func streamBackpressureSwallowsCompletion() throws {
        guard audioOutputAvailable else { return }
        let fixtureData = try Data(contentsOf: Fixtures.streamADTS) // 21s > high water
        let server = try TestHTTPServer(serving: fixtureData)
        defer { server.stop() }
        let partURL = Fixtures.dir.appendingPathComponent("stream-c2.part")
        try? FileManager.default.removeItem(at: partURL)
        let serverURL = server.url

        let result = withWatchdog("backpressure", timeout: 40) { () -> Bool in
            let engine = PlaybackEngine()
            let log = EventLog(engine)
            defer { engine.stopAll() }
            engine.outputVolume = 0
            engine.startStreaming(from: serverURL, formatHint: "aac", writingTo: partURL, on: .b)
            engine.play(deck: .b, from: 0)
            // With a correct engine the low-water resume (~15s in) releases
            // the transfer and completion arrives shortly after; 30s is ample.
            return log.wait(timeout: 30) {
                if case .streamDownloadCompleted(.b) = $0 { return true }
                return false
            }
        }
        guard let downloadDone = result else { return }
        #expect(downloadDone, ".streamDownloadCompleted should arrive even when the download outruns playback past the high-water mark")
    }

    // (e) Gapless transition A → B: midpoint + completed events, then B's
    // position advances.
    @Test func gaplessTransition() throws {
        guard audioOutputAvailable else { return }
        struct Outcome { var midpoint = false; var completed = false
                         var bPosEarly = TimeInterval(-1); var bPosLate = TimeInterval(-1) }
        let result = withWatchdog("gapless", timeout: 30) { () -> Outcome in
            var o = Outcome()
            let engine = PlaybackEngine()
            let log = EventLog(engine)
            defer { engine.stopAll() }
            guard (try? engine.loadFile(at: Fixtures.eightSecondCAF, on: .a)) != nil,
                  (try? engine.loadFile(at: Fixtures.sixSecondCAF, on: .b)) != nil else { return o }
            engine.outputVolume = 0
            // Start A near its tail so the hand-over happens within ~3s.
            engine.play(deck: .a, from: 5)
            engine.scheduleTransition(.plain(.gapless), from: .a, to: .b)

            o.completed = log.wait(timeout: 10) {
                if case .transitionCompleted(from: .a, to: .b) = $0 { return true }
                return false
            }
            o.midpoint = log.contains {
                if case .transitionMidpoint(from: .a, to: .b, via: _) = $0 { return true }
                return false
            }
            o.bPosEarly = engine.position(of: .b)
            Thread.sleep(forTimeInterval: 1.0)
            o.bPosLate = engine.position(of: .b)
            return o
        }
        guard let o = result else { return }
        #expect(o.midpoint, ".transitionMidpoint(a→b) should be emitted")
        #expect(o.completed, ".transitionCompleted(a→b) should be emitted")
        #expect(o.bPosLate > o.bPosEarly + 0.5,
                "deck B position should advance after the hand-over (\(o.bPosEarly) → \(o.bPosLate))")
    }

    // (f) TransitionStyle execution. Each style runs a real A → B overlap and
    // must (1) show its effect engaged while the overlap is live and (2) leave
    // BOTH decks fully neutral once everything has settled — decks are reused,
    // so a stuck high-pass or a wet delay would poison the next track.
    @Test func styledTransitionsRunAndResetDecks() throws {
        guard audioOutputAvailable else { return }

        struct Case {
            let name: String
            let planned: PlannedTransition
            /// Evidence, sampled during the overlap, that the style ran.
            let evidence: (PlaybackEngine.DeckEffectSnapshot) -> Bool
        }

        let crossfade = TransitionPlan.crossfade(duration: 2.0, outPoint: 5.2, inPoint: 0)
        let beatMatched = TransitionPlan.beatMatched(BeatMatchedPlan(
            outPoint: 5.2, inPoint: 0, overlapBars: 2,
            outgoingRate: 0.99, incomingRate: 1.02,
            bassSwapOffset: 1.2, overlapDuration: 2.4))

        let cases = [
            Case(name: "echoOut",
                 planned: PlannedTransition(
                     plan: crossfade,
                     style: TransitionStyle(outroEffect: .echoOut, stagedEQ: false)),
                 // The delay is thrown at the stop point (65% into the overlap).
                 evidence: { $0.delayWetDryMix > 1 }),
            Case(name: "filterSweep",
                 planned: PlannedTransition(
                     plan: crossfade,
                     style: TransitionStyle(outroEffect: .filterSweep, stagedEQ: false)),
                 // The high-pass band un-bypasses and sweeps up from 20 Hz.
                 evidence: { !$0.highPassBypassed && $0.highPassFrequency > 25 }),
            Case(name: "stagedEQ/beatMatched",
                 planned: PlannedTransition(
                     plan: beatMatched,
                     style: TransitionStyle(outroEffect: .fade, stagedEQ: true)),
                 // Highs leave the outgoing deck first, before the bass swap.
                 evidence: { $0.highGain < -1 && $0.midGain < -0.5 }),
        ]

        for testCase in cases {
            struct Outcome {
                var evidenceSeen = false
                var completed = false
                var settled = false
                var deckA = PlaybackEngine.DeckEffectSnapshot(
                    volume: -1, rate: -1, eqGlobalGain: -1, lowGain: -1, midGain: -1, highGain: -1,
                    highPassBypassed: false, highPassFrequency: -1,
                    delayWetDryMix: -1, delayFeedback: -1)
                var deckB: PlaybackEngine.DeckEffectSnapshot?
            }

            let result = withWatchdog("style-\(testCase.name)", timeout: 45) { () -> Outcome in
                var o = Outcome()
                let engine = PlaybackEngine()
                let log = EventLog(engine)
                defer { engine.stopAll() }
                guard (try? engine.loadFile(at: Fixtures.eightSecondCAF, on: .a)) != nil,
                      (try? engine.loadFile(at: Fixtures.sixSecondCAF, on: .b)) != nil else { return o }
                engine.outputVolume = 0
                engine.play(deck: .a, from: 4.7)
                engine.scheduleTransition(testCase.planned, from: .a, to: .b)

                // Sample deck A at 20 Hz until the overlap is over, looking for
                // the style's fingerprint.
                let deadline = Date().addingTimeInterval(12)
                while Date() < deadline {
                    if testCase.evidence(engine.effectSnapshot(of: .a)) { o.evidenceSeen = true }
                    if log.contains({
                        if case .transitionCompleted(from: .a, to: .b) = $0 { return true }
                        return false
                    }) { o.completed = true; break }
                    Thread.sleep(forTimeInterval: 0.05)
                }

                // Wait out the settling phase (rate restore / echo tail decay).
                let settleDeadline = Date().addingTimeInterval(6)
                while Date() < settleDeadline {
                    if !engine.hasPendingTransition { o.settled = true; break }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                o.deckA = engine.effectSnapshot(of: .a)
                o.deckB = engine.effectSnapshot(of: .b)
                return o
            }
            guard let o = result else { continue }
            #expect(o.completed, "\(testCase.name): .transitionCompleted(a→b) should be emitted")
            #expect(o.evidenceSeen, "\(testCase.name): the style's effect should engage during the overlap")
            #expect(o.settled, "\(testCase.name): the transition should clear itself after settling")
            // The spent deck is parked: chain transparent AND fader down, so
            // the ~200 ms still draining out of a just-stopped player node
            // cannot be heard (see resetDeckLocked).
            #expect(o.deckA.isParked,
                    "\(testCase.name): outgoing deck must be parked silent + neutral after the transition (\(o.deckA))")
            if let deckB = o.deckB {
                #expect(deckB.isNeutral,
                        "\(testCase.name): incoming deck must be neutral after the transition (\(deckB))")
            }
        }
    }

    // (g) Regression floor: `.plain` must behave exactly as the engine did
    // before styles existed — a beat-matched overlap with the single low-shelf
    // bass swap, no delay, no high-pass, and neutral decks afterwards.
    @Test func plainStyleIsUnchanged() throws {
        guard audioOutputAvailable else { return }
        struct Outcome {
            var completed = false
            var sawBassSwap = false
            var sawDelayOrSweep = false
            var deckA: PlaybackEngine.DeckEffectSnapshot?
            var deckB: PlaybackEngine.DeckEffectSnapshot?
        }
        let plan = TransitionPlan.beatMatched(BeatMatchedPlan(
            outPoint: 5.2, inPoint: 0, overlapBars: 2,
            outgoingRate: 0.99, incomingRate: 1.02,
            bassSwapOffset: 1.2, overlapDuration: 2.4))

        let result = withWatchdog("plainStyle", timeout: 45) { () -> Outcome in
            var o = Outcome()
            let engine = PlaybackEngine()
            let log = EventLog(engine)
            defer { engine.stopAll() }
            guard (try? engine.loadFile(at: Fixtures.eightSecondCAF, on: .a)) != nil,
                  (try? engine.loadFile(at: Fixtures.sixSecondCAF, on: .b)) != nil else { return o }
            engine.outputVolume = 0
            engine.play(deck: .a, from: 4.7)
            engine.scheduleTransition(.plain(plan), from: .a, to: .b)

            let deadline = Date().addingTimeInterval(12)
            while Date() < deadline {
                let a = engine.effectSnapshot(of: .a)
                if a.lowGain < -1 { o.sawBassSwap = true }
                // Untouched by `.plain`: mid/high bands, high-pass, delay.
                if a.delayWetDryMix > 0.001 || !a.highPassBypassed
                    || abs(a.midGain) > 0.001 || abs(a.highGain) > 0.001 {
                    o.sawDelayOrSweep = true
                }
                if log.contains({
                    if case .transitionCompleted(from: .a, to: .b) = $0 { return true }
                    return false
                }) { o.completed = true; break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            let settleDeadline = Date().addingTimeInterval(6)
            while Date() < settleDeadline {
                if !engine.hasPendingTransition { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            o.deckA = engine.effectSnapshot(of: .a)
            o.deckB = engine.effectSnapshot(of: .b)
            return o
        }
        guard let o = result else { return }
        #expect(o.completed, "plain: .transitionCompleted(a→b) should be emitted")
        #expect(o.sawBassSwap, "plain: the low-shelf bass swap should still duck the outgoing deck")
        #expect(!o.sawDelayOrSweep, "plain: no delay, high-pass or extra EQ band may be touched")
        #expect(o.deckA?.isParked == true, "plain: outgoing deck must end parked silent + neutral (\(String(describing: o.deckA)))")
        #expect(o.deckB?.isNeutral == true, "plain: incoming deck must end neutral (\(String(describing: o.deckB)))")
    }

    // (g2) Loudness compensation. The trim is a multiplier folded into the one
    // fader writer, so two things have to hold: at 0 dB the engine is
    // bit-identical to what it was before the trim existed, and at a real trim
    // every fader path (play, the overlap ramp, the parked pose) is scaled by
    // exactly that factor with nothing else moving.
    @Test func loudnessTrimScalesTheFaderAndZeroDBChangesNothing() throws {
        guard audioOutputAvailable else { return }
        struct Outcome {
            var untrimmed: PlaybackEngine.DeckEffectSnapshot?
            var trimmed: PlaybackEngine.DeckEffectSnapshot?
            var trimmedAfterStop: PlaybackEngine.DeckEffectSnapshot?
        }
        let result = withWatchdog("loudnessTrim", timeout: 40) { () -> Outcome in
            var o = Outcome()
            let engine = PlaybackEngine()
            _ = EventLog(engine)
            defer { engine.stopAll() }
            engine.outputVolume = 0
            // Default (no trim argument): unity, exactly the old behaviour.
            guard (try? engine.loadFile(at: Fixtures.eightSecondCAF, on: .a)) != nil
            else { return o }
            engine.play(deck: .a, from: 0)
            Thread.sleep(forTimeInterval: 0.4)
            o.untrimmed = engine.effectSnapshot(of: .a)

            // −6.0206 dB = exactly half amplitude.
            guard (try? engine.loadFile(at: Fixtures.sixSecondCAF, on: .b,
                                        trimDB: -6.0206)) != nil else { return o }
            engine.play(deck: .b, from: 0)
            Thread.sleep(forTimeInterval: 0.4)
            o.trimmed = engine.effectSnapshot(of: .b)

            engine.stop(deck: .b)
            Thread.sleep(forTimeInterval: 0.2)
            o.trimmedAfterStop = engine.effectSnapshot(of: .b)
            return o
        }
        guard let o = result, let untrimmed = o.untrimmed, let trimmed = o.trimmed,
              let stopped = o.trimmedAfterStop else { return }

        #expect(untrimmed.trim == 1, "a plain load must leave the deck at unity")
        #expect(abs(untrimmed.volume - 1) < 0.001,
                "0 dB trim: the fader must sit at 1 exactly as before (\(untrimmed.volume))")
        #expect(untrimmed.isNeutral, "0 dB trim: the deck's pose must be unchanged")

        #expect(abs(trimmed.trim - 0.5) < 0.001, "trim multiplier (\(trimmed.trim))")
        #expect(abs(trimmed.volume - 0.5) < 0.001,
                "a fully open fader on a −6 dB deck sits at 0.5 (\(trimmed.volume))")
        // Nothing *but* the fader moves: the trim is not an EQ or a rate change.
        #expect(trimmed.effectsAreNeutral)
        #expect(trimmed.isNeutral, "'fader open' means the deck's trim, not literally 1")

        // A deck taken out of service goes back to unity, so the next track
        // cannot inherit the previous one's gain.
        #expect(stopped.trim == 1)
        #expect(stopped.isParked)
    }

    /// A styled overlap under a trim: the automation's 0–1 curves are scaled,
    /// never replaced, so the incoming deck still lands exactly on its trim and
    /// the outgoing deck still ends parked silent.
    @Test func aTrimmedDeckStillEndsTheTransitionNeutral() throws {
        guard audioOutputAvailable else { return }
        let plan = TransitionPlan.beatMatched(BeatMatchedPlan(
            outPoint: 5.2, inPoint: 0, overlapBars: 2,
            outgoingRate: 0.99, incomingRate: 1.02,
            bassSwapOffset: 1.2, overlapDuration: 2.4))
        let result = withWatchdog("trimmedTransition", timeout: 45) {
            () -> [PlaybackEngine.DeckEffectSnapshot] in
            let engine = PlaybackEngine()
            let log = EventLog(engine)
            defer { engine.stopAll() }
            guard (try? engine.loadFile(at: Fixtures.eightSecondCAF, on: .a,
                                        trimDB: -3)) != nil,
                  (try? engine.loadFile(at: Fixtures.sixSecondCAF, on: .b,
                                        trimDB: 2)) != nil else { return [] }
            engine.outputVolume = 0
            engine.play(deck: .a, from: 4.7)
            engine.scheduleTransition(.plain(plan), from: .a, to: .b)
            let deadline = Date().addingTimeInterval(14)
            while Date() < deadline {
                if log.contains({
                    if case .transitionCompleted(from: .a, to: .b) = $0 { return true }
                    return false
                }) { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            let settle = Date().addingTimeInterval(6)
            while Date() < settle, engine.hasPendingTransition {
                Thread.sleep(forTimeInterval: 0.05)
            }
            return [engine.effectSnapshot(of: .a), engine.effectSnapshot(of: .b)]
        }
        guard let snapshots = result, snapshots.count == 2 else { return }
        #expect(snapshots[0].isParked,
                "trimmed outgoing deck must end parked silent (\(snapshots[0]))")
        #expect(snapshots[1].isNeutral,
                "trimmed incoming deck must end at its own trim (\(snapshots[1]))")
        #expect(abs(snapshots[1].volume - snapshots[1].trim) < 0.001)
        #expect(abs(snapshots[1].trim - 1.2589) < 0.001, "+2 dB = ×1.2589")
    }

    /// The transition gain ride, end to end on the live graph: full value for
    /// the whole overlap, then a slow glide back to unity that outlives the
    /// transition itself.
    @Test func theRideIsHeldAcrossTheOverlapAndThenGlidesBack() throws {
        guard audioOutputAvailable else { return }
        let planned = PlannedTransition(
            plan: .crossfade(duration: 2.0, outPoint: 5.2, inPoint: 0),
            style: .plain, rideDB: -4)
        struct Outcome {
            var duringOverlap: PlaybackEngine.DeckEffectSnapshot?
            var justAfter: PlaybackEngine.DeckEffectSnapshot?
            var laterStillGliding: PlaybackEngine.DeckEffectSnapshot?
            var transitionCleared = false
        }
        let result = withWatchdog("rideGlide", timeout: 45) { () -> Outcome in
            var o = Outcome()
            let engine = PlaybackEngine()
            let log = EventLog(engine)
            defer { engine.stopAll() }
            guard (try? engine.loadFile(at: Fixtures.eightSecondCAF, on: .a)) != nil,
                  (try? engine.loadFile(at: Fixtures.sixSecondCAF, on: .b)) != nil else { return o }
            engine.outputVolume = 0
            engine.play(deck: .a, from: 4.7)
            engine.scheduleTransition(planned, from: .a, to: .b)
            // Out point is ~0.5 s away; sample a second in, mid-overlap.
            Thread.sleep(forTimeInterval: 1.2)
            o.duringOverlap = engine.effectSnapshot(of: .b)

            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if log.contains({
                    if case .transitionCompleted(from: .a, to: .b) = $0 { return true }
                    return false
                }) { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            Thread.sleep(forTimeInterval: 0.3)
            o.justAfter = engine.effectSnapshot(of: .b)
            // A −4 dB cut releases at 1.2 dB/s, so it runs for ~3.3 s. Long
            // before that is up the transition state machine must have let go.
            Thread.sleep(forTimeInterval: 1.2)
            o.transitionCleared = !engine.hasPendingTransition
            o.laterStillGliding = engine.effectSnapshot(of: .b)
            return o
        }
        guard let o = result, let during = o.duringOverlap, let after = o.justAfter,
              let later = o.laterStillGliding else { return }

        // Held at its full value while the two decks share the room.
        #expect(abs(during.rideDB - -4) < 0.001,
                "the ride must be at full value across the overlap (\(during))")
        #expect(abs(during.rideTargetDB - -4) < 0.001, "…and not yet gliding anywhere")

        // Released the moment the overlap ends: heading for unity, not there yet.
        #expect(after.rideTargetDB == 0, "the release must be aimed at unity (\(after))")
        #expect(after.rideDB < 0 && after.rideDB > -4,
                "the release must have started but not finished (\(after))")
        // …and it does not hold the transition open while it runs.
        #expect(o.transitionCleared,
                "the ride release must not block the transition state machine")
        #expect(later.rideDB > after.rideDB && later.rideDB < 0,
                "the glide must keep climbing after the transition cleared (\(after.rideDB) → \(later.rideDB))")
        // ~1.2 dB/s — this is a *cut*, released upward, and the fast slope is
        // the whole point: at the old 0.3 dB/s the new track spent its first
        // dozen seconds under its own level. Tolerance scaled with the slope,
        // since a slow timer's leeway now costs four times the dB.
        let elapsed = 1.2
        let moved = later.rideDB - after.rideDB
        #expect(abs(moved - TransitionAutomation.rideReleaseCutDBPerSecond * elapsed) < 0.4,
                "the release slope must be ~1.2 dB/s (moved \(moved) in \(elapsed)s)")
        // The ride is a *fader* multiplier and nothing else.
        #expect(later.effectsAreNeutral, "the ride must not touch EQ, rate or delay (\(later))")
        #expect(abs(later.volume
                    - later.trim * LoudnessCompensation.gain(fromDB: later.rideDB)) < 0.002,
                "the deck's level must be exactly trim × ride (\(later))")
        #expect(later.isNeutral, "'fader open' now means trim × ride (\(later))")
    }

    /// A ride of 0 — every `.plain` hand-over, every AutoMix-off and iOS path —
    /// must leave the gain path exactly where it was before the ride existed.
    @Test func aZeroRideChangesNothing() throws {
        guard audioOutputAvailable else { return }
        let planned = PlannedTransition(
            plan: .crossfade(duration: 2.0, outPoint: 5.2, inPoint: 0), style: .plain)
        #expect(planned.rideDB == 0, "the memberwise default must be no ride")
        let result = withWatchdog("zeroRide", timeout: 45) {
            () -> [PlaybackEngine.DeckEffectSnapshot] in
            let engine = PlaybackEngine()
            let log = EventLog(engine)
            defer { engine.stopAll() }
            guard (try? engine.loadFile(at: Fixtures.eightSecondCAF, on: .a)) != nil,
                  (try? engine.loadFile(at: Fixtures.sixSecondCAF, on: .b)) != nil else { return [] }
            engine.outputVolume = 0
            engine.play(deck: .a, from: 4.7)
            engine.scheduleTransition(planned, from: .a, to: .b)
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if log.contains({
                    if case .transitionCompleted(from: .a, to: .b) = $0 { return true }
                    return false
                }) { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            Thread.sleep(forTimeInterval: 0.6)
            return [engine.effectSnapshot(of: .a), engine.effectSnapshot(of: .b)]
        }
        guard let snapshots = result, snapshots.count == 2 else { return }
        #expect(snapshots[0].isParked, "outgoing deck parked silent (\(snapshots[0]))")
        #expect(snapshots[1].rideDB == 0 && snapshots[1].rideTargetDB == 0,
                "no ride anywhere on the incoming deck (\(snapshots[1]))")
        #expect(abs(snapshots[1].volume - 1) < 0.001,
                "a fully open, untrimmed, un-ridden fader is literally 1 (\(snapshots[1]))")
        #expect(snapshots[1].isNeutral)
    }

    /// The ride release says so in the journal, at both ends — and says nothing
    /// at all when there is no ride.
    ///
    /// This class of defect was found *blind*: a release running at the wrong
    /// slope leaves no trace anywhere else, because it lives on a deck timer
    /// that outlives its transition and lands on a value indistinguishable from
    /// "there was never a ride". The pair of lines is the only record that it
    /// happened and how long it took, which makes the journal itself the thing
    /// under test here. The silence matters just as much: most hand-overs carry
    /// no ride, and a line per seam saying nothing happened would bury the ones
    /// that mean something.
    @Test func theRideReleaseIsJournalledAtBothEndsAndOnlyWhenItRuns() throws {
        guard audioOutputAvailable else { return }
        func runSeam(ride: Double, waitAfterComplete: TimeInterval) -> [String] {
            let captured = PlaybackJournal.tap.capture {
                _ = withWatchdog("rideJournal", timeout: 45) { () -> Bool in
                    let engine = PlaybackEngine()
                    let log = EventLog(engine)
                    defer { engine.stopAll() }
                    guard (try? engine.loadFile(at: Fixtures.eightSecondCAF, on: .a)) != nil,
                          (try? engine.loadFile(at: Fixtures.sixSecondCAF, on: .b)) != nil
                    else { return false }
                    engine.outputVolume = 0
                    engine.play(deck: .a, from: 4.7)
                    engine.scheduleTransition(
                        PlannedTransition(
                            plan: .crossfade(duration: 2.0, outPoint: 5.2, inPoint: 0),
                            style: .plain, rideDB: ride),
                        from: .a, to: .b)
                    let deadline = Date().addingTimeInterval(10)
                    while Date() < deadline {
                        if log.contains({
                            if case .transitionCompleted(from: .a, to: .b) = $0 { return true }
                            return false
                        }) { break }
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                    Thread.sleep(forTimeInterval: waitAfterComplete)
                    return true
                }
            }
            return captured.lines
        }

        // A −4 dB cut: one start line naming the slope and the duration, one
        // DONE line, and the arithmetic between them agrees with the constant.
        let ridden = runSeam(ride: -4, waitAfterComplete: 4.5)
        let starts = ridden.filter { $0.hasPrefix("ride release start") }
        let dones = ridden.filter { $0.hasPrefix("ride release DONE") }
        #expect(starts.count == 1, "exactly one start line (\(starts))")
        #expect(dones.count == 1, "exactly one DONE line (\(dones))")
        #expect(starts.first?.contains("from=-4.00dB") == true, "\(starts)")
        #expect(starts.first?.contains("slope=1.20dB/s") == true, "\(starts)")
        #expect(starts.first?.contains("over=3.33s") == true, "\(starts)")
        #expect(dones.first?.contains("slope=1.20dB/s") == true, "\(dones)")
        // The completion line carries the ride too, so one grep answers "what
        // was this seam holding when it handed over".
        #expect(ridden.contains { $0.hasPrefix("transition complete") && $0.contains("ride=") })

        // …and a seam with no ride writes neither line.
        let flat = runSeam(ride: 0, waitAfterComplete: 1.0)
        #expect(!flat.contains { $0.contains("ride release") },
                "a rideless seam must not journal a release (\(flat))")
        #expect(flat.contains { $0.hasPrefix("transition complete") },
                "…but the seam itself must still be journalled (\(flat))")
    }

    /// Pause, seek and a re-issued play all settle a running release to its
    /// target instead of leaving it drifting under a track the listener has
    /// just re-aimed. Every one of those moments is silent or muted, so the
    /// jump is inaudible — see `PlaybackEngine.settleRideLocked`.
    @Test func pauseAndSeekSettleTheRideImmediately() throws {
        guard audioOutputAvailable else { return }
        func runRide(interrupt: @escaping (PlaybackEngine) -> Void)
            -> PlaybackEngine.DeckEffectSnapshot? {
            withWatchdog("rideSettle", timeout: 45) {
                () -> PlaybackEngine.DeckEffectSnapshot? in
                let engine = PlaybackEngine()
                let log = EventLog(engine)
                defer { engine.stopAll() }
                guard (try? engine.loadFile(at: Fixtures.eightSecondCAF, on: .a)) != nil,
                      (try? engine.loadFile(at: Fixtures.sixSecondCAF, on: .b)) != nil
                else { return nil }
                engine.outputVolume = 0
                engine.play(deck: .a, from: 4.7)
                engine.scheduleTransition(
                    PlannedTransition(
                        plan: .crossfade(duration: 2.0, outPoint: 5.2, inPoint: 0),
                        style: .plain, rideDB: -4),
                    from: .a, to: .b)
                let deadline = Date().addingTimeInterval(10)
                while Date() < deadline {
                    if log.contains({
                        if case .transitionCompleted(from: .a, to: .b) = $0 { return true }
                        return false
                    }) { break }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                Thread.sleep(forTimeInterval: 0.4)
                interrupt(engine)
                Thread.sleep(forTimeInterval: 0.5)
                return engine.effectSnapshot(of: .b)
            } ?? nil
        }

        for (label, interrupt) in [
            ("pause", { (e: PlaybackEngine) in e.pause() }),
            ("seek", { (e: PlaybackEngine) in e.seek(deck: .b, to: 1.0) }),
            ("play", { (e: PlaybackEngine) in e.play(deck: .b, from: 1.0) }),
        ] {
            guard let s = runRide(interrupt: interrupt) else { continue }
            #expect(s.rideDB == 0,
                    "\(label) must settle the release to its target at once (\(s))")
            #expect(s.rideTargetDB == 0)
        }
    }

    // (h) Cancelling mid-overlap (seek / skip / disarm) must also leave both
    // decks neutral — the reset invariant, on the interrupted path.
    @Test func cancelDuringStyledOverlapResetsDecks() throws {
        guard audioOutputAvailable else { return }
        let planned = PlannedTransition(
            plan: .crossfade(duration: 3.0, outPoint: 5.2, inPoint: 0),
            style: TransitionStyle(outroEffect: .echoOut, stagedEQ: true))

        let result = withWatchdog("cancelStyled", timeout: 40) { () -> [PlaybackEngine.DeckEffectSnapshot] in
            let engine = PlaybackEngine()
            _ = EventLog(engine)
            defer { engine.stopAll() }
            guard (try? engine.loadFile(at: Fixtures.eightSecondCAF, on: .a)) != nil,
                  (try? engine.loadFile(at: Fixtures.sixSecondCAF, on: .b)) != nil else { return [] }
            engine.outputVolume = 0
            engine.play(deck: .a, from: 4.7)
            engine.scheduleTransition(planned, from: .a, to: .b)
            // Let the overlap get going (out point ~0.5s in), then cut it.
            Thread.sleep(forTimeInterval: 1.2)
            engine.cancelScheduledTransition()
            Thread.sleep(forTimeInterval: 0.3)
            return [engine.effectSnapshot(of: .a), engine.effectSnapshot(of: .b)]
        }
        guard let snapshots = result, snapshots.count == 2 else { return }
        // Volume is the one knob a cancel past the midpoint may leave ramped
        // on the outgoing deck only if it was reset — check the effects.
        for (deck, snapshot) in zip(["a", "b"], snapshots) {
            #expect(abs(snapshot.lowGain) < 0.001 && abs(snapshot.midGain) < 0.001
                    && abs(snapshot.highGain) < 0.001,
                    "cancel: deck \(deck) EQ must be neutral (\(snapshot))")
            #expect(snapshot.highPassBypassed, "cancel: deck \(deck) high-pass must be bypassed")
            #expect(abs(snapshot.delayWetDryMix) < 0.001 && abs(snapshot.delayFeedback) < 0.001,
                    "cancel: deck \(deck) delay must be dry (\(snapshot))")
            #expect(abs(snapshot.rate - 1) < 0.001, "cancel: deck \(deck) rate must be 1 (\(snapshot))")
        }
    }

    // (i) The outgoing deck must never come back up. Once a transition has
    // faded the outgoing track out, the deck's contribution to the mixer has
    // to stay down — the transition's own reset (fader back to 1, EQ back to
    // flat) must not re-amplify whatever is still in flight through the
    // chain, and nothing may resume feeding the stopped player.
    //
    // Measured on the deck's post-effect output (what actually reaches the
    // mixer), not on parameters, because the audible symptom lives entirely
    // in the signal: "the fade reached silence, then the volume jumped back
    // and the old track played on for a moment".
    @Test func outgoingDeckStaysSilentAfterTransition() throws {
        guard audioOutputAvailable else { return }

        struct Sample { var t: TimeInterval; var peak: Float }
        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private var samples: [Sample] = []
            let start = Date()
            func record(_ peak: Float) {
                lock.lock(); defer { lock.unlock() }
                samples.append(Sample(t: Date().timeIntervalSince(start), peak: peak))
            }
            func snapshot() -> [Sample] {
                lock.lock(); defer { lock.unlock() }
                return samples
            }
        }

        // Fixture amplitude is 0.25; the overlap runs 5.2 → 7.2 while deck A's
        // file has audio all the way to 8.0, so a full second of outgoing
        // material is still schedulable when the transition finishes.
        let cases: [(String, URL, PlannedTransition)] = [
            // Deck A mono → the chunk-converted (buffer-fed) source path, the
            // same shape a progressive stream uses; then once more stereo, on
            // the sample-accurate scheduleSegment path.
            ("fade", Fixtures.eightSecondCAF, PlannedTransition(
                plan: .crossfade(duration: 2.0, outPoint: 5.2, inPoint: 0),
                style: TransitionStyle(outroEffect: .fade, stagedEQ: true))),
            ("filterSweep", Fixtures.eightSecondCAF, PlannedTransition(
                plan: .crossfade(duration: 2.0, outPoint: 5.2, inPoint: 0),
                style: TransitionStyle(outroEffect: .filterSweep, stagedEQ: true))),
            // `.echoOut` is the interesting one: its tail is *supposed* to
            // keep ringing past the overlap, so the assertion below allows a
            // decaying tail — but not a jump back up.
            ("echoOut", Fixtures.eightSecondCAF, PlannedTransition(
                plan: .crossfade(duration: 2.0, outPoint: 5.2, inPoint: 0),
                style: TransitionStyle(outroEffect: .echoOut, stagedEQ: true))),
            ("fade/stereo-file", Fixtures.eightSecondStereoCAF, PlannedTransition(
                plan: .crossfade(duration: 2.0, outPoint: 5.2, inPoint: 0),
                style: TransitionStyle(outroEffect: .fade, stagedEQ: true))),
        ]

        for (name, deckAFixture, planned) in cases {
            let result = withWatchdog("outgoingSilence-\(name)", timeout: 45) { () -> ([Sample], TimeInterval) in
                let engine = PlaybackEngine()
                let log = EventLog(engine)
                defer { engine.setOutputMonitor(on: .a, nil); engine.stopAll() }
                guard (try? engine.loadFile(at: deckAFixture, on: .a)) != nil,
                      (try? engine.loadFile(at: Fixtures.sixSecondCAF, on: .b)) != nil else { return ([], -1) }
                engine.outputVolume = 0
                let recorder = Recorder()
                engine.setOutputMonitor(on: .a) { recorder.record($0) }
                engine.play(deck: .a, from: 4.7)
                engine.scheduleTransition(planned, from: .a, to: .b)

                // Timestamp the completion against the recorder's clock, at
                // 5 ms resolution, so "after the transition" is unambiguous.
                var completedAt: TimeInterval = -1
                let deadline = Date().addingTimeInterval(20)
                while Date() < deadline {
                    if log.contains({
                        if case .transitionCompleted(from: .a, to: .b) = $0 { return true }
                        return false
                    }) {
                        completedAt = Date().timeIntervalSince(recorder.start)
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.005)
                }
                // Keep listening well past the reset: the resurrection lasts
                // as long as the outgoing file had material left.
                Thread.sleep(forTimeInterval: 1.5)
                return (recorder.snapshot(), completedAt)
            }
            guard let (samples, completedAt) = result, !samples.isEmpty else {
                Issue.record("\(name): no audio was captured from deck A")
                continue
            }
            guard completedAt > 0 else {
                Issue.record("\(name): the transition never completed")
                continue
            }

            // Sanity: deck A really was sounding at full level early on.
            let nominal = samples.filter { $0.t < completedAt - 1.8 }.map(\.peak).max() ?? 0
            #expect(nominal > 0.05, "\(name): deck A should be sounding before the overlap (peak \(nominal))")

            // The level the style had already brought deck A down to, taken
            // over the last 150 ms before the reset. Everything after the
            // reset has to stay at or below it: the outgoing deck may keep
            // decaying (an `.echoOut` tail does), it may never come back up.
            let before = samples.filter { $0.t > completedAt - 0.15 && $0.t <= completedAt }
            let ceiling = max((before.map(\.peak).max() ?? 0) * 1.5, nominal * 0.02)
            // One render buffer of grace: the mixer smooths a gain change over
            // a few ms, so the very first buffer may still be crossing down.
            let after = samples.filter { $0.t > completedAt + 0.03 }
            let worst = after.max { $0.peak < $1.peak }
            let window = samples.filter { $0.t > completedAt - 2.2 && $0.t < completedAt + 0.6 }
            let timeline = stride(from: 0, to: window.count, by: max(window.count / 30, 1))
                .map { String(format: "%+.2f:%.3f", window[$0].t - completedAt, window[$0].peak) }
                .joined(separator: " ")
            print("outgoingSilence[\(name)]: nominal=\(nominal) ceiling=\(ceiling) " +
                  "worstAfter=\(worst?.peak ?? 0) at +\((worst?.t ?? 0) - completedAt)s | \(timeline)")
            let detail = "\(name): the outgoing deck was down to \(before.map(\.peak).max() ?? 0) " +
                "when the transition completed, then jumped back up to \(worst?.peak ?? 0) " +
                "(nominal \(nominal)) at +\((worst?.t ?? 0) - completedAt)s — the faded-out track " +
                "is audibly resurrected"
            #expect((worst?.peak ?? 0) <= ceiling, "\(detail)")
        }
    }

    // (j) A seek must never *trigger* a hand-over. The out point of an armed
    // plan sits in the last stretch of the track, so dropping the playhead
    // there — or past it — used to make the wait tick fire the overlap on its
    // very next pass: the reported "seek near the end and the next song starts
    // immediately".
    //
    // The rule the engine now enforces (resolvePlanLocked): a transition fires
    // only when the track *plays into* its out point; a plan whose out point
    // the playhead has already passed is degraded to something anchored at the
    // end of the track — a short tail crossfade when there is runway left,
    // `.gapless` when there is not — so the rest of the song still plays and
    // the queue still moves.
    @Test func seekIntoTransitionWindowFallsBackInsteadOfFiring() throws {
        guard audioOutputAvailable else { return }

        struct Case {
            let name: String
            /// Where deck A starts, and where the user then drags to.
            let playFrom: TimeInterval
            let seekTo: TimeInterval
            let plan: TransitionPlan
            /// How long after the seek nothing may fire.
            let quiet: TimeInterval
            /// Re-arm the way PlayerService.seek does (disarm → seek → arm)
            /// instead of leaving the armed plan for the engine to revalidate.
            let rearm: Bool
        }

        // Deck A is the 8 s stereo fixture (sample-accurate `.file` path).
        let cases = [
            // Seek past the out point with only 2.5 s of track left: no room
            // for a fallback overlap → gapless at the end of the file.
            Case(name: "seek past out point → gapless tail",
                 playFrom: 3.0, seekTo: 5.5,
                 plan: .crossfade(duration: 2.0, outPoint: 5.2, inPoint: 0),
                 quiet: 1.5, rearm: false),
            // Same, but re-armed by the caller after the seek (the path
            // PlayerService takes) — the guard must hold at arm time too.
            Case(name: "re-armed after seek → gapless tail",
                 playFrom: 3.0, seekTo: 5.5,
                 plan: .crossfade(duration: 2.0, outPoint: 5.2, inPoint: 0),
                 quiet: 1.5, rearm: true),
            // Seek past an early out point with 5.5 s left: enough runway, so
            // the plan is re-anchored to a 2 s crossfade at 6.0 → 8.0.
            Case(name: "seek past out point → tail crossfade",
                 playFrom: 0.5, seekTo: 2.5,
                 plan: .crossfade(duration: 2.0, outPoint: 2.0, inPoint: 0),
                 quiet: 2.5, rearm: false),
        ]

        for testCase in cases {
            struct Outcome {
                var firedEarly = false
                var aPosAfterQuiet = TimeInterval(-1)
                var bPosAfterQuiet = TimeInterval(-1)
                var completed = false
            }
            let result = withWatchdog("seekFallback-\(testCase.name)", timeout: 40) { () -> Outcome in
                var o = Outcome()
                let engine = PlaybackEngine()
                let log = EventLog(engine)
                defer { engine.stopAll() }
                guard (try? engine.loadFile(at: Fixtures.eightSecondStereoCAF, on: .a)) != nil,
                      (try? engine.loadFile(at: Fixtures.sixSecondStereoCAF, on: .b)) != nil else { return o }
                engine.outputVolume = 0
                engine.play(deck: .a, from: testCase.playFrom)
                engine.scheduleTransition(.plain(testCase.plan), from: .a, to: .b)
                _ = pollPosition(engine, deck: .a, past: testCase.playFrom + 0.2, timeout: 3)

                if testCase.rearm { engine.cancelScheduledTransition() }
                engine.seek(deck: .a, to: testCase.seekTo)
                if testCase.rearm {
                    engine.scheduleTransition(.plain(testCase.plan), from: .a, to: .b)
                }

                Thread.sleep(forTimeInterval: testCase.quiet)
                o.firedEarly = log.contains {
                    switch $0 {
                    case .transitionMidpoint(from: .a, to: .b, via: _),
                         .transitionCompleted(from: .a, to: .b): return true
                    default: return false
                    }
                }
                o.aPosAfterQuiet = engine.position(of: .a)
                o.bPosAfterQuiet = engine.position(of: .b)
                // The fallback still has to hand over at the end of the track.
                o.completed = log.wait(timeout: 8) {
                    if case .transitionCompleted(from: .a, to: .b) = $0 { return true }
                    return false
                }
                return o
            }
            guard let o = result else { continue }
            let firedDetail = "\(testCase.name): seeking to \(testCase.seekTo) " +
                "(out point \(testCase.plan.outPoint ?? -1)) must not start the hand-over — " +
                "the transition belongs to the natural end of the track"
            #expect(!o.firedEarly, "\(firedDetail)")
            let expected = testCase.seekTo + testCase.quiet
            #expect(abs(o.aPosAfterQuiet - expected) < 0.5,
                    "\(testCase.name): deck A should just keep playing (expected ≈\(expected), got \(o.aPosAfterQuiet))")
            #expect(o.bPosAfterQuiet < 0.2,
                    "\(testCase.name): deck B must still be idle (got \(o.bPosAfterQuiet))")
            #expect(o.completed,
                    "\(testCase.name): the degraded plan must still hand over at the end of the track")
        }
    }

    // (k) A manual seek must not leak the position it seeked away from.
    // `player.stop()` empties the schedule, not the chain: timePitch/EQ/delay
    // still hold ~200 ms of already-rendered audio, and they used to push it
    // out at full level right after the user dropped the playhead somewhere
    // else. Same failure mode as the post-transition resurrection in (i), and
    // measured the same way: on the deck's post-effect output, folding in the
    // fader (which sits at the mixer input, downstream of everything).
    //
    // The fixture is loud for 4 s then digitally silent, and the seek goes
    // from the loud half into the silent half — so ANY level after the seek is
    // audio from the old position.
    @Test func seekDoesNotLeakTheOldPosition() throws {
        guard audioOutputAvailable else { return }

        struct Sample { var t: TimeInterval; var peak: Float }
        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private var samples: [Sample] = []
            let start = Date()
            func record(_ peak: Float) {
                lock.lock(); defer { lock.unlock() }
                samples.append(Sample(t: Date().timeIntervalSince(start), peak: peak))
            }
            func snapshot() -> [Sample] {
                lock.lock(); defer { lock.unlock() }
                return samples
            }
        }

        // Mono → chunk-converted (buffer-fed) source, where the residue is
        // biggest; stereo → the sample-accurate scheduleSegment path.
        for (name, fixture) in [("converted", Fixtures.loudThenSilentCAF),
                                ("stereo-file", Fixtures.loudThenSilentStereoCAF)] {
            let result = withWatchdog("seekResidue-\(name)", timeout: 40) {
                () -> ([Sample], TimeInterval, TimeInterval, Float) in
                let engine = PlaybackEngine()
                _ = EventLog(engine)
                defer { engine.setOutputMonitor(on: .a, nil); engine.stopAll() }
                guard (try? engine.loadFile(at: fixture, on: .a)) != nil else { return ([], -1, -1, -1) }
                engine.outputVolume = 0
                let recorder = Recorder()
                engine.setOutputMonitor(on: .a) { recorder.record($0) }
                engine.play(deck: .a, from: 0)
                // Sounding at full level well inside the loud half.
                _ = pollPosition(engine, deck: .a, past: 1.0, timeout: 5)

                let seekAt = Date().timeIntervalSince(recorder.start)
                engine.seek(deck: .a, to: 5.0)
                Thread.sleep(forTimeInterval: 1.2)
                // The fader has to come back on its own, or "no leak" would be
                // trivially satisfied by a deck that never sounds again.
                let volume = engine.effectSnapshot(of: .a).volume
                let position = engine.position(of: .a)
                return (recorder.snapshot(), seekAt, position, volume)
            }
            guard let (samples, seekAt, position, volume) = result, !samples.isEmpty else {
                Issue.record("\(name): no audio was captured from deck A")
                continue
            }

            let nominal = samples.filter { $0.t < seekAt }.map(\.peak).max() ?? 0
            #expect(nominal > 0.05, "\(name): deck A should be sounding before the seek (peak \(nominal))")

            // One render buffer of grace: the seek is an async hop onto the
            // engine queue and the mixer smooths a gain change over a few ms.
            let after = samples.filter { $0.t > seekAt + 0.05 }
            let worst = after.max { $0.peak < $1.peak }
            let window = samples.filter { $0.t > seekAt - 0.3 && $0.t < seekAt + 0.8 }
            let timeline = stride(from: 0, to: window.count, by: max(window.count / 30, 1))
                .map { String(format: "%+.2f:%.3f", window[$0].t - seekAt, window[$0].peak) }
                .joined(separator: " ")
            print("seekResidue[\(name)]: nominal=\(nominal) worstAfter=\(worst?.peak ?? 0) " +
                  "at +\((worst?.t ?? 0) - seekAt)s | \(timeline)")
            let leakDetail = "\(name): after seeking from the loud half to the silent half the deck " +
                "still put out \(worst?.peak ?? 0) (nominal \(nominal)) at " +
                "+\((worst?.t ?? 0) - seekAt)s — that is the pre-seek position draining out of the chain"
            #expect((worst?.peak ?? 0) <= nominal * 0.1, "\(leakDetail)")
            #expect(abs(volume - 1) < 0.001,
                    "\(name): the fader must be handed back after the flush window (got \(volume))")
            #expect(position > 5.5, "\(name): playback must continue from the seek target (got \(position))")
        }
    }

    // (l) Whatever ends a transition, the deck that is left carrying the track
    // must be *in service*: chain fully transparent and fader open. A deck is
    // reused as-is — `play(deck:from:)` does not rebuild it — so a band left
    // ducked keeps ducking for the whole next song: the reported "everything
    // sounds muffled / like it is under water" (a -24 dB high shelf is exactly
    // that). The incoming deck is the risky one, because `beginOverlapLocked`
    // primes it with the full three-band cut and only the ramps release it.
    @Test func liveDeckIsNeutralAfterEveryTransitionExit() throws {
        guard audioOutputAvailable else { return }

        let stagedCrossfade = PlannedTransition(
            plan: .crossfade(duration: 2.5, outPoint: 5.2, inPoint: 0),
            style: TransitionStyle(outroEffect: .fade, stagedEQ: true))
        let echoBeatMatched = PlannedTransition(
            plan: .beatMatched(BeatMatchedPlan(
                outPoint: 5.2, inPoint: 0, overlapBars: 2,
                outgoingRate: 0.99, incomingRate: 1.03,
                bassSwapOffset: 1.2, overlapDuration: 2.4)),
            style: TransitionStyle(outroEffect: .echoOut, stagedEQ: true))

        /// What the test does once the overlap is under way, and which deck is
        /// carrying the track afterwards.
        enum Interruption { case none, cancelAfterMidpoint, cancelWhileSettling, pauseThenCancel }

        struct Case {
            let name: String
            let planned: PlannedTransition
            let interruption: Interruption
            /// Load the incoming deck at all? Not loading it is the contract
            /// violation the engine has to bail out of *cleanly*.
            let loadIncoming: Bool
            /// The deck that owns the track once the dust settles.
            let live: Deck
        }

        let cases = [
            Case(name: "normal completion", planned: stagedCrossfade,
                 interruption: .none, loadIncoming: true, live: .b),
            Case(name: "cancel after midpoint", planned: stagedCrossfade,
                 interruption: .cancelAfterMidpoint, loadIncoming: true, live: .b),
            Case(name: "cancel while settling", planned: echoBeatMatched,
                 interruption: .cancelWhileSettling, loadIncoming: true, live: .b),
            Case(name: "pause mid-overlap then cancel", planned: stagedCrossfade,
                 interruption: .pauseThenCancel, loadIncoming: true, live: .b),
            // The incoming deck was never loaded: the engine drops the plan —
            // and must not leave the deck primed with the staged cut, because
            // the next track will be played on it as-is.
            Case(name: "incoming deck not loaded", planned: stagedCrossfade,
                 interruption: .none, loadIncoming: false, live: .b),
        ]

        for testCase in cases {
            let result = withWatchdog("liveDeckNeutral-\(testCase.name)", timeout: 45) {
                () -> PlaybackEngine.DeckEffectSnapshot? in
                let engine = PlaybackEngine()
                let log = EventLog(engine)
                defer { engine.stopAll() }
                guard (try? engine.loadFile(at: Fixtures.eightSecondCAF, on: .a)) != nil else { return nil }
                if testCase.loadIncoming {
                    guard (try? engine.loadFile(at: Fixtures.sixSecondCAF, on: .b)) != nil else { return nil }
                }
                engine.outputVolume = 0
                engine.play(deck: .a, from: 4.7)
                engine.scheduleTransition(testCase.planned, from: .a, to: .b)

                func waitForMidpoint() -> Bool {
                    log.wait(timeout: 12) {
                        if case .transitionMidpoint(from: .a, to: .b, via: _) = $0 { return true }
                        return false
                    }
                }
                switch testCase.interruption {
                case .none:
                    // Let it run to completion and settle out on its own.
                    _ = log.wait(timeout: 15) {
                        if case .transitionCompleted(from: .a, to: .b) = $0 { return true }
                        return false
                    }
                    let deadline = Date().addingTimeInterval(6)
                    while Date() < deadline, engine.hasPendingTransition {
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                case .cancelAfterMidpoint:
                    // Past the midpoint the incoming deck IS the current track;
                    // a skip/seek here must hand it over neutral, not muffled.
                    _ = waitForMidpoint()
                    engine.cancelScheduledTransition()
                case .cancelWhileSettling:
                    _ = log.wait(timeout: 15) {
                        if case .transitionCompleted(from: .a, to: .b) = $0 { return true }
                        return false
                    }
                    Thread.sleep(forTimeInterval: 0.3) // inside the settle phase
                    engine.cancelScheduledTransition()
                case .pauseThenCancel:
                    _ = waitForMidpoint()
                    engine.pause()
                    Thread.sleep(forTimeInterval: 0.4)
                    engine.cancelScheduledTransition()
                    engine.resume()
                }
                Thread.sleep(forTimeInterval: 0.5)
                if !testCase.loadIncoming {
                    // Nothing handed the deck over, so nothing raised its
                    // fader either — judge the chain only (see below).
                    return engine.effectSnapshot(of: testCase.live)
                }
                return engine.effectSnapshot(of: testCase.live)
            }
            guard let snapshot = result ?? nil else { continue }
            let detail = "\(testCase.name): the deck left carrying the track has a filter still " +
                "engaged — it will colour the whole next song (\(snapshot))"
            #expect(snapshot.effectsAreNeutral, "\(detail)")
            if testCase.loadIncoming {
                #expect(abs(snapshot.volume - 1) < 0.001,
                        "\(testCase.name): the live deck's fader must be open (\(snapshot))")
            }
        }
    }

    // MARK: - Tempo ramp

    /// A plan carrying a pre-seam tempo glide, end to end on a real graph: the
    /// outgoing deck sits at unity before the ramp window, drifts across it,
    /// arrives fully bent, and the incoming deck is let back to unity
    /// afterwards over the plan's own release rather than the legacy 1.5 s.
    ///
    /// The bend here (−10 %) is far past anything the planner would ask for —
    /// the point is a signal the sampler cannot mistake for jitter, not a
    /// realistic seam.
    @Test func aTempoRampedTransitionGlidesInAndCompletes() throws {
        guard audioOutputAvailable else { return }
        struct Outcome {
            var beforeRamp: Float?
            var midRamp: Float?
            var atSeam: Float?
            var releasing: Float?
            var completed = false
            var deckB: PlaybackEngine.DeckEffectSnapshot?
        }
        // Ramp window is [outPoint − handoff − lead, outPoint − handoff]
        // = [2.7, 4.7] on the outgoing track's own clock.
        let plan = TransitionPlan.beatMatched(BeatMatchedPlan(
            outPoint: 5.2, inPoint: 0, overlapBars: 2,
            outgoingRate: 0.90, incomingRate: 1.05,
            bassSwapOffset: 1.0, overlapDuration: 2.0,
            rampLeadSeconds: 2, rampReleaseSeconds: 2))

        let result = withWatchdog("tempoRamp", timeout: 45) { () -> Outcome in
            var o = Outcome()
            let engine = PlaybackEngine()
            let log = EventLog(engine)
            defer { engine.stopAll() }
            guard (try? engine.loadFile(at: Fixtures.eightSecondCAF, on: .a)) != nil,
                  (try? engine.loadFile(at: Fixtures.sixSecondCAF, on: .b)) != nil else { return o }
            engine.outputVolume = 0
            engine.play(deck: .a, from: 2.0)
            engine.scheduleTransition(.plain(plan), from: .a, to: .b)

            // Still short of the ramp window (position ≈ 2.3).
            Thread.sleep(forTimeInterval: 0.3)
            o.beforeRamp = engine.effectSnapshot(of: .a).rate
            // Inside it (position ≈ 3.2, a quarter of the way across).
            Thread.sleep(forTimeInterval: 0.9)
            o.midRamp = engine.effectSnapshot(of: .a).rate
            // Past its end (position ≈ 4.9), fully bent and holding.
            _ = pollPosition(engine, deck: .a, past: 4.85, timeout: 6)
            o.atSeam = engine.effectSnapshot(of: .a).rate

            o.completed = log.wait(timeout: 15) {
                if case .transitionCompleted(from: .a, to: .b) = $0 { return true }
                return false
            }
            // Half a second into a 2 s release: on its way back, not home.
            Thread.sleep(forTimeInterval: 0.5)
            o.releasing = engine.effectSnapshot(of: .b).rate
            let deadline = Date().addingTimeInterval(6)
            while Date() < deadline, engine.hasPendingTransition {
                Thread.sleep(forTimeInterval: 0.05)
            }
            o.deckB = engine.effectSnapshot(of: .b)
            return o
        }
        guard let o = result, let before = o.beforeRamp, let mid = o.midRamp,
              let seam = o.atSeam, let releasing = o.releasing else { return }

        #expect(abs(before - 1) < 0.001,
                "the deck must sit at unity until the ramp window opens (\(before))")
        #expect(mid < 0.999 && mid > 0.9001,
                "the deck must be part-way onto its bent rate mid-glide (\(mid))")
        #expect(mid < before, "the glide must have moved (\(before) → \(mid))")
        #expect(abs(seam - 0.90) < 0.002,
                "the glide must have landed before the out point (\(seam))")
        #expect(o.completed, "a ramped transition must still complete")
        #expect(releasing > 1.001 && releasing < 1.05,
                "the incoming rate must be part-way home on a 2 s release (\(releasing))")
        if let deckB = o.deckB {
            #expect(deckB.effectsAreNeutral,
                    "the release must finish and leave the deck neutral (\(deckB))")
        }
    }

    /// The glide is the only thing a *waiting* transition writes to a deck, so
    /// it is the only thing the drop paths have to take back. A seek and a
    /// cancel, both mid-glide, both leaving the deck at unity: anything less
    /// and the user's own playback is left detuned by a hand-over that never
    /// happened.
    @Test func seekingOrCancellingDuringTheTempoRampPutsTheRateBack() throws {
        guard audioOutputAvailable else { return }
        struct Outcome {
            var midRamp: Float?
            var afterSeek: Float?
            var midRampAgain: Float?
            var afterCancel: Float?
        }
        let plan = TransitionPlan.beatMatched(BeatMatchedPlan(
            outPoint: 5.2, inPoint: 0, overlapBars: 2,
            outgoingRate: 0.90, incomingRate: 1.05,
            bassSwapOffset: 1.0, overlapDuration: 2.0,
            rampLeadSeconds: 2, rampReleaseSeconds: 2))

        let result = withWatchdog("tempoRampRevert", timeout: 45) { () -> Outcome in
            var o = Outcome()
            let engine = PlaybackEngine()
            defer { engine.stopAll() }
            guard (try? engine.loadFile(at: Fixtures.eightSecondCAF, on: .a)) != nil,
                  (try? engine.loadFile(at: Fixtures.sixSecondCAF, on: .b)) != nil else { return o }
            engine.outputVolume = 0

            engine.play(deck: .a, from: 2.0)
            engine.scheduleTransition(.plain(plan), from: .a, to: .b)
            Thread.sleep(forTimeInterval: 1.2)
            o.midRamp = engine.effectSnapshot(of: .a).rate
            // Back to the top of the track: nowhere near the ramp window, so
            // the deck must be plainly at unity again.
            engine.seek(deck: .a, to: 0.2)
            Thread.sleep(forTimeInterval: 0.4)
            o.afterSeek = engine.effectSnapshot(of: .a).rate

            // Same again, ended with a cancel instead.
            engine.play(deck: .a, from: 2.0)
            engine.scheduleTransition(.plain(plan), from: .a, to: .b)
            Thread.sleep(forTimeInterval: 1.2)
            o.midRampAgain = engine.effectSnapshot(of: .a).rate
            engine.cancelScheduledTransition()
            Thread.sleep(forTimeInterval: 0.3)
            o.afterCancel = engine.effectSnapshot(of: .a).rate
            return o
        }
        guard let o = result, let mid = o.midRamp, let afterSeek = o.afterSeek,
              let midAgain = o.midRampAgain, let afterCancel = o.afterCancel else { return }

        #expect(mid < 0.999, "the glide must have been running before the seek (\(mid))")
        #expect(abs(afterSeek - 1) < 0.001,
                "a seek out of the ramp window must hand the rate back (\(afterSeek))")
        #expect(midAgain < 0.999,
                "the glide must have been running before the cancel (\(midAgain))")
        #expect(abs(afterCancel - 1) < 0.001,
                "a cancelled hand-over must not leave the deck detuned (\(afterCancel))")
    }

    /// **A bent deck must always have something scheduled to un-bend it.**
    ///
    /// A time-pitch unit off unity is not a subtle colour: it is the phasey,
    /// watery artifact a listener describes as the music being underwater, and
    /// unlike a stuck fader or a ducked EQ band it never resolves on its own.
    /// So the rule is stronger than "the happy path restores it" — *every*
    /// teardown order has to, in any order, at any moment, including the ones
    /// that tear the transition down while its release glide is still running.
    ///
    /// Each case interrupts the hand-over somewhere different and then asks the
    /// same question of whichever deck is left carrying the music.
    @Test func everyTeardownOrderHandsTheRateBack() throws {
        guard audioOutputAvailable else { return }
        enum Interruption: String {
            /// The undisturbed path: just wait the release out.
            case none
            /// What `PlayerService` really does — `.transitionCompleted`
            /// arrives, the next hand-over is armed, and the release for the
            /// last one is still running.
            case armNextImmediately
            /// The prefetcher loads the next track onto the spent deck while
            /// the release runs.
            case loadOntoSpentDeck
            /// The user drags the playhead moments after the seam.
            case seekAfterSeam
            /// …or pauses in the middle of the release.
            case pauseThenResume
            /// The transition is dropped outright mid-release.
            case cancelMidRelease
        }
        // A long release and a big bend, so a deck left bent is unmistakable.
        let plan = TransitionPlan.beatMatched(BeatMatchedPlan(
            outPoint: 5.2, inPoint: 0, overlapBars: 2,
            outgoingRate: 0.95, incomingRate: 1.06,
            bassSwapOffset: 1.0, overlapDuration: 2.0,
            rampLeadSeconds: 2, rampReleaseSeconds: 6))

        for interruption in [Interruption.none, .armNextImmediately, .loadOntoSpentDeck,
                             .seekAfterSeam, .pauseThenResume, .cancelMidRelease] {
            let result = withWatchdog("rateHandBack-\(interruption.rawValue)", timeout: 60) {
                () -> PlaybackEngine.DeckEffectSnapshot? in
                let engine = PlaybackEngine()
                let log = EventLog(engine)
                defer { engine.stopAll() }
                // Loaded as 0 dBFS-peak masters, so both decks really do owe a
                // bent-rate headroom pad and "was it handed back" is a
                // question with teeth.
                guard (try? engine.loadFile(at: Fixtures.eightSecondCAF, on: .a,
                                            peakDBFS: 0)) != nil,
                      (try? engine.loadFile(at: Fixtures.sixSecondCAF, on: .b,
                                            peakDBFS: 0)) != nil
                else { return nil }
                engine.outputVolume = 0
                engine.play(deck: .a, from: 2.6)
                engine.scheduleTransition(.plain(plan), from: .a, to: .b)
                _ = log.wait(timeout: 20) {
                    if case .transitionCompleted(from: .a, to: .b) = $0 { return true }
                    return false
                }
                // Deck B is the music now, and is bent at 1.06 with a 6 s
                // release running. Interrupt it a second in.
                Thread.sleep(forTimeInterval: 1.0)
                switch interruption {
                case .none:
                    break
                case .armNextImmediately:
                    engine.scheduleTransition(
                        .plain(.crossfade(duration: 2, outPoint: 4.5, inPoint: 0)),
                        from: .b, to: .a)
                case .loadOntoSpentDeck:
                    _ = try? engine.loadFile(at: Fixtures.eightSecondCAF, on: .a)
                case .seekAfterSeam:
                    engine.seek(deck: .b, to: 0.5)
                case .pauseThenResume:
                    engine.pause()
                    Thread.sleep(forTimeInterval: 0.8)
                    engine.resume()
                case .cancelMidRelease:
                    engine.cancelScheduledTransition()
                }
                // Well past the 6 s release, whatever happened to it. Waiting
                // on the transition clearing rather than on the rate looking
                // close enough to 1: the settle only hands back the pad once
                // it declares the restore *done*, and a rate of 1.0006 is
                // within any sane tolerance while still being mid-glide.
                let deadline = Date().addingTimeInterval(12)
                while Date() < deadline, engine.hasPendingTransition {
                    Thread.sleep(forTimeInterval: 0.1)
                }
                return engine.effectSnapshot(of: .b)
            }
            guard let snapshot = result ?? nil else { continue }
            let detuned = "\(interruption.rawValue): the deck carrying the music is still "
                + "detuned — it will sound underwater until the track ends (\(snapshot))"
            let coloured = "\(interruption.rawValue): the live deck's chain must be "
                + "transparent once the hand-over is done with it (\(snapshot))"
            let padded = "\(interruption.rawValue): the bent-rate headroom pad outlived "
                + "the bend — the rest of the song plays quiet (\(snapshot))"
            #expect(abs(snapshot.rate - 1) < 0.001, "\(detuned)")
            #expect(snapshot.effectsAreNeutral, "\(coloured)")
            // The pad is a gain, so `effectsAreNeutral` cannot see it: it has
            // to be asserted separately, and on the same six teardown orders —
            // a deck left padded is a deck playing the rest of its song a few
            // dB down, which is quieter to notice and no easier to explain.
            // Asserted on the *target*, like the ride's release: what must be
            // true is that it has been let go of, not that a 0.3 dB/s glide has
            // already finished.
            #expect(abs(snapshot.ratePadTargetDB) < 0.001, "\(padded)")
            #expect(snapshot.ratePadDB <= 0.001, "the pad is only ever a cut (\(snapshot))")
        }
    }

    /// The bent-rate headroom pad, on a real graph: it goes on *before* the
    /// deck's rate leaves unity, holds while bent, and is gone once the rate is
    /// home — and a deck with headroom to spare never sees it at all.
    ///
    /// The pad exists because `AVAudioUnitTimePitch` at a non-unity rate can
    /// push a signal several dB above its own input peak, which on a 0 dBFS
    /// master clips; the tempo ramp made that much worse by holding the
    /// outgoing deck bent at full fader for the whole glide.
    @Test func theHeadroomPadRidesInAheadOfTheBendAndLeavesWithIt() throws {
        guard audioOutputAvailable else { return }
        struct Outcome {
            var beforePad: Double?
            var padded: Double?
            var atFullBend: (pad: Double, rate: Float)?
            var afterRelease: Double?
            var quietMasterPad: Double?
        }
        // Ramp window [2.7, 4.7]; a 0 dBFS master on no trim owes 6.5 dB, so
        // the pad's own lead-in is ~21.7 s — far longer than this fixture — and
        // it engages from the moment the plan is armed.
        let plan = TransitionPlan.beatMatched(BeatMatchedPlan(
            outPoint: 5.2, inPoint: 0, overlapBars: 2,
            outgoingRate: 0.90, incomingRate: 1.05,
            bassSwapOffset: 1.0, overlapDuration: 2.0,
            rampLeadSeconds: 2, rampReleaseSeconds: 2))

        let result = withWatchdog("headroomPad", timeout: 45) { () -> Outcome in
            var o = Outcome()
            let engine = PlaybackEngine()
            let log = EventLog(engine)
            defer { engine.stopAll() }
            guard (try? engine.loadFile(at: Fixtures.eightSecondCAF, on: .a,
                                        peakDBFS: 0)) != nil,
                  (try? engine.loadFile(at: Fixtures.sixSecondCAF, on: .b,
                                        peakDBFS: 0)) != nil else { return o }
            engine.outputVolume = 0
            engine.play(deck: .a, from: 0.2)
            o.beforePad = engine.effectSnapshot(of: .a).ratePadDB
            engine.scheduleTransition(.plain(plan), from: .a, to: .b)

            // Inside the pad's lead-in but before the bend: padding, unbent.
            Thread.sleep(forTimeInterval: 0.6)
            let early = engine.effectSnapshot(of: .a)
            o.padded = early.ratePadDB
            // At full bend, the pad must be at full value.
            _ = pollPosition(engine, deck: .a, past: 4.85, timeout: 8)
            let bent = engine.effectSnapshot(of: .a)
            o.atFullBend = (bent.ratePadDB, bent.rate)

            _ = log.wait(timeout: 15) {
                if case .transitionCompleted(from: .a, to: .b) = $0 { return true }
                return false
            }
            let deadline = Date().addingTimeInterval(9)
            while Date() < deadline, engine.hasPendingTransition {
                Thread.sleep(forTimeInterval: 0.05)
            }
            o.afterRelease = engine.effectSnapshot(of: .b).ratePadTargetDB

            // A quiet master, same everything else: never padded.
            let quiet = PlaybackEngine()
            defer { quiet.stopAll() }
            guard (try? quiet.loadFile(at: Fixtures.eightSecondCAF, on: .a,
                                       peakDBFS: -20)) != nil,
                  (try? quiet.loadFile(at: Fixtures.sixSecondCAF, on: .b,
                                       peakDBFS: -20)) != nil else { return o }
            quiet.outputVolume = 0
            quiet.play(deck: .a, from: 2.0)
            quiet.scheduleTransition(.plain(plan), from: .a, to: .b)
            Thread.sleep(forTimeInterval: 1.2)
            o.quietMasterPad = quiet.effectSnapshot(of: .a).ratePadDB
            return o
        }
        guard let o = result, let before = o.beforePad, let padded = o.padded,
              let full = o.atFullBend, let after = o.afterRelease,
              let quiet = o.quietMasterPad else { return }

        #expect(before == 0, "an unbent deck starts unpadded (\(before))")
        #expect(padded < -0.05, "the pad must lead the bend, not follow it (\(padded))")
        #expect(full.pad < -0.05 && abs(full.rate - 0.90) < 0.002,
                "fully bent, so fully padded (pad \(full.pad), rate \(full.rate))")
        #expect(full.pad <= padded + 1e-6, "the pad only deepens as the bend approaches")
        #expect(abs(after) < 0.001,
                "the pad must be let go of once the rate is home (\(after))")
        #expect(quiet == 0,
                "a master with headroom to spare must never be padded (\(quiet))")
    }

    /// The contract-violation exit from `beginOverlapLocked`: the incoming deck
    /// turns out not to be loaded, so the plan is dropped at the out point.
    ///
    /// The comment above that exit already tells this story once — a dropped
    /// plan used to strand the *incoming* deck at −24 dB because nothing but
    /// the ramps that never ran would have released it. The tempo glide put the
    /// *outgoing* deck in exactly the same position, and this pins it: the deck
    /// still playing the song must come back to unity.
    @Test func aDroppedPlanUnbendsTheDeckItWasAlreadyGliding() throws {
        guard audioOutputAvailable else { return }
        let plan = TransitionPlan.beatMatched(BeatMatchedPlan(
            outPoint: 5.2, inPoint: 0, overlapBars: 2,
            outgoingRate: 0.90, incomingRate: 1.05,
            bassSwapOffset: 1.0, overlapDuration: 2.0,
            rampLeadSeconds: 2, rampReleaseSeconds: 2))
        struct Outcome {
            var midRamp: Float?
            var afterOutPoint: Float?
        }
        let result = withWatchdog("droppedPlanUnbends", timeout: 45) { () -> Outcome in
            var o = Outcome()
            let engine = PlaybackEngine()
            defer { engine.stopAll() }
            // Deck B is deliberately never loaded: the plan cannot be honoured.
            guard (try? engine.loadFile(at: Fixtures.eightSecondCAF, on: .a)) != nil
            else { return o }
            engine.outputVolume = 0
            engine.play(deck: .a, from: 2.6)
            engine.scheduleTransition(.plain(plan), from: .a, to: .b)
            Thread.sleep(forTimeInterval: 1.2)
            o.midRamp = engine.effectSnapshot(of: .a).rate
            // Play past the out point, where the plan is dropped.
            _ = pollPosition(engine, deck: .a, past: 5.6, timeout: 8)
            Thread.sleep(forTimeInterval: 0.5)
            o.afterOutPoint = engine.effectSnapshot(of: .a).rate
            return o
        }
        guard let o = result, let mid = o.midRamp, let after = o.afterOutPoint else { return }
        #expect(mid < 0.999, "the glide must have been running (\(mid))")
        let stranded = "a plan dropped at the out point must un-bend the deck that is "
            + "still playing — nothing else ever will (\(after))"
        #expect(abs(after - 1) < 0.001, "\(stranded)")
    }

    /// **A deck coming out of `resetDeckLocked` owes nothing to the hand-over
    /// that just spent it.**
    ///
    /// Every test above this one asks its question of a *single* seam, and of
    /// the deck that seam handed the music to. The field report that produced
    /// this one could not be reproduced that way, because its signature only
    /// appears from the second seam onwards: track 1 fine, track 2 wrong,
    /// track 3 fine, track 4 wrong — alternating, because tracks alternate
    /// between the decks and exactly one deck was carrying stale state.
    ///
    /// So this chains three seams the way `PlayerService` really drives them —
    /// seam, then the next track loaded onto the deck the seam just spent —
    /// and after each one polls **both** decks for a second and a half of real
    /// playback. The poll is the point: a check taken the instant after a
    /// `loadFile` passes even on the broken tree, because `resetDeckLocked`
    /// genuinely does write every knob back. What it does not do is stop a
    /// glide target the *previous* hand-over left on the deck from being
    /// picked up again by the 20 Hz glide timer the moment the deck has a
    /// source to write a fader for. That is a re-application, not a survival,
    /// and only a poll across the following seconds can see it.
    @Test func aChainOfSeamsLeavesEveryReusedDeckClean() throws {
        guard audioOutputAvailable else { return }
        /// The worst thing seen on one deck across one mid-track poll.
        ///
        /// The pad is judged by how much *deeper* it got, not by its absolute
        /// value: a deck that was legitimately padded for the seam it has just
        /// won is supposed to still be a few dB down here, because the release
        /// is a deliberately inaudible 0.3 dB/s walk that outlives the
        /// transition on the deck's own timer. What no deck may do mid-track is
        /// get *further* down than it already was — that is a pad being
        /// acquired, and nothing on this timeline is bent.
        struct Worst: CustomStringConvertible {
            var rateDeviation: Float = 0
            var firstPadDB: Double?
            var padDB: Double = 0
            var padDeepenedBy: Double = 0
            var padTargetDB: Double = 0
            var volume: Float = 0
            var description: String {
                "rate 1±\(rateDeviation), pad \(padDB) dB → \(padTargetDB) dB "
                    + "(deepened \(padDeepenedBy) dB), volume \(volume)"
            }
        }
        // Labelled by which seam has just finished and which deck was polled.
        typealias Observation = (label: String, deck: Deck, worst: Worst)

        /// When the prefetcher gets to the deck the seam just spent. Both
        /// orders happen in the field — the release runs for tens of seconds,
        /// so whether the next `loadFile` lands inside it is a race between the
        /// glide and the library.
        enum Reuse: String, CaseIterable {
            /// The release finished first; the deck was parked and idle.
            case afterRelease
            /// The next track arrives while the previous release is still
            /// gliding, so the deck's glide timer is already awake.
            case duringRelease
        }

        // 0 dBFS masters, so every deck really does owe a bent-rate headroom
        // pad — the state this is hunting is only created by a deck that was
        // padded and bent for a seam and then handed back for reuse.
        let plan = TransitionPlan.beatMatched(BeatMatchedPlan(
            outPoint: 5.2, inPoint: 0, overlapBars: 2,
            outgoingRate: 0.95, incomingRate: 1.06,
            bassSwapOffset: 1.0, overlapDuration: 2.0,
            rampLeadSeconds: 2, rampReleaseSeconds: 2))

        var everything: [Observation] = []
        for reuse in Reuse.allCases {
        let result = withWatchdog("seamChain-\(reuse.rawValue)", timeout: 120) { () -> [Observation] in
            var observations: [Observation] = []
            let engine = PlaybackEngine()
            let log = EventLog(engine)
            defer { engine.stopAll() }
            engine.outputVolume = 0

            /// Poll both decks for `seconds` of playing time and keep the worst
            /// reading of each — a stale target is re-applied by a *later*
            /// tick, so the interesting moment is never the first sample.
            func pollBothDecks(_ label: String, seconds: TimeInterval) {
                var worst: [Deck: Worst] = [.a: Worst(), .b: Worst()]
                let deadline = Date().addingTimeInterval(seconds)
                while Date() < deadline {
                    for deck in [Deck.a, Deck.b] {
                        let s = engine.effectSnapshot(of: deck)
                        var w = worst[deck]!
                        w.rateDeviation = max(w.rateDeviation, abs(s.rate - 1))
                        let first = w.firstPadDB ?? s.ratePadDB
                        w.firstPadDB = first
                        w.padDeepenedBy = max(w.padDeepenedBy, first - s.ratePadDB)
                        w.padDB = s.ratePadDB
                        if abs(s.ratePadTargetDB) > abs(w.padTargetDB) {
                            w.padTargetDB = s.ratePadTargetDB
                        }
                        w.volume = s.volume
                        worst[deck] = w
                    }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                for deck in [Deck.a, Deck.b] {
                    observations.append((label, deck, worst[deck]!))
                }
            }

            /// One seam: arm it, let it complete, then load the next track onto
            /// the deck it spent — `PlayerService`'s own order — and watch what
            /// the reused deck does across the following seconds.
            func runSeam(_ label: String, from: Deck, to: Deck) -> Bool {
                engine.scheduleTransition(.plain(plan), from: from, to: to)
                let completed = log.wait(timeout: 25) {
                    if case .transitionCompleted(from: from, to: to) = $0 { return true }
                    return false
                }
                guard completed else { return false }
                switch reuse {
                case .afterRelease:
                    // Let the rate release and the pad hand-back finish on
                    // their own, exactly as an undisturbed player would.
                    let deadline = Date().addingTimeInterval(10)
                    while Date() < deadline, engine.hasPendingTransition {
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                case .duringRelease:
                    Thread.sleep(forTimeInterval: 1.0)
                }
                // The prefetcher fills the spent deck with the next track.
                guard (try? engine.loadFile(at: Fixtures.eightSecondCAF, on: from,
                                            peakDBFS: 0)) != nil else { return false }
                pollBothDecks(label, seconds: 1.5)
                return true
            }

            guard (try? engine.loadFile(at: Fixtures.eightSecondCAF, on: .a, peakDBFS: 0)) != nil,
                  (try? engine.loadFile(at: Fixtures.eightSecondCAF, on: .b, peakDBFS: 0)) != nil
            else { return observations }
            engine.play(deck: .a, from: 2.6)

            let tag = reuse.rawValue
            guard runSeam("\(tag)/seam 1 (a→b), track 2 playing", from: .a, to: .b) else {
                return observations
            }
            // Track 2 is on deck B and has been playing since the seam; put it
            // back near the top so the next seam has its whole ramp window.
            engine.seek(deck: .b, to: 2.6)
            guard runSeam("\(tag)/seam 2 (b→a), track 3 playing", from: .b, to: .a) else {
                return observations
            }
            engine.seek(deck: .a, to: 2.6)
            _ = runSeam("\(tag)/seam 3 (a→b), track 4 playing", from: .a, to: .b)
            return observations
        }
        everything.append(contentsOf: result ?? [])
        }

        guard !everything.isEmpty else { return }
        for (label, deck, worst) in everything {
            let here = "\(label): deck \(deck)"
            let detuned = "\(here) is detuned mid-track — the phase vocoder is engaged on "
                + "a deck no hand-over is bending, which is the \"underwater\" "
                + "artifact (\(worst))"
            let aiming = "\(here) is still aiming at a bent-rate headroom pad left over "
                + "from an earlier seam — a reset deck must owe nothing to the "
                + "hand-over that spent it (\(worst))"
            let padding = "\(here) is being padded *down* mid-track — a headroom pad is "
                + "being acquired by a deck nothing is bending (\(worst))"
            #expect(worst.rateDeviation < 0.001, "\(detuned)")
            #expect(abs(worst.padTargetDB) < 0.001, "\(aiming)")
            #expect(worst.padDeepenedBy < 0.001, "\(padding)")
        }
    }

    /// **The `.settling` rate release has to survive losing its transition,
    /// the same way the pre-seam glide does.**
    ///
    /// The two bends are mirror images and only one of them was covered. The
    /// pre-seam glide bends `tr.from` and the `transition` setter hands it back
    /// through `endTempoRampLocked` on every teardown path at once. The
    /// post-seam release bends `tr.to` — the deck that *is* the music now — and
    /// nothing structural took that one back: `endTempoRampLocked` addresses
    /// `tr.from` only, and only while `rampActive`, which `beginOverlapLocked`
    /// has already cleared by then. The single path that got it right,
    /// `cancelTransitionLocked`'s `.settling` case, did it by hand.
    ///
    /// A deck stranded there sits at up to ±6 % with its headroom pad still
    /// down, for the rest of the track, which is the "underwater" artifact
    /// exactly. So this asks the same question of every way a release can be
    /// interrupted, and asks it by *polling*: a rate that reads 1.0 the instant
    /// after the interruption proves nothing if the next 50 ms tick re-bends it.
    @Test func theSettlingReleaseSurvivesEveryTeardown() throws {
        guard audioOutputAvailable else { return }
        enum Interruption: String, CaseIterable {
            /// The spent deck is restarted and runs out *inside* the release —
            /// the drained-early path, whose `else` branch is a bare
            /// `transition = nil` for every phase except `.overlapping`.
            case spentDeckDrainsDuringRelease
            /// The user pauses in the middle of the release and comes back.
            case pauseMidRelease
            /// A new track is started on the deck that is carrying the music
            /// while its release is still gliding.
            case playOntoSettlingDeck
            /// The transition is dropped outright. Green today only because
            /// `cancelTransitionLocked` hand-rolls the hand-back; kept as the
            /// guard on that behaviour once the invariant owns it.
            case cancelMidRelease
        }
        struct Outcome {
            var transitionSurvived = false
            var worstRateDeviation: Float = 0
            var finalRate: Float = 1
            var padTargetDB: Double = 0
        }
        // A big bend and a long release, so a stranded deck is unmistakable and
        // there is room to interrupt the glide well before it lands.
        let plan = TransitionPlan.beatMatched(BeatMatchedPlan(
            outPoint: 5.2, inPoint: 0, overlapBars: 2,
            outgoingRate: 0.95, incomingRate: 1.06,
            bassSwapOffset: 1.0, overlapDuration: 2.0,
            rampLeadSeconds: 2, rampReleaseSeconds: 6))

        for interruption in Interruption.allCases {
            let result = withWatchdog("settlingTeardown-\(interruption.rawValue)",
                                      timeout: 60) { () -> Outcome? in
                var o = Outcome()
                let engine = PlaybackEngine()
                let log = EventLog(engine)
                defer { engine.stopAll() }
                // 0 dBFS masters, so both decks really do owe a headroom pad
                // and "was the pad let go of too" has teeth.
                guard (try? engine.loadFile(at: Fixtures.eightSecondCAF, on: .a,
                                            peakDBFS: 0)) != nil,
                      (try? engine.loadFile(at: Fixtures.eightSecondCAF, on: .b,
                                            peakDBFS: 0)) != nil
                else { return nil }
                engine.outputVolume = 0
                engine.play(deck: .a, from: 2.6)
                engine.scheduleTransition(.plain(plan), from: .a, to: .b)
                guard log.wait(timeout: 25, for: {
                    if case .transitionCompleted(from: .a, to: .b) = $0 { return true }
                    return false
                }) else { return nil }

                // Deck B is the music now, bent at 1.06 with a 6 s release
                // running. Interrupt it a second in.
                Thread.sleep(forTimeInterval: 1.0)
                switch interruption {
                case .spentDeckDrainsDuringRelease:
                    // Deck A is the spent one. Try to put it back on the air
                    // near the end of its file so it drains while the release
                    // is still gliding — that is the only way to reach
                    // `handleFromDeckDrainedLocked` from `.settling`.
                    engine.play(deck: .a, from: 7.5)
                    Thread.sleep(forTimeInterval: 1.5)
                    o.transitionSurvived = engine.hasPendingTransition
                case .pauseMidRelease:
                    engine.pause()
                    Thread.sleep(forTimeInterval: 1.5)
                    engine.resume()
                case .playOntoSettlingDeck:
                    engine.play(deck: .b, from: 0.5)
                case .cancelMidRelease:
                    engine.cancelScheduledTransition()
                }

                // Let whatever is left of the release run out. Waiting on the
                // transition clearing rather than on the rate looking close
                // enough: a rate of 1.0006 is inside any sane tolerance and
                // still mid-glide.
                let deadline = Date().addingTimeInterval(14)
                while Date() < deadline, engine.hasPendingTransition {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                // Now poll. The whole point: a stale target is re-applied by a
                // *later* tick, so the reading that matters is never the first.
                let pollEnd = Date().addingTimeInterval(1.5)
                while Date() < pollEnd {
                    let s = engine.effectSnapshot(of: .b)
                    o.worstRateDeviation = max(o.worstRateDeviation, abs(s.rate - 1))
                    o.finalRate = s.rate
                    if abs(s.ratePadTargetDB) > abs(o.padTargetDB) {
                        o.padTargetDB = s.ratePadTargetDB
                    }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                return o
            }
            guard let o = result ?? nil else { continue }

            let where_ = interruption.rawValue
            let detuned = "\(where_): the deck carrying the music is still detuned "
                + "\(o.worstRateDeviation) off unity (final ×\(o.finalRate)) — the "
                + "settling release lost its transition and nothing handed the rate "
                + "back, so this track plays underwater to the end"
            let padded = "\(where_): the bent-rate headroom pad outlived the bend it "
                + "covered (target \(o.padTargetDB) dB) — the rest of the song plays quiet"
            #expect(o.worstRateDeviation < 0.001, "\(detuned)")
            #expect(abs(o.padTargetDB) < 0.001, "\(padded)")

            if interruption == .spentDeckDrainsDuringRelease {
                // Reachability probe, reported rather than asserted either way:
                // `finishOverlapLocked` resets the spent deck, which clears its
                // source, so `play` finds nothing to schedule and the drain
                // never fires. If that ever stops being true this records it.
                print("settlingTeardown: spent deck restarted mid-release — "
                      + "transition still pending afterwards: \(o.transitionSurvived)")
            }
        }
    }
}
