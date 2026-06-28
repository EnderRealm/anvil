// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AnvilEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AnvilEngine", targets: ["AnvilEngine"]),
        .library(name: "AnvilUI", targets: ["AnvilUI"]),
        .executable(name: "AnvilApp", targets: ["AnvilApp"]),
    ],
    targets: [
        .target(name: "AnvilEngine"),
        .target(name: "AnvilUI", dependencies: ["AnvilEngine"]),
        .executableTarget(name: "AnvilApp", dependencies: ["AnvilUI", "AnvilEngine"]),
        .testTarget(name: "AnvilEngineTests", dependencies: ["AnvilEngine", "AnvilUI"]),
    ]
)
