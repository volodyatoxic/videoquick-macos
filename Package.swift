// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "VideoQuick", platforms: [.macOS(.v14)], products: [.library(name: "VideoQuickCore", targets: ["VideoQuickCore"])], targets: [.target(name: "VideoQuickCore"), .testTarget(name: "VideoQuickCoreTests", dependencies: ["VideoQuickCore"])])
