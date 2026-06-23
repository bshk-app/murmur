// swift-tools-version: 6.0
import PackageDescription

// Shared core for both the Murmur menu-bar app and the murmur-cli tool: mic
// capture, the two-tier STT engine wrapper, text injection, and the dictation
// orchestrator. STT comes from the fork's `dev/nemo-mic` branch via its git
// worktree (a local path dependency; identity = the worktree dir name).
let package = Package(
    name: "MurmurKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MurmurKit", targets: ["MurmurKit"]),
        .executable(name: "murmur-cli", targets: ["murmur-cli"]),
    ],
    dependencies: [
        .package(path: "/Volumes/DATA/mlx-audio-swift-worktrees/nemotron-session"),
    ],
    targets: [
        .target(
            name: "MurmurKit",
            dependencies: [.product(name: "MLXAudioSTT", package: "nemotron-session")]
        ),
        .executableTarget(
            name: "murmur-cli",
            dependencies: ["MurmurKit"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
