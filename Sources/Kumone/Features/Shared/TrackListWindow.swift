import Foundation

/// Geometry for a fixed-height virtual track list. Indices refer to the full
/// filtered list so row numbers and playback order survive window changes.
struct TrackListWindow {
    let range: Range<Int>
    let leadingHeight: CGFloat

    init(count: Int, rowHeight: CGFloat, spacing: CGFloat, viewport: CGRect, overscan: Int = 8) {
        let stride = rowHeight + spacing
        let first = Int(floor(max(0, viewport.minY) / stride))
        let end = Int(ceil(max(0, viewport.maxY) / stride))
        let lower = min(count, max(0, first - overscan))
        let upper = min(count, max(lower, end + overscan))
        range = lower..<upper
        leadingHeight = CGFloat(lower) * stride
    }

    static func contentHeight(count: Int, rowHeight: CGFloat, spacing: CGFloat) -> CGFloat {
        max(0, CGFloat(count) * (rowHeight + spacing) - spacing)
    }
}
