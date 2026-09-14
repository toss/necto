// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "__PROJECT_NAME__",
    platforms: [
        .iOS(.v16),
        .macOS(.v14),
    ],
    products: [
        .library(name: "__PLUGIN_MODULE__", targets: ["__PLUGIN_MODULE__"]),
    ],
    dependencies: [
        .package(url: "__NECTO_REPOSITORY_URL__", exact: "__NECTO_VERSION__"),
    ],
    targets: [
        .target(
            name: "__PLUGIN_MODULE__",
            dependencies: [
                .product(name: "NectoSDK", package: "necto"),
            ],
            resources: [
                .copy("Panel"),
            ]
        ),
        .testTarget(
            name: "__PLUGIN_MODULE__Tests",
            dependencies: ["__PLUGIN_MODULE__"]
        ),
    ]
)
