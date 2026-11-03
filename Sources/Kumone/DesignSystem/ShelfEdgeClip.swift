import SwiftUI

/// Horizontal safe-area insets of the window a shelf is shown in.
///
/// iPhone Duo reserves a column along one edge for the status bar, camera and
/// its vertical tab bar, and iPhone landscape keeps the sensor housing clear.
/// Shelves disable scroll clipping so card shadows survive, which would let
/// cards scrolled past the shelf's end draw straight into that column; with
/// the insets known they clip at the content edge instead.
struct WindowHorizontalInsets: Equatable {
    var leading: CGFloat = 0
    var trailing: CGFloat = 0

    var isZero: Bool { leading == 0 && trailing == 0 }
}

private struct WindowHorizontalInsetsKey: EnvironmentKey {
    static let defaultValue = WindowHorizontalInsets()
}

extension EnvironmentValues {
    var windowHorizontalInsets: WindowHorizontalInsets {
        get { self[WindowHorizontalInsetsKey.self] }
        set { self[WindowHorizontalInsetsKey.self] = newValue }
    }
}

extension View {
    /// Publishes this view's horizontal safe-area insets to the shelves below
    /// it. Apply outside any scroll view, which consumes the safe area.
    func publishesWindowHorizontalInsets() -> some View {
        modifier(WindowHorizontalInsetsPublisher())
    }

    /// Keeps a horizontal shelf inside the content column when the window has
    /// horizontal safe-area insets: the sides are clipped at the shelf's own
    /// edges while the vertical overflow that `scrollClipDisabled` exists for
    /// (shadows, pressed-card scale) stays visible. A no-op elsewhere, where
    /// the shelf already spans the whole window.
    func shelfEdgeClip() -> some View {
        modifier(ShelfEdgeClip())
    }
}

private struct WindowHorizontalInsetsPublisher: ViewModifier {
    @State private var insets = WindowHorizontalInsets()

    func body(content: Content) -> some View {
        content
            .environment(\.windowHorizontalInsets, insets)
            .onGeometryChange(for: WindowHorizontalInsets.self) { proxy in
                WindowHorizontalInsets(leading: proxy.safeAreaInsets.leading,
                                       trailing: proxy.safeAreaInsets.trailing)
            } action: { insets = $0 }
    }
}

private struct ShelfEdgeClip: ViewModifier {
    @Environment(\.windowHorizontalInsets) private var insets

    @ViewBuilder
    func body(content: Content) -> some View {
        if insets.isZero {
            content
        } else {
            content.mask { Rectangle().padding(.vertical, -24) }
        }
    }
}
