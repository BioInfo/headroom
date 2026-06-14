// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Headroom",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HeadroomKit", targets: ["HeadroomKit"]),
        .executable(name: "headroom", targets: ["headroom"]),
        .executable(name: "HeadroomApp", targets: ["HeadroomApp"]),
    ],
    targets: [
        .target(name: "HeadroomKit"),
        .executableTarget(
            name: "headroom",
            dependencies: ["HeadroomKit"]
        ),
        .executableTarget(
            name: "HeadroomApp",
            dependencies: ["HeadroomKit"]
        ),
        .testTarget(
            name: "HeadroomKitTests",
            dependencies: ["HeadroomKit"]
        ),
    ]
)
