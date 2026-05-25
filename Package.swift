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
    dependencies: [
        .package(url: "https://github.com/ukushu/Ifrit.git", exact: "4.0.0")
    ],
    targets: [
        .target(
            name: "ATTCore",
            dependencies: [
                .product(name: "IfritStatic", package: "Ifrit")
            ]
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
