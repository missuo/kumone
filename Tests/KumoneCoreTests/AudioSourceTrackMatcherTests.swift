import Foundation
import Testing
@testable import KumoneCore

@Suite("Audio source track matcher tests")
struct AudioSourceTrackMatcherTests {
    @Test func acceptsMatchingTitleArtistAndDuration() throws {
        let track = try makeTrack(name: "Blue Moon (Live)", artist: "Example Artist", durationMS: 180_000)

        #expect(AudioSourceTrackMatcher.matches(
            track: track,
            title: "Blue Moon - Live",
            artist: "Example Artist / Guest",
            durationMS: 183_000
        ))
    }

    @Test func rejectsWrongArtistVersionOrDuration() throws {
        let track = try makeTrack(name: "Blue Moon (Live)", artist: "Example Artist", durationMS: 180_000)

        #expect(!AudioSourceTrackMatcher.matches(
            track: track,
            title: "Blue Moon (Live)",
            artist: "Another Artist",
            durationMS: 180_000
        ))
        #expect(!AudioSourceTrackMatcher.matches(
            track: track,
            title: "Blue Moon (Remix)",
            artist: "Example Artist",
            durationMS: 180_000
        ))
        #expect(!AudioSourceTrackMatcher.matches(
            track: track,
            title: "Blue Moon (Live)",
            artist: "Example Artist",
            durationMS: 186_000
        ))
    }

    private func makeTrack(name: String, artist: String, durationMS: Int) throws -> Track {
        let data = Data(
            """
            {
              "id": 1,
              "name": "\(name)",
              "ar": [{"id": 2, "name": "\(artist)"}],
              "al": {"id": 3, "name": "Album", "picUrl": null},
              "dt": \(durationMS)
            }
            """.utf8
        )
        return try JSONDecoder().decode(Track.self, from: data)
    }
}
