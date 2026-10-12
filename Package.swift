// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "prankvirus",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "prankvirus", path: "Sources")
    ]
)
