import SwiftUI

struct OfflinePlaybackAlert: ViewModifier {
    @ObservedObject var player: PlayerService
    let onDownloads: () -> Void
    var enabled = true

    func body(content: Content) -> some View {
        content.alert(title, isPresented: Binding(get: { enabled && player.offlineIssue != nil }, set: {
            if enabled && !$0 { player.offlineIssue = nil }
        }), presenting: enabled ? player.offlineIssue : nil) { issue in
            if issue.kind == .missingTrack {
                Button("播放下一首离线歌曲") { player.playNextAvailableOffline() }
            }
            Button("查看已下载") { player.offlineIssue = nil; onDownloads() }
            Button("取消", role: .cancel) { player.offlineIssue = nil }
        } message: { issue in
            if let name = issue.trackName {
                Text("《\(name)》尚未完整缓存。连接网络后可重试，或播放队列里已有的离线歌曲。")
            } else {
                Text("当前队列没有可离线播放的歌曲。连接网络后可继续，或前往已下载查看其他歌曲。")
            }
        }
    }

    private var title: String {
        player.offlineIssue?.kind == .emptyQueue ? String(localized: "暂无离线歌曲") : String(localized: "歌曲暂不可离线播放")
    }
}
