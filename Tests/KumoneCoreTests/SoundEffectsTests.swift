import AudioToolbox
import Foundation
import KumoneAudioDSP
import Testing
@testable import KumoneCore

@Suite("iOS sound effects", .serialized)
struct SoundEffectsTests {
    private let expectedCurves: [SoundEffectPreset: [Float]] = [
        .original: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        .pop: [0, 1, 2, 1, -1, -1, 1, 2, 2, 1],
        .rock: [3, 2, 1, -1, -2, -1, 1, 3, 3, 2],
        .electronic: [4, 3, 1, 0, -1, 0, 1, 3, 4, 3],
        .classical: [-1, 0, 0, -1, -1, 0, 1, 2, 3, 3],
        .jazz: [2, 1, 0, 1, -1, -1, 0, 1, 2, 2],
        .deepBass: [6, 5, 4, 2, 0, -1, -2, -2, -1, 0],
        .clearVocal: [-2, -2, -1, 0, 1, 3, 4, 3, 1, 0],
    ]

    @Test func presetOrderFrequenciesAndCurvesAreStable() {
        #expect(SoundEffectPreset.allCases == [
            .original, .pop, .rock, .electronic, .classical,
            .jazz, .deepBass, .clearVocal, .custom,
        ])
        #expect(EqualizerConfiguration.frequencies == [
            31, 62, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000,
        ])
        let custom = EqualizerConfiguration(gains: [Float](repeating: -7, count: 10))
        for (preset, curve) in expectedCurves {
            #expect(preset.configuration(custom: custom).gains == curve)
        }
        #expect(SoundEffectPreset.custom.configuration(custom: custom) == custom)
    }

    @Test func invalidConfigurationsRecoverAndFiniteValuesAreClamped() {
        #expect(EqualizerConfiguration(gains: []).gains == EqualizerConfiguration.flat.gains)
        #expect(EqualizerConfiguration(gains: [Float](repeating: 1, count: 9)).gains
            == EqualizerConfiguration.flat.gains)
        var invalid = [Float](repeating: 0, count: 10)
        invalid[3] = .nan
        #expect(EqualizerConfiguration(gains: invalid).gains == EqualizerConfiguration.flat.gains)
        invalid[3] = .infinity
        #expect(EqualizerConfiguration(gains: invalid).gains == EqualizerConfiguration.flat.gains)

        let clamped = EqualizerConfiguration(gains: [-20, 20] + [Float](repeating: 0, count: 8))
        #expect(clamped.gains[0] == -12)
        #expect(clamped.gains[1] == 12)
    }

    @Test func preferencesRoundTripAndRejectDamagedDefaults() throws {
        let suite = "SoundEffectsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let custom = EqualizerConfiguration(gains: [-12, -9, -6, -3, 0, 3, 6, 9, 11, 12])

        SoundEffectPreferences.save(
            preset: .custom, custom: custom, to: defaults,
            presetKey: "preset", customKey: "custom")

        #expect(SoundEffectPreferences.preset(from: defaults, key: "preset") == .custom)
        #expect(SoundEffectPreferences.customConfiguration(from: defaults, key: "custom") == custom)

        defaults.set("removed-preset", forKey: "preset")
        defaults.set([0, 1, 2], forKey: "custom")
        #expect(SoundEffectPreferences.preset(from: defaults, key: "preset") == .original)
        #expect(SoundEffectPreferences.customConfiguration(from: defaults, key: "custom") == .flat)
    }

    @Test func automaticPreampKeepsTheModeledPeakBelowMinusHalfDB() {
        let sampleRate = 48_000.0
        #expect(EqualizerMath.automaticPreampDB(
            gains: EqualizerConfiguration.flat.gains, sampleRate: sampleRate) == 0)

        for curve in expectedCurves.values where curve.contains(where: { $0 > 0 }) {
            let preamp = Double(EqualizerMath.automaticPreampDB(
                gains: curve, sampleRate: sampleRate))
            var modeledPeak = -Double.infinity
            for point in 0..<256 {
                let fraction = Double(point) / 255
                let frequency = 20 * pow((20_000.0 / 20), fraction)
                modeledPeak = max(modeledPeak, EqualizerMath.responseDB(
                    gains: curve, frequency: frequency, sampleRate: sampleRate) + preamp)
            }
            #expect(modeledPeak <= -0.49)
        }
    }

    @Test func originalIsBitTransparentForSupportedPCMLayouts() {
        SoundEffectParameterStore.publish(SoundEffectParameters(
            preset: .original, custom: .flat))
        for sampleRate in [44_100.0, 48_000.0] {
            for channelCount in [1, 2] {
                for interleaved in [false, true] {
                    var channels = (0..<channelCount).map { channel in
                        (0..<512).map { frame in
                            Float(channel + 1) * 0.1 * sinf(2 * .pi * 997 * Float(frame) / Float(sampleRate))
                        }
                    }
                    let original = channels
                    let dsp = GraphicEqualizerDSP()
                    dsp.configure(format: pcmFormat(
                        sampleRate: sampleRate, channels: channelCount, interleaved: interleaved))
                    process(dsp, channels: &channels, interleaved: interleaved)
                    #expect(channels == original)
                }
            }
        }
    }

    @Test func impulseResponseMatchesEveryPresetAcrossAllTenBands() {
        let sampleRate = 48_000.0
        let frameCount = 65_536
        for preset in SoundEffectPreset.allCases where preset != .custom && preset != .original {
            let parameters = SoundEffectParameters(preset: preset, custom: .flat)
            SoundEffectParameterStore.publish(parameters)
            let dsp = GraphicEqualizerDSP()
            dsp.configure(format: pcmFormat(sampleRate: sampleRate, channels: 1, interleaved: true))
            var channels = [[Float](repeating: 0, count: frameCount)]
            channels[0][0] = 1
            process(dsp, channels: &channels, interleaved: true)

            for frequency in EqualizerConfiguration.frequencies {
                let measured = responseDB(
                    impulse: channels[0], frequency: Double(frequency), sampleRate: sampleRate)
                let expected = EqualizerMath.responseDB(
                    gains: parameters.gains, frequency: Double(frequency), sampleRate: sampleRate)
                    + Double(parameters.preampDB)
                #expect(abs(measured - expected) <= 0.75,
                        "\(preset.rawValue) at \(frequency) Hz: \(measured) vs \(expected)")
            }
            #expect(channels[0].allSatisfy { $0.isFinite })
        }
    }

    @Test func smoothingConvergesWithoutNonFiniteSamplesOrRunawayPeaks() {
        SoundEffectParameterStore.publish(SoundEffectParameters(
            preset: .original, custom: .flat))
        let dsp = GraphicEqualizerDSP()
        dsp.configure(format: pcmFormat(sampleRate: 48_000, channels: 2, interleaved: false))
        SoundEffectParameterStore.publish(SoundEffectParameters(
            preset: .deepBass, custom: .flat))

        var largest: Float = 0
        for block in 0..<24 {
            var channels = (0..<2).map { channel in
                (0..<256).map { frame in
                    0.2 * sinf(2 * .pi * Float(80 + channel * 920)
                        * Float(block * 256 + frame) / 48_000)
                }
            }
            process(dsp, channels: &channels, interleaved: false)
            for sample in channels.joined() {
                #expect(sample.isFinite)
                largest = max(largest, abs(sample))
            }
        }
        #expect(largest < 1)

        SoundEffectParameterStore.publish(SoundEffectParameters(
            preset: .original, custom: .flat))
        for _ in 0..<20 {
            var silence = [[Float](repeating: 0, count: 256), [Float](repeating: 0, count: 256)]
            process(dsp, channels: &silence, interleaved: false)
        }
        var probe = [[Float](repeating: 0.125, count: 256), [Float](repeating: -0.125, count: 256)]
        let expected = probe
        process(dsp, channels: &probe, interleaved: false)
        #expect(probe == expected)
    }

    @Test func atomicBridgeSurvivesOneWriterAndConcurrentReaders() async {
        KumoneEqualizerReset()
        let readerSucceeded = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            group.addTask {
                for iteration in 0..<20_000 {
                    let value = Float(iteration % 25 - 12)
                    var gains = [Float](repeating: value, count: 10)
                    _ = gains.withUnsafeMutableBufferPointer {
                        KumoneEqualizerPublish($0.baseAddress, -abs(value), false)
                    }
                }
                return true
            }
            for _ in 0..<3 {
                group.addTask {
                    for _ in 0..<20_000 {
                        var gains = [Float](repeating: 0, count: 10)
                        var preamp: Float = 0
                        var bypassed = true
                        gains.withUnsafeMutableBufferPointer {
                            _ = KumoneEqualizerLoad($0.baseAddress, &preamp, &bypassed)
                        }
                        guard gains.allSatisfy({ $0.isFinite && (-12...12).contains($0) }),
                              preamp.isFinite, preamp <= 0 else { return false }
                    }
                    return true
                }
            }
            for await result in group where !result { return false }
            return true
        }
        #expect(readerSucceeded)
    }

    private func pcmFormat(sampleRate: Double, channels: Int,
                           interleaved: Bool) -> AudioStreamBasicDescription {
        let flags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
            | (interleaved ? 0 : kAudioFormatFlagIsNonInterleaved)
        let bytesPerFrame = UInt32(MemoryLayout<Float>.size * (interleaved ? channels : 1))
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: flags,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0)
    }

    private func process(_ dsp: GraphicEqualizerDSP, channels: inout [[Float]],
                         interleaved: Bool) {
        let frameCount = channels[0].count
        if interleaved {
            var samples = [Float](repeating: 0, count: frameCount * channels.count)
            for frame in 0..<frameCount {
                for channel in channels.indices {
                    samples[frame * channels.count + channel] = channels[channel][frame]
                }
            }
            samples.withUnsafeMutableBufferPointer { pointer in
                var list = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: UInt32(channels.count),
                        mDataByteSize: UInt32(pointer.count * MemoryLayout<Float>.size),
                        mData: UnsafeMutableRawPointer(pointer.baseAddress)))
                dsp.process(&list, frames: frameCount)
            }
            for frame in 0..<frameCount {
                for channel in channels.indices {
                    channels[channel][frame] = samples[frame * channels.count + channel]
                }
            }
            return
        }

        let list = AudioBufferList.allocate(maximumBuffers: channels.count)
        var storage: [UnsafeMutablePointer<Float>] = []
        defer {
            for pointer in storage { pointer.deallocate() }
            list.unsafeMutablePointer.deallocate()
        }
        for channel in channels.indices {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
            for frame in 0..<frameCount { pointer[frame] = channels[channel][frame] }
            storage.append(pointer)
            list[channel] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(frameCount * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(pointer))
        }
        dsp.process(list.unsafeMutablePointer, frames: frameCount)
        for channel in channels.indices {
            for frame in 0..<frameCount { channels[channel][frame] = storage[channel][frame] }
        }
    }

    private func responseDB(impulse: [Float], frequency: Double, sampleRate: Double) -> Double {
        let omega = 2 * Double.pi * frequency / sampleRate
        var real = 0.0
        var imaginary = 0.0
        for (index, sample) in impulse.enumerated() {
            real += Double(sample) * cos(omega * Double(index))
            imaginary -= Double(sample) * sin(omega * Double(index))
        }
        return 20 * log10(max(hypot(real, imaginary), 1e-12))
    }
}
