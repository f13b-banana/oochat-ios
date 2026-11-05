// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ConnectOnionKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ConnectOnionKit", targets: ["ConnectOnionKit"])
    ],
    targets: [
        .target(
            name: "ConnectOnionKit",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "ConnectOnionKitTests",
            dependencies: ["ConnectOnionKit"],
            resources: [.copy("Fixtures")]
        )
    ]
)
