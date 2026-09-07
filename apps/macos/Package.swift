// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeetingAgent",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MeetingCapture", targets: ["MeetingCapture"]),
        .library(name: "MeetingPipeline", targets: ["MeetingPipeline"]),
        .library(name: "LocalAPI", targets: ["LocalAPI"]),
        .executable(name: "MeetingVerification", targets: ["MeetingVerification"]),
        .executable(name: "MeetingAgent", targets: ["MeetingAgentApp"]),
        .executable(name: "MeetingCodexHelper", targets: ["MeetingCodexHelper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "0.15.0"),
        .package(path: "../../packages/meeting-core"),
        .package(path: "../../packages/meeting-analysis"),
    ],
    targets: [
        .target(name: "CodexSupport", dependencies: [.product(name: "MeetingCore", package: "meeting-core")]),
        .executableTarget(name: "MeetingCodexHelper", dependencies: ["CodexSupport"]),
        .target(name: "MeetingCapture", dependencies: [.product(name: "WhisperKit", package: "WhisperKit")]),
        .target(
            name: "MeetingPipeline",
            dependencies: [
                "CodexSupport",
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
        .executableTarget(name: "MeetingVerification", dependencies: ["CodexSupport", "MeetingCapture", "MeetingPipeline", "LocalAPI", .product(name: "MeetingCore", package: "meeting-core")]),
        .testTarget(name: "MeetingCaptureTests", dependencies: ["MeetingCapture"]),
        .testTarget(
            name: "MeetingPipelineTests",
            dependencies: ["MeetingPipeline", "MeetingCapture", .product(name: "MeetingCore", package: "meeting-core")]
        ),
        .testTarget(name: "LocalAPITests", dependencies: ["LocalAPI", "MeetingCapture", .product(name: "MeetingCore", package: "meeting-core")]),
    ]
)
