// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Gleaner",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Gleaner", targets: ["Gleaner"]),
        .library(name: "GleanerCore", targets: ["GleanerCore"]),
    ],
    dependencies: [
        // In-app updates for builds distributed outside the App Store.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        // UI-independent logic: notification sources, LLM providers, extraction, pipeline.
        .target(
            name: "GleanerCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // The menu bar app (SwiftUI).
        .executableTarget(
            name: "Gleaner",
            dependencies: ["GleanerCore", .product(name: "Sparkle", package: "Sparkle")]
        ),
        .testTarget(
            name: "GleanerCoreTests",
            dependencies: ["GleanerCore"]
        ),
    ]
)
