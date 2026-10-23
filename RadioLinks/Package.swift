// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RadioLinks",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "RadioLinks", targets: ["RadioLinks"])],
    targets: [.executableTarget(name: "RadioLinks")]
)
