// swift-tools-version: 6.0
import PackageDescription

// Shared core for the Murmur menu-bar app and murmur-cli: mic capture,
// Nemotron live transcription, Parakeet batch final, Silero speech boundaries,
// text injection, and the dictation orchestrator.
//
// STT and VAD come from `beshkenadze/mlx-audio-swift` over HTTPS, pinned to
// `main`. The two-pass composition is application policy and lives in MurmurKit.
let package = Package(
    name: "MurmurKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MurmurKit", targets: ["MurmurKit"]),
        .executable(name: "murmur-cli", targets: ["murmur-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/beshkenadze/mlx-audio-swift.git", branch: "main"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", .upToNextMajor(from: "0.8.1")),
    ],
    targets: [
        .target(
            name: "MurmurKit",
            dependencies: [
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),  // ModelUtils.resolveOrDownloadModel
                .product(name: "MLXAudioVAD", package: "mlx-audio-swift"),   // Silero speech boundaries
                .product(name: "HuggingFace", package: "swift-huggingface"), // Repo.ID / HubClient / HubCache
            ]
        ),
        .executableTarget(
            name: "murmur-cli",
            dependencies: ["MurmurKit"]
        ),
        .testTarget(
            name: "MurmurKitTests",
            dependencies: ["MurmurKit"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
