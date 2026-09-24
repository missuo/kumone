#if os(iOS)
import UIKit

/// Finish resolving and registering the system download if the phone locks.
@MainActor
final class DownloadPreparationActivity {
    private var token: UIBackgroundTaskIdentifier = .invalid

    init(onExpiration: @escaping @MainActor () -> Void) {
        token = UIApplication.shared.beginBackgroundTask(withName: "Prepare music download") { [weak self] in
            onExpiration()
            self?.end()
        }
        if token == .invalid, UIApplication.shared.applicationState == .background { onExpiration() }
    }

    func end() {
        guard token != .invalid else { return }
        UIApplication.shared.endBackgroundTask(token)
        token = .invalid
    }
}
#endif
