import SwiftUI

/// Decides between the phone-style (compact) layout and the regular one.
///
/// iPhone Duo keeps the `.phone` idiom while its inner display reports regular
/// size classes in both axes, so the idiom can no longer stand in for "phone
/// layout". Either axis being compact (any iPhone orientation, iPad Split
/// View) keeps the compact layout; iPad and the open Duo get the regular one.
enum LayoutSizeClass {
    /// `fallback` answers for views that have not been measured yet (both
    /// size classes nil), where the idiom is the only hint available.
    static func isCompact(horizontal: UserInterfaceSizeClass?,
                          vertical: UserInterfaceSizeClass?,
                          fallback: Bool) -> Bool {
        guard let horizontal, let vertical else { return fallback }
        return horizontal == .compact || vertical == .compact
    }
}
