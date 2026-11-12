/// Music content on the account's recommendation blacklist.
enum MusicBlacklistTarget: Hashable, Sendable {
    case song(Int)
    case artist(Int)
}
