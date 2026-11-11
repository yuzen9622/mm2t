// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DiarizationEval",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            exact: "0.18.3",
            traits: ["Diarizer"]
        )
    ],
    targets: [
        .executableTarget(
            name: "diareval",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        )
    ]
)
