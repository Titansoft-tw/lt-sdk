// swift-tools-version: 6.0
// iOS entry: SPM needs Package.swift at the repo root; each target points into its SDK folder with path:.
import PackageDescription

let package = Package(
    name: "lt-sdk",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LtDeviceInfo", targets: ["LtDeviceInfo"]),
        .library(name: "LtTelemetry", targets: ["LtTelemetry"]),
        .library(name: "LtErrorGuard", targets: ["LtErrorGuard"]),
        .library(name: "LtErrorGuardSentry", targets: ["LtErrorGuardSentry"]),
    ],
    // Only LtErrorGuardSentry uses it; the range follows the app's own sentry-cocoa (8.x and 9.x).
    dependencies: [.package(url: "https://github.com/getsentry/sentry-cocoa", "8.0.0"..<"10.0.0")],
    targets: [
        .target(name: "LtDeviceInfo", path: "LtDeviceInfo-ios/Sources/LtDeviceInfo"),
        .testTarget(name: "LtDeviceInfoTests", dependencies: ["LtDeviceInfo"], path: "LtDeviceInfo-ios/Tests/LtDeviceInfoTests"),
        .target(name: "LtTelemetry", dependencies: ["LtDeviceInfo"], path: "LtTelemetry-ios/Sources/LtTelemetry"),
        .testTarget(name: "LtTelemetryTests", dependencies: ["LtTelemetry"], path: "LtTelemetry-ios/Tests/LtTelemetryTests"),
        .target(name: "LtErrorGuard", path: "LtErrorGuard-ios/Sources/LtErrorGuard"),
        .testTarget(name: "LtErrorGuardTests", dependencies: ["LtErrorGuard"], path: "LtErrorGuard-ios/Tests/LtErrorGuardTests"),
        .target(name: "LtErrorGuardSentry", dependencies: ["LtErrorGuard", .product(name: "Sentry", package: "sentry-cocoa")],
                path: "LtErrorGuardSentry-ios/Sources/LtErrorGuardSentry"),
        .testTarget(name: "LtErrorGuardSentryTests", dependencies: ["LtErrorGuardSentry", .product(name: "Sentry", package: "sentry-cocoa")],
                    path: "LtErrorGuardSentry-ios/Tests/LtErrorGuardSentryTests"),
    ]
)
