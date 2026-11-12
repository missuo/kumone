#if os(macOS)
import SwiftUI

/// Whether the main window's sidebar is shown, and whether it is in the
/// middle of showing or hiding.
///
/// The sidebar never moves: it is a fixed panel at the window's leading edge,
/// and the page lies over it. Showing or hiding it slides the page's leading
/// edge — across the sidebar to fill the window, or back to uncover it. This
/// replaces `NavigationSplitView`, whose collapse resized the detail column
/// and laid the whole page out again on every frame, and whose sidebar toggle
/// hopped between the sidebar's and the detail's part of the toolbar.
@MainActor
final class SidebarState: ObservableObject {
    static let shared = SidebarState()

    /// Quick, settling without overshoot.
    static let animation = Animation.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.28)

    @Published private(set) var isOpen = true
    /// True from the start of a slide until a moment after it ends.
    @Published private(set) var isSliding = false
    /// The toggle's trailing edge in the window, so the page's title can
    /// stay clear of it (it moves in full screen, with no window buttons).
    @Published private(set) var toggleTrailingEdge: CGFloat = 0

    func setToggleTrailingEdge(_ x: CGFloat) {
        if abs(toggleTrailingEdge - x) > 0.5 { toggleTrailingEdge = x }
    }

    private var slideEnd: DispatchWorkItem?

    func toggle() {
        beginSlide()
        if Platform.isReduceMotionEnabled {
            isOpen.toggle()
        } else {
            withAnimation(Self.animation) { isOpen.toggle() }
        }
    }

    private func beginSlide() {
        if !isSliding { isSliding = true }
        slideEnd?.cancel()
        let finish = DispatchWorkItem { [weak self] in self?.isSliding = false }
        slideEnd = finish
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34, execute: finish)
    }
}

enum SidebarMetrics {
    /// Liquid Glass floats inside the window; earlier sidebars meet its edges.
    static var inset: CGFloat {
        if #available(macOS 26.0, *) { return 8 }
        return 0
    }
    /// From the window's leading edge to the page's while the sidebar is
    /// open: the page starts right at the panel's trailing edge.
    static var span: CGFloat { Theme.Layout.sidebarWidth + inset }
    static var panelRadius: CGFloat {
        if #available(macOS 26.0, *) { return 16 }
        return 0
    }
    /// Sequoia adds 10pt above source lists outside a system split view.
    static var listTopPadding: CGFloat {
        if #available(macOS 26.0, *) { return 0 }
        return -10
    }
    /// From the page's leading edge to its title.
    static let titleInset: CGFloat = 20
    /// Align the back chevron with the system detail-column navigation.
    static let navigationInset: CGFloat = 14
    /// From the toggle to the title, when the page runs under the toggle.
    static let titleGapAfterToggle: CGFloat = 14
}

/// The main window's body on macOS: the fixed sidebar panel, and the page
/// over it, whose leading edge slides with `SidebarState`.
struct MacSidebarShell<Sidebar: View, Detail: View, Tint: View>: View {
    @ObservedObject private var state = SidebarState.shared
    let goBack: (() -> Void)?
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let detail: () -> Detail
    /// Laid over the page, the toolbar's band included; takes no hits.
    @ViewBuilder let tint: () -> Tint

    var body: some View {
        ZStack(alignment: .topLeading) {
            Platform.windowBackgroundColor
                .ignoresSafeArea()

            SidebarPanel(isOpen: state.isOpen, isSliding: state.isSliding, content: sidebar)

            page
                .padding(.leading, state.isOpen ? SidebarMetrics.span : 0)

            // Where the split view put it: at the page's leading edge, or
            // after the toggle when the page runs under it.
            PageNavigationBand(goBack: goBack)
                .padding(.leading, max(
                    (state.isOpen ? SidebarMetrics.span : 0)
                        + (goBack == nil ? SidebarMetrics.titleInset : SidebarMetrics.navigationInset),
                    state.toggleTrailingEdge + SidebarMetrics.titleGapAfterToggle
                ))
        }
        // The page paints the toolbar's band itself (backdrop, tint, title),
        // so it slides with the page; the toolbar draws nothing of its own.
        .toolbarBackground(.hidden, for: .windowToolbar)
        // The title is the page's own (`PageNavigationBand`), so it can sit at
        // the page's edge; the system one would stay beside the toggle.
        .toolbar(removing: .title)
    }

    private var page: some View {
        ZStack(alignment: .topLeading) {
            // An opaque backdrop of its own, so the page covers the sidebar
            // as its edge slides over it.
            Platform.windowBackgroundColor
                .ignoresSafeArea()
            detail()
                // Pages scroll up to the toolbar's band and no further.
                .mask { BelowToolbarMask() }
                // Nothing on the page can be pointed at while it moves; every
                // frame would otherwise hit-test each hover region again.
                .allowsHitTesting(!state.isSliding)
            tint()
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }
}

/// Opaque below the toolbar's band (the top safe-area inset), clear in it.
private struct BelowToolbarMask: View {
    var body: some View {
        GeometryReader { proxy in
            Color.black
                .padding(.top, proxy.safeAreaInsets.top)
                .ignoresSafeArea()
        }
    }
}

/// Page navigation follows the detail's leading edge in the toolbar band.
private struct PageNavigationBand: View {
    let goBack: (() -> Void)?
    @ObservedObject private var title = PageTitle.shared
    @Environment(\.controlActiveState) private var controlActiveState
    /// Pressed through `ToolbarBandClickTarget`, which the button's own
    /// style never hears about.
    @State private var isBandPressed = false

