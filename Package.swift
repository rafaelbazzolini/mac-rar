// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacRar",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "MacRar", targets: ["MacRar"])],
    targets: [
        .target(name: "ArchiveBridge", linkerSettings: [.linkedLibrary("archive")]),
        .executableTarget(name: "MacRar", dependencies: ["ArchiveBridge"]),
        .testTarget(name: "MacRarTests", dependencies: ["MacRar"])
    ]
)
