import AudioToolbox
import AVFoundation
import Foundation
import KumoneAudioDSP

enum SoundEffectPreset: String, CaseIterable, Identifiable, Sendable {
    case original
    case pop
    case rock
    case electronic
    case classical
    case jazz
    case deepBass
    case clearVocal
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .original: return String(localized: "原声")
        case .pop: return String(localized: "流行")
        case .rock: return String(localized: "摇滚")
        case .electronic: return String(localized: "电子")
        case .classical: return String(localized: "古典")
        case .jazz: return String(localized: "爵士")
        case .deepBass: return String(localized: "超重低音")
        case .clearVocal: return String(localized: "清澈人声")
        case .custom: return String(localized: "自定义")
        }
    }

    var systemImage: String {
        switch self {
        case .original: return "waveform"
        case .pop: return "sparkles"
        case .rock: return "guitars.fill"
        case .electronic: return "bolt.fill"
        case .classical: return "music.quarternote.3"
        case .jazz: return "pianokeys"
        case .deepBass: return "speaker.wave.3.fill"
        case .clearVocal: return "mic.fill"
        case .custom: return "slider.vertical.3"
        }
    }

    var effectDescription: String {
        switch self {
        case .original:
            return String(localized: "保留音乐原本的频率与动态")
        case .pop:
            return String(localized: "提亮节奏与旋律，让整体听感更鲜明")
        case .rock:
            return String(localized: "增强低频冲击与高频亮度，突出吉他和鼓点")
        case .electronic:
            return String(localized: "强化低频下潜与空气感，营造更强电子氛围")
        case .classical:
            return String(localized: "保持中频自然，提升乐器层次与空间细节")
        case .jazz:
            return String(localized: "温暖低频并柔和提升高频，突出器乐质感")
        case .deepBass:
            return String(localized: "显著增强低频下潜与弹性，适合强节奏音乐")
        case .clearVocal:
            return String(localized: "收紧低频并抬升中高频，让歌声更靠前")
        case .custom:
            return String(localized: "按照均衡器设置调整各个频段")
        }
    }

    func configuration(custom: EqualizerConfiguration) -> EqualizerConfiguration {
        switch self {
        case .original:
            return .flat
        case .pop:
            return EqualizerConfiguration(gains: [0, 1, 2, 1, -1, -1, 1, 2, 2, 1])
        case .rock:
            return EqualizerConfiguration(gains: [3, 2, 1, -1, -2, -1, 1, 3, 3, 2])
        case .electronic:
            return EqualizerConfiguration(gains: [4, 3, 1, 0, -1, 0, 1, 3, 4, 3])
        case .classical:
            return EqualizerConfiguration(gains: [-1, 0, 0, -1, -1, 0, 1, 2, 3, 3])
        case .jazz:
            return EqualizerConfiguration(gains: [2, 1, 0, 1, -1, -1, 0, 1, 2, 2])
        case .deepBass:
            return EqualizerConfiguration(gains: [6, 5, 4, 2, 0, -1, -2, -2, -1, 0])
        case .clearVocal:
            return EqualizerConfiguration(gains: [-2, -2, -1, 0, 1, 3, 4, 3, 1, 0])
        case .custom:
            return custom
        }
    }
}

struct EqualizerConfiguration: Equatable, Sendable {
    static let frequencies: [Float] = [31, 62, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
    static let gainRange: ClosedRange<Float> = -12...12
    static let bandCount = 10
    static let flat = EqualizerConfiguration(gains: [Float](repeating: 0, count: bandCount))

    let gains: [Float]

    init(gains: [Float]) {
        guard gains.count == Self.bandCount, gains.allSatisfy(\.isFinite) else {
            self.gains = [Float](repeating: 0, count: Self.bandCount)
            return
        }
        self.gains = gains.map { min(max($0, Self.gainRange.lowerBound), Self.gainRange.upperBound) }
    }

    init(storedValues: [Any]?) {
        let values = storedValues?.compactMap { value -> Float? in
            if let number = value as? NSNumber { return number.floatValue }
            return nil
        } ?? []
        self.init(gains: values)
    }

    var storedValues: [Double] { gains.map(Double.init) }

    static func frequencyLabel(at index: Int) -> String {
        guard frequencies.indices.contains(index) else { return "" }
        let frequency = frequencies[index]
        if frequency >= 1_000 {
            let value = frequency / 1_000
            return value.rounded() == value
                ? "\(Int(value))k"
                : String(format: "%.1fk", value)
        }
        return "\(Int(frequency))"
    }
}

struct SoundEffectParameters: Equatable, Sendable {
    let gains: [Float]
    let preampDB: Float
    let isBypassed: Bool