    var body: some View {
        GeometryReader { proxy in
            let band = proxy.safeAreaInsets.top
            HStack(spacing: 12) {
                if let goBack {
                    Button(action: goBack) {
                        Label("返回", systemImage: "chevron.backward")
                            .labelStyle(.iconOnly)
                            .frame(width: 24, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.interactiveRow)
                    .opacity(isBandPressed ? 0.8 : 1)
                    .background {
                        if #available(macOS 26.0, *) {
                            ToolbarBandClickTarget(action: goBack, isPressed: $isBandPressed)
                        }
                    }
                    .keyboardShortcut("[", modifiers: .command)
                    .help("返回")
                }
                Text(verbatim: title.text)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(controlActiveState == .inactive ? .tertiary : .primary)
                    .lineLimit(1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            // Clear of the search field at the trailing end.
            .padding(.trailing, 240)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: band)
            .offset(y: -band)
        }
    }
}

/// The title SwiftUI gives the main window from the page's
/// `navigationTitle`, which the window itself no longer shows.
@MainActor
final class PageTitle: ObservableObject {
    static let shared = PageTitle()

    @Published private(set) var text = ""

    func update(_ text: String) {
        if self.text != text { self.text = text }
    }
}

/// A fixed sidebar under the window buttons and toggle. The page covers it
/// when hidden; its surface follows the system's sidebar appearance.
private struct SidebarPanel<Content: View>: View {
    let isOpen: Bool
    let isSliding: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SidebarMetrics.panelRadius, style: .continuous)
        content()
            .padding(.top, SidebarMetrics.listTopPadding)
            .frame(width: Theme.Layout.sidebarWidth)
            .frame(maxHeight: .infinity)
            // The account footer paints its own material down to the panel's
            // bottom edge; round it with the panel. The top runs on up under
            // the toolbar, where the background below takes over.
            .clipShape(UnevenRoundedRectangle(
                bottomLeadingRadius: SidebarMetrics.panelRadius,
                bottomTrailingRadius: SidebarMetrics.panelRadius,
                style: .continuous
            ))
            // Up past the toolbar to just under the window's top edge, so the
            // window buttons and the toggle sit on the panel.
            .background {
                panelBackground(shape)
                    .padding(.top, SidebarMetrics.inset)
                    .ignoresSafeArea(.container, edges: .top)
            }
            .padding(.leading, SidebarMetrics.inset)
            .padding(.bottom, SidebarMetrics.inset)
            // Covered by the page while hidden; out of the way once it is.
            .opacity(isOpen || isSliding ? 1 : 0)
            .allowsHitTesting(isOpen && !isSliding)
            .accessibilityHidden(!isOpen)
    }

    @ViewBuilder
    private func panelBackground(_ shape: RoundedRectangle) -> some View {
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(.regular, in: shape)
        } else {
            SidebarBackdrop()
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: 1)
                }
        }
    }
}

/// The sidebar material samples the desktop, including the system's inactive
/// appearance and accessibility contrast/transparency settings.
private struct SidebarBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// macOS 26's window toolbar claims every click in its band, so a button the
/// page draws there sees the pointer hover but never a click (Sequoia lets
/// the click through). This catches the clicks over the button's own frame
/// before the toolbar does; hover, VoiceOver and ⌘[ stay the button's.
private struct ToolbarBandClickTarget: NSViewRepresentable {
    let action: () -> Void
    @Binding var isPressed: Bool

    func makeNSView(context: Context) -> ClickTargetView { ClickTargetView() }

    func updateNSView(_ view: ClickTargetView, context: Context) {
        view.onClick = action
        view.onPress = { pressed in
            if isPressed != pressed { isPressed = pressed }
        }
    }

    static func dismantleNSView(_ view: ClickTargetView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class ClickTargetView: NSView {
        var onClick: () -> Void = {}
        var onPress: (Bool) -> Void = { _ in }
        private var monitor: Any?
        private var isTracking = false

        /// Never the target of a hit itself: the button below keeps hover.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            ) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            if isTracking {
                isTracking = false
                onPress(false)
            }
        }

        private func isInside(_ event: NSEvent) -> Bool {
            guard let window, event.window === window, !isHiddenOrHasHiddenAncestor else { return false }
            return bounds.contains(convert(event.locationInWindow, from: nil))
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            switch event.type {
            case .leftMouseDown:
                // A sheet over the window owns its clicks.
                guard window?.attachedSheet == nil, isInside(event) else { return event }
                isTracking = true
                onPress(true)
                return nil
            case .leftMouseDragged:
                guard isTracking else { return event }
                onPress(isInside(event))
                return nil
            case .leftMouseUp:
                guard isTracking else { return event }
                isTracking = false
                onPress(false)
                // Released outside, like any button: nothing happens.
                if isInside(event) { onClick() }
                return nil
            default:
                return event
            }
        }
    }
}

/// Shows and hides the sidebar from the start of the toolbar, beside the
/// window buttons, where it stays whether the sidebar is open or not.
struct SidebarToggleButton: View {
    var body: some View {
        Button {
            SidebarState.shared.toggle()
        } label: {
            Label("显示或隐藏边栏", systemImage: "sidebar.leading")
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .global).maxX
        } action: { x in
            SidebarState.shared.setToggleTrailingEdge(x)
        }
        .help("显示或隐藏边栏 (⌃⌘S)")
    }
}

/// View ▸ Show/Hide Sidebar, ⌃⌘S — what `NavigationSplitView` used to add.
struct SidebarCommandButton: View {
    @ObservedObject private var state = SidebarState.shared

    var body: some View {
        Button(state.isOpen ? String(localized: "隐藏边栏") : String(localized: "显示边栏")) {
            state.toggle()
        }
        .keyboardShortcut("s", modifiers: [.command, .control])
    }
}
#endif
