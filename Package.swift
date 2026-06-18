// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Headroom",
    // Localization base. The String Catalog (Sources/HeadroomApp/Resources/Localizable.xcstrings)
    // makes the UI translation-ready; the top-10 translations are the documented fast-follow
    // (see docs/I18N.md).
    defaultLocalization: "en",
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
            dependencies: ["HeadroomKit"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "HeadroomKitTests",
            dependencies: ["HeadroomKit"]
        ),
    ]
)
