// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Redeploy",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "RedeployCore"),
        .executableTarget(name: "Redeploy", dependencies: ["RedeployCore"]),
        .testTarget(name: "RedeployCoreTests", dependencies: ["RedeployCore"]),
    ]
)
