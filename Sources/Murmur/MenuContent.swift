import SwiftUI

/// Contents of the menu-bar dropdown. Reflects the live dictation state, opens
/// Settings, and surfaces the Accessibility grant (needed only to type the
/// result into other apps — the hotkey itself needs no permission).
struct MenuContent: View {
    let dictation: DictationController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(dictation.statusLine)
        Divider()
        if dictation.needsAccessibilityToType {
            Button("Grant Accessibility (to type into apps)…") { dictation.requestAccessibility() }
        }
        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit Murmur") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
