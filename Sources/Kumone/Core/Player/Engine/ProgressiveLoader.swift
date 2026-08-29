import AVFoundation
import AudioToolbox
import Foundation

// AudioFileStream C callbacks. They only fire from inside
// AudioFileStreamParseBytes, which the loader calls on its work queue.
private let loaderPropertyProc: AudioFileStream_PropertyListenerProc = { clientData, streamID, propertyID, _ in
    Unmanaged<ProgressiveLoader>.fromOpaque(clientData).takeUnretainedValue()
        .handleProperty(streamID: streamID, propertyID: propertyID)
}

private let loaderPacketsProc: AudioFileStream_PacketsProc = { clientData, byteCount, packetCount, inputData, descriptions in
    Unmanaged<ProgressiveLoader>.fromOpaque(clientData).takeUnretainedValue()
        .handlePackets(byteCount: byteCount, packetCount: packetCount,
                       data: inputData, descriptions: descriptions)
}

/// Streams a remote audio file, decodes it to PCM on the fly, and mirrors the
/// raw bytes into a `.part` cache file (spec §3).
///
/// Byte flow: URLSession → AudioFileStream (packet parsing, with a file-type
/// hint) → AudioConverter (C API) → ~0.5s float32 PCM buffers via `onBuffer`.
///
/// The decoder is deliberately the C `AudioConverter` API, not
/// `AVAudioConverter`: letting AVAudioConverter decode AAC anywhere in the
/// process corrupts AudioFileStream's parser state — the very next
/// `AudioFileStreamParseBytes` call fails with kAudioFileStreamError 'wht?',
/// deterministically (macOS 26; reproduced standalone with per-packet,
/// batched, deferred, and cross-thread convert calls — only the C API is
/// clean). Decoding also runs strictly *between* parse calls, never inside
/// the packets callback: `handlePackets` only queues the compressed packets,
/// and `parseOnQueue` decodes them after AudioFileStreamParseBytes returns.
///
/// Threading: all network delivery, parsing, decoding, and disk mirroring run
/// on the loader's own serial `workQueue` — never on the engine queue, so a
/// decode burst (fast CDN + FLAC) cannot starve the engine queue that the
/// main thread synchronously queries for playback position. Results hop to
/// `callbackQueue` (the engine queue): the `onFormat`/`onBuffer`/
/// `onCompleted`/`onError` closures always fire there, in order.
///
/// Public control methods (`start`/`cancel`/`seek`/`setDownloadSuspended`)
/// may be called from the engine queue; they enqueue onto `workQueue`.
/// The cheap estimate getters (`canSeek`/`estimatedDuration`/
/// `downloadFinished`) are safe from any thread via `statLock`.
final class ProgressiveLoader: NSObject, @unchecked Sendable {

    /// Decoded PCM output format; fires once, before the first `onBuffer`.
    var onFormat: ((AVAudioFormat) -> Void)?
    /// Decoded PCM in roughly 0.5s chunks.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// Network stream ended cleanly and the tail was flushed. `cacheCommitted`
    /// is false when a seek abandoned the contiguous `.part` write.
    var onCompleted: ((_ cacheCommitted: Bool) -> Void)?
    var onError: ((Error) -> Void)?

    enum LoaderError: LocalizedError {
        case badStatus(Int)
        case rangeNotSupported
        case parseFailed(OSStatus)
        case decodeFailed(OSStatus)
        case unsupportedFormat
        case cannotWritePartFile

        var errorDescription: String? {
            switch self {
            case .badStatus(let code): return "HTTP status \(code)"
            case .rangeNotSupported: return "Server ignored the Range request"
            case .parseFailed(let status): return "Audio stream parse failed (\(status))"
            case .decodeFailed(let status): return "Audio decode failed (\(status))"
            case .unsupportedFormat: return "Unsupported stream format"
            case .cannotWritePartFile: return "Cannot write the partial cache file"
            }
        }
    }

