import KumoneCore

#if os(macOS)
// Before anything can play: hand the core a vocal separator if this machine
// has one, so AutoMix can pre-render stem hand-overs instead of approximating
// them. A no-op when the model or MLX's metallib is missing.
StemSetup.install()
KumoneApp.main()
#endif
