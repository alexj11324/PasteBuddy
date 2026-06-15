// swift-tools-version: 5.9

import PackageDescription

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
    targets: [
        .target(name: "PasteBuddyCore"),
        .executableTarget(
            name: "PasteBuddy",
            dependencies: ["PasteBuddyCore"],
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "PasteBuddyMCP",
            dependencies: ["PasteBuddyCore"]
        ),
        .target(
            name: "PasteBuddyMobile",
            dependencies: ["PasteBuddyCore"]
        ),
        .testTarget(
            name: "PasteBuddyCoreTests",
            dependencies: ["PasteBuddyCore", "PasteBuddyMobile"]
        )
    ]
)
