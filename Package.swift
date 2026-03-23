// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "piqley",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/josephquigley/piqley-plugin-sdk.git", .upToNextMajor(from: "0.6.0")),
    ],
    targets: [
        .executableTarget(
            name: "piqley",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "PiqleyPluginSDK", package: "piqley-plugin-sdk"),
            ]
        ),
        .testTarget(
            name: "piqleyTests",
            dependencies: ["piqley"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
