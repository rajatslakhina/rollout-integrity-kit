// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RolloutIntegrityKit",
    // Only the platforms CI actually builds are declared. tvOS and watchOS would
    // very likely work — the core module is platform-agnostic and the arithmetic is
    // 32-bit-safe — but "very likely" is not a support claim, and an unverified
    // platform in this list is a promise nobody has tested.
    platforms: [.iOS(.v17), .macOS(.v14)],
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
