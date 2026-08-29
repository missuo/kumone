import AVFoundation
import Foundation
import MLX
import StemKit

// stemtool — offline acceptance harness for StemKit.
//
// Deliberately dependency-free argument handling: Kumone's only SPM dependency of record
// is Sparkle, and StemKit already costs the project mlx-swift. Adding swift-argument-parser
// on top of that, for a tool with four flags, is not a trade worth making.

// MARK: - Usage

let usage = """
    stemtool — Mel-Band RoFormer vocal separation (offline)

    USAGE:
      stemtool separate <audio-file> [options]

    OPTIONS:
      --from <seconds>     Window start (default: 0)
      --to <seconds>       Window end (default: end of file)
      -o, --output <dir>   Output directory (default: ./stems)
      --models <dir>       Model cache directory
                           (default: ~/Library/Application Support/Kumone/Models)
      --repeat <n>         Run separation n times and report each timing (default: 1)
      -h, --help           Show this message

    OUTPUT:
      <dir>/vocals.wav          separated vocals, 44.1 kHz stereo
      <dir>/accompaniment.wav   mixture - vocals, 44.1 kHz stereo
      <dir>/mixture.wav         the analysed window itself, for A/B reference

    The checkpoint (Mel-Band RoFormer ZFTurbo vocals v1, MIT, 64.3 MiB) downloads from
    Hugging Face on first run and is verified against a hardcoded SHA-256.
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

// MARK: - Argument parsing

var arguments = Array(CommandLine.arguments.dropFirst())

if arguments.isEmpty || arguments.contains("-h") || arguments.contains("--help") {
    print(usage)
    exit(arguments.isEmpty ? 1 : 0)
}

guard arguments.first == "separate" else {
    fail("unknown command '\(arguments[0])'. Expected 'separate'. Run with --help.")
}
arguments.removeFirst()

var inputPath: String?
var fromSeconds: Double = 0
var toSeconds: Double?
var outputPath = "./stems"
var modelsPath: String?
var repeatCount = 1

func nextValue(_ flag: String, _ index: inout Int) -> String {
    guard index + 1 < arguments.count else { fail("\(flag) requires a value") }
    index += 1
    return arguments[index]
}

var index = 0
while index < arguments.count {
    let argument = arguments[index]
    switch argument {
    case "--from":
        guard let value = Double(nextValue("--from", &index)) else { fail("--from needs a number") }
        fromSeconds = value
    case "--to":
        guard let value = Double(nextValue("--to", &index)) else { fail("--to needs a number") }
        toSeconds = value
    case "-o", "--output":
        outputPath = nextValue(argument, &index)
    case "--models":
        modelsPath = nextValue("--models", &index)
    case "--repeat":
        guard let value = Int(nextValue("--repeat", &index)), value >= 1 else {
            fail("--repeat needs a positive integer")
        }
        repeatCount = value
    default:
        if argument.hasPrefix("-") { fail("unknown option '\(argument)'") }
        if inputPath != nil { fail("more than one input file given") }
        inputPath = argument
    }
    index += 1
}

guard let inputPath else { fail("no input audio file given. Run with --help.") }
if let toSeconds, toSeconds <= fromSeconds {
    fail("--to (\(toSeconds)) must be greater than --from (\(fromSeconds))")
}

let inputURL = URL(fileURLWithPath: inputPath)
guard FileManager.default.fileExists(atPath: inputURL.path) else {
    fail("input file not found: \(inputURL.path)")
}
let outputURL = URL(fileURLWithPath: outputPath)

// MARK: - Audio loading

/// Read a time window from any AVAudioFile-readable source as 44.1 kHz deinterleaved stereo.
func loadWindow(
    from url: URL,
    from startSeconds: Double,
    to endSeconds: Double?
) throws -> (channels: [[Float]], sampleRate: Double) {
    let targetRate = 44_100.0
    let file = try AVAudioFile(forReading: url)
    let sourceFormat = file.processingFormat

    guard
        let readFormat = AVAudioFormat(
            standardFormatWithSampleRate: sourceFormat.sampleRate,
            channels: sourceFormat.channelCount)
    else { fail("could not build a read format for \(url.lastPathComponent)") }

    let sourceRate = sourceFormat.sampleRate
    let totalFrames = file.length
    let startFrame = max(0, AVAudioFramePosition(startSeconds * sourceRate))
    let endFrame = endSeconds.map { min(totalFrames, AVAudioFramePosition($0 * sourceRate)) }
        ?? totalFrames
    guard startFrame < endFrame else {
        fail("requested window is empty or past the end of the file")
    }
    let frameCount = AVAudioFrameCount(endFrame - startFrame)

    file.framePosition = startFrame
    guard let buffer = AVAudioPCMBuffer(pcmFormat: readFormat, frameCapacity: frameCount) else {
        fail("could not allocate a read buffer")
    }
    try file.read(into: buffer, frameCount: frameCount)

    // Resample to 44.1 kHz stereo if the source is not already there.
    let working: AVAudioPCMBuffer
    if sourceRate == targetRate && sourceFormat.channelCount == 2 {
        working = buffer
    } else {
        guard
            let targetFormat = AVAudioFormat(
                standardFormatWithSampleRate: targetRate, channels: 2),
            let converter = AVAudioConverter(from: readFormat, to: targetFormat)
        else { fail("could not build a converter to 44.1 kHz stereo") }

        let outputCapacity = AVAudioFrameCount(
            ceil(Double(buffer.frameLength) * targetRate / sourceRate) + 1024)
        guard
            let converted = AVAudioPCMBuffer(
                pcmFormat: targetFormat, frameCapacity: outputCapacity)
        else { fail("could not allocate a conversion buffer") }

        nonisolated(unsafe) var consumed = false
        nonisolated(unsafe) let source = buffer
        var conversionError: NSError?
        converter.convert(to: converted, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return source
        }
        if let conversionError { throw conversionError }
        working = converted
    }

    guard let data = working.floatChannelData else { fail("no float samples in the read buffer") }
    let frames = Int(working.frameLength)
    let channelCount = Int(working.format.channelCount)
    let channels = (0..<min(channelCount, 2)).map { channel in
        Array(UnsafeBufferPointer(start: data[channel], count: frames))
    }
    return (channels.count == 1 ? [channels[0], channels[0]] : channels, targetRate)
}

/// Write deinterleaved channels as a 44.1 kHz float WAV.
func writeWAV(_ channels: [[Float]], to url: URL, sampleRate: Double) throws {
    guard
        let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: AVAudioChannelCount(channels.count))
    else { fail("could not build an output format") }

    let frames = channels[0].count
    guard
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
    else { fail("could not allocate an output buffer") }
    buffer.frameLength = AVAudioFrameCount(frames)

    for (channelIndex, samples) in channels.enumerated() {
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![channelIndex].update(
                from: source.baseAddress!, count: frames)
        }
    }

    try? FileManager.default.removeItem(at: url)
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
}

// MARK: - Reporting helpers

func rms(_ channels: [[Float]]) -> Double {
    var total = 0.0
    var count = 0
    for channel in channels {
        for sample in channel { total += Double(sample) * Double(sample) }
        count += channel.count
    }
    guard count > 0 else { return 0 }
    return (total / Double(count)).squareRoot()
}

func decibels(_ value: Double) -> String {
    value <= 0 ? "-inf dB" : String(format: "%.2f dB", 20 * log10(value))
}

func peak(_ channels: [[Float]]) -> Double {
    channels.reduce(0.0) { current, channel in
        max(current, channel.reduce(0.0) { max($0, Double(abs($1))) })
    }
}

/// Peak resident set size of this process, in bytes.
func peakResidentBytes() -> UInt64 {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    // Darwin reports ru_maxrss in bytes (Linux uses kilobytes).
    return UInt64(usage.ru_maxrss)
}

func formatBytes(_ bytes: UInt64) -> String {
    String(format: "%.2f GB", Double(bytes) / 1_073_741_824)
}

// MARK: - Run

let semaphore = DispatchSemaphore(value: 0)
nonisolated(unsafe) var exitCode: Int32 = 0

Task {
    defer { semaphore.signal() }
    do {
        let (mixture, sampleRate) = try loadWindow(
            from: inputURL, from: fromSeconds, to: toSeconds)
        let windowSeconds = Double(mixture[0].count) / sampleRate
        print("input      \(inputURL.lastPathComponent)")
        print(
            "window     \(String(format: "%.2f", fromSeconds))s – "
                + "\(String(format: "%.2f", fromSeconds + windowSeconds))s "
                + "(\(String(format: "%.2f", windowSeconds))s, \(mixture[0].count) frames)")

        let store = modelsPath.map { ModelStore(directory: URL(fileURLWithPath: $0)) }
            ?? ModelStore()
        print("models     \(store.directory.path)")

        let loadStart = CFAbsoluteTimeGetCurrent()
        let separator = try await StemSeparator.prepare(modelStore: store) { fraction in
            if fraction >= 1.0 { print("           download complete") }
        }
        let loadSeconds = CFAbsoluteTimeGetCurrent() - loadStart
        print("model      loaded + warmed in \(String(format: "%.2f", loadSeconds))s")
        print("")

        var stems: SeparatedStems?
        for run in 1...repeatCount {
            let result = try await separator.separate(samples: mixture, sampleRate: sampleRate)
            print(
                "run \(run)      \(String(format: "%.2f", result.separationSeconds))s  "
                    + "(\(String(format: "%.2f", result.realtimeFactor))× realtime)")
            stems = result
        }
        guard let stems else { fail("no separation ran") }

        try FileManager.default.createDirectory(
            at: outputURL, withIntermediateDirectories: true)
        try writeWAV(stems.vocals, to: outputURL.appendingPathComponent("vocals.wav"),
            sampleRate: sampleRate)
        try writeWAV(
            stems.accompaniment, to: outputURL.appendingPathComponent("accompaniment.wav"),
            sampleRate: sampleRate)
        try writeWAV(mixture, to: outputURL.appendingPathComponent("mixture.wav"),
            sampleRate: sampleRate)

        let mixtureRMS = rms(mixture)
        print("")
        print("mixture    RMS \(decibels(mixtureRMS))  peak \(decibels(peak(mixture)))")
        print(
            "vocals     RMS \(decibels(rms(stems.vocals)))  peak "
                + "\(decibels(peak(stems.vocals)))  "
                + "ratio \(String(format: "%.3f", rms(stems.vocals) / max(mixtureRMS, 1e-12)))")
        print(
            "accomp.    RMS \(decibels(rms(stems.accompaniment)))  peak "
                + "\(decibels(peak(stems.accompaniment)))")
        print(
            "peak mem   MLX allocator \(formatBytes(UInt64(MLX.Memory.peakMemory)))  "
                + "process RSS \(formatBytes(peakResidentBytes()))")
        print("output     \(outputURL.path)")
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exitCode = 1
    }
}

semaphore.wait()
exit(exitCode)
