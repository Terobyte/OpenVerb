// swift-tools-version: 5.9
//
// Package.swift — OpenVerb macOS app (MVP3)
//
// NOTE: Full GUI build requires Xcode (SwiftUI lifecycle, LSUIElement, entitlements).
// This Package.swift exists for SPM-based code validation and test execution.
// The @main entry point (App/OpenVerbApp.swift) is excluded because it conflicts
// with SPM's own entry point handling; it is included in the Xcode target directly.

import PackageDescription

let package = Package(
    name: "OpenVerb",
    platforms: [.macOS(.v13)],
    targets: [
        // Library target: all app logic except the @main entry point.
        .target(
            name: "OpenVerb",
            path: "OpenVerb",
            exclude: [
                "App/OpenVerbApp.swift",   // @main — built via Xcode, not SPM
                "Resources",
            ],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("IOKit"),
            ]
        ),
        .testTarget(
            name: "OpenVerbTests",
            dependencies: ["OpenVerb"],
            path: "OpenVerbTests"
        ),
    ]
)
