// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "StowKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "StowKit", targets: ["StowKit"]),
    ],
    targets: [
        .target(name: "StowKit"),
        .testTarget(
            name: "StowKitTests",
            dependencies: ["StowKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
