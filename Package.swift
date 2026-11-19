// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MM2TCore",
    defaultLocalization: "en",
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "MM2TCore", targets: ["MM2TCore"]),
        .library(name: "MM2TProviders", targets: ["MM2TProviders"]),
        .library(name: "MM2TSystem", targets: ["MM2TSystem"]),
        .library(name: "MM2TDiarization", targets: ["MM2TDiarization"]),
        .library(name: "MM2TLocal", targets: ["MM2TLocal"]),
        .library(name: "MM2TApp", targets: ["MM2TApp"]),
        // Kept free of the other modules: the sandboxed widget extension links only this.
        .library(name: "MM2TWidgetData", targets: ["MM2TWidgetData"]),
    ],
    dependencies: [
        // Tools 6.2 is what lets the trait list drop FluidAudio's NemoTextProcessing binary and TTS code.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.3", traits: ["Diarizer"]),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1"),
    ],
    targets: [
        .target(name: "MM2TCore"),
        .target(name: "MM2TProviders", dependencies: ["MM2TCore"]),
        .target(name: "MM2TSystem", dependencies: ["MM2TCore"]),
        .target(
            name: "MM2TDiarization",
            dependencies: ["MM2TCore", .product(name: "FluidAudio", package: "FluidAudio")]),
        .target(
            name: "MM2TLocal",
            dependencies: ["MM2TCore", "MM2TProviders", "llama", "Bergamot", "CWhisperCPU", .product(name: "FluidAudio", package: "FluidAudio"), .product(name: "WhisperKit", package: "WhisperKit")]),
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11929/llama-b11929-xcframework.zip",
            checksum: "22644a57aad53f4a0a440860607c6d2f1da9e683f78cf03266569c0030d2dbd7"),
        .target(name: "CWhisperCPU", dependencies: ["whisper"]),
        .binaryTarget(name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.2/whisper-v1.9.2-xcframework.zip",
            checksum: "af74fed13ea7f2d5ca2a39d9f58ec177713fafd7cab63aef4e27b79f3ceca80b"),
        // App/Tools/build-bergamot.sh builds the engine with optional shortlist support.
        .binaryTarget(name: "Bergamot", path: "Vendor/Bergamot.xcframework.zip"),
        .target(name: "MM2TWidgetData"),
        .target(name: "MM2TApp", dependencies: ["MM2TCore", "MM2TProviders", "MM2TSystem", "MM2TDiarization", "MM2TLocal", "MM2TWidgetData"]),
        .testTarget(name: "MM2TCoreTests", dependencies: ["MM2TCore"]),
        .testTarget(name: "MM2TProvidersTests", dependencies: ["MM2TProviders"]),
        .testTarget(name: "MM2TSystemTests", dependencies: ["MM2TSystem"]),
        .testTarget(name: "MM2TDiarizationTests", dependencies: ["MM2TDiarization", "MM2TCore"]),
        .testTarget(name: "MM2TLocalTests", dependencies: ["MM2TLocal", "MM2TCore", "MM2TProviders", "llama"]),
        .testTarget(name: "MM2TAppTests", dependencies: ["MM2TApp", "MM2TCore", "MM2TSystem", "MM2TProviders", "MM2TDiarization", "MM2TLocal", "MM2TWidgetData"]),
        .testTarget(name: "MM2TWidgetDataTests", dependencies: ["MM2TWidgetData"]),
    ],
    swiftLanguageModes: [.v6]
)
