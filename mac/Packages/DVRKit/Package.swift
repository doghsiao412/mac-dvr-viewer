// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DVRKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "DVRKit", targets: ["DVRKit"]),
        .executable(name: "dvrcli", targets: ["dvrcli"]),
    ],
    targets: [
        .target(name: "DVRKit"),
        .executableTarget(name: "dvrcli", dependencies: ["DVRKit"]),
        .testTarget(name: "DVRKitTests", dependencies: ["DVRKit"]),
    ]
)
