// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "sidekick",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SidekickCore", targets: ["SidekickCore"]),
        .library(name: "SidekickApp", targets: ["SidekickApp"]),
        .executable(name: "Sidekick", targets: ["Sidekick"]),
        .executable(name: "sidekick-checks", targets: ["sidekick-checks"]),
    ],
    dependencies: [
        // Global shortcut through Carbon hot keys (no Accessibility permission) and the recorder in Settings. MIT.
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "3.0.0"),
    ],
    targets: [
        // Everything that can run without a window: the claude process, the stream parser, markdown, springs.
        .target(name: "SidekickCore"),
        // The app itself, a library so Xcode can render its previews. The executable only calls in.
        .target(
            name: "SidekickApp",
            dependencies: [
                "SidekickCore",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ]
        ),
        .executableTarget(name: "Sidekick", dependencies: ["SidekickApp"]),
        .executableTarget(name: "sidekick-checks", dependencies: ["SidekickCore"]),
    ]
)
