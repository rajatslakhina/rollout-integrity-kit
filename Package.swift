// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RolloutIntegrityKit",
    platforms: [.iOS(.v17), .macOS(.v14), .tvOS(.v17), .watchOS(.v10)],
    products: [
        // Library products only. This package deliberately ships NO executable
        // target: the runnable demo lives in its own repository and consumes
        // this package by its published git URL, exactly like any other client.
        .library(name: "RolloutIntegrity", targets: ["RolloutIntegrity"]),
        .library(name: "RolloutIntegrityUI", targets: ["RolloutIntegrityUI"])
    ],
    targets: [
        .target(name: "RolloutIntegrity"),
        .target(name: "RolloutIntegrityUI", dependencies: ["RolloutIntegrity"]),
        .testTarget(name: "RolloutIntegrityTests", dependencies: ["RolloutIntegrity"])
    ]
)
