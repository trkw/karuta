// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Karuta",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Karuta", path: "Sources/Karuta")
    ]
)
