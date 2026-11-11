// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MM2TCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MM2TCore", targets: ["MM2TCore"]),
        .library(name: "MM2TProviders", targets: ["MM2TProviders"]),
        .library(name: "MM2TSystem", targets: ["MM2TSystem"]),
        .library(name: "MM2TDiarization", targets: ["MM2TDiarization"]),
        .executable(name: "mm2t-probe", targets: ["mm2t-probe"]),
    ],
    dependencies: [
        // Tools 6.2 is what lets the trait list drop FluidAudio's NemoTextProcessing binary and TTS code.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.3", traits: ["Diarizer"]),
    ],
    targets: [
        .target(name: "MM2TCore"),
        .target(name: "MM2TProviders", dependencies: ["MM2TCore"]),
        .target(name: "MM2TSystem", dependencies: ["MM2TCore"]),
        .target(
            name: "MM2TDiarization",
            dependencies: ["MM2TCore", .product(name: "FluidAudio", package: "FluidAudio")]),
        .executableTarget(name: "mm2t-probe", dependencies: ["MM2TSystem"]),
        .testTarget(name: "MM2TCoreTests", dependencies: ["MM2TCore"]),
        .testTarget(name: "MM2TProvidersTests", dependencies: ["MM2TProviders"]),
        .testTarget(name: "MM2TSystemTests", dependencies: ["MM2TSystem"]),
        .testTarget(name: "MM2TDiarizationTests", dependencies: ["MM2TDiarization", "MM2TCore"]),
    ],
    swiftLanguageModes: [.v6]
)
