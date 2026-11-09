// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Karuta",
    platforms: [.macOS(.v14)],
    targets: [
        // File naming and other logic without AppKit or settings, so it can be checked.
        .target(name: "KarutaCore", path: "Sources/KarutaCore"),
        .executableTarget(name: "Karuta", dependencies: ["KarutaCore"], path: "Sources/Karuta"),
        // The Command Line Tools ship neither XCTest nor the Swift Testing macros, so the checks are
        // a plain executable: `make test` (= `swift run karuta-check`).
        .executableTarget(name: "karuta-check", dependencies: ["KarutaCore"], path: "Tests/KarutaChecks"),
    ]
)
