// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GitHubPRInbox",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(
            name: "GitHubPRInbox",
            targets: ["GitHubPRInbox"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-testing.git", exact: "6.2.4"),
    ],
    targets: [
        .executableTarget(
            name: "GitHubPRInbox",
            path: "Sources/GitHubPRInbox"
        ),
        .testTarget(
            name: "GitHubPRInboxTests",
            dependencies: [
                "GitHubPRInbox",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/GitHubPRInboxTests"
        ),
    ]
)
