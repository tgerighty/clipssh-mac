// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "clipssh-mac",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "ClipsshCore"),
        .executableTarget(
            name: "ClipsshMac",
            dependencies: ["ClipsshCore"]
        ),
        .testTarget(
            name: "ClipsshCoreTests",
            dependencies: ["ClipsshCore"]
        ),
        .testTarget(
            name: "ClipsshMacTests",
            dependencies: ["ClipsshMac", "ClipsshCore"]
        )
    ]
)
