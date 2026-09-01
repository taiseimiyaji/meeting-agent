// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeetingAgent",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MeetingCapture", targets: ["MeetingCapture"]),
        .library(name: "MeetingPipeline", targets: ["MeetingPipeline"]),
        .library(name: "LocalAPI", targets: ["LocalAPI"]),
        .executable(name: "MeetingAgent", targets: ["MeetingAgentApp"]),
    ],
    dependencies: [
        .package(path: "../../packages/meeting-core"),
        .package(path: "../../packages/meeting-analysis"),
    ],
    targets: [
        .target(name: "MeetingCapture"),
        .target(
            name: "MeetingPipeline",
            dependencies: [
                "MeetingCapture",
                .product(name: "MeetingCore", package: "meeting-core"),
                .product(name: "MeetingAnalysis", package: "meeting-analysis"),
            ]
        ),
        .target(
            name: "LocalAPI",
            dependencies: ["MeetingCapture", "MeetingPipeline", .product(name: "MeetingCore", package: "meeting-core")]
        ),
        .executableTarget(name: "MeetingAgentApp", dependencies: ["MeetingCapture", "MeetingPipeline", "LocalAPI", .product(name: "MeetingCore", package: "meeting-core")]),
        .testTarget(name: "MeetingCaptureTests", dependencies: ["MeetingCapture"]),
        .testTarget(
            name: "MeetingPipelineTests",
            dependencies: ["MeetingPipeline", "MeetingCapture", .product(name: "MeetingCore", package: "meeting-core")]
        ),
        .testTarget(name: "LocalAPITests", dependencies: ["LocalAPI", "MeetingCapture", .product(name: "MeetingCore", package: "meeting-core")]),
    ]
)