    private let remoteURL: URL
    private let partURL: URL
    private let typeHint: AudioFileTypeID
    /// Decoded output format — the engine's fixed graph format; the
    /// converter resamples/remaps into it so the graph never reconfigures.
    private let outputFormat: AVAudioFormat
    /// Where the result closures fire — the engine queue.
    private let callbackQueue: DispatchQueue
    /// Where all network/parse/decode/disk work runs.
    private let workQueue = DispatchQueue(label: "app.kumone.progressive-loader", qos: .userInitiated)

    // MARK: - State confined to workQueue

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var streamID: AudioFileStreamID?

    private var asbd = AudioStreamBasicDescription()
    private var converter: AudioConverterRef?
    private var outFormat: AVAudioFormat?
    private var accum: AVAudioPCMBuffer?
    private var accumCapacity: AVAudioFrameCount = 0

    /// Compressed packets queued by `handlePackets`, decoded by
    /// `decodePendingPackets` once the parse call that produced them returns.
    private var pendingPacketBytes: [UInt8] = []
    private var pendingPacketDescs: [AudioStreamPacketDescription] = []
    /// Feeds `pendingPacketBytes` to AudioConverterFillComplexBuffer.
    private let feed = ConverterFeed()

    private var fileHandle: FileHandle?
    private var cacheAbandoned = false
    private var cancelled = false
    private var failed = false
    private var suspended = false
    private var needsDiscontinuity = false
    private var expectPartialContent = false

    // Backpressure state. Suspending never touches the URLSession task:
    // suspending a data task whose transfer is finishing races with the
    // final delegate callbacks, and pausing the network would also stall the
    // `.part` mirror. Instead the transfer keeps flowing — bytes are still
    // written to the `.part` file on arrival — and only *parsing/decoding*
    // pauses, which is what actually bounds decoded-but-unplayed PCM.
    // Arrived-but-unparsed bytes wait in `backlog`.
    private var backlog = Data()
    /// The transfer ended cleanly but `backlog` may still hold undecoded
    /// bytes; completion is surfaced once the backlog drains.
    private var networkDone = false
    private var drainScheduled = false
    /// Parse the backlog in slices this big, re-queued between slices, so a
    /// new suspend request can interleave before PCM overshoots high water.
    private static let drainChunkBytes = 32 * 1024

    // MARK: - Cross-thread estimates (guarded by statLock)

    // Written on workQueue during parsing; read from the engine queue for
    // seek decisions and duration estimates.
    private let statLock = NSLock()
    private var dataOffset: Int64 = 0
    private var audioDataByteCount: UInt64 = 0
    private var bitRate: UInt32 = 0
    private var parsedAudioBytes: Int64 = 0
    private var decodedFrames: AVAudioFramePosition = 0
    private var outSampleRate: Double = 0
    private var converterReady = false
    private var completed = false

    init(remoteURL: URL, formatHint: String?, partURL: URL,
         output: AVAudioFormat, queue: DispatchQueue) {
        self.remoteURL = remoteURL
        self.partURL = partURL
        self.outputFormat = output
        self.callbackQueue = queue
        switch formatHint?.lowercased() {
        case "mp3": typeHint = kAudioFileMP3Type
        case "flac": typeHint = kAudioFileFLACType
        case "m4a", "mp4", "alac": typeHint = kAudioFileM4AType
        case "aac": typeHint = kAudioFileAAC_ADTSType
        case "wav": typeHint = kAudioFileWAVEType
        default: typeHint = 0
        }
        super.init()
    }

    deinit {
        if let streamID { AudioFileStreamClose(streamID) }
        if let converter { AudioConverterDispose(converter) }
    }

    // MARK: - Estimates

