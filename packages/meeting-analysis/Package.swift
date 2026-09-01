// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeetingAnalysis",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MeetingAnalysis", targets: ["MeetingAnalysis"])],
    dependencies: [.package(path: "../meeting-core")],
    targets: [
        .target(
            name: "MeetingAnalysis",
            dependencies: [.product(name: "MeetingCore", package: "meeting-core")]
        ),
        .testTarget(
            name: "MeetingAnalysisTests",
            dependencies: ["MeetingAnalysis", .product(name: "MeetingCore", package: "meeting-core")]
        )
    ]
)
