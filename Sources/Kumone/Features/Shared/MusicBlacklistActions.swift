import SwiftUI

struct TrackBlacklistMenu: View {
    let track: Track
    var showsIcons = false
    @EnvironmentObject private var account: AccountStore

    var body: some View {
        if account.authenticatedAccountID != nil, track.id > 0, !track.isCloud {
            Menu {
                MusicBlacklistButton(target: .song(track.id), title: "这首歌")
                ForEach(track.artists.filter { $0.id > 0 && !$0.name.isEmpty }) { artist in
                    MusicBlacklistButton(target: .artist(artist.id), title: "音乐人：\(artist.name)")
                }
            } label: {
                if showsIcons {
                    Label("减少推荐", systemImage: "hand.thumbsdown")
                } else {
                    Text("减少推荐")
                }
            }
        }
    }
}

/// Shared by song menus and artist pages; only an in-flight request is local state.
struct MusicBlacklistButton: View {
    let target: MusicBlacklistTarget
    let title: LocalizedStringKey
    @State private var pendingTargets: Set<MusicBlacklistTarget> = []

    var body: some View {
        Button(title) {
            let target = target
            guard pendingTargets.insert(target).inserted else { return }
            Task { @MainActor in
                defer { pendingTargets.remove(target) }
                do {
                    try await MusicAPI.addToMusicBlacklist(target)
                    ToastCenter.shared.show(String(localized: "已加入音乐黑名单"))
                } catch is CancellationError {
                    return
                } catch {
                    ToastCenter.shared.show(error.localizedDescription)
                }
            }
        }
        .disabled(pendingTargets.contains(target))
    }
}
