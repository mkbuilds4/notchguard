// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PresenceLock",
    platforms: [.macOS(.v14)],
    products: [
        // The embeddable core (used by the standalone app and by NotchNerd's Guard).
        .library(name: "PresenceKit", targets: ["PresenceKit"]),
        .executable(name: "presence-lock", targets: ["PresenceLock"]),
    ],
    targets: [
        .target(name: "PresenceKit", path: "Sources/PresenceKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "PresenceLock", dependencies: ["PresenceKit"], path: "Sources/PresenceLock",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
