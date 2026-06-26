import KeyboardShortcuts
import PostHog
import SwiftUI

/// Murmur's preferences window (a SwiftUI `Settings` scene): the push-to-talk
/// shortcut and where the transcript goes on release.
struct SettingsView: View {
    @AppStorage(InsertMode.defaultsKey) private var insertModeRaw = InsertMode.inField.rawValue
    @AppStorage(AnalyticsConsent.key) private var analyticsEnabled = false

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

            Section {
                Toggle("Share anonymous usage & crash reports", isOn: $analyticsEnabled)
                    .onChange(of: analyticsEnabled) { _, on in
                        on ? PostHogSDK.shared.optIn() : PostHogSDK.shared.optOut()
                    }
            } header: {
                Text("Privacy")
            } footer: {
                Text("Helps fix bugs and improve Murmur. Only anonymous events and errors are sent — never your audio or transcripts. Dictation runs fully on-device either way.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .frame(minHeight: 300)
    }
}
