import Testing
@testable import KumoneCore

@Suite("Navigation destination tests")
struct NavigationDestinationTests {
    @Test func doesNotAppendTheCurrentDestination() {
        var destinations: [Destination] = [.artist(42)]

        destinations.appendIfNotCurrent(.artist(42))

        #expect(destinations == [.artist(42)])
    }

    @Test func appendsADifferentDestination() {
        var destinations: [Destination] = [.album(7)]

        destinations.appendIfNotCurrent(.artist(42))

        #expect(destinations == [.album(7), .artist(42)])
    }
}
