import ProjectDescription

// Tuist is the source of truth for the Murmur app target (a proper .app bundle:
// Info.plist, agent mode, mic usage string). MLX/STT dependencies are added in a
// follow-up step via Tuist/Package.swift once the dictation pipeline is wired.
let project = Project(
    name: "Murmur",
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
            settings: .settings(base: ["SWIFT_VERSION": "5.0"])
        )
    ]
)
