// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LongyanReader",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "LongyanReader",
            dependencies: ["llama"],
            path: "Sources/LongyanReader",
            swiftSettings: [.swiftLanguageMode(.v5)],
            // The app bundle carries llama.framework in Contents/Frameworks (scripts/build-app.sh).
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        // llama.cpp (MIT), the release's prebuilt Metal framework.
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11588/llama-b11588-xcframework.zip",
            checksum: "4efb28d65a9e4bade3e1d0aeeaf6094206de85b7ad77da2cb585a938bfb1f052"
        ),
    ]
)
