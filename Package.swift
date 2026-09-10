// swift-tools-version: 6.0
// ReportMate for Mac: the native SwiftUI fleet dashboard.

import PackageDescription

let package = Package(
    name: "ReportMate",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ReportMateKit", targets: ["ReportMateKit"]),
        .executable(name: "ReportMateMac", targets: ["ReportMateMac"]),
    ],
    targets: [
        .target(
            name: "ReportMateKit",
            path: "Sources/ReportMateKit"
        ),
        .executableTarget(
            name: "ReportMateMac",
            dependencies: ["ReportMateKit"],
            path: "Sources/ReportMateMac",
            exclude: ["Info.plist", "Resources"]
        ),
        .testTarget(
            name: "ReportMateKitTests",
            dependencies: ["ReportMateKit"],
            path: "Tests/ReportMateKitTests"
        ),
    ]
)
