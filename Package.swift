// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AllTheThings",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "AllTheThings", targets: ["AllTheThings"])
    ],
    targets: [
        .target(
            name: "ATTCore"
        ),
        .executableTarget(
            name: "AllTheThings",
            dependencies: ["ATTCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreServices")
            ]
        ),
        .testTarget(
            name: "ATTCoreTests",
            dependencies: ["ATTCore"]
        )
    ]
)
