import SwiftUI

/// Murmur — local push-to-talk dictation for macOS.
///
/// Hold a global hotkey, speak, and the transcription is typed into the focused
/// field of whatever app you're in. Everything runs on-device via MLX (no cloud).
///
/// Step A wires the menu-bar agent to the global hotkey + mic capture, with a
/// Settings window to rebind the hotkey. STT, the live HUD, and text injection
/// land in follow-up steps.
@main
struct MurmurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Murmur", systemImage: "mic.circle") {
            MenuContent(dictation: appDelegate.dictation)
        }
        Settings {
            SettingsView(settings: appDelegate.dictation.settings)
        }
    }
}
