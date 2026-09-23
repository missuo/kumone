#if os(macOS)
import AVFoundation
import Foundation

/// Feeds a local audio file whose format differs from the engine's fixed
/// graph format (Hi-Res sample rates, mono files): reads the file in chunks
/// on its own queue, converts to the graph format, and delivers ~0.5s PCM
/// buffers to the engine queue — the same shape as ProgressiveLoader, minus
/// the network.
///
/// The graph never reconfigures for these files (reconnecting a running
/// AVAudioEngine graph while another deck renders throws NSException — the
/// crash this class exists to prevent); the cost is one sample-rate
/// conversion, done here.
///
/// Threading: all file I/O and conversion on `workQueue`; `onBuffer`/
/// `onEnded` fire on `callbackQueue` (the engine queue). Public methods may
/// be called from the engine queue.
final class FileFeeder: @unchecked Sendable {

    /// Converted PCM in roughly 0.5s chunks, in file order.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// The whole file has been delivered (fires after the last onBuffer).
    var onEnded: (() -> Void)?

    // MARK: - Health, for the engine's flight recorder

    /// What the feeder's dispatch looks like from outside, in one atomic read.
    ///
    /// "The deck went silent but the engine still thinks it is playing" is,
    /// on a converted deck, almost always this class starving: `inFlight` at 0
    /// with `ended` false means nothing is queued and nothing is coming. The
    /// numbers live behind the same lock as `liveGeneration` so the engine
    /// queue can read a consistent set of them while the work queue moves them.
    struct Health: Sendable, Equatable {
        var inFlight = 0
        /// Chunks handed to the callback queue since the current `start(from:)`.
        var delivered = 0
        var ended = false
        var generation = 0
    }

    /// What just happened to the feeder's dispatch, for the engine's ring.
    enum TraceKind: Sendable {
        case started, stopped, cancelled, chunks, ended
    }

    /// Fires on `callbackQueue` (the engine queue), never on `workQueue` — the
    /// engine's ring is queue-confined and this is how a feeder event crosses
    /// into it. Nil unless the verbose trace is on, so the whole path costs an
    /// optional test when it is off.
    var onTrace: ((TraceKind, Health) -> Void)?

    /// A milestone every this many delivered chunks; a line per chunk would be
    /// two a second per deck and would bury everything else in the ring.
    private static let chunkMilestone = 10

    var health: Health {
        healthLock.lock()
        defer { healthLock.unlock() }
        return _health
    }

    /// Duration in file time (unaffected by the conversion).
    let duration: TimeInterval

    /// The file being fed. Readable because a converted deck is still a deck
    /// playing a *file*, and the seam-offset measurement needs to open that
    /// file to say where the deck's audio actually was
    /// (`PlaybackEngine.seamSourceURL`).
    let fileURL: URL
    private let outputFormat: AVAudioFormat
    private let callbackQueue: DispatchQueue
    private let workQueue = DispatchQueue(label: "app.kumone.file-feeder", qos: .userInitiated)

    // workQueue state
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var cancelled = false
    private var ended = false
    /// Buffers delivered but not yet reported played; capped for memory.
    private var inFlight = 0
    private let maxInFlight = 8
    private var generation = 0

    /// `generation`, readable from the callback queue.
    ///
    /// A chunk is handed to `callbackQueue.async` while it is still current and
    /// can arrive after a `start(from:)`/`stop()` has moved on — audio from the
    /// old position, scheduled onto a deck that has been re-cued. The engine
    /// cannot filter it (its own deck generation is a different counter), so the
    /// feeder does, at the moment of delivery.
    private let healthLock = NSLock()
    private var _health = Health()
    /// Chunks delivered under the current run; workQueue-only.
    private var delivered = 0
    private var liveGeneration: Int {
        get { healthLock.lock(); defer { healthLock.unlock() }; return _health.generation }
        set { healthLock.lock(); _health.generation = newValue; healthLock.unlock() }
    }

    /// Publish the workQueue's counters so the engine queue can read them.
    /// Called at every point one of them moves; one uncontended lock per
    /// half-second chunk.
    private func syncHealth() {
        healthLock.lock()
        _health.inFlight = inFlight
        _health.delivered = delivered
        _health.ended = ended
        _health.generation = generation
        healthLock.unlock()
    }

    /// Hand a feeder event to the engine queue, with a consistent health read.
    private func trace(_ kind: TraceKind) {
        guard let onTrace else { return }
        let snapshot = health
        callbackQueue.async { onTrace(kind, snapshot) }
    }

    /// Deliver on the callback queue, unless the run that produced this has
    /// since been superseded.
    private func deliver(generation: Int, _ body: @escaping () -> Void) {
        callbackQueue.async { [weak self] in
            guard let self, self.liveGeneration == generation else { return }
            body()
        }
    }

