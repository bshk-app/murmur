import AppKit
import SwiftUI

/// Murmur — local push-to-talk dictation for macOS.
///
/// Hold a global hotkey, speak, and the transcription is typed into the focused
/// field of whatever app you're in. Everything runs on-device via MLX (no cloud).
@main
struct MurmurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // The menu-bar icon is inserted only once setup is complete — during first-run
    // onboarding there's no menu app. `@AppStorage` is reliably reactive in a Scene
    // (the AppDelegate flips this key); a `Binding` over an `@Observable` is not.
    @AppStorage(AppDelegate.menuReadyKey) private var menuReady = false

    var body: some Scene {
        // The onboarding window itself is an AppKit `NSWindow` owned by the AppDelegate
        // (a SwiftUI `Window` scene hides on deactivation and can't open reliably at
        // launch here).
        MenuBarExtra(isInserted: $menuReady) {
            MenuPopover(dictation: appDelegate.dictation,
                        onSetupTour: { appDelegate.replayOnboarding() })
        } label: {
            Image(nsImage: Self.menuIcon)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
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

