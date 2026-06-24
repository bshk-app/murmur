import KeyboardShortcuts
import SwiftUI

/// Murmur's preferences window (a SwiftUI `Settings` scene): the push-to-talk
/// shortcut and where the transcript goes on release.
struct SettingsView: View {
    @AppStorage(InsertMode.defaultsKey) private var insertModeRaw = InsertMode.inField.rawValue

    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Push-to-talk:", name: .dictate)
            } header: {
                Text("Shortcut")
            } footer: {
                Text("Hold the shortcut to dictate; release to finish.")
            }

            Section {
                Picker("On release", selection: $insertModeRaw) {
                    Text("Type into the focused field").tag(InsertMode.inField.rawValue)
                    Text("Show in the HUD only").tag(InsertMode.hudOnly.rawValue)
                }
                .pickerStyle(.inline)
            } header: {
                Text("Insert")
            } footer: {
                Text("“HUD only” never types into other apps — it shows live subtitles in the HUD, handy for presentations and demos.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .frame(minHeight: 240)
    }
}
