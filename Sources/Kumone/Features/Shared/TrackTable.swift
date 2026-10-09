#if os(macOS)
import AppKit
import SwiftUI

/// AppKit owns scrolling and cell reuse. Delegate heights keep the header,
/// songs and footer independent of SwiftUI measurement and playback updates.
struct TrackTable: NSViewRepresentable {
    let trackIDs: [Int]
    let header: AnyView
    let footer: AnyView
    var headerHeight: CGFloat? = nil
    var footerHeight: CGFloat? = nil
    var rowHeight: CGFloat = TrackRowStyle.full.desktopRowHeight + 1
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
        let scrollView = ScrollView()
        let table = NSTableView()
        private var content: TrackTable?
        private var environment = EnvironmentValues()
        private let headerCell = Cell()
        private let footerCell = Cell()
        private var headerHeight: CGFloat = 1
        private var footerHeight: CGFloat = 1

        override init() {
            super.init()
            let column = NSTableColumn(identifier: .init("tracks"))
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
            scrollView.onWidthChange = { [weak self] in self?.updateChrome(contentChanged: false) }
        }

        func update(_ next: TrackTable, environment: EnvironmentValues) {
            let previousIDs = content?.trackIDs
            let previousRowHeight = content?.rowHeight
            content = next
            self.environment = environment
            let changedHeights = updateChrome(notifyTable: false)
            if previousIDs != next.trackIDs || previousRowHeight != next.rowHeight {
                table.rowHeight = next.rowHeight
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
                notifyHeightChanges(changedHeights)
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { (content?.trackIDs.count ?? 0) + 2 }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            if row == 0 { return headerHeight }
            if row == (content?.trackIDs.count ?? 0) + 1 { return footerHeight }
            return content?.rowHeight ?? tableView.rowHeight
        }

        func selectionShouldChange(in tableView: NSTableView) -> Bool { false }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            if row == 0 { return headerCell }
            if row == (content?.trackIDs.count ?? 0) + 1 { return footerCell }
            let identifier = NSUserInterfaceItemIdentifier("track")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? Cell ?? Cell()
            cell.identifier = identifier
            configure(cell, at: row)
            return cell
        }

        private func configure(_ cell: Cell, at index: Int) {
            guard let content else { return }
            guard index > 0, index <= content.trackIDs.count else { return }
            let trackIndex = index - 1
            // A reused host must retain its view graph. Keying the entire root
            // by song ID destroys and rebuilds every label, button and layout.
            // TrackRow scopes its transient interaction state to the song.
            cell.update(content.row(trackIndex), environment: environment)
        }

        /// Measure only the two chrome views on content/width changes. Keep
        /// these hosts alive offscreen so view state and measured heights survive
        /// cell reuse; scrolling and playback never measure the whole song list.
        @discardableResult
        private func updateChrome(contentChanged: Bool = true, notifyTable: Bool = true) -> IndexSet {
            guard let content else { return [] }
            let width = scrollView.contentSize.width
            let nextHeader = contentChanged || content.headerHeight == nil
                ? measure(content.header, in: headerCell, width: width, fixedHeight: content.headerHeight)
                : headerHeight
            let nextFooter = contentChanged || content.footerHeight == nil
                ? measure(content.footer, in: footerCell, width: width, fixedHeight: content.footerHeight)
                : footerHeight
            var changed = IndexSet()
            if nextHeader != headerHeight { changed.insert(0) }
            if nextFooter != footerHeight { changed.insert(content.trackIDs.count + 1) }
            headerHeight = nextHeader
            footerHeight = nextFooter
            if notifyTable { notifyHeightChanges(changed) }
            return changed
        }

        private func measure(_ view: AnyView, in cell: Cell, width: CGFloat,
                             fixedHeight: CGFloat?) -> CGFloat {
            if let fixedHeight {
                // AppKit can resize this host directly; assigning a new SwiftUI
                // root for every animation frame would rebuild fixed chrome.
                cell.host.sizingOptions = []
                cell.host.rootView = AnyView(view
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .environment(\.self, environment))
                return max(1, fixedHeight)
            }
            cell.host.sizingOptions = [.intrinsicContentSize]
            cell.host.rootView = AnyView(view
                .frame(width: max(1, width), alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.self, environment))
            // The representable receives its viewport after makeNSView.
            // Defer flexible measurement until that width is available.
            guard width > 0 else { return 1 }
            return max(1, ceil(cell.host.intrinsicContentSize.height))
        }

        private func notifyHeightChanges(_ indexes: IndexSet) {
            guard !indexes.isEmpty else { return }
            NSAnimationContext.runAnimationGroup { animation in
                animation.duration = 0
                table.noteHeightOfRows(withIndexesChanged: indexes)
            }
        }
    }

    @MainActor
    final class ScrollView: NSScrollView {
        var onWidthChange: (() -> Void)?
        private var measuredWidth: CGFloat = 0

        override func layout() {
            super.layout()
            let width = contentSize.width
            guard width > 0, width != measuredWidth else { return }
            measuredWidth = width
            onWidthChange?()
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

        func update(_ view: AnyView, environment: EnvironmentValues) {
            host.rootView = AnyView(view
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .environment(\.self, environment))
        }

        override func layout() {
            super.layout()
            if host.frame != bounds { host.frame = bounds }
        }
    }
}
#endif
