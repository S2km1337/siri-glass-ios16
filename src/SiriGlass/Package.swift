// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SiriGlass",
    platforms: [
        .iOS(.v16),
    ],
    products: [
        .library(name: "SiriGlass", targets: ["SiriGlass"]),
    ],
    targets: [
        .target(
            name: "SiriGlass",
            exclude: ["SiriGlass.metal.txt"]
        ),
        .testTarget(name: "SiriGlassTests", dependencies: ["SiriGlass"]),
    ]
)
