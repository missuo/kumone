import Testing
@testable import KumoneCore

struct DistributionChannelTests {
    @Test func missingOrUnknownValuesAreSideload() {
        #expect(DistributionChannel(infoValue: nil) == .sideload)
        #expect(DistributionChannel(infoValue: "") == .sideload)
        #expect(DistributionChannel(infoValue: "enterprise") == .sideload)
        #expect(DistributionChannel(infoValue: nil).allowsSelfUpdate)
    }

    @Test func storeChannelsDisableSelfUpdate() {
        #expect(DistributionChannel(infoValue: "testflight") == .testFlight)
        #expect(DistributionChannel(infoValue: " TestFlight ") == .testFlight)
        #expect(DistributionChannel(infoValue: "appstore") == .appStore)
        #expect(!DistributionChannel(infoValue: "testflight").allowsSelfUpdate)
        #expect(!DistributionChannel(infoValue: "appstore").allowsSelfUpdate)
    }
}
