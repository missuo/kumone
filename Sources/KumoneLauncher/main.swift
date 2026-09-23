import KumoneCore

#if os(macOS)
// Before anything can play: hand the core a vocal separator if this machine
// has one, so AutoMix can pre-render stem hand-overs instead of approximating
// them. A no-op when the model or MLX's metallib is missing.
StemSetup.install()
// A model downloaded from the settings page is wired in right away, the same
// way; `install()` re-reads the disk, so a later four-stem download upgrades
// the full-lane provider too.
MainActor.assumeIsolated {
    StemModelDownloader.shared.onInstalled = { StemSetup.install() }
}
KumoneApp.main()
#endif
