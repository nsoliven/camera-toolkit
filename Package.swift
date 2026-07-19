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
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0")
    ],
    targets: [
        .target(
            name: "CameraToolkitCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
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
