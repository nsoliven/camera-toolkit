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
        .target(
            name: "CameraToolkitCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "CameraToolkitApp",
            dependencies: ["CameraToolkitCore"]
        ),
        .testTarget(
            name: "CameraToolkitCoreTests",
            dependencies: ["CameraToolkitCore"],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "CameraToolkitAppTests",
            dependencies: ["CameraToolkitApp", "CameraToolkitCore"]
        )
    ]
)