    init(preset: SoundEffectPreset, custom: EqualizerConfiguration) {
        let configuration = preset.configuration(custom: custom)
        gains = configuration.gains
        isBypassed = configuration.gains.allSatisfy { abs($0) < 0.0001 }
        preampDB = isBypassed
            ? 0
            : EqualizerMath.automaticPreampDB(gains: configuration.gains, sampleRate: 48_000)
    }
}

enum SoundEffectPreferences {
    static func preset(from defaults: UserDefaults, key: String) -> SoundEffectPreset {
        defaults.string(forKey: key).flatMap(SoundEffectPreset.init(rawValue:)) ?? .original
    }

    static func customConfiguration(from defaults: UserDefaults, key: String) -> EqualizerConfiguration {
        EqualizerConfiguration(storedValues: defaults.array(forKey: key))
    }

    static func save(preset: SoundEffectPreset, custom: EqualizerConfiguration,
                     to defaults: UserDefaults, presetKey: String, customKey: String) {
        defaults.set(preset.rawValue, forKey: presetKey)
        defaults.set(custom.storedValues, forKey: customKey)
    }
}

enum SoundEffectParameterStore {
    @discardableResult
    static func publish(_ parameters: SoundEffectParameters) -> UInt32 {
        parameters.gains.withUnsafeBufferPointer { gains in
            KumoneEqualizerPublish(gains.baseAddress, parameters.preampDB, parameters.isBypassed)
        }
    }

    static func reset() {
        KumoneEqualizerReset()
    }
}

// MARK: - Real-time equalizer

/// Fixed-storage 10-band equalizer used by the iOS MTAudioProcessingTap.
/// Configuration and allocation happen in `configure`; `process` only reads
/// atomics and mutates preallocated arrays.
final class GraphicEqualizerDSP: @unchecked Sendable {
    private static let smoothingSeconds = 0.08
    private static let epsilon: Float = 0.0001

    private var sampleRate: Double = 44_100
    private var channelCount = 2
    private var isInterleaved = true
    private var currentGains = [Float](repeating: 0, count: EqualizerConfiguration.bandCount)
    private var targetGains = [Float](repeating: 0, count: EqualizerConfiguration.bandCount)
    private var coefficients = [BiquadCoefficients](
        repeating: .identity, count: EqualizerConfiguration.bandCount)
    private var states = [BiquadState](
        repeating: .zero, count: EqualizerConfiguration.bandCount * 2)
    private var currentPreampDB: Float = 0
    private var targetPreampDB: Float = 0
    private var smoothingFramesRemaining = 0
    private var lastRevision = UInt32.max
    private var hasFilterHistory = false

    func configure(format: AudioStreamBasicDescription) {
        let nextSampleRate = format.mSampleRate > 0 ? format.mSampleRate : 44_100
        let nextChannelCount = max(1, Int(format.mChannelsPerFrame))
        sampleRate = nextSampleRate
        channelCount = nextChannelCount
        isInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        states = [BiquadState](
            repeating: .zero, count: EqualizerConfiguration.bandCount * nextChannelCount)
        hasFilterHistory = false
        lastRevision = UInt32.max
        adoptPublishedTarget(force: true)
        for index in currentGains.indices {
            currentGains[index] = targetGains[index]
        }
        currentPreampDB = targetPreampDB
        smoothingFramesRemaining = 0
        rebuildCoefficients()
    }

