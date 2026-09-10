// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ziri",
    platforms: [.macOS("15.0"), .iOS("18.0")],
    products: [
        .library(name: "ZiriCore", targets: ["ZiriCore"]),
    ],
    targets: [
        .target(name: "ZiriCore"),
        .executableTarget(name: "ziri", dependencies: ["ZiriCore"]),
    ]
)
