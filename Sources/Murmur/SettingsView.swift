import AppKit
import KeyboardShortcuts
import MurmurKit
import SwiftUI

/// Murmur's preferences window (a SwiftUI `Settings` scene): the push-to-talk
/// shortcut and where the transcript goes on release.
struct SettingsView: View {
    @AppStorage(AnalyticsConsent.key) private var analyticsEnabled = false
    @AppStorage(DictationSession.recordUtterancesKey) private var recordUtterances = false
    @State private var confirmingDelete = false
    /// Counted when the pane appears and after a delete, never inside `body`:
    /// touching the filesystem on every re-render would run it on each animation
    /// frame of the switch above it.
    @State private var recordingCount = 0

    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Push-to-talk:", name: .dictate)
                KeyboardShortcuts.Recorder("Dictate and send:", name: .dictateAndSend)
            } header: {
                Text("Shortcut")
            } footer: {
                Text("Hold a shortcut to dictate; release to finish. “Dictate and send” also presses Return, which sends the message in most chats. Leave it empty if you mostly dictate into editors, where Return would just break the line.")
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

            Section {
                // Turning it off only stops new recordings. Deleting is a separate,
                // confirmed action: a switch must not destroy someone's audio as a
                // side effect of being flipped.
                Toggle("Keep recordings of what I dictate", isOn: $recordUtterances)
                HStack {
                    Button("Show Recordings") {
                        NSWorkspace.shared.open(DiagnosticRecordings.directory())
                    }
                    Button("Delete Recordings Now…") { confirmingDelete = true }
                    .disabled(recordingCount == 0)
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Saves your dictated audio as WAV files on this Mac so a bug can be reproduced from the real recording. Off by default. Nothing is uploaded. The last \(DiagnosticRecordings.keepNewest) recordings are kept for \(Int(DiagnosticRecordings.maxAge / 86_400)) days, then deleted automatically.")
            }
            .confirmationDialog(
                "Delete \(recordingCount) recording\(recordingCount == 1 ? "" : "s")?",
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    DiagnosticRecordings.deleteAll()
                    recordingCount = DiagnosticRecordings.count()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the saved audio of what you dictated. It cannot be undone.")
            }
        }
        .onAppear { recordingCount = DiagnosticRecordings.count() }
        .formStyle(.grouped)
        .frame(width: 420)
        .frame(minHeight: 300)
    }
}
