#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import KumoneCore

@Suite("Native song-list geometry")
@MainActor
struct TrackTableTests {
    @Test(arguments: [true, false])
    func offscreenHeaderRetainsItsHeightAcrossContentUpdates(explicitHeight: Bool) {
        let coordinator = TrackTable.Coordinator()
        coordinator.scrollView.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        var content = fixture(count: 1_200)
        if !explicitHeight { content.headerHeight = nil }
        coordinator.update(content, environment: EnvironmentValues())
        let table = coordinator.table
        // AppKit may defer geometry for distant rows. Realize the destination
        // before recording it, as it would be during an actual scroll.
        table.scrollRowToVisible(1_200)
        table.layoutSubtreeIfNeeded()
        let lastSong = table.rect(ofRow: 1_200)
        #expect(lastSong.height == 53)
        #expect(table.rect(ofRow: 0).height == 246)

        coordinator.scrollView.contentView.scroll(to: NSPoint(x: 0, y: lastSong.minY - 500))
        let offset = coordinator.scrollView.contentView.bounds.origin
        coordinator.update(content, environment: EnvironmentValues())
        table.layoutSubtreeIfNeeded()
        #expect(table.rect(ofRow: 1_200) == lastSong)
        #expect(coordinator.scrollView.contentView.bounds.origin == offset)
    }

    @Test func filteringKeepsHeaderAndFooterHeightsIncludingEmptyResults() {
        let coordinator = TrackTable.Coordinator()
        for count in [1_200, 2, 0, 90] {
            coordinator.update(fixture(count: count), environment: EnvironmentValues())
            let footer = coordinator.table.rect(ofRow: count + 1)
            #expect(coordinator.table.numberOfRows == count + 2)
            #expect(coordinator.table.rect(ofRow: 0).height == 246)
            if count > 0 {
                #expect(coordinator.table.rect(ofRow: count).height == 53)
            }
            if count == 0 { #expect(footer.minY == 246) }
            #expect(footer.height == 100)
        }
    }

    @Test func contentSizedChromeUpdatesWithoutChangingSongHeights() {
        let coordinator = TrackTable.Coordinator()
        coordinator.scrollView.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        var content = TrackTable(trackIDs: Array(0..<30),
                                 header: AnyView(Color.clear.frame(height: 220)),
                                 footer: AnyView(Color.clear.frame(height: 80))) { _ in
            AnyView(Text("Song"))
        }
        coordinator.update(content, environment: EnvironmentValues())
        #expect(coordinator.table.rect(ofRow: 0).height == 220)
        #expect(coordinator.table.rect(ofRow: 31).height == 80)
        content = TrackTable(trackIDs: content.trackIDs,
                             header: AnyView(Color.clear.frame(height: 60)),
                             footer: AnyView(Color.clear.frame(height: 320))) { _ in
            AnyView(Text("Song"))
        }
        coordinator.update(content, environment: EnvironmentValues())
        #expect(coordinator.table.rect(ofRow: 0).height == 60)
        #expect(coordinator.table.rect(ofRow: 31).height == 320)
        #expect(coordinator.table.rect(ofRow: 1).height == 53)
    }

    @Test func wrappedHeaderAdaptsToWindowWidth() {
        let coordinator = TrackTable.Coordinator()
        coordinator.scrollView.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let header = Text(String(repeating: "An artist and a long album description. ", count: 12))
            .font(.system(size: 14)).padding(24)
        let content = TrackTable(trackIDs: [1], header: AnyView(header),
                                 footer: AnyView(Color.clear.frame(height: 80))) { _ in
            AnyView(Text("Song"))
        }
        coordinator.update(content, environment: EnvironmentValues())
        coordinator.scrollView.layoutSubtreeIfNeeded()
        let wideHeight = coordinator.table.rect(ofRow: 0).height
        coordinator.scrollView.frame.size.width = 300
        coordinator.scrollView.needsLayout = true
        coordinator.scrollView.layoutSubtreeIfNeeded()
        #expect(coordinator.table.rect(ofRow: 0).height > wideHeight)
        #expect(coordinator.table.rect(ofRow: 1).height == 53)
    }

    private func fixture(count: Int) -> TrackTable {
        TrackTable(trackIDs: Array(0..<count), header: AnyView(Text("Playlist").frame(height: 246)),
                      footer: AnyView(Color.clear), headerHeight: 246, footerHeight: 100) { index in
            AnyView(Text("Song \(index)"))
        }
    }
}
#endif
