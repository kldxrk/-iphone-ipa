// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VNPlayer",
    platforms: [.iOS(.v16)],
    products: [.library(name: "VNPlayer", targets: ["VNPlayer"])],
    targets: [.target(name: "VNPlayer", path: "Sources/VNPlayer")]
)
