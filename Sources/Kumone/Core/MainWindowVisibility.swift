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

    @Published private(set) var isVisible = true

    func update(isVisible: Bool) {
        guard isVisible != self.isVisible else { return }
        self.isVisible = isVisible
    }
}
