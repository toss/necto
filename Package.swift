// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Necto",
    platforms: [
        .macOS(.v14),
        .iOS(.v16),
    ],
    products: [
        .library(name: "NectoSDK", targets: [
            "NectoSDK", "NectoDefaultPlugins", "NectoProcessMetrics",
            "NectoURLSessionCapture", "NectoModel", "NectoTransport",
        ]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.37.5"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.98.0"),
    ],
    targets: [
        .target(name: "NectoModel"),
        .target(
            name: "NectoTransport",
            dependencies: [
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOTLS", package: "swift-nio"),
            ]
        ),
        .target(
            name: "NectoSDK",
            dependencies: ["NectoModel", "NectoTransport"]
        ),
        .target(
            name: "NectoDefaultPlugins",
            dependencies: [
                "NectoModel", "NectoSDK",
                .target(name: "NectoTouchInjection", condition: .when(platforms: [.iOS])),
            ],
            resources: [
                .copy("Panels"),
            ]
        ),
        .target(name: "NectoTouchInjection"),
        // CPU, memory and frame-rate capture for apps that explicitly opt in.
        .target(
            name: "NectoProcessMetrics",
            dependencies: ["NectoDefaultPlugins", "NectoModel", "NectoSDK"]
        ),
        // Capture stays separate from the reporting API and starts only on registration.
        .target(
            name: "NectoURLSessionCapture",
            dependencies: ["NectoDefaultPlugins", "NectoModel", "NectoSDK"]
        ),
        .testTarget(
            name: "NectoModelTests",
            dependencies: ["NectoModel"]
        ),
        .testTarget(
            name: "NectoTransportTests",
            dependencies: ["NectoTransport"]
        ),
        .testTarget(
            name: "NectoSDKTests",
            dependencies: ["NectoSDK", "NectoDefaultPlugins", "NectoProcessMetrics", "NectoTransport", "NectoModel"]
        ),
        .testTarget(
            name: "NectoProcessMetricsTests",
            dependencies: ["NectoProcessMetrics", "NectoDefaultPlugins", "NectoSDK", "NectoModel"]
        ),
    ]
)
