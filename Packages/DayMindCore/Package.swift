// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DayMindCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DayMindCore", targets: ["DayMindCore"])
    ],
    targets: [
        .target(name: "DayMindCore", path: "Sources/DayMindCore"),
        .testTarget(name: "DayMindCoreTests", dependencies: ["DayMindCore"], path: "Tests/DayMindCoreTests")
    ],
    swiftLanguageVersions: [.v5]
)
