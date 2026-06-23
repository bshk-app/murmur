import ProjectDescription

// Tuist is the source of truth for the Murmur app target (a proper .app bundle:
// Info.plist, agent mode, mic usage string).
//
// On-device STT comes from the fork's `dev/nemo-mic` branch (Nemotron stream +
// Voxtral Realtime + TwoTierSession), which is NOT merged to main — consumed via
// Xcode-native SPM from the existing git worktree that has that branch checked
// out. Native SPM builds only `MLXAudioSTT` + its transitive deps, so the
// package's executables/tests don't get pulled into the app build.
let project = Project(
    name: "Murmur",
    packages: [
        .local(path: "/Volumes/DATA/mlx-audio-swift-worktrees/nemotron-session")
    ],
    targets: [
        .target(
            name: "Murmur",
            destinations: .macOS,
            product: .app,
            bundleId: "dev.beshkenadze.Murmur",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .extendingDefault(with: [
                "LSUIElement": true,                       // menu-bar agent: no Dock icon
                "CFBundleDisplayName": "Murmur",
                "NSMicrophoneUsageDescription":
                    "Murmur transcribes your speech on-device while you hold the dictation hotkey.",
            ]),
            sources: ["Sources/Murmur/**"],
            dependencies: [
                .package(product: "MLXAudioSTT")
            ],
            settings: .settings(base: ["SWIFT_VERSION": "5.0"])
        )
    ]
)
