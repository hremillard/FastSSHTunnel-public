// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FastSSHTunnel",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FastSSHTunnel", targets: ["FastSSHTunnel"])
    ],
    targets: [
        .executableTarget(name: "FastSSHTunnel"),
        .testTarget(name: "FastSSHTunnelTests", dependencies: ["FastSSHTunnel"])
    ]
)
