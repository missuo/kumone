import AVKit
import Combine
import SwiftUI

/// System AirPlay / output-route picker (`AVRoutePickerView`), styled to sit
/// among the transport controls. Because playback is audio-only (AVPlayer with
/// no video track), selecting a route sends audio to the device — it does not
/// mirror the screen.
struct RoutePickerButton: View {
    var diameter: CGFloat = 40
    var glyphSize: CGFloat = 15
    var request = 0
    /// White-on-glass (now-playing) vs. accent-aware (player bar).
    var tint: Color = .white.opacity(0.8)
    var background: Color = .white.opacity(0.1)

    var body: some View {
        #if os(macOS)
        // macOS shows an in-app output-device picker instead of the system
        // one: `AVRoutePickerView` on the Mac routes an `AVPlayer` /
        // `AVSampleBufferAudioRenderer`, and macOS playback is an
        // AVAudioEngine graph with no AVPlayer since the dual-deck engine
        // landed, so that button was inert — selecting an AirPlay speaker did
        // nothing at all. The Mac equivalent is choosing the CoreAudio output
        // device the engine renders to; see `AudioOutputDevices`. `request`
        // is iOS-only (it opens the system route sheet programmatically).
        OutputDevicePicker(
            diameter: diameter, glyphSize: glyphSize, tint: tint, background: background)
        #else
        RoutePickerRepresentable(
            tint: PlatformColor(tint), glyphSize: glyphSize, request: request
        )
            .frame(width: diameter, height: diameter)
            .background(background, in: Circle())
            .help("AirPlay")
        #endif
    }
}

#if os(iOS)
private struct RoutePickerRepresentable: UIViewRepresentable {
    let tint: UIColor
    let glyphSize: CGFloat
    let request: Int

    final class Coordinator {
        var request: Int
        init(request: Int) { self.request = request }
    }

    func makeCoordinator() -> Coordinator { Coordinator(request: request) }

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.backgroundColor = .clear
        view.tintColor = tint
        view.activeTintColor = UIColor(Theme.accent)
        view.prioritizesVideoDevices = false // audio routing, not screen mirroring
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        view.tintColor = tint
        guard request != context.coordinator.request else { return }
        context.coordinator.request = request
        DispatchQueue.main.async {
            view.subviews.compactMap { $0 as? UIButton }.first?
                .sendActions(for: .touchUpInside)
        }
    }
}
#elseif os(macOS)
import AppKit

/// macOS output picker: a popover modelled on Control Centre's Sound module.
///
/// ```
/// 输出设备
/// (◉) 系统默认                  ✓     ← follows macOS; subtitle = what it resolves to
///     Mac mini 扬声器
/// 此 Mac
/// (◯) Mac mini 扬声器                 ← built-in speakers / headphone jack
/// 外接设备
/// (◯) OF27UT Pro   HDMI               ← wired, then Bluetooth
/// 虚拟设备                              ← only when there are any
/// AirPlay
///     AirPlay 音箱需先在控制中心…        ← hint, only when none are listed
/// ─────────
/// 声音设置…                            ← System Settings › Sound
/// ```
///
/// A popover rather than a `Menu`: a menu cannot carry the explanatory hint
/// for the empty AirPlay section, a two-line row ("系统默认" over the device
/// it resolves to) or icon wells, and the player bar already hosts a popover
/// (`VolumeControl`) without focus or dismissal trouble. Rows are listed
/// from `AudioOutputDevices.sections`, which only ever contains devices that
/// can actually be selected.
///
/// "系统默认" is not a device — it follows whatever macOS is routing to, which
/// is also how an AirPlay receiver picked in Control Centre reaches Kumone.
struct OutputDevicePicker: View {
    var diameter: CGFloat = 40
    var glyphSize: CGFloat = 15
    var tint: Color = .white.opacity(0.8)
    var background: Color = .white.opacity(0.1)

