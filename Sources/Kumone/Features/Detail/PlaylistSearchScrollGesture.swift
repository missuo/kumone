#if os(iOS)
import SwiftUI
import UIKit

/// Observes the scroll view's existing pan recognizer without adding a competing gesture.
struct PlaylistSearchScrollGesture: UIViewRepresentable {
    let isSearchActive: Bool
    let onPullDown: () -> Void
    let onScrollUp: () -> Void

    func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: ObserverView, context: Context) {
        view.isSearchActive = isSearchActive
        view.onPullDown = onPullDown
        view.onScrollUp = onScrollUp
    }

    static func dismantleUIView(_ view: ObserverView, coordinator: Void) {
        view.stopObserving()
    }

    final class ObserverView: UIView {
        var isSearchActive = false
        var onPullDown: (() -> Void)?
        var onScrollUp: (() -> Void)?
        private weak var scrollView: UIScrollView?
        private var startedAtTop = false
        private var searchWasActive = false
        private var didTrigger = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            stopObserving()
            guard window != nil else { return }
            var ancestor = superview
            while let view = ancestor, !(view is UIScrollView) {
                ancestor = view.superview
            }
            guard let scrollView = ancestor as? UIScrollView else {
                assertionFailure("PlaylistSearchScrollGesture must be placed inside a ScrollView")
                return
            }
            self.scrollView = scrollView
            scrollView.panGestureRecognizer.addTarget(self, action: #selector(panChanged(_:)))
        }

        func stopObserving() {
            scrollView?.panGestureRecognizer.removeTarget(self, action: #selector(panChanged(_:)))
            scrollView = nil
            startedAtTop = false
            didTrigger = false
        }

        @objc private func panChanged(_ pan: UIPanGestureRecognizer) {
            guard let scrollView else { return }
            let atTop = scrollView.contentOffset.y + scrollView.adjustedContentInset.top <= 1
            switch pan.state {
            case .began:
                startedAtTop = atTop
                searchWasActive = isSearchActive
                didTrigger = false
            case .changed:
                guard !didTrigger else { return }
                let translation = pan.translation(in: scrollView)
                guard abs(translation.y) > abs(translation.x) else { return }
                if searchWasActive, translation.y < -20 {
                    didTrigger = true
                    onScrollUp?()
                }
            case .ended:
                let translation = pan.translation(in: scrollView)
                // Let the scroll view finish releasing the pan before changing layout or focus.
                if !didTrigger, !searchWasActive, startedAtTop, atTop,
                   translation.y > 36, abs(translation.y) > abs(translation.x) {
                    didTrigger = true
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.window != nil, !self.isSearchActive,
                              let scrollView = self.scrollView, !scrollView.isDragging else { return }
                        // End the overscroll before the header-to-search animation moves the list.
                        scrollView.setContentOffset(
                            CGPoint(x: scrollView.contentOffset.x, y: -scrollView.adjustedContentInset.top),
                            animated: false
                        )
                        self.onPullDown?()
                    }
                }
            default:
                break
            }
        }
    }
}
#endif
