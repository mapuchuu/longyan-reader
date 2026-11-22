// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LongyanReader",
    platforms: [.macOS(.v15)],
    targets: [
        // Everything that decides what a card says: the dictionary, segmenter, notes, model
        // prompts and their fallbacks. Plain Swift and Foundation, so every platform's app
        // builds the same logic; the few system services it needs come through `Platform`.
        .target(
            name: "LongyanCore",
            dependencies: ["llama"],
            path: "Sources/LongyanCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "LongyanReader",
            dependencies: ["LongyanCore", "Sparkle"],
            path: "Sources/LongyanReader",
            swiftSettings: [.swiftLanguageMode(.v5)],
            // The app bundle carries llama.framework and Sparkle.framework in Contents/Frameworks (scripts/build-app.sh).
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        // llama.cpp (MIT): release b11588 with patches/llama.cpp-output-tokens.patch, built by
        // scripts/build-llama.sh.
        .binaryTarget(name: "llama", path: "Vendor/llama.xcframework"),
        // Sparkle (MIT) for updates: the release's prebuilt framework.
        .binaryTarget(
            name: "Sparkle",
            url: "https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-for-Swift-Package-Manager.zip",
            checksum: "4c2e48a3e50ebcc2c88a58a4c7264a1a99c3c31857ce754357afb9cdb323022a"
        ),
    ]
)
