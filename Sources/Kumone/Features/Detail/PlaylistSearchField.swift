#if os(iOS)
import SwiftUI
import UIKit

struct PlaylistSearchField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool

    func makeUIView(context: Context) -> UISearchBar {
        let bar = UISearchBar()
        bar.searchBarStyle = .minimal
        bar.placeholder = String(localized: "搜索歌单内歌曲")
        bar.searchTextField.accessibilityHint = String(localized: "按歌名、歌手或专辑搜索")
        bar.searchTextField.accessibilityIdentifier = "likedSongsSearch"
        bar.autocapitalizationType = .none
        bar.autocorrectionType = .no
        bar.delegate = context.coordinator
        return bar
    }

    func updateUIView(_ bar: UISearchBar, context: Context) {
        context.coordinator.parent = self
        // Marked text belongs to the input method until the user commits it.
        if bar.searchTextField.markedTextRange == nil, bar.text != text {
            bar.text = text
        }
        if isFocused && !bar.searchTextField.isFirstResponder {
            // A newly revealed field joins the window after this update.
            DispatchQueue.main.async { [weak bar, weak coordinator = context.coordinator] in
                guard coordinator?.parent.isFocused == true else { return }
                bar?.searchTextField.becomeFirstResponder()
            }
        } else if !isFocused && bar.searchTextField.isFirstResponder {
            bar.searchTextField.resignFirstResponder()
        }
    }

    static func dismantleUIView(_ bar: UISearchBar, coordinator: Coordinator) {
        bar.delegate = nil
        bar.searchTextField.resignFirstResponder()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UISearchBarDelegate {
        var parent: PlaylistSearchField

        init(_ parent: PlaylistSearchField) { self.parent = parent }

        func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
            guard searchBar.searchTextField.markedTextRange == nil else { return }
            parent.text = searchText
        }

        func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
            parent.isFocused = true
        }

        func searchBarTextDidEndEditing(_ searchBar: UISearchBar) {
            parent.isFocused = false
        }

        func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
            searchBar.searchTextField.resignFirstResponder()
        }
    }
}
#endif
