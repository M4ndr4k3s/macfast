// swift-tools-version: 5.9
import PackageDescription

// The engine, the CLI and the tests only need Foundation, so they build and run
// on Linux too. The SwiftUI app cannot, so it is only offered when the package
// is being built from macOS — that way `swift test` works in Linux CI.
var products: [Product] = [
    .library(name: "MacFastKit", targets: ["MacFastKit"]),
    .executable(name: "macfast", targets: ["macfastcli"]),
]

var targets: [Target] = [
    .target(name: "MacFastKit"),
    .executableTarget(name: "macfastcli", dependencies: ["MacFastKit"]),
    .testTarget(name: "MacFastKitTests", dependencies: ["MacFastKit"]),
]

#if os(macOS)
products.append(.executable(name: "MacFast", targets: ["MacFastApp"]))
targets.append(.executableTarget(name: "MacFastApp", dependencies: ["MacFastKit"]))
#endif

let package = Package(
    name: "MacFast",
    platforms: [.macOS(.v11)],
    products: products,
    targets: targets
)
