#if os(macOS)
import AppKit
import SwiftUI

/// AppKit owns scrolling and cell reuse. Delegate heights keep the header,
/// songs and footer independent of SwiftUI measurement and playback updates.
struct PlaylistTable: NSViewRepresentable {
    let trackIDs: [Int]
    let header: AnyView
    let footer: AnyView
    let footerHeight: CGFloat
    let row: (Int) -> AnyView

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.update(self, environment: context.environment)
        return context.coordinator.scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(self, environment: context.environment)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let scrollView = NSScrollView()
        let table = NSTableView()
        private var content: PlaylistTable?
        private var environment = EnvironmentValues()

        override init() {
            super.init()
            let column = NSTableColumn(identifier: .init("playlist"))
            column.resizingMask = .autoresizingMask
            table.addTableColumn(column)
            table.headerView = nil
            table.style = .plain
            table.backgroundColor = .clear
            table.intercellSpacing = .zero
            table.rowSizeStyle = .custom
            table.rowHeight = TrackRowStyle.full.desktopRowHeight + 1
            table.usesAutomaticRowHeights = false
            table.selectionHighlightStyle = .none
            table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
            table.autoresizingMask = [.width]
            table.dataSource = self
            table.delegate = self
            scrollView.documentView = table
            scrollView.hasVerticalScroller = true
            scrollView.drawsBackground = false
            scrollView.borderType = .noBorder
            scrollView.automaticallyAdjustsContentInsets = false
        }

        func update(_ next: PlaylistTable, environment: EnvironmentValues) {
            let previousIDs = content?.trackIDs
            let previousFooterHeight = content?.footerHeight
            content = next
            self.environment = environment
            if previousIDs != next.trackIDs {
                table.reloadData()
            } else {
                // Permission, search-header and download updates refresh only
                // existing cells. Playback is observed inside each hosted row.
                let visible = table.rows(in: table.visibleRect)
                if visible.location != NSNotFound {
                    for index in visible.location..<NSMaxRange(visible) {
                        if let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? Cell {
                            configure(cell, at: index)
                        }
                    }
                }
                if previousFooterHeight != next.footerHeight {
                    NSAnimationContext.runAnimationGroup { animation in
                        animation.duration = 0
                        table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: next.trackIDs.count + 1))
                    }
                }
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { (content?.trackIDs.count ?? 0) + 2 }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            if row == 0 { return 246 } // 210-point header, 16 top, 20 bottom.
            if row == (content?.trackIDs.count ?? 0) + 1 { return content?.footerHeight ?? 100 }
            return TrackRowStyle.full.desktopRowHeight + 1
        }

        func selectionShouldChange(in tableView: NSTableView) -> Bool { false }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let role = row == 0 ? "header" : row == (content?.trackIDs.count ?? 0) + 1 ? "footer" : "track"
            let identifier = NSUserInterfaceItemIdentifier(role)
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? Cell ?? Cell()
            cell.identifier = identifier
            configure(cell, at: row)
            return cell
        }

        private func configure(_ cell: Cell, at index: Int) {
            guard let content else { return }
            let view: AnyView
            if index == 0 { view = content.header }
            else if index == content.trackIDs.count + 1 { view = content.footer }
            else {
                let trackIndex = index - 1
                view = AnyView(content.row(trackIndex).id(content.trackIDs[trackIndex]))
            }
            cell.host.rootView = AnyView(view
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .environment(\.self, environment))
        }
    }

    @MainActor
    final class Cell: NSTableCellView {
        let host = NSHostingView(rootView: AnyView(EmptyView()))

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            host.sizingOptions = []
            host.autoresizingMask = [.width, .height]
            addSubview(host)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            host.frame = bounds
        }
    }
}
#endif
