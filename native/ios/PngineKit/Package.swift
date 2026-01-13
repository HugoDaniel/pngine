// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PngineKit",
    platforms: [
        .iOS(.v14),
        .macOS(.v11)
    ],
    products: [
        .library(
            name: "PngineKit",
            targets: ["PngineKit"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "PngineKit",
            dependencies: ["PngineCore"],
            path: "Sources/PngineKit"
        ),
        .binaryTarget(
            name: "PngineCore",
            // Path to XCFramework built by Zig
            path: "Sources/PngineCore.xcframework"
        ),
    ]
)
