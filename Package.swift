// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PencilPad",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "PencilPad", path: "Sources/PencilPad")
    ]
)
