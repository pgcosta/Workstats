// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "workstats",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "workstats",
            path: "Sources/workstats"
        )
    ]
)