    /// Bytes of encoded audio per second of sound; used for both the duration
    /// estimate and the CBR seek offset. VBR streams get an approximation.
    /// Callers must hold `statLock`.
    private var bytesPerSecondLocked: Double? {
        if bitRate > 0 { return Double(bitRate) / 8 }
        guard outSampleRate > 0, decodedFrames > 0, parsedAudioBytes > 0 else { return nil }
        let seconds = Double(decodedFrames) / outSampleRate
        guard seconds > 1 else { return nil }
        return Double(parsedAudioBytes) / seconds
    }

    var estimatedDuration: TimeInterval? {
        statLock.lock()
        defer { statLock.unlock() }
        guard audioDataByteCount > 0, let bps = bytesPerSecondLocked, bps > 0 else { return nil }
        return Double(audioDataByteCount) / bps
    }

    /// True once enough of the stream is parsed to map seconds → bytes.
    var canSeek: Bool {
        statLock.lock()
        defer { statLock.unlock() }
        return converterReady && bytesPerSecondLocked != nil
    }

    var downloadFinished: Bool {
        statLock.lock()
        defer { statLock.unlock() }
        return completed
    }

    // MARK: - Lifecycle (public wrappers hop to workQueue)

    func start() {
        workQueue.async { self.startOnQueue() }
    }

    func cancel() {
        workQueue.async { self.cancelOnQueue() }
    }

    /// Backpressure from the engine so decoded-but-unplayed PCM stays
    /// bounded. Pauses decoding, not the transfer — see the `backlog` note.
    func setDownloadSuspended(_ suspend: Bool) {
        workQueue.async {
            guard !self.cancelled, !self.failed, !self.downloadFinished,
                  suspend != self.suspended else { return }
            self.suspended = suspend
            if !suspend { self.scheduleDrainIfNeeded() }
        }
    }

    /// Restart the transfer from an estimated byte offset for `seconds`
    /// (CBR estimate — not sample accurate; VBR streams land nearby).
    ///
    /// Limitations, by design (spec §3 allows the simplification):
    /// - No-op until `canSeek` (bitrate unknown) — the engine must check first.
    /// - Abandons the `.part` cache write: bytes are no longer contiguous, so
    ///   `onCompleted` reports `cacheCommitted == false` and the caller must
    ///   not commit the file.
    /// - Relies on AudioFileStream discontinuity parsing; solid for MP3/ADTS,
    ///   best effort for FLAC/M4A (an unparseable resync surfaces as an error
    ///   and the caller falls back to a fresh load).
    func seek(to seconds: TimeInterval) {
        workQueue.async { self.seekOnQueue(to: seconds) }
    }

    // MARK: - workQueue implementations

    private func startOnQueue() {
        guard !cancelled else { return }
        let clientData = Unmanaged.passUnretained(self).toOpaque()
        var sid: AudioFileStreamID?
        let status = AudioFileStreamOpen(clientData, loaderPropertyProc, loaderPacketsProc, typeHint, &sid)
        guard status == noErr, let sid else {
            fail(LoaderError.parseFailed(status))
            return
        }
        streamID = sid

        FileManager.default.createFile(atPath: partURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: partURL) else {
            // Keep playing without the cache mirror rather than failing playback.
            cacheAbandoned = true
            startRequest(rangeOffset: nil)
            return
        }
        fileHandle = handle
        startRequest(rangeOffset: nil)
    }

    private func cancelOnQueue() {
        guard !cancelled else { return }
        cancelled = true
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        try? fileHandle?.close()
        fileHandle = nil
        if let streamID {
            AudioFileStreamClose(streamID)
            self.streamID = nil
        }
        if let converter {
            AudioConverterDispose(converter)
            self.converter = nil
        }
    }

