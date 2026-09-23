import Testing
@testable import KumoneCore

@Suite("Automatic song cache limit")
struct AutomaticCacheLimitTests {
    @Test func takesATenthOfRecoverableSpaceWithinBounds() {
        #expect(AutomaticCacheLimit.megabytes(freeBytes: 100_000_000_000, cacheBytes: 0) == 10_000)
        #expect(AutomaticCacheLimit.megabytes(freeBytes: 5_000_000_000, cacheBytes: 0) == 2_000)
        #expect(AutomaticCacheLimit.megabytes(freeBytes: 900_000_000_000, cacheBytes: 0) == 30_000)
        // Filling the cache does not shrink its own allowance.
        #expect(AutomaticCacheLimit.megabytes(freeBytes: 90_000_000_000, cacheBytes: 10_000_000_000) == 10_000)
        #expect(AutomaticCacheLimit.megabytes(freeBytes: -1, cacheBytes: -1) == 2_000)
    }
}
