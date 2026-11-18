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
            dependencies: ["MM2TCore", "MM2TProviders", "llama", "Bergamot", .product(name: "WhisperKit", package: "WhisperKit")]),
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11929/llama-b11929-xcframework.zip",
            checksum: "22644a57aad53f4a0a440860607c6d2f1da9e683f78cf03266569c0030d2dbd7"),
        // Mozilla's Bergamot translation engine behind a small C API, built by App/Tools/build-bergamot.sh
        // and published as a release asset of this repository.
        .binaryTarget(
            name: "Bergamot",
            url: "https://github.com/yuzen9622/mm2t/releases/download/bergamot-0.4.5-9271618/Bergamot.xcframework.zip",
            checksum: "97b1bb70599e7fab826cdb0548188be00b601258b896d3848f144d8b2d298d0b"),
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