    init(file: AVAudioFile, output: AVAudioFormat, queue: DispatchQueue) {
        self.fileURL = file.url
        self.outputFormat = output
        self.callbackQueue = queue
        self.duration = Double(file.length) / file.processingFormat.sampleRate
    }

    /// (Re)start delivery from `seconds` in file time. Any earlier run's
    /// pending chunks are discarded.
    ///
    /// The seek is frame-accurate **at the file's own rate** — the position is
    /// rounded to one source frame and the converter is rebuilt from scratch
    /// there, so the first delivered sample is the requested instant to within
    /// half a source frame plus the resampler's own phase (tens of
    /// microseconds at any rate the graph accepts). That is what lets a
    /// converted deck be cued for a splice's hand-back, where the segment's
    /// half-second identity crossfade absorbs the remainder.
    func start(from seconds: TimeInterval) {
        workQueue.async {
            self.generation += 1
            self.liveGeneration = self.generation
            let generation = self.generation
            self.ended = false
            self.inFlight = 0
            self.delivered = 0
            self.syncHealth()
            self.trace(.started)
            guard let file = try? AVAudioFile(forReading: self.fileURL) else {
                self.ended = true
                self.syncHealth()
                self.trace(.ended)
                let cb = self.onEnded
                self.deliver(generation: generation) { cb?() }
                return
            }
            let frame = AVAudioFramePosition((max(0, seconds) * file.processingFormat.sampleRate).rounded())
            file.framePosition = min(frame, file.length)
            self.file = file
            self.converter = AVAudioConverter(from: file.processingFormat, to: self.outputFormat)
            self.fillOnQueue(generation: generation)
        }
    }

    /// Halt delivery without retiring the feeder: pending chunks are dropped
    /// and nothing more is read until the next `start(from:)`.
    ///
    /// Distinct from `cancel()`, which is terminal (a cancelled feeder never
    /// feeds again — `resetDeckLocked` uses it when the deck's track is gone).
    /// This is for a cue that was set up and then not used: the splice tail that
    /// was pre-rolled and then disarmed still has the same track on the deck.
    func stop() {
        workQueue.async {
            self.generation += 1
            self.liveGeneration = self.generation
            self.inFlight = 0
            self.ended = false
            self.file = nil
            self.converter = nil
            self.syncHealth()
            self.trace(.stopped)
        }
    }

    /// The engine played one delivered buffer; keep the window full.
    func bufferPlayed() {
        workQueue.async {
            self.inFlight = max(0, self.inFlight - 1)
            self.syncHealth()
            self.fillOnQueue(generation: self.generation)
        }
    }

    func cancel() {
        workQueue.async {
            self.cancelled = true
            self.generation += 1
            self.liveGeneration = self.generation
            self.file = nil
            self.converter = nil
            self.syncHealth()
            self.trace(.cancelled)
        }
    }

    // MARK: - workQueue

    private func fillOnQueue(generation: Int) {
        guard !cancelled, !ended, generation == self.generation,
              let file, let converter else { return }
        let srcRate = file.processingFormat.sampleRate
        let chunkFrames = AVAudioFrameCount(srcRate / 2) // ~0.5s of source

        while inFlight < maxInFlight {
            guard file.framePosition < file.length else {
                // Rate conversion buffers internally; drain the tail.
                while true {
                    guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 8192)
                    else { break }
                    var error: NSError?
                    let status = converter.convert(to: out, error: &error) { _, st in
                        st.pointee = .endOfStream
                        return nil
                    }
                    if out.frameLength > 0 {
                        delivered += 1
                        let cb = onBuffer
                        deliver(generation: generation) { cb?(out) }
                    }
                    if status != .haveData { break }
                }
                ended = true
                syncHealth()
                trace(.ended)
                let cb = onEnded
                deliver(generation: generation) { cb?() }
                return
            }
            guard let src = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                             frameCapacity: chunkFrames) else { return }
            do {
                try file.read(into: src, frameCount: chunkFrames)
            } catch {
                ended = true
                syncHealth()
                trace(.ended)
                let cb = onEnded
                deliver(generation: generation) { cb?() }
                return
            }
            guard src.frameLength > 0 else { continue }

            let outCapacity = AVAudioFrameCount(
                (Double(src.frameLength) * outputFormat.sampleRate / srcRate).rounded(.up) + 64)
            guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                             frameCapacity: outCapacity) else { return }
            var fed = false
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, st in
                if fed {
                    st.pointee = .noDataNow
                    return nil
                }
                fed = true
                st.pointee = .haveData
                return src
            }
            guard status != .error else {
                ended = true
                syncHealth()
                trace(.ended)
                let cb = onEnded
                deliver(generation: generation) { cb?() }
                return
            }
            guard out.frameLength > 0 else { continue }
            inFlight += 1
            delivered += 1
            syncHealth()
            if delivered % Self.chunkMilestone == 0 { trace(.chunks) }
            let cb = onBuffer
            deliver(generation: generation) { cb?(out) }
        }
    }
}
#endif
