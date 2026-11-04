import Foundation
import Testing
@testable import KumoneCore

@Suite("Recommendation Tests")
struct RecommendationTests {
    @Test func decodesReplacementTrack() throws {
        let response = try JSONDecoder().decode(
            MusicAPI.RecommendDislikeResponse.self,
            from: Data("""
            {"data":{"id":2,"name":"Replacement","ar":[],"al":{"id":1,"name":"Album"},"dt":1}}
            """.utf8)
        )

        #expect(response.data.id == 2)
        #expect(response.data.name == "Replacement")
    }

    @Test func rejectsIncompleteReplacementTrack() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                MusicAPI.RecommendDislikeResponse.self,
                from: Data("""
                {"data":{"id":0,"name":" ","ar":[],"al":{"id":1,"name":"Album"},"dt":1}}
                """.utf8)
            )
        }
    }

    @Test func replacementPreservesListIdentity() throws {
        let first = try track(id: 1)
        let rejected = try track(id: 2)
        let replacement = try track(id: 3)
        var tracks = [first, rejected]

        tracks.replaceRecommendation(rejected, with: replacement)

        #expect(tracks.map(\.id) == [1, 3])
    }

    @Test func duplicateReplacementPreservesRejectedTrack() throws {
        let existing = try track(id: 1)
        let rejected = try track(id: 2)
        var tracks = [existing, rejected]

        tracks.replaceRecommendation(rejected, with: existing)

        #expect(tracks.map(\.id) == [1, 2])
    }

    private func track(id: Int) throws -> Track {
        try JSONDecoder().decode(
            Track.self,
            from: Data("""
            {"id":\(id),"name":"Track \(id)","ar":[],"al":{"id":1,"name":"Album"},"dt":1}
            """.utf8)
        )
    }
}
