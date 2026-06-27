import Foundation
import ProjectDescription

// Tuist is the source of truth for the Murmur app target — it regenerates the
// .xcodeproj, so bundle id and signing MUST live here (Xcode edits get clobbered).
//
// The app is a thin UI over MurmurKit, the shared dictation core it builds from
// the local `MurmurKit/` Swift package (which pulls STT from the fork's
// `dev/nemo-mic` worktree). The same MurmurKit powers `murmur-cli`. The global
// hotkey uses Carbon `RegisterEventHotKey` (KeyboardShortcuts) — no Accessibility.

// PostHog ingestion key injected at generation time. Tuist only forwards TUIST_-prefixed env
// vars into the manifest, so the maintainer's build sets TUIST_MURMUR_POSTHOG_KEY (local or
// CI). Absent in a plain `tuist generate` → source/fork builds ship with analytics OFF.
let posthogAPIKey = ProcessInfo.processInfo.environment["TUIST_MURMUR_POSTHOG_KEY"] ?? ""

// App version comes from the release tag. Tuist ONLY forwards TUIST_-prefixed env vars into
// the manifest, so CI must export TUIST_APP_VERSION (`murmur-vX.Y.Z` → X.Y.Z) before
// `tuist generate` — a bare APP_VERSION is silently filtered out and the build falls back.
// TUIST_APP_BUILD (e.g. the run number) gives a monotonic CFBundleVersion; else the version.
// Without these, Tuist's default Info.plist ships the placeholder 1.0.
let appVersion = ProcessInfo.processInfo.environment["TUIST_APP_VERSION"] ?? "0.1.0"
let appBuild = ProcessInfo.processInfo.environment["TUIST_APP_BUILD"] ?? appVersion

let project = Project(
    name: "Murmur",
    packages: [
        .local(path: "MurmurKit"),
        .remote(url: "https://github.com/sindresorhus/KeyboardShortcuts",
                requirement: .upToNextMajor(from: "2.0.0")),
        .remote(url: "https://github.com/PostHog/posthog-ios",
                requirement: .upToNextMajor(from: "3.0.0")),   // anonymous usage/error analytics (opt-out)
        .remote(url: "https://github.com/sparkle-project/Sparkle",
                requirement: .upToNextMajor(from: "2.6.0")),   // in-app auto-update (appcast + EdDSA)
    ],
    targets: [
        .target(
            name: "Murmur",
            destinations: .macOS,
            product: .app,
            bundleId: "app.bshk.murmur",
            deploymentTargets: .macOS("15.0"),   // MLXAudioSTT (dev/nemo-mic) requires macOS 15
            infoPlist: .extendingDefault(with: [
                "CFBundleShortVersionString": .string(appVersion),   // X.Y.Z from the release tag
                "CFBundleVersion": .string(appBuild),                // monotonic build (APP_BUILD) or version
                "LSUIElement": true,                       // menu-bar agent: no Dock icon
                "LSApplicationCategoryType": "public.app-category.productivity",
                "CFBundleDisplayName": "Murmur",
                "CFBundleLocalizations": ["en", "ru"],
                "CFBundleDevelopmentRegion": "en",
                "NSMicrophoneUsageDescription":
                    "Murmur transcribes your speech on-device while you hold the dictation hotkey.",
                // Analytics key injected from MURMUR_POSTHOG_KEY (empty in source/fork builds → off).
                "PostHogAPIKey": .string(posthogAPIKey),
                // Sparkle in-app updates: the appcast lives in the app's own GitHub repo
                // (the artifact source; the Homebrew tap stays thin).
                // Public key is shared across our Sparkle apps (Sparkle recommends one key).
                "SUFeedURL": "https://raw.githubusercontent.com/bshk-app/murmur/main/appcast.xml",
                "SUPublicEDKey": "vCki0eiwlGncDf3ZwIZawLNFss906pi/drQi/PnUaUA=",
                "SUEnableAutomaticChecks": true,
                "SUScheduledCheckInterval": 86400,   // daily
            ]),
            sources: ["Sources/Murmur/**/*.swift"],
            resources: ["Sources/Murmur/Resources/**"],
            dependencies: [
                .package(product: "MurmurKit"),
                .package(product: "KeyboardShortcuts"),
                .package(product: "PostHog"),
                .package(product: "Sparkle"),
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
