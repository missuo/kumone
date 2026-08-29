#if os(macOS)
import AppKit

/// Dock icon menu (right-click / long-press on the Dock tile).
///
/// AppKit asks for this menu each time it is opened, so it is rebuilt from
/// the player's current state rather than kept in sync. Layout follows what
/// Spotify and Music put there: transport controls, shuffle / repeat state,
/// and recently played tracks.
@MainActor
final class DockMenu: NSObject, NSMenuDelegate {
    static let shared = DockMenu()

    private let player = PlayerService.shared

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        // The Dock menu is not in the responder chain, so nothing would
        // validate the items for us.
        menu.autoenablesItems = false

        add(to: menu,
            title: player.isPlaying ? String(localized: "暂停") : String(localized: "播放"),
            action: #selector(togglePlayPause),
            enabled: player.hasCurrentTrack)
        menu.addItem(.separator())

        add(to: menu, title: String(localized: "下一首"),
            action: #selector(next), enabled: player.hasCurrentTrack)
        add(to: menu, title: String(localized: "上一首"),
            action: #selector(previous), enabled: player.hasCurrentTrack)
        menu.addItem(.separator())

        let shuffle = add(to: menu, title: String(localized: "随机播放"),
                          action: #selector(toggleShuffle), enabled: true)
        shuffle.state = player.shuffleEnabled ? .on : .off

        if player.autoMixOrderAvailable {
            let autoMix = add(to: menu, title: String(localized: "AutoMix 顺序"),
                              action: #selector(toggleAutoMixOrder), enabled: true)
            autoMix.state = player.queueOrder == .autoMix ? .on : .off
        }

        // Three-way repeat reads better as a submenu than as one checkmark.
        let repeatItem = NSMenuItem(title: String(localized: "循环模式"),
                                    action: nil, keyEquivalent: "")
        let repeatMenu = NSMenu()
        repeatMenu.autoenablesItems = false
        for mode in RepeatMode.allCases {
            let item = add(to: repeatMenu, title: mode.menuTitle,
                           action: #selector(setRepeatMode(_:)), enabled: true)
            item.representedObject = mode.rawValue
            item.state = player.repeatMode == mode ? .on : .off
        }
        repeatItem.submenu = repeatMenu
        menu.addItem(repeatItem)

        if !player.recentContexts.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: String(localized: "最近播放"),
                                    action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            for context in player.recentContexts {
                let item = add(to: menu, title: context.name,
                               action: #selector(playRecent(_:)), enabled: true)
                item.representedObject = context
                item.indentationLevel = 1
            }
        }

        return menu
    }

    @discardableResult
    private func add(to menu: NSMenu, title: String, action: Selector, enabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
        return item
    }

    // MARK: - Actions

    @objc private func togglePlayPause() { player.togglePlayPause() }
    @objc private func next() { player.next() }
    @objc private func previous() { player.previous() }
    @objc private func toggleShuffle() { player.toggleShuffle() }
    @objc private func toggleAutoMixOrder() { player.toggleAutoMixOrder() }

    @objc private func setRepeatMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = RepeatMode(rawValue: raw) else { return }
        player.repeatMode = mode
    }

    @objc private func playRecent(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? PlayContext else { return }
        player.play(context: context)
    }
}

private extension RepeatMode {
    var menuTitle: String {
        switch self {
        case .off: return String(localized: "不循环")
        case .all: return String(localized: "列表循环")
        case .one: return String(localized: "单曲循环")
        }
    }
}
#endif
