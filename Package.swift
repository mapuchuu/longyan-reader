// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LongyanReader",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "LongyanReader",
            path: "Sources/LongyanReader",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
