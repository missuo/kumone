import Combine
import Foundation

/// Whether the main window is actually on screen.
///
/// The now-playing page runs several per-frame animations — the spinning
/// vinyl, the tonearm's wobble, the karaoke wipe. SwiftUI keeps their
/// `TimelineView`s ticking while the window is miniaturised, hidden by the
/// close interceptor or fully occluded, burning CPU on frames nobody can see.
/// `MainWindowConfigurator`'s coordinator feeds this from the live `NSWindow`
/// and the page's timelines pause while it reads `false`; on iOS, where there
/// is no window coordinator, it simply stays `true`.
final class MainWindowVisibility: ObservableObject {
    static let shared = MainWindowVisibility()

    /// Fully on screen — not miniaturised, not ordered out, not covered. The
    /// page's per-frame animations pause while this reads `false`.
    @Published private(set) var isVisible = true
    /// The same idea without the occlusion clause: `false` only while the
    /// window is miniaturised or ordered out. The now-playing page itself is
    /// put away on this: the vinyl, lyrics and cover it holds add up to tens
    /// of megabytes, and rebuilding the page is a single frame when the
    /// window comes back. Merely being covered does not count — switching
    /// apps would then tear the page down and up again for no gain.
    @Published private(set) var isOnScreen = true

    func update(isVisible: Bool, isOnScreen: Bool) {
        if isVisible != self.isVisible {
            self.isVisible = isVisible
        }
        if isOnScreen != self.isOnScreen {
            self.isOnScreen = isOnScreen
        }
    }
}
