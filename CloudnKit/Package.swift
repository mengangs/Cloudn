// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "CloudnKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CloudnKit", targets: ["CloudnKit"])
    ],
    targets: [
        .target(name: "CloudnKit"),
        .testTarget(name: "CloudnKitTests", dependencies: ["CloudnKit"])
    ]
)
