// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MagicCommit",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MagicCommit",
            path: "Sources/MagicCommit"
        ),
        .testTarget(
            name: "MagicCommitTests",
            dependencies: ["MagicCommit"],
            path: "Tests/MagicCommitTests"
        ),
    ]
)
