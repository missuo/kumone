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
    /// Between the sidebar panel and the window's edges.
    static let inset: CGFloat = 8
    /// From the window's leading edge to the page's while the sidebar is
    /// open: the page starts right at the panel's trailing edge.
    static var span: CGFloat { Theme.Layout.sidebarWidth + inset }
    static let panelRadius: CGFloat = 16
    /// From the page's leading edge to its title.
    static let titleInset: CGFloat = 20
    /// From the toggle to the title, when the page runs under the toggle.
    static let titleGapAfterToggle: CGFloat = 14
}

/// The main window's body on macOS: the fixed sidebar panel, and the page
/// over it, whose leading edge slides with `SidebarState`.
struct MacSidebarShell<Sidebar: View, Detail: View, Tint: View>: View {
    @ObservedObject private var state = SidebarState.shared
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
            PageTitleBand()
                .padding(.leading, max(
                    (state.isOpen ? SidebarMetrics.span : 0) + SidebarMetrics.titleInset,
                    state.toggleTrailingEdge + SidebarMetrics.titleGapAfterToggle
                ))
        }
        // The page paints the toolbar's band itself (backdrop, tint, title),
        // so it slides with the page; the toolbar draws nothing of its own.
        .toolbarBackground(.hidden, for: .windowToolbar)
        // The title is the page's own (`PageTitleBand`), so it can sit at
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

/// The page's title, as the window would draw it, but at the page's leading
/// edge in the toolbar's band, so it moves with the page.
private struct PageTitleBand: View {
    @ObservedObject private var title = PageTitle.shared
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        GeometryReader { proxy in
            let band = proxy.safeAreaInsets.top
            Text(verbatim: title.text)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(controlActiveState == .inactive ? .tertiary : .primary)
                .lineLimit(1)
                // Clear of the search field at the trailing end.
                .padding(.trailing, 240)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: band)
                .offset(y: -band)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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

/// The sidebar: a panel inset from the window's leading edge, under the
/// window buttons and the toggle, at a fixed width. It does not move; while
/// it is hidden the page lies over it.
private struct SidebarPanel<Content: View>: View {
    let isOpen: Bool
    let isSliding: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SidebarMetrics.panelRadius, style: .continuous)
        content()
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
            shape
                .fill(.regularMaterial)
                .overlay(shape.strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
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

/// Back to the previous page, in the toolbar after the sidebar toggle.
struct BackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("返回", systemImage: "chevron.backward")
        }
        .keyboardShortcut("[", modifiers: .command)
        .help("返回")
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
