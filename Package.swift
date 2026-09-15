// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Kumone",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS("15.0"), .iOS("16.0")],
    products: [
        .executable(name: "Kumone", targets: ["KumoneLauncher"]),
        .library(name: "KumoneCore", targets: ["KumoneCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.5"),
    ],
    targets: [
        .target(
            name: "KumoneCore",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS])),
            ],
            path: "Sources/Kumone",
            exclude: ["Resources"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .executableTarget(
            name: "KumoneLauncher",
            dependencies: [
                "KumoneCore",
                .product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS])),
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
        .testTarget(
            name: "KumoneCoreTests",
            dependencies: ["KumoneCore"],
            path: "Tests/KumoneCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
