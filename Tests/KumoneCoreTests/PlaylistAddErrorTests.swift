import Foundation
import Testing
@testable import KumoneCore

@Suite("Playlist add error classification")
struct PlaylistAddErrorTests {
    @Test("detects Chinese duplicate message")
    func chineseDuplicate() {
        let error = MusicAPIError.business(code: 400, message: "歌曲已存在歌单中")
        #expect(PlaylistAddError.isAlreadyInPlaylist(error))
    }

    @Test("detects English duplicate message")
    func englishDuplicate() {
        let error = MusicAPIError.business(code: 400, message: "song already exists")
        #expect(PlaylistAddError.isAlreadyInPlaylist(error))
    }

    @Test("ignores unrelated business error")
    func unrelated() {
        let error = MusicAPIError.business(code: 400, message: "需要登录")
        #expect(!PlaylistAddError.isAlreadyInPlaylist(error))
    }

    @Test("nil message is not a duplicate")
    func nilMessage() {
        let error = MusicAPIError.business(code: 400, message: nil)
        #expect(!PlaylistAddError.isAlreadyInPlaylist(error))
    }
}
