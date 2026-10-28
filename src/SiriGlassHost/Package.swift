// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SiriGlassHost",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "SiriGlassHost", type: .dynamic, targets: ["SiriGlassHost"]),
    ],
    dependencies: [
        .package(path: "../SiriGlass"),
    ],
    targets: [
        .target(name: "SiriGlassHost", dependencies: [.product(name: "SiriGlass", package: "SiriGlass")]),
    ]
)
