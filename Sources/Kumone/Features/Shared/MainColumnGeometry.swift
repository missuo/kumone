import SwiftUI

/// Only horizontal geometry affects the floating player and ambient chrome.
/// MainWindow stores this reference in State without subscribing to it; small
/// chrome views observe it so split-view animation does not rebuild navigation.
@MainActor
final class MainColumnGeometry: ObservableObject {
    struct Layout: Equatable {
        var width: CGFloat = 0
        var leadingInset: CGFloat = 0

        init(frame: CGRect = .zero) {
            width = frame.width
            leadingInset = frame.minX
        }
    }

    @Published private(set) var layout = Layout()

    func update(_ next: Layout) {
        guard next != layout else { return }
        layout = next
    }
}
