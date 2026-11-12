// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiskCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "DiskCore", targets: ["DiskIndex", "Insights", "Recognizers", "Reclaim", "Update", "Privileged"]),
        .library(name: "Privileged", targets: ["Privileged"]),
        .executable(name: "smd", targets: ["smd"]),
    ],
    targets: [
        .target(name: "CFastScan"),
        .target(name: "DiskIndex", dependencies: ["CFastScan"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "Insights", dependencies: ["DiskIndex"]),
        .target(name: "Recognizers", dependencies: ["DiskIndex", "Insights"]),
        .target(name: "Reclaim", dependencies: ["DiskIndex", "Recognizers", "Privileged"]),
        .target(name: "Update", dependencies: ["DiskIndex"]),
        // What the root helper is made of: it depends on nothing else here.
        .target(name: "Privileged"),
        .executableTarget(name: "smd", dependencies: ["DiskIndex", "Insights", "Recognizers", "Reclaim"]),
        .testTarget(
            name: "DiskCoreTests",
            dependencies: ["CFastScan", "DiskIndex", "Insights", "Recognizers", "Reclaim", "Update", "Privileged"]
        ),
    ]
)
