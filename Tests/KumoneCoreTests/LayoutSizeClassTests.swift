import SwiftUI
import Testing
@testable import KumoneCore

struct LayoutSizeClassTests {
    @Test func regularInBothAxesLeavesTheCompactLayout() {
        // iPad, and iPhone Duo's inner display, which keeps the phone idiom.
        #expect(!LayoutSizeClass.isCompact(horizontal: .regular, vertical: .regular, fallback: true))
    }

    @Test func aCompactAxisKeepsTheCompactLayout() {
        // iPhone portrait, iPhone Max landscape, iPad Split View.
        #expect(LayoutSizeClass.isCompact(horizontal: .compact, vertical: .regular, fallback: false))
        #expect(LayoutSizeClass.isCompact(horizontal: .regular, vertical: .compact, fallback: false))
        #expect(LayoutSizeClass.isCompact(horizontal: .compact, vertical: .compact, fallback: false))
    }

    @Test func unmeasuredViewsFallBackToTheIdiom() {
        #expect(LayoutSizeClass.isCompact(horizontal: nil, vertical: nil, fallback: true))
        #expect(!LayoutSizeClass.isCompact(horizontal: nil, vertical: .regular, fallback: false))
    }
}
