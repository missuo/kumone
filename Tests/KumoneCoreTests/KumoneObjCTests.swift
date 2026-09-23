#if os(macOS)
import AVFoundation
import KumoneObjC
import Testing

/// The engine leans on `KumoneCatchException` to survive AVFAudio's
/// NSExceptions; prove it really catches one rather than trusting the shim.
@Suite struct KumoneObjCTests {
    @Test func catchesAnAVFAudioException() {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        // Never attached: AVFAudio's "required condition is false" raise.
        let exception = KumoneCatchException {
            engine.connect(player, to: engine.mainMixerNode, format: nil)
        }
        #expect(exception?.name.rawValue == "com.apple.coreaudio.avfaudio")
    }

    @Test func returnsNilWhenNothingIsRaised() {
        var ran = false
        #expect(KumoneCatchException { ran = true } == nil)
        #expect(ran)
    }
}
#endif
