import SwiftUI

/// Downloads that would run on cellular, a hotspot or Low Data Mode ask once
/// before they start. Menus cannot host an alert, so the request is published
/// here and the window roots present it, the way offline playback issues are.
struct MeteredDownloadPrompt: Identifiable {
    let id = UUID()
    let count: Int
    let constrained: Bool
    let run: (Bool) -> Void
}

@MainActor
final class MeteredDownloadCenter: ObservableObject {
    static let shared = MeteredDownloadCenter()

    @Published var prompt: MeteredDownloadPrompt?

    private init() {}

    /// Starts the download right away, or asks first on a metered path.
    func request(bulk: Bool, count: Int, network: DownloadNetworkState, run: @escaping (Bool) -> Void) {
        guard network.needsMeteredConfirmation(bulk: bulk) else { run(true); return }
        prompt = MeteredDownloadPrompt(count: count, constrained: network.constrained, run: run)
    }
}

struct MeteredDownloadAlert: ViewModifier {
    @ObservedObject var center = MeteredDownloadCenter.shared
    var enabled = true

    func body(content: Content) -> some View {
        content.alert(title, isPresented: Binding(get: { enabled && center.prompt != nil }, set: {
            if enabled && !$0 { center.prompt = nil }
        }), presenting: enabled ? center.prompt : nil) { prompt in
            Button("继续下载") { center.prompt = nil; prompt.run(true) }
            Button("等待 Wi-Fi") { center.prompt = nil; prompt.run(false) }
            Button("取消", role: .cancel) { center.prompt = nil }
        } message: { prompt in
            Text("下载 \(prompt.count) 首歌曲可能消耗较多流量")
        }
    }

    private var title: String {
        center.prompt?.constrained == true
            ? String(localized: "当前已开启低数据模式")
            : String(localized: "当前正在使用蜂窝网络或个人热点")
    }
}
