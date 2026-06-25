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
            // Wrapped so it can host `@Environment(\.openWindow)` and observe the
            // router (a menu-bar app has no AppKit handle to open a SwiftUI window).
            MenuBarContent(dictation: appDelegate.dictation,
                           model: appDelegate.onboarding,
                           router: appDelegate.router)
        } label: {
            Image(nsImage: Self.menuIcon)
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

/// The menu-bar dropdown plus the AppKit→SwiftUI window bridge: when the router's
/// `showOnboarding` flips true (first run or "Setup tour…"), open the onboarding
/// window and reset the flag.
private struct MenuBarContent: View {
    let dictation: DictationController
    let model: OnboardingModel
    let router: AppRouter
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuPopover(dictation: dictation, model: model, router: router)
            .onChange(of: router.showOnboarding) { _, show in
                guard show else { return }
                openWindow(id: "onboarding")
                router.showOnboarding = false
            }
    }
}
