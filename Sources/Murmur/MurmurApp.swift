import SwiftUI

/// Murmur — local push-to-talk dictation for macOS.
///
/// Hold a global hotkey, speak, and the transcription is typed into the focused
/// field of whatever app you're in. Everything runs on-device via MLX (no cloud).
///
/// This file is the scaffold: a menu-bar agent shell. The real pieces —
/// global hotkey capture, mic streaming, on-device STT, a live HUD, and text
/// injection into the focused field — land in follow-up steps.
@main
struct MurmurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Murmur", systemImage: "mic.circle") {
            MenuContent()
        }
    }
}
