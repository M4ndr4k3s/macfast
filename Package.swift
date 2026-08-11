// swift-tools-version: 5.9
import PackageDescription

import Foundation

// The engine, the CLI and the tests only need Foundation, so they build and run
// on Linux too. The SwiftUI app cannot, so it is only offered when the package
// is being built from macOS — that way `swift test` works in Linux CI.
//
// MACFAST_SKIP_APP additionally drops the app from the package on macOS. It is
// meant for `swift test`: the test target does not depend on the app, but
// SwiftPM still builds every executable, and in test mode it compiles them as
// libraries — which leaves the entry point out and fails linking with an
// undefined `_MacFastApp_main`. Skipping the target sidesteps that; the app is
// still compiled by a plain `swift build`.
let skipApp = ProcessInfo.processInfo.environment["MACFAST_SKIP_APP"] != nil
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
if !skipApp {
    products.append(.executable(name: "MacFast", targets: ["MacFastApp"]))
    targets.append(.executableTarget(name: "MacFastApp", dependencies: ["MacFastKit"]))
}
#endif

let package = Package(
    name: "MacFast",
    platforms: [.macOS(.v11)],
    products: products,
    targets: targets
)
