// swift-tools-version: 6.2
import PackageDescription

// Runs the core without any system service, on every platform, so its output can be compared
// across them (.github/workflows/core.yml).
let coreCheck: Target = .executableTarget(
    name: "longyan-core-check",
    dependencies: ["LongyanCore"],
    path: "Sources/LongyanCoreCheck",
    swiftSettings: [.swiftLanguageMode(.v5)]
)

#if os(macOS)
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
        coreCheck,
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
#else
// Windows and Linux: the core and the check tool only. llama.cpp (the same release and patch,
// CPU only) is built as static libraries into Vendor/llama/{include,lib}, as the workflow does.
let package = Package(
    name: "LongyanReader",
    targets: [
        .target(
            name: "LongyanCore",
            dependencies: ["llama"],
            path: "Sources/LongyanCore",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags(["-L", Context.packageDirectory + "/Vendor/llama/lib"]),
                .linkedLibrary("llama"), .linkedLibrary("ggml"), .linkedLibrary("ggml-cpu"), .linkedLibrary("ggml-base"),
                .linkedLibrary("stdc++", .when(platforms: [.linux])),
            ]
        ),
        coreCheck,
        // llama.h as the module `llama`, which the Mac gets from its framework.
        .systemLibrary(name: "llama", path: "Sources/LlamaSystem"),
    ]
)
#endif
