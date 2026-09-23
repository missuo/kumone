import Testing
@testable import KumoneCore
import AVFoundation
import Foundation

// FLAC streaming coverage for ProgressiveLoader.
//
// Background: the field SIGSEGVs (caulk::alloc::tiered_allocator::allocate
// with a garbage pointer, detonating inside AudioConverterNew / AVAudioFile
// open right after prefetch analysis) were reproduced deterministically from
// the loader's FLAC decode path: the previous AVAudioConverter-based decode
// corrupted AudioFileStream/CoreAudio allocator state near the stream tail
// (parse error 'wht?' followed by delayed detonation at the next audio-pool
// allocation). The smoke tests only stream AAC/ADTS; this suite pins the
// FLAC path end-to-end, no audio output device required — the loader never
// touches AVAudioEngine.
//
// The fixture is generated programmatically: sine .caf (Fixtures.writeSineCAF)
// converted with /usr/bin/afconvert, the same tool the repro used.

@Suite("ProgressiveLoaderFLACStream", .serialized)
struct ProgressiveLoaderFLACTests {

    /// afconvert an existing fixture .caf to FLAC. Cached per-process.
    static func flacFixture(from caf: URL, name: String) throws -> URL {
        let url = Fixtures.dir.appendingPathComponent("\(name).flac")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        p.arguments = ["-f", "flac", "-d", "flac", caf.path, url.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "ProgressiveLoaderFLACTests", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "afconvert to FLAC failed (\(p.terminationStatus))"])
        }
        return url
    }

    private struct StreamOutcome {
        var completed = false
        var error: String?
        var decodedFrames: AVAudioFramePosition = 0
        var buffers = 0
    }

    /// Streams `data` through a ProgressiveLoader with the given hint and
    /// collects the outcome. Returns nil on watchdog timeout.
    private func stream(_ data: Data, hint: String, partName: String,
                        timeout: TimeInterval = 60) throws -> StreamOutcome {
        let server = try TestHTTPServer(serving: data)
        defer { server.stop() }
        let partURL = Fixtures.dir.appendingPathComponent(partName)
        try? FileManager.default.removeItem(at: partURL)

        let output = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let engineQueue = DispatchQueue(label: "flac-test.engine")
        let loader = ProgressiveLoader(remoteURL: server.url, formatHint: hint,
                                       partURL: partURL, output: output, queue: engineQueue)
        final class Box: @unchecked Sendable { var o = StreamOutcome() }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        // Callbacks all fire on engineQueue (serial), so plain writes are safe.
        loader.onBuffer = { buf in
            box.o.buffers += 1
            box.o.decodedFrames += AVAudioFramePosition(buf.frameLength)
        }
        loader.onCompleted = {
            box.o.completed = true
            done.signal()
        }
        loader.onError = { err in
            box.o.error = "\(err)"
            done.signal()
        }
        loader.start()
        defer { loader.cancel() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            Issue.record("FLAC stream neither completed nor failed within \(timeout)s")
        }
        // Let any trailing onBuffer callbacks land before reading.
        engineQueue.sync {}
        return box.o
    }

    // The cache mirror must be reported complete when the *transfer* ends,
    // not when parsing catches up. The engine suspends decoding as soon as it
    // has enough PCM queued, so on a real track the parse trails the network
    // by minutes; tying the commit to `onCompleted` left the first track of
    // every fresh playlist without an analysis (field: .part files never
    // committed, `order commit … because=noOutgoingAnalysis`).
    @Test func mirrorCompletesWhileDecodingIsSuspended() throws {
        let caf = try Fixtures.writeSineCAF(seconds: 6, name: "flac-src-mirror")
        let flac = try Self.flacFixture(from: caf, name: "stream-mirror")
        let payload = try Data(contentsOf: flac)
        let server = try TestHTTPServer(serving: payload)
        defer { server.stop() }
        let partURL = Fixtures.dir.appendingPathComponent("flac-mirror.part")
        try? FileManager.default.removeItem(at: partURL)

        let output = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let engineQueue = DispatchQueue(label: "flac-test.mirror")
        let loader = ProgressiveLoader(remoteURL: server.url, formatHint: "flac",
                                       partURL: partURL, output: output, queue: engineQueue)
        final class Box: @unchecked Sendable {
            var mirrorBytes: Int64?
            var completedBeforeMirror = false
            var completed = false
        }
        let box = Box()
        let mirrored = DispatchSemaphore(value: 0)
        // Backpressure from the first buffer on, exactly like a deck that has
        // its low-water mark covered: decoding stops, the transfer does not.
        loader.onBuffer = { [weak loader] _ in loader?.setDownloadSuspended(true) }
        loader.onMirrorCompleted = { bytes in
            box.mirrorBytes = bytes
            mirrored.signal()
        }
        loader.onCompleted = {
            if box.mirrorBytes == nil { box.completedBeforeMirror = true }
            box.completed = true
        }
        loader.start()
        defer { loader.cancel() }

        #expect(mirrored.wait(timeout: .now() + 30) == .success,
                "the mirror should complete while decoding is suspended")
        engineQueue.sync {}
        #expect(!box.completedBeforeMirror)
        #expect(!box.completed, "decoding was suspended, so the parse cannot have finished")
        #expect(box.mirrorBytes == Int64(payload.count))
        #expect(try Data(contentsOf: partURL) == payload,
                "the .part must be a complete, byte-identical copy once reported")

        // Releasing the backpressure still finishes the parse, reporting the
        // mirror as committed.
        loader.setDownloadSuspended(false)
        let deadline = Date().addingTimeInterval(30)
        while !box.completed, Date() < deadline {
            loader.setDownloadSuspended(false)
            Thread.sleep(forTimeInterval: 0.05)
            engineQueue.sync {}
        }
        #expect(box.completed)
    }

    // FLAC 44.1k stereo streams to completion and decodes every frame.
    // Regression coverage for the FLAC decode path (heap corruption at the
    // stream tail in the AVAudioConverter-based decoder; decodeFailed(-50)
    // in the first C-API rewrite).
    @Test func flacStreamDecodesToCompletion() throws {
        let caf = try Fixtures.writeSineCAF(seconds: 6, name: "flac-src-6s")
        let flac = try Self.flacFixture(from: caf, name: "stream-6s")
        let o = try stream(try Data(contentsOf: flac), hint: "flac", partName: "flac-a.part")
        #expect(o.error == nil, "FLAC stream failed: \(o.error ?? "")")
        #expect(o.completed, "FLAC stream should complete")
        // 6s at 44.1k; allow codec priming/rounding slack.
        let expected = AVAudioFramePosition(6 * 44_100)
        #expect(abs(o.decodedFrames - expected) < 44_100 / 4,
                "decoded \(o.decodedFrames) frames, expected ≈\(expected)")
    }

    // Hi-Res FLAC (48k source → 44.1k graph rate): the loader owns the rate
    // conversion; frame count must match at the OUTPUT rate.
    @Test func hiResFLACStreamResamples() throws {
        let caf = try Fixtures.writeSineCAF(seconds: 6, sampleRate: 48_000, name: "flac-src-48k")
        let flac = try Self.flacFixture(from: caf, name: "stream-48k")
        let o = try stream(try Data(contentsOf: flac), hint: "flac", partName: "flac-b.part")
        #expect(o.error == nil, "48k FLAC stream failed: \(o.error ?? "")")
        #expect(o.completed, "48k FLAC stream should complete")
        let expected = AVAudioFramePosition(6 * 44_100)
        #expect(abs(o.decodedFrames - expected) < 44_100 / 4,
                "decoded \(o.decodedFrames) frames at 44.1k, expected ≈\(expected)")
    }

    // Delayed-detonation canary: after a full FLAC stream decode, opening the
    // audio-conversion machinery again must work. With the corrupting decoder
    // this is where the caulk allocator blew up (AudioConverterNew /
    // AVAudioFile open on the *next* track), so run it right after streaming.
    @Test func audioAllocatorHealthyAfterFLACStream() throws {
        let caf = try Fixtures.writeSineCAF(seconds: 6, name: "flac-src-6s")
        let flac = try Self.flacFixture(from: caf, name: "stream-6s")
        _ = try stream(try Data(contentsOf: flac), hint: "flac", partName: "flac-c.part")

        // "Load the next track": AVAudioFile + AVAudioConverter open cycles.
        for _ in 0..<8 {
            let f = try AVAudioFile(forReading: flac)
            let dst = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 22_050,
                                    channels: 1, interleaved: false)!
            #expect(AVAudioConverter(from: f.processingFormat, to: dst) != nil)
        }
        // And the real prefetch-analysis path over the same FLAC file.
        let analysis = try TrackAnalyzer.analyze(fileAt: flac)
        #expect(analysis.duration > 5.5 && analysis.duration < 6.5,
                "analysis duration \(analysis.duration) should be ≈6s")
    }
}
