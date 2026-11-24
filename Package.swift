// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Browter",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "BrowterCore", targets: ["BrowterCore"]),
        .executable(name: "Browter", targets: ["Browter"]),
    ],
    targets: [
        .target(
            name: "BrowterCore",
            path: "Sources/BrowterCore"
        ),
        .executableTarget(
            name: "Browter",
            dependencies: ["BrowterCore"],
            path: "Sources/Browter"
        ),
        .testTarget(
            name: "BrowterTests",
            dependencies: ["BrowterCore"],
            path: "Tests/BrowterTests"
        ),
    ]
)
