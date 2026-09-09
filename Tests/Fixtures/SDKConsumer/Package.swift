// swift-tools-version: 6.0

// Copyright (c) 2026 Viva Republica, Inc.

import PackageDescription

let package = Package(
    name: "SDKConsumer",
    platforms: [.macOS(.v14), .iOS(.v16)],
    dependencies: [.package(name: "Necto", path: "../../..")],
    targets: [
        .testTarget(
            name: "SDKConsumerTests",
            dependencies: [.product(name: "NectoSDK", package: "Necto")]
        ),
    ]
)