    func reset() {
        for index in states.indices { states[index] = .zero }
        hasFilterHistory = false
    }

    func process(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frames requestedFrames: Int) {
        guard requestedFrames > 0 else { return }
        adoptPublishedTarget(force: false)
        advanceSmoothing(frames: requestedFrames)

        let transparent = currentGains.allSatisfy { abs($0) < Self.epsilon }
            && abs(currentPreampDB) < Self.epsilon
            && smoothingFramesRemaining == 0
        if transparent {
            if hasFilterHistory { reset() }
            return
        }

        rebuildCoefficients()
        let preamp = powf(10, currentPreampDB / 20)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        if isInterleaved {
            guard let first = buffers.first, let raw = first.mData else { return }
            let availableFloats = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            let channels = min(channelCount, max(1, Int(first.mNumberChannels)))
            let frames = min(requestedFrames, availableFloats / channels)
            let samples = raw.bindMemory(to: Float.self, capacity: availableFloats)
            for channel in 0..<channels {
                processChannel(samples.advanced(by: channel), frames: frames,
                               stride: channels, channel: channel, preamp: preamp)
            }
        } else {
            let channels = min(channelCount, buffers.count)
            for channel in 0..<channels {
                let buffer = buffers[channel]
                guard let raw = buffer.mData else { continue }
                let available = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let frames = min(requestedFrames, available)
                let samples = raw.bindMemory(to: Float.self, capacity: available)
                processChannel(samples, frames: frames, stride: 1,
                               channel: channel, preamp: preamp)
            }
        }
        hasFilterHistory = true
    }

    private func adoptPublishedTarget(force: Bool) {
        var preamp: Float = 0
        var bypassed = true
        let revision = targetGains.withUnsafeMutableBufferPointer { gains in
            KumoneEqualizerLoad(gains.baseAddress, &preamp, &bypassed)
        }
        guard force || revision != lastRevision else { return }
        lastRevision = revision
        if bypassed {
            for index in targetGains.indices { targetGains[index] = 0 }
            targetPreampDB = 0
        } else {
            targetPreampDB = preamp.isFinite ? min(preamp, 0) : 0
        }
        smoothingFramesRemaining = max(1, Int(sampleRate * Self.smoothingSeconds))
    }

    private func advanceSmoothing(frames: Int) {
        guard smoothingFramesRemaining > 0 else { return }
        let step = min(frames, smoothingFramesRemaining)
        let fraction = Float(step) / Float(smoothingFramesRemaining)
        for index in currentGains.indices {
            currentGains[index] += (targetGains[index] - currentGains[index]) * fraction
        }
        currentPreampDB += (targetPreampDB - currentPreampDB) * fraction
        smoothingFramesRemaining -= step
        if smoothingFramesRemaining == 0 {
            for index in currentGains.indices {
                currentGains[index] = targetGains[index]
            }
            currentPreampDB = targetPreampDB
        }
    }

    private func rebuildCoefficients() {
        for index in coefficients.indices {
            let frequency = Double(EqualizerConfiguration.frequencies[index])
            coefficients[index] = frequency < sampleRate * 0.45
                ? EqualizerMath.peakingCoefficients(
                    frequency: frequency, gainDB: Double(currentGains[index]),
                    sampleRate: sampleRate)
                : .identity
        }
    }

    private func processChannel(_ samples: UnsafeMutablePointer<Float>, frames: Int,
                                stride: Int, channel: Int, preamp: Float) {
        guard frames > 0 else { return }
        let stateOffset = channel * EqualizerConfiguration.bandCount
        // Take the arrays' storage once per buffer: indexing the class's array
        // properties inside the per-sample loop would run an exclusivity check
        // and a uniqueness check for every band of every sample.
        coefficients.withUnsafeBufferPointer { coefficients in
            states.withUnsafeMutableBufferPointer { states in
                for frame in 0..<frames {
                    let sampleIndex = frame * stride
                    var value = samples[sampleIndex] * preamp
                    for band in 0..<EqualizerConfiguration.bandCount {
                        let coefficient = coefficients[band]
                        let stateIndex = stateOffset + band
                        var state = states[stateIndex]
                        let output = coefficient.b0 * value + state.z1
                        state.z1 = coefficient.b1 * value - coefficient.a1 * output + state.z2
                        state.z2 = coefficient.b2 * value - coefficient.a2 * output
                        states[stateIndex] = state
                        value = output
                    }
                    samples[sampleIndex] = value
                }
            }
        }
    }
}

struct BiquadCoefficients: Equatable, Sendable {
    let b0: Float
    let b1: Float
    let b2: Float
    let a1: Float
    let a2: Float

