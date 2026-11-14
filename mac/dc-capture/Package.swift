// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "dc-capture",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "dc-capture", path: "Sources/dc-capture")
    ]
)
