// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PngineTest",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(name: "PngineTest", targets: ["PngineTest"])
    ],
    dependencies: [
        .package(path: "../PngineKit")
    ],
    targets: [
        .target(
            name: "PngineTest",
            dependencies: ["PngineKit"]
        )
    ]
)