    @ObservedObject private var controller = AudioOutputController.shared
    @State private var isPresented = false
    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "airplayaudio")
                .font(.system(size: glyphSize, weight: .medium))
                .foregroundStyle(controller.isRoutedAway ? Theme.accent : tint)
                .frame(width: diameter, height: diameter)
                .background { chrome }
                .contentShape(Circle())
        }
        .buttonStyle(.pressable)
        .frame(width: diameter, height: diameter)
        .onHover { isHovering = $0 }
        .animation(AppAnimation.quick, value: isHovering)
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            OutputDevicePanel(controller: controller) { isPresented = false }
        }
        .help("输出设备：\(controller.currentDisplayName)")
        .accessibilityLabel("输出设备")
        .accessibilityValue(controller.currentDisplayName)
    }

    /// Bare in the player bar (hover fill shaped like its `PlayerIconButton`
    /// neighbours), a filled circle on the now-playing glass.
    @ViewBuilder private var chrome: some View {
        let lit = isHovering || isPresented
        if background == .clear {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill((colorScheme == .dark ? Color.white : .black).opacity(lit ? 0.08 : 0))
        } else {
            Circle()
                .fill(background)
                .overlay(Circle().fill(Color.white.opacity(lit ? 0.08 : 0)))
        }
    }
}

/// The popover body. Hover and the arrow keys share one highlight, the way a
/// native menu does; Return / Space picks the highlighted row, Esc closes
/// (the popover's own behaviour), and any pick closes it.
private struct OutputDevicePanel: View {
    @ObservedObject var controller: AudioOutputController
    let dismiss: () -> Void

    /// Keyboard highlight only. Hover lives inside each row (see `PanelRow`),
    /// so moving the mouse across the list invalidates one row rather than
    /// the whole panel.
    @State private var highlighted: Row?
    /// Grouped once per device-list change instead of once per body pass:
    /// `sections` dedupes, sorts and runs four filters.
    @State private var sections: [AudioOutputSection] = []
    /// Which row the mouse is over, for the arrow keys to start from. A plain
    /// reference on purpose — writing it must not invalidate anything.
    @State private var hovered = HoveredRow()
    @FocusState private var focused: Bool

    enum Row: Hashable {
        case systemDefault
        case device(uid: String)
        case soundSettings
    }

    final class HoveredRow {
        var row: Row?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("输出设备")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)

            deviceRow(
                .systemDefault,
                title: Text("系统默认"),
                subtitle: controller.systemDefaultName.map { Text(verbatim: $0) }
                    ?? Text("跟随系统设置"),
                symbol: "speaker.wave.2",
                isSelected: controller.selection == .systemDefault)

            ForEach(sections, id: \.group) { section in
                sectionHeader(section.group)
                ForEach(section.devices) { device in
                    deviceRow(
                        .device(uid: device.uid),
                        title: Text(verbatim: device.name),
                        subtitle: device.kind.transportLabel,
                        symbol: device.symbolName,
                        isSelected: controller.selection == .device(uid: device.uid))
                }
                if section.group == .airPlay, section.devices.isEmpty {
                    Text("AirPlay 音箱需先在控制中心或“声音”设置中选择一次，才会出现在这里")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                }
            }

            Divider()
                .padding(.horizontal, 14)
                .padding(.vertical, 6)

