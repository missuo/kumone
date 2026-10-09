import SwiftUI

/// A complete song-list page: one scroll owner, reusable desktop rows and
/// content-sized chrome. Mobile keeps the existing lazy stack and spacing.
struct TrackListScrollView<Header: View, Rows: View, Footer: View>: View {
    let trackIDs: [Int]
    var style: TrackRowStyle = .full
    var spacing: CGFloat = 20
    @ViewBuilder var header: () -> Header
    @ViewBuilder var rows: (TrackListView.Layout) -> Rows
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        #if os(macOS)
        TrackTable(
            trackIDs: trackIDs,
            header: AnyView(header().padding(.bottom, spacing)),
            footer: AnyView(footer().padding(.top, spacing)),
            rowHeight: style.desktopRowHeight + 1
        ) { index in
            AnyView(rows(.singleRow(index)))
        }
        .clipped()
        #else
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) {
                header()
                if !trackIDs.isEmpty { rows(.stack) }
                footer()
            }
        }
        #endif
    }
}
