// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "ClaudeSiri",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ClaudeSiri", path: "Sources/ClaudeSiri"),
        .testTarget(name: "ClaudeSiriTests", dependencies: ["ClaudeSiri"], path: "Tests/ClaudeSiriTests"),
    ]
)
