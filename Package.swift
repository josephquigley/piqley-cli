// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "piqley",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/sersoft-gmbh/swift-smtp.git", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "piqley",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "SwiftSMTP", package: "swift-smtp"),
            ]
        ),
        .testTarget(
            name: "piqleyTests",
            dependencies: ["piqley"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
