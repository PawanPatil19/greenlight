// swift-tools-version: 5.9
import PackageDescription

// Shared by the app and the widget extension. Foundation only, so it also builds
// and tests on Linux (CI runs `swift test` here).
let package = Package(
    name: "GreenlightKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "GreenlightKit", targets: ["GreenlightKit"])],
    targets: [
        .target(name: "GreenlightKit"),
        .testTarget(name: "GreenlightKitTests", dependencies: ["GreenlightKit"], exclude: ["Fixtures"]),
    ]
)
