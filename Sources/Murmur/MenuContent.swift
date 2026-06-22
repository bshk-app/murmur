import SwiftUI

/// Contents of the menu-bar dropdown. Reflects the live dictation state and
/// surfaces the Accessibility grant when the hotkey tap can't be armed.
struct MenuContent: View {
    let dictation: DictationController

    var body: some View {
        Text(dictation.statusLine)
        Divider()
        if dictation.state == .needsAccessibility {
            Button("Grant Accessibility…") { dictation.enableHotkey() }
        }
        Button("Quit Murmur") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
