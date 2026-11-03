import Foundation

/// How this build reaches people.
///
/// Sideloaded builds update themselves from GitHub releases (TrollStore
/// hand-off or an IPA download). TestFlight and App Store builds must not ship
/// that path (App Review 2.5.2); they update through Apple instead.
enum DistributionChannel: String, Sendable {
    case sideload
    case testFlight = "testflight"
    case appStore = "appstore"

    /// Read from `KumoneDistribution` in Info.plist, which the build
    /// configuration writes (`ios/Config/TestFlight.xcconfig`). A build that
    /// says nothing is a sideload build, the default for every contributor.
    static let current = DistributionChannel(
        infoValue: Bundle.main.object(forInfoDictionaryKey: "KumoneDistribution") as? String)

    init(infoValue: String?) {
        let value = infoValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self = value.flatMap(DistributionChannel.init(rawValue:)) ?? .sideload
    }

    /// Whether the app may look for and install its own updates.
    var allowsSelfUpdate: Bool { self == .sideload }
}
