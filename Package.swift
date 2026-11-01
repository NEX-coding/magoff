// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MagOff",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MagOff", targets: ["MagOffApp"]),
        .executable(name: "magoff-helper", targets: ["MagOffHelper"]),
    ],
    targets: [
        .target(name: "MagOffCore"),
        .executableTarget(
            name: "MagOffHelper",
            dependencies: ["MagOffCore"]
        ),
        .executableTarget(
            name: "MagOffApp",
            dependencies: ["MagOffCore"]
        ),
    ]
)
