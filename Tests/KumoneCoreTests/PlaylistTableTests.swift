#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import KumoneCore

@Suite("Native playlist geometry")
@MainActor
struct PlaylistTableTests {
    @Test func offscreenHeaderRetainsItsHeightAcrossContentUpdates() {
        let coordinator = PlaylistTable.Coordinator()
        coordinator.scrollView.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let content = fixture(count: 1_200)
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
        let coordinator = PlaylistTable.Coordinator()
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

    private func fixture(count: Int) -> PlaylistTable {
        PlaylistTable(trackIDs: Array(0..<count), header: AnyView(Text("Playlist")),
                      footer: AnyView(Color.clear), footerHeight: 100) { index in
            AnyView(Text("Song \(index)"))
        }
    }
}
#endif
