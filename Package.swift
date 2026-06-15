// swift-tools-version: 6.0

import PackageDescription

let pasteBuddySwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v5)
]

let package = Package(
    name: "PasteBuddy",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .executable(name: "PasteBuddy", targets: ["PasteBuddy"]),
        .executable(name: "PasteBuddyMCP", targets: ["PasteBuddyMCP"]),
        .library(name: "PasteBuddyCore", targets: ["PasteBuddyCore"]),
        .library(name: "PasteBuddyMobile", targets: ["PasteBuddyMobile"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.5.0")
    ],
    targets: [
        .target(
            name: "PasteBuddyCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            swiftSettings: pasteBuddySwiftSettings
        ),
        .executableTarget(
            name: "PasteBuddy",
            dependencies: ["PasteBuddyCore"],
            resources: [
                .process("Resources")
            ],
            swiftSettings: pasteBuddySwiftSettings
        ),
        .executableTarget(
            name: "PasteBuddyMCP",
            dependencies: ["PasteBuddyCore"],
            swiftSettings: pasteBuddySwiftSettings
        ),
        .target(
            name: "PasteBuddyMobile",
            dependencies: ["PasteBuddyCore"],
            swiftSettings: pasteBuddySwiftSettings
        ),
        .testTarget(
            name: "PasteBuddyCoreTests",
            dependencies: ["PasteBuddyCore", "PasteBuddyMobile"],
            swiftSettings: pasteBuddySwiftSettings
        ),
        .testTarget(
            name: "PasteBuddyAppTests",
            dependencies: ["PasteBuddy"],
            swiftSettings: pasteBuddySwiftSettings
        )
    ],
    swiftLanguageModes: [.v5, .v6]
)
