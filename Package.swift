// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DiskBro",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "DiskBro",
            path: "Sources/DiskBro",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