    static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)
}

private struct BiquadState {
    var z1: Float
    var z2: Float

    static let zero = BiquadState(z1: 0, z2: 0)
}

enum EqualizerMath {
    static let q = 1.4

    static func peakingCoefficients(frequency: Double, gainDB: Double,
                                    sampleRate: Double) -> BiquadCoefficients {
        guard gainDB.isFinite, abs(gainDB) > 0.000_001,
              frequency > 0, frequency < sampleRate * 0.5 else { return .identity }
        let amplitude = pow(10, gainDB / 40)
        let omega = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(omega) / (2 * q)
        let a0 = 1 + alpha / amplitude
        return BiquadCoefficients(
            b0: Float((1 + alpha * amplitude) / a0),
            b1: Float((-2 * cos(omega)) / a0),
            b2: Float((1 - alpha * amplitude) / a0),
            a1: Float((-2 * cos(omega)) / a0),
            a2: Float((1 - alpha / amplitude) / a0)
        )
    }

    static func automaticPreampDB(gains: [Float], sampleRate: Double) -> Float {
        guard gains.count == EqualizerConfiguration.bandCount,
              gains.contains(where: { $0 > 0 }) else { return 0 }
        let minimumFrequency = 20.0
        let maximumFrequency = min(20_000, sampleRate * 0.45)
        let ratio = maximumFrequency / minimumFrequency
        var peakDB = 0.0
        for point in 0..<256 {
            let fraction = Double(point) / 255
            let frequency = minimumFrequency * pow(ratio, fraction)
            peakDB = max(
                peakDB,
                responseDB(gains: gains, frequency: frequency, sampleRate: sampleRate)
            )
        }
        return peakDB > 0 ? Float(-(peakDB + 0.5)) : 0
    }

    static func responseDB(gains: [Float], frequency: Double, sampleRate: Double) -> Double {
        guard gains.count == EqualizerConfiguration.bandCount,
              frequency > 0, frequency < sampleRate * 0.5 else { return 0 }
        let omega = 2 * Double.pi * frequency / sampleRate
        var response = 0.0
        for index in gains.indices {
            let center = Double(EqualizerConfiguration.frequencies[index])
            guard center < sampleRate * 0.45 else { continue }
            let coefficients = peakingCoefficients(
                frequency: center, gainDB: Double(gains[index]), sampleRate: sampleRate)
            response += magnitudeDB(coefficients, omega: omega)
        }
        return response
    }

    private static func magnitudeDB(_ coefficients: BiquadCoefficients, omega: Double) -> Double {
        let cos1 = cos(omega)
        let sin1 = sin(omega)
        let cos2 = cos(2 * omega)
        let sin2 = sin(2 * omega)
        let numeratorReal = Double(coefficients.b0)
            + Double(coefficients.b1) * cos1 + Double(coefficients.b2) * cos2
        let numeratorImaginary = -Double(coefficients.b1) * sin1
            - Double(coefficients.b2) * sin2
        let denominatorReal = 1 + Double(coefficients.a1) * cos1
            + Double(coefficients.a2) * cos2
        let denominatorImaginary = -Double(coefficients.a1) * sin1
            - Double(coefficients.a2) * sin2
        let numerator = hypot(numeratorReal, numeratorImaginary)
        let denominator = max(hypot(denominatorReal, denominatorImaginary), 1e-12)
        return 20 * log10(max(numerator / denominator, 1e-12))
    }
}
