@testable import KumoneCore

/// Tests run against placeholder hosts
/// (`music.1.com`, `*.music.2.net`) that a stubbed URL protocol answers.
enum TestUpstream {
    static let hosts = Upstream.Hosts(api: 1, cdn: 2)

    /// Idempotent; safe to call from every suite's `init`.
    static func configure() {
        if Upstream.hosts != hosts { Upstream.configure(hosts, persist: false) }
    }

    /// `.music.2.net`, configuring first.
    static var cdnSuffix: String {
        configure()
        return Upstream.cdnSuffix!
    }
}
