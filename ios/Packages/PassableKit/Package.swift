// swift-tools-version: 6.0
import PackageDescription

// Passable's iPhone player as a reusable module: the standalone app and the
// Hub launcher both show `PassableRootView()`. `PassableMix.swift` is a
// symlink to the Mac app's file, so the .passablemix format can't drift.
// What the host app must declare is listed in `hub-module.json`.
let package = Package(
    name: "PassableKit",
    platforms: [.iOS(.v17)],
    products: [.library(name: "PassableKit", targets: ["PassableKit"])],
    targets: [.target(name: "PassableKit")],
    swiftLanguageModes: [.v5]
)
