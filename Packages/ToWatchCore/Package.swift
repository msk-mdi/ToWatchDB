// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ToWatchCore",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "ToWatchCore", targets: ["ToWatchCore"]),
    ],
    targets: [
        .target(name: "ToWatchCore"),
        .testTarget(
            name: "ToWatchCoreTests",
            dependencies: ["ToWatchCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
