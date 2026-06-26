// swift-tools-version: 6.0
import PackageDescription

// Shared core for the Murmur menu-bar app and the murmur-cli tool: mic capture,
// the two-tier STT composition, the Silero speech gate, text injection, and the
// dictation orchestrator.
//
// STT + VAD come from the fork `beshkenadze/mlx-audio-swift` as a normal external
// dependency over HTTPS, pinned to `main` (which already carries the merged
// Nemotron/Voxtral streaming sessions + Silero VAD, all public, no dev-only
// tooling). The two-tier composition itself lives here in MurmurKit, not the
// library — it's application policy (which models, how to merge, memory budget).
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
                .product(name: "MLXAudioVAD", package: "mlx-audio-swift"),   // Silero 32ms speech gate
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),  // ModelUtils.resolveOrDownloadModel
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
