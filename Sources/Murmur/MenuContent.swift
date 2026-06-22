import SwiftUI

/// Contents of the menu-bar dropdown. Placeholder until the dictation pipeline
/// is wired in (hotkey → mic → STT → inject).
struct MenuContent: View {
    var body: some View {
        Text("Murmur — idle")
        Divider()
        // Placeholder: the hotkey is not bound yet.
        Text("Hold ⌥Space to dictate")
        Divider()
        Button("Quit Murmur") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
