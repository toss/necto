// swift-tools-version: 6.0

// Copyright (c) 2026 Viva Republica, Inc.

import PackageDescription

let package = Package(
    name: "NectoMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NectoMacService", targets: ["NectoMacService", "NectoCLIService"]),
        .executable(name: "necto-cli", targets: ["necto-cli"]),
    ],
    dependencies: [
        .package(name: "Necto", path: ".."),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "NectoCLIService",
            dependencies: [.product(name: "NectoSDK", package: "Necto")]
        ),
        .target(
            name: "NectoMacService",
            dependencies: ["NectoCLIService", .product(name: "NectoSDK", package: "Necto")]
        ),
        .executableTarget(
            name: "necto-cli",
            dependencies: [
                "NectoCLIService",
                .product(name: "NectoSDK", package: "Necto"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            resources: [.copy("Resources/Skills")]
        ),
        .testTarget(
            name: "NectoMacServiceTests",
            dependencies: ["NectoMacService", "NectoCLIService", .product(name: "NectoSDK", package: "Necto")]
        ),
        .testTarget(
            name: "NectoCLITests",
            dependencies: ["necto-cli", "NectoCLIService", .product(name: "NectoSDK", package: "Necto")]
        ),
    ]
)
