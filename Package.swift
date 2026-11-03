// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Necto",
    platforms: [
        .macOS(.v14),
        .iOS(.v16),
    ],
    products: [
        .library(name: "NectoSDK", targets: ["NectoSDK"]),
        .library(name: "NectoNetworkPlugin", targets: ["NectoNetworkPlugin"]),
        .library(name: "NectoEventsPlugin", targets: ["NectoEventsPlugin"]),
        .library(name: "NectoFilesPlugin", targets: ["NectoFilesPlugin"]),
        .library(name: "NectoPreferencesPlugin", targets: ["NectoPreferencesPlugin"]),
        .library(name: "NectoPerformancePlugin", targets: ["NectoPerformancePlugin"]),
        .library(name: "NectoUIControlPlugin", targets: ["NectoUIControlPlugin"]),
        .library(name: "NectoProcessMetricPlugin", targets: ["NectoProcessMetricPlugin"]),
        .library(name: "NectoURLSessionCapturePlugin", targets: ["NectoURLSessionCapturePlugin"]),
    ],
    targets: [
        .target(name: "NectoModel", path: "SDK/iOS/Sources/NectoModel"),
        .target(
            name: "NectoTransport",
            path: "SDK/iOS/Sources/NectoTransport"
        ),
        .target(
            name: "NectoSDK",
            dependencies: ["NectoModel", "NectoTransport"],
            path: "SDK/iOS/Sources/NectoSDK"
        ),
        .target(
            name: "NectoNetworkPlugin",
            dependencies: ["NectoModel", "NectoSDK"],
            path: "SDK/iOS/Sources/NectoNetworkPlugin",
            resources: [.copy("Panels")]
        ),
        .target(
            name: "NectoEventsPlugin",
            dependencies: ["NectoModel", "NectoSDK"],
            path: "SDK/iOS/Sources/NectoEventsPlugin",
            resources: [.copy("Panels")]
        ),
        .target(
            name: "NectoFilesPlugin",
            dependencies: ["NectoModel", "NectoSDK"],
            path: "SDK/iOS/Sources/NectoFilesPlugin",
            resources: [.copy("Panels")]
        ),
        .target(
            name: "NectoPreferencesPlugin",
            dependencies: ["NectoModel", "NectoSDK"],
            path: "SDK/iOS/Sources/NectoPreferencesPlugin",
            resources: [.copy("Panels")]
        ),
        .target(
            name: "NectoPerformancePlugin",
            dependencies: ["NectoModel", "NectoSDK"],
            path: "SDK/iOS/Sources/NectoPerformancePlugin",
            resources: [.copy("Panels")]
        ),
        .target(
            name: "NectoUIControlPlugin",
            dependencies: ["NectoModel", "NectoSDK"],
            path: "SDK/iOS/Sources/NectoUIControlPlugin",
            resources: [.copy("Panels")]
        ),
        // CPU, memory and frame-rate capture for apps that explicitly opt in.
        .target(
            name: "NectoProcessMetricPlugin",
            dependencies: ["NectoPerformancePlugin", "NectoModel", "NectoSDK"],
            path: "SDK/iOS/Sources/NectoProcessMetricPlugin"
        ),
        // Capture stays separate from the reporting API and starts only on registration.
        .target(
            name: "NectoURLSessionCapturePlugin",
            dependencies: ["NectoNetworkPlugin", "NectoModel", "NectoSDK"],
            path: "SDK/iOS/Sources/NectoURLSessionCapturePlugin"
        ),
        .testTarget(
            name: "NectoModelTests",
            dependencies: ["NectoModel"],
            path: "SDK/iOS/Tests/NectoModelTests"
        ),
        .testTarget(
            name: "NectoTransportTests",
            dependencies: ["NectoTransport"],
            path: "SDK/iOS/Tests/NectoTransportTests"
        ),
        .testTarget(
            name: "NectoSDKTests",
            dependencies: [
                "NectoSDK", "NectoProcessMetricPlugin", "NectoTransport", "NectoModel",
                "NectoNetworkPlugin", "NectoEventsPlugin", "NectoFilesPlugin", "NectoPreferencesPlugin",
                "NectoPerformancePlugin", "NectoUIControlPlugin",
            ],
            path: "SDK/iOS/Tests/NectoSDKTests"
        ),
        .testTarget(
            name: "NectoURLSessionCaptureTests",
            dependencies: ["NectoURLSessionCapturePlugin", "NectoNetworkPlugin", "NectoModel"],
            path: "SDK/iOS/Tests/NectoURLSessionCaptureTests"
        ),
        .testTarget(
            name: "NectoProcessMetricsTests",
            dependencies: ["NectoProcessMetricPlugin", "NectoPerformancePlugin", "NectoSDK", "NectoModel"],
            path: "SDK/iOS/Tests/NectoProcessMetricsTests"
        ),
    ]
)
