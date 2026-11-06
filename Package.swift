// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 David Nawara

import PackageDescription

let package = Package(
    name: "MouseGauge",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MouseGauge", targets: ["MouseGauge"])
    ],
    targets: [
        .executableTarget(
            name: "MouseGauge",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit")
            ]
        )
    ]
)
