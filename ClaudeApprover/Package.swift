// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeApprover",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "ClaudeApprover",
            path: "Sources",
            swiftSettings: [
                .enableUpcomingFeature("BareSlashRegexLiterals")
            ]
        ),
        .testTarget(
            name: "ClaudeApproverTests",
            dependencies: ["ClaudeApprover"],
            path: "Tests/ClaudeApproverTests"
        )
    ]
)
