import AppKit
import SwiftUI

/// Murmur — local push-to-talk dictation for macOS.
///
/// Hold a global hotkey, speak, and the transcription is typed into the focused
/// field of whatever app you're in. Everything runs on-device via MLX (no cloud).
@main
struct MurmurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuPopover(dictation: appDelegate.dictation,
                        model: appDelegate.onboarding,
                        router: appDelegate.router)
        } label: {
            // The opener lives on the LABEL (not the popover content): a
            // `.window`-style MenuBarExtra doesn't instantiate its content until the
            // menu is first opened, but the label renders at launch and stays alive —
            // so it's the only place that can catch the first-run trigger.
            MenuBarLabel(icon: Self.menuIcon, router: appDelegate.router)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }

        Window("MurMur Setup", id: "onboarding") {
            OnboardingView(model: appDelegate.onboarding)
                .frame(width: 880, height: 580)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }

    /// The menu-bar glyph: `cat_fill` (Media.xcassets) rendered as a **template**
    /// — monochrome, auto-tinted for light/dark menu bars — sized to the menu bar.
    /// Falls back to an SF Symbol if the asset is somehow missing.
    private static let menuIcon: NSImage = {
        let image = NSImage(named: "cat_fill")
            ?? NSImage(systemSymbolName: "mic.circle", accessibilityDescription: "Murmur")
            ?? NSImage()
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()
}

/// The menu-bar icon, doubling as the always-alive opener for the onboarding
/// window. When the router's `showOnboarding` flips true (first run via
/// `applicationDidFinishLaunching`, or "Setup tour…" from the popover), it opens
/// the SwiftUI `Window` and resets the flag. `.onAppear` catches a flip that
/// already happened before the label rendered; `.onChange` catches later flips —
/// together they cover whichever runs first at launch.
private struct MenuBarLabel: View {
    let icon: NSImage
    let router: AppRouter
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: icon)
            .onAppear { openOnboardingIfRequested() }
            .onChange(of: router.showOnboarding) { _, _ in openOnboardingIfRequested() }
    }

    private func openOnboardingIfRequested() {
        guard router.showOnboarding else { return }
        openWindow(id: "onboarding")
        router.showOnboarding = false
    }
}
