// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Burnish",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BurnishApp", targets: ["BurnishApp"]),
        .executable(name: "burnish", targets: ["BurnishCLI"]),
    ],
    dependencies: [
        // Used only to update Burnish itself (no other third-party dependencies).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.6"),
    ],
    targets: [
        // Pure Swift: parse and compare version strings.
        .target(name: "Versions"),
        // HTTP client with Burnish's User-Agent, timeouts and an in-flight limit.
        .target(name: "Net"),
        // A canned-response HTTP client for tests; nothing that ships depends on it.
        .target(name: "NetTesting", dependencies: ["Net"]),
        // Find installed apps and read what they say about themselves.
        .target(name: "Inventory", dependencies: ["Versions"]),
        // Homebrew's cask list: download, cache, index and match.
        .target(name: "CaskIndex", dependencies: ["Versions", "Net", "Inventory"]),
        // One type per update source behind a shared protocol.
        .target(name: "UpdateSources", dependencies: ["Versions", "Net", "Inventory", "CaskIndex"]),
        // Settings, ignore rules, match overrides and last results as JSON.
        .target(name: "Store"),
        // Download, verify, quit, replace, relaunch.
        .target(name: "Installer", dependencies: ["Versions", "Net", "Inventory", "UpdateSources"]),
        // Daily background check.
        .target(name: "Scheduler"),
        // Ties the modules together; shared by the app and the CLI.
        .target(
            name: "BurnishCore",
            dependencies: ["Versions", "Net", "Inventory", "CaskIndex", "UpdateSources", "Store", "Installer"]
        ),
        .executableTarget(
            name: "BurnishApp",
            dependencies: ["BurnishCore", "Scheduler", .product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: [.unsafeFlags(["-parse-as-library"])],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(name: "BurnishCLI", dependencies: ["BurnishCore"], swiftSettings: [.unsafeFlags(["-parse-as-library"])]),

        .testTarget(name: "VersionsTests", dependencies: ["Versions"]),
        .testTarget(name: "InventoryTests", dependencies: ["Inventory"]),
        .testTarget(name: "CaskIndexTests", dependencies: ["CaskIndex", "NetTesting"], resources: [.copy("Fixtures")]),
        .testTarget(name: "UpdateSourcesTests", dependencies: ["UpdateSources", "NetTesting"], resources: [.copy("Fixtures")]),
        .testTarget(name: "StoreTests", dependencies: ["Store"]),
        .testTarget(name: "InstallerTests", dependencies: ["Installer", "NetTesting"]),
        .testTarget(name: "SchedulerTests", dependencies: ["Scheduler"]),
        .testTarget(name: "BurnishCoreTests", dependencies: ["BurnishCore", "NetTesting"], resources: [.copy("Fixtures")]),
    ]
)
