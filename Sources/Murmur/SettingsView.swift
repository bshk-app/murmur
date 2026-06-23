import KeyboardShortcuts
import SwiftUI

/// Murmur's preferences window (a SwiftUI `Settings` scene). The recorder stores
/// and conflict-checks the push-to-talk shortcut via KeyboardShortcuts.
struct SettingsView: View {
    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Push-to-talk:", name: .dictate)
            } header: {
                Text("Shortcut")
            } footer: {
                Text("Hold the shortcut to dictate; release to finish.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .frame(minHeight: 160)
    }
}
