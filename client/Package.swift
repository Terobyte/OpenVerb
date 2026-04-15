// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "openverb-client",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "OpenVerbClient",
            path: "Sources",
            exclude: ["main.swift"]
        ),
        .executableTarget(
            name: "openverb-client",
            dependencies: ["OpenVerbClient"],
            path: "Sources",
            sources: ["main.swift"]
        ),
        .testTarget(
            name: "IntegrationTests",
            dependencies: ["OpenVerbClient"],
            path: "Tests"
        ),
    ]
)
