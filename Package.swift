// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PresenceLock",
    platforms: [.macOS(.v14)],
    products: [
        // The embeddable core (used by the standalone app and by NotchNerd's Guard).
        .library(name: "PresenceKit", targets: ["PresenceKit"]),
        .executable(name: "notchguard", targets: ["PresenceLock"]),
    ],
    dependencies: [
        // Updates for the standalone app only; PresenceKit (and so NotchNerd) doesn't pull it in.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.4"),
    ],
    targets: [
        .target(name: "PresenceKit", path: "Sources/PresenceKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "PresenceLock", dependencies: ["PresenceKit", .product(name: "Sparkle", package: "Sparkle")],
                          path: "Sources/PresenceLock", swiftSettings: [.swiftLanguageMode(.v5)],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
    ]
)
