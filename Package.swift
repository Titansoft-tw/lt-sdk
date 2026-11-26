// swift-tools-version: 6.0
// iOS entry: SPM needs Package.swift at the repo root; each target points into its SDK folder with path:.
import PackageDescription

let package = Package(
    name: "lt-sdk",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LtDeviceInfo", targets: ["LtDeviceInfo"]),
    ],
    targets: [
        .target(name: "LtDeviceInfo", path: "LtDeviceInfo-ios/Sources/LtDeviceInfo"),
        .testTarget(name: "LtDeviceInfoTests", dependencies: ["LtDeviceInfo"], path: "LtDeviceInfo-ios/Tests/LtDeviceInfoTests"),
    ]
)
