import Foundation
import Testing
@testable import KumoneCore

@Suite("Song URL retry")
struct SongURLRetryTests {
    // A request that failed on its way is asked again before third-party
    // sources take the song; a refusal by the service is not.
    @Test func retriesTransientFailuresOnly() {
        #expect(MusicAPI.songURLWorthRetrying(after: URLError(.timedOut)))
        #expect(MusicAPI.songURLWorthRetrying(after: URLError(.networkConnectionLost)))
        #expect(MusicAPI.songURLWorthRetrying(after: MusicAPIError.http(502)))
        #expect(MusicAPI.songURLWorthRetrying(after: MusicAPIError.decoding("truncated")))

        #expect(!MusicAPI.songURLWorthRetrying(after: MusicAPIError.http(400)))
        #expect(!MusicAPI.songURLWorthRetrying(after: MusicAPIError.business(code: -460, message: nil)))
        #expect(!MusicAPI.songURLWorthRetrying(after: MusicAPIError.needLogin))
        #expect(!MusicAPI.songURLWorthRetrying(after: CancellationError()))
        #expect(!MusicAPI.songURLWorthRetrying(after: URLError(.notConnectedToInternet)))
    }
}
