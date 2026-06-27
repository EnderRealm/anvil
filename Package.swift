// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AnvilEngine",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AnvilEngine", targets: ["AnvilEngine"]),
    ],
    targets: [
        .target(name: "AnvilEngine"),
        .testTarget(name: "AnvilEngineTests", dependencies: ["AnvilEngine"]),
    ]
)
