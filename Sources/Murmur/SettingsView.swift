import KeyboardShortcuts
import SwiftUI

/// Murmur's preferences window (a SwiftUI `Settings` scene): the push-to-talk
/// shortcut and where the transcript goes on release.
struct SettingsView: View {
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
                Toggle("Share anonymous usage & crash reports", isOn: $analyticsEnabled)
                    .onChange(of: analyticsEnabled) { _, on in
                        AnalyticsConsent.set(on)
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
