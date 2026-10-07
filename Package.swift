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
        // The dashboard's views, for embedding the dashboard in another SwiftUI app.
        .library(name: "ReportMateUI", targets: ["ReportMateUI"]),
        .executable(name: "ReportMateMac", targets: ["ReportMateMac"]),
    ],
    targets: [
        .target(
            name: "ReportMateKit",
            path: "Sources/ReportMateKit"
        ),
        .target(
            name: "ReportMateUI",
            dependencies: ["ReportMateKit"],
            path: "Sources/ReportMateUI"
        ),
        .executableTarget(
            name: "ReportMateMac",
            dependencies: ["ReportMateKit", "ReportMateUI"],
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
