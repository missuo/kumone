// swift-tools-version: 6.2
import Foundation
import PackageDescription

// Command Line Tools (no Xcode) ship Testing.framework outside the default
// search paths. Opt in with KUMONE_CLT_TESTING=1 to wire it up so `swift test`
// works there; leave it unset with Xcode (and in CI), where these flags are
// unnecessary.
//
// After a full .build wipe on a CLT-only machine, `swift test` needs a
// two-phase dance (SPM's derived runner compiles without these settings, so
// its canImport(Testing) fails and it silently runs 0 tests; but exposing
// the swiftmodule during the test-target compile kills the framework
// autolink and the link fails with undefined Testing symbols):
//   1. Build once (KUMONE_CLT_TESTING=1 swift build --build-tests) with NO
//      Testing.swiftmodule symlink present, so the test objects compile
//      against the framework (autolink intact).
//   2. ln -sfn "$CLT/Frameworks/Testing.framework/Versions/A/Modules/\
//      Testing.swiftmodule" .build/arm64-apple-macosx/debug/Modules/ ,
//      rm -rf .build/arm64-apple-macosx/debug/KumonePackageTests.derived ,
//      then KUMONE_CLT_TESTING=1 swift test — the runner regenerates with
//      Testing visible while the cached test objects keep their autolink
//      records.
let cltDeveloperDir = "/Library/Developer/CommandLineTools/Library/Developer"
let cltHasTesting = ProcessInfo.processInfo.environment["KUMONE_CLT_TESTING"] == "1"
let cltTestingSwiftSettings: [SwiftSetting] = cltHasTesting
    ? [.unsafeFlags(["-F", cltDeveloperDir + "/Frameworks"])]
    : []
let cltTestingLinkerSettings: [LinkerSetting] = cltHasTesting
    ? [.unsafeFlags([
        "-F", cltDeveloperDir + "/Frameworks",
        "-Xlinker", "-rpath", "-Xlinker", cltDeveloperDir + "/Frameworks",
        "-Xlinker", "-rpath", "-Xlinker", cltDeveloperDir + "/usr/lib",
    ])]
    : []

let package = Package(
    name: "Kumone",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS("15.0"), .iOS("16.0")],
    products: [
        .executable(name: "Kumone", targets: ["KumoneLauncher"]),
        .library(name: "KumoneCore", targets: ["KumoneCore"]),
        // Offline vocal/accompaniment separation for AutoMix stem transitions; macOS only.
        .library(name: "StemKit", targets: ["StemKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.5"),
        // MLX Swift (MIT, Apple) — Metal inference runtime for StemKit.
        //
        // Pinned exactly, not ranged, for two reasons found by testing on this
        // Command Line Tools-only machine:
        //   - 0.31.1+ vendors an fmt that our clang rejects (consteval in
        //     format-inl.h), and 0.31.6+ additionally ships a CudaBuild build-tool
        //     plugin that fails to compile against our SwiftPM plugin API.
        //   - The prebuilt mlx.metallib that CLT-only builds need must match the
        //     vendored MLX version exactly; 0.30.6 vendors MLX 0.30.6, which is
        //     published on PyPI. See Scripts/fetch-mlx-metallib.sh.
        // Revisit the pin only alongside a fresh metallib fetch (and its pinned
        // sha256) and a stem separation run in a release build of the app.
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.30.6"),
    ],
    targets: [
        .target(
            name: "KumoneCore",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS])),
                .target(name: "KumoneObjC", condition: .when(platforms: [.macOS])),
            ],
            path: "Sources/Kumone",
            exclude: ["Resources"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        // Objective-C exception catching for the playback engine (macOS only):
        // AVFAudio reports some failures as NSExceptions Swift cannot catch.
        .target(
            name: "KumoneObjC",
            path: "Sources/KumoneObjC"
        ),
        .executableTarget(
            name: "KumoneLauncher",
            dependencies: [
                "KumoneCore",
                .product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS])),
                // AutoMix stem hand-overs: KumoneCore stays MLX-free and takes
                // a separator as a closure, which `StemSetup` installs here.
                // The built app therefore needs mlx.metallib beside its binary
                // — see Scripts/fetch-mlx-metallib.sh — and degrades to the
                // whole-mix transition path without it.
                .target(name: "StemKit", condition: .when(platforms: [.macOS])),
            ],
            path: "Sources/KumoneLauncher",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                // Sparkle.framework is embedded in Contents/Frameworks by Scripts/build-app.sh.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        // Mel-Band RoFormer vocal separation on MLX/Metal. macOS only: mlx-swift
        // requires iOS 17+, and AutoMix stem work is macOS-first anyway.
        // Model code adapted from xocialize/mel-roformer-mlx-swift (MIT) — see the
        // per-file headers in Sources/StemKit.
        .target(
            name: "StemKit",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift", condition: .when(platforms: [.macOS])),
                .product(
                    name: "MLXNN", package: "mlx-swift", condition: .when(platforms: [.macOS])),
                .product(
                    name: "MLXFFT", package: "mlx-swift", condition: .when(platforms: [.macOS])),
                .product(
                    name: "MLXFast", package: "mlx-swift", condition: .when(platforms: [.macOS])),
            ],
            path: "Sources/StemKit",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        // Everything about a checkpoint that can be checked without one: key
        // sets, band tables, manifest digests. No weights, no Metal, no
        // network — see the file's own header for why that is the interesting
        // layer.
        .testTarget(
            name: "StemKitTests",
            dependencies: [.target(name: "StemKit", condition: .when(platforms: [.macOS]))],
            path: "Tests/StemKitTests",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ] + cltTestingSwiftSettings,
            linkerSettings: cltTestingLinkerSettings
        ),
        .testTarget(
            name: "KumoneCoreTests",
            dependencies: [
                "KumoneCore",
                .target(name: "KumoneObjC", condition: .when(platforms: [.macOS])),
            ],
            path: "Tests/KumoneCoreTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ] + cltTestingSwiftSettings,
            linkerSettings: cltTestingLinkerSettings
        ),
    ]
)
