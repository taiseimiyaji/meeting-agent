// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeetingCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MeetingCore", targets: ["MeetingCore"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3", providers: [.brew(["sqlite3"]), .apt(["libsqlite3-dev"])]),
        .target(name: "MeetingCore", dependencies: ["CSQLite"]),
        .testTarget(name: "MeetingCoreTests", dependencies: ["MeetingCore"])
    ]
)
