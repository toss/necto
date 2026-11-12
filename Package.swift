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
            path: "SDK/Plugins/Network",
            exclude: ["Android"],
            sources: ["iOS"],
            resources: [.copy("Panel")]
        ),
        .target(
            name: "NectoEventsPlugin",
            dependencies: ["NectoModel", "NectoSDK"],
            path: "SDK/Plugins/Events",
            exclude: ["Android"],
            sources: ["iOS"],
            resources: [.copy("Panel")]
        ),
        .target(
            name: "NectoFilesPlugin",
            dependencies: ["NectoModel", "NectoSDK"],
            path: "SDK/Plugins/Files",
            exclude: ["Android"],
            sources: ["iOS"],
            resources: [.copy("Panel")]
        ),
        .target(
            name: "NectoPreferencesPlugin",
            dependencies: ["NectoModel", "NectoSDK"],
            path: "SDK/Plugins/Preferences",
            exclude: ["Android"],
            sources: ["iOS"],
            resources: [.copy("Panel")]
        ),
        .target(
            name: "NectoPerformancePlugin",
            dependencies: ["NectoModel", "NectoSDK"],
            path: "SDK/Plugins/Performance",
            exclude: ["Android"],
            sources: ["iOS"],
            resources: [.copy("Panel")]
        ),
        .target(
            name: "NectoUIControlPlugin",
            dependencies: ["NectoModel", "NectoSDK"],
            path: "SDK/Plugins/UIControl",
            exclude: ["Android"],
            sources: ["iOS"],
            resources: [.copy("Panel")]
        ),
        // CPU, memory and frame-rate capture for apps that explicitly opt in.
        .target(
            name: "NectoProcessMetricPlugin",
            dependencies: ["NectoPerformancePlugin", "NectoModel", "NectoSDK"],
            path: "SDK/Plugins/ProcessMetric/iOS"
        ),
        // Capture stays separate from the reporting API and starts only on registration.
        .target(
            name: "NectoURLSessionCapturePlugin",
            dependencies: ["NectoNetworkPlugin", "NectoModel", "NectoSDK"],
            path: "SDK/Plugins/URLSessionCapture/iOS"
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
