import SwiftUI

/// Contents of the menu-bar dropdown. Reflects the live dictation state, opens
/// Settings, and surfaces the Accessibility grant when the tap can't be armed.
struct MenuContent: View {
    let dictation: DictationController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(dictation.statusLine)
        Divider()
        if dictation.state == .needsAccessibility {
            Button("Grant Accessibility…") { dictation.enableHotkey() }
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
