// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiskCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "DiskCore", targets: ["DiskIndex", "Insights", "Recognizers", "Reclaim"]),
        .executable(name: "smd", targets: ["smd"]),
    ],
    targets: [
        .target(name: "CFastScan"),
        .target(name: "DiskIndex", dependencies: ["CFastScan"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "Insights", dependencies: ["DiskIndex"]),
        .target(name: "Recognizers", dependencies: ["DiskIndex", "Insights"]),
        .target(name: "Reclaim", dependencies: ["DiskIndex", "Recognizers"]),
        .executableTarget(name: "smd", dependencies: ["DiskIndex", "Insights", "Recognizers", "Reclaim"]),
        .testTarget(
            name: "DiskCoreTests",
            dependencies: ["CFastScan", "DiskIndex", "Insights", "Recognizers", "Reclaim"]
        ),
    ]
)
