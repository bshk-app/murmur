import ProjectDescription

// Tuist is the source of truth for the Murmur app target — it regenerates the
// .xcodeproj, so bundle id and signing MUST live here, not in Xcode (manual
// project edits get clobbered on `tuist generate`).
//
// STT comes from the fork's `dev/nemo-mic` branch (Nemotron + Voxtral +
// TwoTierEngine) via Xcode-native SPM from its git worktree. The global hotkey
// uses Carbon `RegisterEventHotKey` (KeyboardShortcuts) — no Accessibility.
let project = Project(
    name: "Murmur",
    packages: [
        .local(path: "/Volumes/DATA/mlx-audio-swift-worktrees/nemotron-session"),
        .remote(url: "https://github.com/sindresorhus/KeyboardShortcuts",
                requirement: .upToNextMajor(from: "2.0.0")),
    ],
    targets: [
        .target(
            name: "Murmur",
            destinations: .macOS,
            product: .app,
            bundleId: "app.bshk.murmur",
            deploymentTargets: .macOS("15.0"),   // MLXAudioSTT (dev/nemo-mic) requires macOS 15
            infoPlist: .extendingDefault(with: [
                "LSUIElement": true,                       // menu-bar agent: no Dock icon
                "CFBundleDisplayName": "Murmur",
                "NSMicrophoneUsageDescription":
                    "Murmur transcribes your speech on-device while you hold the dictation hotkey.",
            ]),
            sources: ["Sources/Murmur/**"],
            dependencies: [
                .package(product: "MLXAudioSTT"),
                .package(product: "KeyboardShortcuts"),
            ],
            settings: .settings(base: [
                "SWIFT_VERSION": "5.0",
                // Stable signature so the Accessibility (typing) grant persists
                // across rebuilds — ad-hoc cdhash churn invalidates TCC every build.
                "CODE_SIGN_STYLE": "Automatic",
                "DEVELOPMENT_TEAM": "Q8H6GWJ658",
                "CODE_SIGN_IDENTITY": "Apple Development",
            ])
        )
    ]
)
