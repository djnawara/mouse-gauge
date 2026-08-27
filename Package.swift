// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WLMouseMenuBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "WLMouseMenuBar", targets: ["WLMouseMenuBar"])
    ],
    targets: [
        .executableTarget(
            name: "WLMouseMenuBar",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit")
            ]
        )
    ]
)
