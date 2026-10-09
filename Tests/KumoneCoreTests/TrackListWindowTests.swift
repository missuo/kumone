import Foundation
import Testing
@testable import KumoneCore

@Suite("Virtual track list geometry")
struct TrackListWindowTests {
    @Test func emptyAndShortListsHaveNoPhantomRowsOrTrailingSpacing() {
        let viewport = CGRect(x: 0, y: 0, width: 900, height: 700)
        #expect(window(count: 0, viewport: viewport).range.isEmpty)
        #expect(height(0) == 0)
        #expect(window(count: 3, viewport: viewport).range == 0..<3)
        #expect(height(3) == 158)
    }

    @Test func headerAndTopOverscrollKeepTheFirstSongsAvailable() {
        let result = window(viewport: CGRect(x: 0, y: -246, width: 900, height: 700))
        #expect(result.range == 0..<17)
        #expect(result.leadingHeight == 0)
    }

    @Test func partialRowsAtBothEdgesAreRendered() {
        let result = window(viewport: CGRect(x: 0, y: 53 * 100 + 1, width: 900, height: 53 * 10))
        #expect(result.range == 92..<119)
        #expect(result.leadingHeight == CGFloat(53 * 92))
    }

    @Test func bottomAndFilterShrinkNeverProduceOutOfBoundsIndices() {
        let viewport = CGRect(x: 0, y: height(1_200) - 700, width: 900, height: 700)
        let bottom = window(viewport: viewport)
        #expect(bottom.range.upperBound == 1_200)
        #expect(bottom.range.contains(1_199))
        let filtered = window(count: 2, viewport: viewport)
        #expect(filtered.range == 2..<2)
        #expect(window(count: 2, viewport: .init(x: 0, y: 0, width: 900, height: 700)).range == 0..<2)
    }

    @Test func everyScrollPositionCoversVisibleRowsWithBoundedWork() {
        let count = 10_000
        let viewportHeight: CGFloat = 727
        for offset in stride(from: CGFloat(0), through: height(count) - viewportHeight, by: 319) {
            let viewport = CGRect(x: 0, y: offset, width: 900, height: viewportHeight)
            let result = window(count: count, viewport: viewport)
            let firstVisible = Int(floor(offset / 53))
            let lastVisible = min(count - 1, Int(floor((viewport.maxY - 1) / 53)))
            #expect(result.range.contains(firstVisible))
            #expect(result.range.contains(lastVisible))
            #expect(result.range.count <= 31)
            // Moving the rendered window does not move a song in the document.
            let firstSongY = result.leadingHeight + CGFloat(firstVisible - result.range.lowerBound) * 53
            #expect(firstSongY == CGFloat(firstVisible) * 53)
        }
    }

    private func window(count: Int = 1_200, viewport: CGRect) -> TrackListWindow {
        TrackListWindow(count: count, rowHeight: 52, spacing: 1, viewport: viewport)
    }

    private func height(_ count: Int) -> CGFloat {
        TrackListWindow.contentHeight(count: count, rowHeight: 52, spacing: 1)
    }
}
