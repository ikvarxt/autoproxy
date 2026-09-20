// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "AdbProxy",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "AdbProxy", targets: ["AdbProxy"])
    ],
    targets: [
        .executableTarget(
            name: "AdbProxy"
        ),
        .testTarget(
            name: "AdbProxyTests",
            dependencies: ["AdbProxy"]
        )
    ]
)
