import AVFoundation
import Foundation

/// The process's vocal separator, if it has one.
///
/// KumoneCore does not depend on StemKit — separation is a macOS-only,
/// model-backed, seconds-per-window concern and this module is the shared
/// playback core. So the separator is *installed* from outside (the app's
/// launcher, the `audition` CLI) as a plain closure, and everything here knows
/// is whether one showed up.
///
/// Nothing installed is the shipping default and the byte-identical path: the
/// planner still says `stems: .none`, no pre-render is ever started, and the
/// engine never sees a segment.
public enum StemSeparation {

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var provider: VocalStemProvider?
    }
    private static let box = Box()

    /// Install (or, with nil, remove) the separator. Called once at startup,
    /// before anything can play.
    public static func install(_ provider: VocalStemProvider?) {
        box.lock.lock()
        box.provider = provider
        box.lock.unlock()
    }

    public static var provider: VocalStemProvider? {
        box.lock.lock()
        defer { box.lock.unlock() }
        return box.provider
    }

    /// Whether a hand-over may be planned with `StemAvailability.ready`.
    public static var isAvailable: Bool { provider != nil }
}

/// Sidecar cache for separated vocals, shared by the app and the `audition`
/// console so a window separated by one is instant for the other.
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
