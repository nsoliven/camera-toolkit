// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CameraToolkit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "CameraToolkitCore", targets: ["CameraToolkitCore"]),
        .executable(name: "CameraToolkit", targets: ["CameraToolkitApp"])
    ],
    targets: [
        .target(name: "CameraToolkitCore"),
        .executableTarget(
            name: "CameraToolkitApp",
            dependencies: ["CameraToolkitCore"]
        ),
        .testTarget(
            name: "CameraToolkitCoreTests",
            dependencies: ["CameraToolkitCore"]
        ),
        .testTarget(
            name: "CameraToolkitAppTests",
            dependencies: ["CameraToolkitApp", "CameraToolkitCore"]
        )
    ]
)
