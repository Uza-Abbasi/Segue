// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Segue",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SegueCore"),
        .executableTarget(name: "Segue", dependencies: ["SegueCore"]),
        .testTarget(name: "SegueCoreTests", dependencies: ["SegueCore"]),
    ],
    swiftLanguageModes: [.v5]
)
