import SwiftUI

struct SleepTimerMenu: View {
    @ObservedObject private var player: PlayerService
    @ObservedObject private var sleepTimer: SleepTimer

    init(player: PlayerService) {
        _player = ObservedObject(wrappedValue: player)
        _sleepTimer = ObservedObject(wrappedValue: player.sleepTimer)
    }

    var body: some View {
        Menu {
            if let activeStatus {
                Label(activeStatus, systemImage: "timer")
                    .disabled(true)
                Divider()
            }

            ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
                Button(String(localized: "\(minutes) 分钟")) {
                    sleepTimer.schedule(afterMinutes: minutes)
                }
                .disabled(!player.hasCurrentTrack)
            }

            Button {
                sleepTimer.scheduleAtEndOfCurrentTrack()
            } label: {
                Label("当前歌曲结束时停止", systemImage: "music.note")
            }
            .disabled(!player.hasCurrentTrack)

            if sleepTimer.state.isActive {
                Divider()
                Button("取消睡眠定时", role: .destructive) {
                    sleepTimer.cancel()
                }
            }
        } label: {
            Label(menuTitle, systemImage: sleepTimer.state.isActive ? "timer.circle.fill" : "timer")
        }
        .disabled(!player.hasCurrentTrack && !sleepTimer.state.isActive)
    }

    private var menuTitle: String {
        switch sleepTimer.state {
        case .inactive:
            return String(localized: "睡眠定时")
        case .countdown:
            return String.localizedStringWithFormat(
                String(localized: "睡眠定时（剩余 %@）"),
                remainingDuration
            )
        case .endOfCurrentTrack:
            return String(localized: "睡眠定时（本曲结束）")
        }
    }

    private var activeStatus: String? {
        switch sleepTimer.state {
        case .inactive:
            return nil
        case .countdown:
            return String.localizedStringWithFormat(
                String(localized: "剩余 %@"),
                remainingDuration
            )
        case .endOfCurrentTrack:
            return String(localized: "将在当前歌曲结束时停止")
        }
    }

    private var remainingDuration: String {
        guard case .countdown(let deadline) = sleepTimer.state else { return "" }
        return Formatters.duration(max(0, deadline.timeIntervalSinceNow))
    }
}
