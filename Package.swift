// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacFast",
    platforms: [.macOS(.v11)],
    products: [
        .library(name: "MacFastKit", targets: ["MacFastKit"]),
        .executable(name: "macfast", targets: ["macfastcli"]),
        .executable(name: "MacFast", targets: ["MacFastApp"]),
    ],
    targets: [
        .target(name: "MacFastKit"),
        .executableTarget(name: "macfastcli", dependencies: ["MacFastKit"]),
        .executableTarget(name: "MacFastApp", dependencies: ["MacFastKit"]),
        .testTarget(name: "MacFastKitTests", dependencies: ["MacFastKit"]),
    ]
)
