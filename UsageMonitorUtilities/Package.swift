// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "UsageMonitorUtilities",
    platforms: [
        .iOS(.v13), .macOS(.v13), .tvOS(.v13), .watchOS(.v6)
    ],
    products: [
        .library(name: "UsageMonitorUtilities", targets: ["UsageMonitorUtilities"])
    ],
    targets: [
        .target(
            name: "UsageMonitorUtilities",
            path: ".",
            exclude: ["Package.swift"]
        )
    ]
)
