// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "quigsphoto-uploader",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/Kitura/Swift-SMTP.git", from: "6.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "quigsphoto-uploader",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "SwiftSMTP", package: "Swift-SMTP"),
            ]
        ),
        .testTarget(
            name: "quigsphoto-uploaderTests",
            dependencies: ["quigsphoto-uploader"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
