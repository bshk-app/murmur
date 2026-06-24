import SwiftUI

/// Contents of the menu-bar dropdown. Reflects the live dictation state, opens
/// Settings, and surfaces the Accessibility grant (needed only to type the
/// result into other apps — the hotkey itself needs no permission).
struct MenuContent: View {
    let dictation: DictationController
    @Environment(\.openSettings) private var openSettings
    @AppStorage(InsertMode.defaultsKey) private var insertModeRaw = InsertMode.inField.rawValue

    var body: some View {
        Text(dictation.statusLine)
        Divider()
        Picker("Insert", selection: $insertModeRaw) {
            Text("In field").tag(InsertMode.inField.rawValue)
            Text("HUD only").tag(InsertMode.hudOnly.rawValue)
        }
        if dictation.needsAccessibilityToType, insertModeRaw == InsertMode.inField.rawValue {
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
