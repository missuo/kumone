import Testing
import Foundation
@testable import KumoneCore

@Suite("Vinyl Record Tests")
struct VinylRecordTests {
    @Test func rotationStateAngleCalculation() {
        var state = RecordRotationState(degreesPerSecond: 20)
        let t0 = Date(timeIntervalSince1970: 1000)

        // Before starting: angle is 0
        #expect(state.currentAngle(at: t0) == 0)
        #expect(!state.isAnimating)

        // Start at t0
        state.start(at: t0)
        #expect(state.isAnimating)

        // After 2.5 seconds: angle should be 50 degrees
        let t1 = Date(timeIntervalSince1970: 1002.5)
        #expect(state.currentAngle(at: t1) == 50.0)

        // Stop at t1
        state.stop(at: t1)
        #expect(!state.isAnimating)
        #expect(state.currentAngle(at: t1) == 50.0)

        // Even after time passes while stopped, angle stays at 50 degrees (no jumping)
        let t2 = Date(timeIntervalSince1970: 1010.0)
        #expect(state.currentAngle(at: t2) == 50.0)

        // Resume at t2: continues smoothly from 50 degrees
        state.start(at: t2)
        #expect(state.isAnimating)
        let t3 = Date(timeIntervalSince1970: 1011.0)
        #expect(state.currentAngle(at: t3) == 70.0)
    }

    @Test func nowPlayingModeCases() {
        #expect(NowPlayingMode.allCases.contains(.vinyl))
        #expect(NowPlayingMode.vinyl.displayName == "黑胶模式")
    }

    @Test func landscapeNowPlayingStyleCases() {
        #expect(LandscapeNowPlayingStyle.allCases == [.classic, .immersive])
        #expect(LandscapeNowPlayingStyle.classic.displayName == "经典双栏")
        #expect(LandscapeNowPlayingStyle.immersive.displayName == "沉浸歌词")
    }
}
