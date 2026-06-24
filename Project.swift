import ProjectDescription

// Tuist is the source of truth for the Murmur app target — it regenerates the
// .xcodeproj, so bundle id and signing MUST live here (Xcode edits get clobbered).
//
// The app is a thin UI over MurmurKit, the shared dictation core it builds from
// the local `MurmurKit/` Swift package (which pulls STT from the fork's
// `dev/nemo-mic` worktree). The same MurmurKit powers `murmur-cli`. The global
// hotkey uses Carbon `RegisterEventHotKey` (KeyboardShortcuts) — no Accessibility.
let project = Project(
    name: "Murmur",
    packages: [
        .local(path: "MurmurKit"),
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
                "LSApplicationCategoryType": "public.app-category.productivity",
                "CFBundleDisplayName": "Murmur",
                "NSMicrophoneUsageDescription":
                    "Murmur transcribes your speech on-device while you hold the dictation hotkey.",
            ]),
            sources: ["Sources/Murmur/**/*.swift"],
            resources: ["Sources/Murmur/Resources/**"],
            dependencies: [
                .package(product: "MurmurKit"),
                .package(product: "KeyboardShortcuts"),
            ],
            settings: .settings(base: [
                "SWIFT_VERSION": "5.0",
                "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",   // Media.xcassets/AppIcon (cat)
                // Stable signature so the Accessibility (typing) grant persists.
                "CODE_SIGN_STYLE": "Automatic",
                "DEVELOPMENT_TEAM": "Q8H6GWJ658",
                "CODE_SIGN_IDENTITY": "Apple Development",
            ])
        )
    ]
)