    private func seekOnQueue(to seconds: TimeInterval) {
        guard !cancelled, !failed else { return }
        statLock.lock()
        let bps = converterReady ? bytesPerSecondLocked : nil
        let offsetBase = dataOffset
        let byteCount = audioDataByteCount
        completed = false
        statLock.unlock()
        guard let bps else { return }
        if !cacheAbandoned {
            cacheAbandoned = true
            try? fileHandle?.close()
            fileHandle = nil
        }
        if let converter { AudioConverterReset(converter) }
        pendingPacketBytes.removeAll()
        pendingPacketDescs.removeAll()
        resetAccum()
        needsDiscontinuity = true
        suspended = false
        backlog.removeAll()
        networkDone = false
        var offset = offsetBase + Int64(seconds * bps)
        if byteCount > 0 {
            offset = min(offset, offsetBase + Int64(byteCount) - 1)
        }
        startRequest(rangeOffset: max(offsetBase, offset))
    }

    private func startRequest(rangeOffset: Int64?) {
        task?.cancel()
        if session == nil {
            let delegateQueue = OperationQueue()
            delegateQueue.maxConcurrentOperationCount = 1
            delegateQueue.underlyingQueue = workQueue
            session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: delegateQueue)
        }
        var request = URLRequest(url: remoteURL)
        if let rangeOffset {
            request.setValue("bytes=\(rangeOffset)-", forHTTPHeaderField: "Range")
            expectPartialContent = true
        } else {
            expectPartialContent = false
        }
        let newTask = session!.dataTask(with: request)
        task = newTask
        newTask.resume()
    }

    private func fail(_ error: Error) {
        guard !failed, !cancelled else { return }
        failed = true
        notify { self.onError?(error) }
        cancelOnQueue()
    }

    /// Deliver a result closure on the engine queue, preserving order.
    private func notify(_ block: @escaping () -> Void) {
        callbackQueue.async(execute: block)
    }

    // MARK: - AudioFileStream callbacks (workQueue)

    fileprivate func handleProperty(streamID: AudioFileStreamID, propertyID: AudioFileStreamPropertyID) {
        switch propertyID {
        case kAudioFileStreamProperty_DataFormat:
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            AudioFileStreamGetProperty(streamID, propertyID, &size, &asbd)
        case kAudioFileStreamProperty_DataOffset:
            var offset: Int64 = 0
            var size = UInt32(MemoryLayout<Int64>.size)
            AudioFileStreamGetProperty(streamID, propertyID, &size, &offset)
            statLock.lock()
            dataOffset = offset
            statLock.unlock()
        case kAudioFileStreamProperty_AudioDataByteCount:
            var count: UInt64 = 0
            var size = UInt32(MemoryLayout<UInt64>.size)
            AudioFileStreamGetProperty(streamID, propertyID, &size, &count)
            statLock.lock()
            audioDataByteCount = count
            statLock.unlock()
        case kAudioFileStreamProperty_BitRate:
            var rate: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            AudioFileStreamGetProperty(streamID, propertyID, &size, &rate)
            statLock.lock()
            bitRate = rate
            statLock.unlock()
        case kAudioFileStreamProperty_ReadyToProducePackets:
            setUpConverter(streamID: streamID)
        default:
            break
        }
    }

    private func setUpConverter(streamID: AudioFileStreamID) {
        guard converter == nil else { return }
        let output = outputFormat
        var inDesc = asbd
        var outDesc = output.streamDescription.pointee
        guard inDesc.mSampleRate > 0, inDesc.mChannelsPerFrame > 0,
              inDesc.mFormatID != kAudioFormatLinearPCM else {
            fail(LoaderError.unsupportedFormat)
            return
        }
        var newConverter: AudioConverterRef?
        guard AudioConverterNew(&inDesc, &outDesc, &newConverter) == noErr,
              let conv = newConverter else {
            fail(LoaderError.unsupportedFormat)
            return
        }

        // AAC and friends need the magic cookie before the first packet.
        var cookieSize: UInt32 = 0
        var writable: DarwinBoolean = false
        if AudioFileStreamGetPropertyInfo(streamID, kAudioFileStreamProperty_MagicCookieData,
                                          &cookieSize, &writable) == noErr, cookieSize > 0 {
            var cookie = [UInt8](repeating: 0, count: Int(cookieSize))
            if AudioFileStreamGetProperty(streamID, kAudioFileStreamProperty_MagicCookieData,
                                          &cookieSize, &cookie) == noErr {
                AudioConverterSetProperty(conv, kAudioConverterDecompressionMagicCookie,
                                          cookieSize, cookie)
            }
        }

        outFormat = output
        converter = conv
        accumCapacity = AVAudioFrameCount(output.sampleRate / 2) // ~0.5s
        resetAccum()
        statLock.lock()
        outSampleRate = output.sampleRate
        converterReady = true
        statLock.unlock()
        notify { self.onFormat?(output) }
    }

    /// Runs inside AudioFileStreamParseBytes. Only *queues* the compressed
    /// packets — decoding happens after the parse call returns (see the class
    /// note on AVAudioConverter/AudioFileStream corruption; even with the C
    /// converter, decoding inside the parser callback is needless risk).
    fileprivate func handlePackets(byteCount: UInt32, packetCount: UInt32,
                                   data: UnsafeRawPointer,
                                   descriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?) {
        guard !failed, !cancelled, converter != nil, packetCount > 0 else { return }
        statLock.lock()
        parsedAudioBytes += Int64(byteCount)
        statLock.unlock()

        let rebase = Int64(pendingPacketBytes.count)
        pendingPacketBytes.append(contentsOf: UnsafeRawBufferPointer(start: data, count: Int(byteCount)))
        if let descriptions, asbd.mBytesPerPacket == 0 {
            // VBR: parser-supplied descriptions, offsets rebased onto the
            // queued byte block.
            for i in 0..<Int(packetCount) {
                var desc = descriptions[i]
                desc.mStartOffset += rebase
                pendingPacketDescs.append(desc)
            }
        } else {
            // CBR: synthesize uniform descriptions so the decode path is one
            // code path for both cases.
            let size = asbd.mBytesPerPacket
            guard size > 0 else { return }
            for i in 0..<Int(packetCount) {
                pendingPacketDescs.append(AudioStreamPacketDescription(
                    mStartOffset: rebase + Int64(i) * Int64(size),
                    mVariableFramesInPacket: 0,
                    mDataByteSize: size))
            }
        }
    }

    // MARK: - Parsing + decoding (workQueue)

    private func parseOnQueue(_ data: Data) {
        guard let streamID else { return }
        let flags: AudioFileStreamParseFlags = needsDiscontinuity ? .discontinuity : []
        needsDiscontinuity = false
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return noErr }
            return AudioFileStreamParseBytes(streamID, UInt32(raw.count), base, flags)
        }
        if status != noErr {
            fail(LoaderError.parseFailed(status))
            return
        }
        decodePendingPackets()
    }

    /// Sentinel the input proc returns when the queued packets are exhausted:
    /// "no data right now" (a plain noErr with zero packets would instead
    /// tell the converter the stream has ended and flush its tail).
    fileprivate static let noDataNowStatus: OSStatus = 0x6B756D6F // 'kumo'

    private final class ConverterFeed {
        var bytes: UnsafeRawPointer?
        var byteCount = 0
        var descs: UnsafeMutablePointer<AudioStreamPacketDescription>?
        var packetCount: UInt32 = 0
        var channels: UInt32 = 1
        var consumed = false
        var atEOF = false
    }

    private static let converterInputProc: AudioConverterComplexInputDataProc = { _, ioNumPackets, ioData, outDescs, userData in
        let feed = Unmanaged<ConverterFeed>.fromOpaque(userData!).takeUnretainedValue()
        if feed.consumed || feed.packetCount == 0 {
            ioNumPackets.pointee = 0
            return feed.atEOF ? noErr : ProgressiveLoader.noDataNowStatus
        }
        feed.consumed = true
        ioNumPackets.pointee = feed.packetCount
        ioData.pointee.mNumberBuffers = 1
        ioData.pointee.mBuffers.mNumberChannels = feed.channels
        ioData.pointee.mBuffers.mDataByteSize = UInt32(feed.byteCount)
        ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: feed.bytes)
        outDescs?.pointee = feed.descs
        return noErr
    }

    private func decodePendingPackets() {
        guard let converter, !failed, !pendingPacketDescs.isEmpty else { return }
        let bytes = pendingPacketBytes
        var descs = pendingPacketDescs
        pendingPacketBytes.removeAll(keepingCapacity: true)
        pendingPacketDescs.removeAll(keepingCapacity: true)
        bytes.withUnsafeBytes { raw in
            descs.withUnsafeMutableBufferPointer { descPtr in
                feed.bytes = raw.baseAddress
                feed.byteCount = raw.count
                feed.descs = descPtr.baseAddress
                feed.packetCount = UInt32(descPtr.count)
                feed.channels = asbd.mChannelsPerFrame
                feed.consumed = false
                feed.atEOF = false
                pullDecodedFrames(converter)
                feed.bytes = nil
                feed.descs = nil
                feed.packetCount = 0
            }
        }
    }

    private func drainConverterTail() {
        guard let converter, !failed else { return }
        feed.packetCount = 0
        feed.consumed = true
        feed.atEOF = true
        pullDecodedFrames(converter)
        feed.atEOF = false
    }

    /// Pull converted PCM out of the converter until the queued input runs
    /// dry (or, with `feed.atEOF`, until the tail is fully flushed).
    private func pullDecodedFrames(_ converter: AudioConverterRef) {
        guard let outFormat else { return }
        let chunkFrames: AVAudioFrameCount = 8192
        let bytesPerFrame = UInt32(MemoryLayout<Float>.size)
        while !failed {
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: chunkFrames) else { return }
            // Capture the ABL pointer once: every access snapshots byte sizes
            // from the current frameLength (0 here), so sizes set through one
            // pointer are not seen through a second access.
            let ablPtr = out.mutableAudioBufferList
            let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
            for i in 0..<abl.count {
                abl[i].mDataByteSize = chunkFrames * bytesPerFrame
            }
            var frames: UInt32 = chunkFrames
            let status = AudioConverterFillComplexBuffer(
                converter, Self.converterInputProc,
                Unmanaged.passUnretained(feed).toOpaque(),
                &frames, ablPtr, nil)
            if frames > 0 {
                out.frameLength = AVAudioFrameCount(frames)
                deliver(out)
            }
            if status == Self.noDataNowStatus { return } // input exhausted for now
            guard status == noErr else {
                fail(LoaderError.decodeFailed(status))
                return
            }
            if frames == 0 { return } // EOF flush complete
        }
    }

    private func deliver(_ buffer: AVAudioPCMBuffer) {
        statLock.lock()
        decodedFrames += AVAudioFramePosition(buffer.frameLength)
        statLock.unlock()
        guard accum != nil else {
            notify { self.onBuffer?(buffer) }
            return
        }
        var offset: AVAudioFrameCount = 0
        while offset < buffer.frameLength {
            // Re-read every iteration: flushAccum() swaps self.accum for a
            // fresh buffer, and a stale local binding of the full one spins
            // this loop forever (count == 0, offset never advances).
            guard let accum = self.accum else { break }
            let space = accum.frameCapacity - accum.frameLength
            let count = min(space, buffer.frameLength - offset)
            copyFrames(from: buffer, at: offset, into: accum, count: count)
            offset += count
            if accum.frameLength == accum.frameCapacity { flushAccum() }
        }
    }

    private func copyFrames(from src: AVAudioPCMBuffer, at srcOffset: AVAudioFrameCount,
                            into dst: AVAudioPCMBuffer, count: AVAudioFrameCount) {
        guard count > 0,
              let srcData = src.floatChannelData,
              let dstData = dst.floatChannelData else { return }
        let channels = Int(min(src.format.channelCount, dst.format.channelCount))
        for ch in 0..<channels {
            (dstData[ch] + Int(dst.frameLength))
                .update(from: srcData[ch] + Int(srcOffset), count: Int(count))
        }
        dst.frameLength += count
    }

    private func flushAccum() {
        guard let full = accum, full.frameLength > 0, let outFormat else { return }
        accum = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: accumCapacity)
        notify { self.onBuffer?(full) }
    }

    private func resetAccum() {
        guard let outFormat, accumCapacity > 0 else { return }
        accum = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: accumCapacity)
    }
}

