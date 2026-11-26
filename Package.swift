// swift-tools-version: 6.0
// iOS entry: SPM needs Package.swift at the repo root; each target points into its SDK folder with path:.
import PackageDescription

let package = Package(
    name: "lt-sdk",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [],
    targets: []
)
