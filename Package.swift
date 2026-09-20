// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "AutoProxy",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "AutoProxy", targets: ["AutoProxy"])
    ],
    targets: [
        .executableTarget(
            name: "AutoProxy"
        ),
        .testTarget(
            name: "AutoProxyTests",
            dependencies: ["AutoProxy"]
        )
    ]
)