// MARK: - URLSessionDataDelegate (callbacks on workQueue)

extension ProgressiveLoader: URLSessionDataDelegate {

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard dataTask === task, !cancelled else {
            completionHandler(.cancel)
            return
        }
        if let http = response as? HTTPURLResponse {
            guard http.statusCode == 200 || http.statusCode == 206 else {
                completionHandler(.cancel)
                fail(LoaderError.badStatus(http.statusCode))
                return
            }
            if expectPartialContent && http.statusCode != 206 {
                // A 200 restarts from byte 0 while we assume mid-file; the
                // position mapping would be wrong, so treat it as a failure.
                completionHandler(.cancel)
                fail(LoaderError.rangeNotSupported)
                return
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask === task, !cancelled, !failed, streamID != nil else { return }
        // Mirror to disk immediately, suspended or not — the `.part` file
        // stays a contiguous copy of everything received.
        if !cacheAbandoned, let fileHandle {
            do {
                try fileHandle.write(contentsOf: data)
            } catch {
                // Losing the cache mirror is not fatal for playback.
                cacheAbandoned = true
                try? fileHandle.close()
                self.fileHandle = nil
            }
        }
        if suspended || !backlog.isEmpty {
            // Paused (or a resume drain is still catching up): keep byte
            // order by appending behind the backlog instead of parsing now.
            backlog.append(data)
        } else {
            parseOnQueue(data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === self.task, !cancelled else { return }
        if let error {
            if (error as NSError).code == NSURLErrorCancelled { return }
            fail(error)
            return
        }
        guard !failed else { return }
        networkDone = true
        if suspended || !backlog.isEmpty {
            // Completion surfaces after the backlog drains (drainStep calls
            // finishOnQueue); while suspended, the engine's low-water resume
            // restarts the drain.
            if !suspended { scheduleDrainIfNeeded() }
            return
        }
        finishOnQueue()
    }

    // MARK: - Deferred parsing (workQueue)

    private func scheduleDrainIfNeeded() {
        guard !drainScheduled else { return }
        drainScheduled = true
        workQueue.async { self.drainStep() }
    }

    private func drainStep() {
        drainScheduled = false
        guard !cancelled, !failed else {
            backlog.removeAll()
            return
        }
        guard !suspended else { return } // re-paused mid-drain; resume reschedules
        if !backlog.isEmpty {
            let chunk = Data(backlog.prefix(Self.drainChunkBytes))
            backlog.removeFirst(chunk.count)
            parseOnQueue(chunk)
            guard !failed else {
                backlog.removeAll()
                return
            }
        }
        if !backlog.isEmpty {
            scheduleDrainIfNeeded()
        } else if networkDone {
            finishOnQueue()
        }
    }

    /// Clean end of stream with every byte parsed: flush the decoder tail,
    /// commit the cache mirror, and surface `onCompleted` (after all
    /// `onBuffer`s — `notify` preserves order).
    private func finishOnQueue() {
        guard !downloadFinished, !failed, !cancelled else { return }
        drainConverterTail()
        flushAccum()
        statLock.lock()
        completed = true
        statLock.unlock()
        var committed = false
        if !cacheAbandoned, let fileHandle {
            try? fileHandle.close()
            self.fileHandle = nil
            committed = true
        }
        notify { self.onCompleted?(committed) }
    }
}