            settingsRow
        }
        .padding(.bottom, 6)
        .frame(width: 290)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.downArrow) { move(by: 1, in: sections); return .handled }
        .onKeyPress(.upArrow) { move(by: -1, in: sections); return .handled }
        .onKeyPress(.return) { activateHighlighted() }
        .onKeyPress(.space) { activateHighlighted() }
        .onReceive(controller.$devices) { sections = AudioOutputDevices.sections($0) }
        .onAppear {
            sections = AudioOutputDevices.sections(controller.devices)
            controller.refresh()
            focused = true
        }
    }

    // MARK: Rows

    private func sectionHeader(_ group: AudioOutputGroup) -> some View {
        Text(group.title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    private func deviceRow(
        _ row: Row, title: Text, subtitle: Text?, symbol: String, isSelected: Bool
    ) -> some View {
        PanelRow(isHighlighted: highlighted == row,
                 onHover: { hover(row, $0) },
                 action: { pick(row) }) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(isSelected ? AnyShapeStyle(Theme.accent)
                                         : AnyShapeStyle(Color.primary.opacity(0.1)))
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white)
                                                    : AnyShapeStyle(.primary))
                }
                .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 1) {
                    title
                        .font(.system(size: 13))
                        .lineLimit(1)
                    if let subtitle {
                        subtitle
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var settingsRow: some View {
        PanelRow(isHighlighted: highlighted == .soundSettings,
                 onHover: { hover(.soundSettings, $0) },
                 action: { pick(.soundSettings) }) {
            HStack {
                Text("声音设置…")
                    .font(.system(size: 13))
                Spacer()
            }
        }
        .accessibilityHint("打开系统设置中的“声音”")
    }

    // MARK: Interaction

    /// The mouse taking over clears the keyboard highlight, so exactly one row
    /// is ever lit — but only when there *is* one to clear, which keeps an
    /// ordinary mouse move free of any panel-level state write.
    private func hover(_ row: Row, _ inside: Bool) {
        if inside {
            hovered.row = row
            if highlighted != nil { highlighted = nil }
        } else if hovered.row == row {
            hovered.row = nil
        }
    }

    private func rows(in sections: [AudioOutputSection]) -> [Row] {
        [.systemDefault]
            + sections.flatMap { $0.devices.map { Row.device(uid: $0.uid) } }
            + [.soundSettings]
    }

    /// The first arrow press starts from the checked row, as a native menu
    /// opened on its current value would.
    private func move(by step: Int, in sections: [AudioOutputSection]) {
        let all = rows(in: sections)
        let current = highlighted ?? hovered.row
        let anchor: Row = current ?? {
            switch controller.selection {
            case .systemDefault: return .systemDefault
            case .device(let uid): return .device(uid: uid)
            }
        }()
        guard let index = all.firstIndex(of: anchor) else {
            highlighted = all.first
            return
        }
        if current == nil {
            highlighted = anchor
            return
        }
        highlighted = all[min(max(index + step, 0), all.count - 1)]
    }

    private func activateHighlighted() -> KeyPress.Result {
        guard let highlighted else { return .ignored }
        pick(highlighted)
        return .handled
    }

    private func pick(_ row: Row) {
        dismiss()
        switch row {
        case .systemDefault:
            select(.systemDefault)
        case .device(let uid):
            select(.device(uid: uid))
        case .soundSettings:
            SoundSettings.open()
        }
    }

    /// Re-picking the current row is a no-op here: `select` always re-points
    /// the engine, which is an audible rebuild for nothing.
    private func select(_ selection: AudioOutputSelection) {
        guard selection != controller.selection else { return }
        controller.select(selection)
    }
}

/// One row of the panel, owning its own hover state.
///
/// The hover highlight used to live on the panel, so a mouse move across the
/// list re-evaluated every row's body — including the grouping pass and each
/// row's `AnyShapeStyle`s. Here it invalidates this row and nothing else.
private struct PanelRow<Content: View>: View {
    let isHighlighted: Bool
    let onHover: (Bool) -> Void
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            content()
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                        .fill(Color.primary.opacity(isHovered || isHighlighted ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { inside in
            isHovered = inside
            onHover(inside)
        }
    }
}

private extension AudioOutputGroup {
    var title: LocalizedStringKey {
        switch self {
        case .thisMac: return "此 Mac"
        case .external: return "外接设备"
        case .virtual: return "虚拟设备"
        case .airPlay: return "AirPlay"
        }
    }
}

private extension AudioOutputKind {
    /// The picker's secondary line — the "类型" column of System Settings ›
    /// Sound, for the sections whose header does not already say it.
    var transportLabel: Text? {
        switch self {
        case .bluetooth: return Text("蓝牙")
        case .usb: return Text(verbatim: "USB")
        case .hdmi: return Text(verbatim: "HDMI")
        case .displayPort: return Text(verbatim: "DisplayPort")
        case .thunderbolt: return Text(verbatim: "Thunderbolt")
        case .virtual: return Text("虚拟")
        case .aggregate: return Text("聚合")
        case .builtInSpeakers, .builtInHeadphones, .airPlay, .other: return nil
        }
    }
}

/// System Settings › Sound. The extension ID is what the Sound pane
/// registers on macOS 13+ (`/System/Library/ExtensionKit/Extensions/
/// Sound.appex`, `CFBundleIdentifier` = `com.apple.Sound-Settings.extension`);
/// the legacy prefPane ID is kept as a fallback, then System Settings itself.
@MainActor
enum SoundSettings {
    static let urls = [
        "x-apple.systempreferences:com.apple.Sound-Settings.extension",
        "x-apple.systempreferences:com.apple.preference.sound",
    ]

    static func open() {
        for string in urls {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
        if let app = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.systempreferences") {
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        }
    }
}
#endif
