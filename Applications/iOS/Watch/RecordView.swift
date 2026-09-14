import SwiftUI

/// One screen, one decision: record or stop. The language and the readiness line
/// come from the phone, so the wrist never invites a recording the phone cannot
/// turn into a note.
struct RecordView: View {
    let recorder: WatchRecorder
    let sync: WatchSync

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if let language = sync.languageName {
                    Text(language).font(.footnote).foregroundStyle(.secondary)
                }
                if !sync.speechReady {
                    Text("Prepare this language on iPhone first")
                        .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                if recorder.recording {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(elapsed).font(.title3.monospacedDigit())
                    }
                }
                Button(action: toggle) {
                    Label(recorder.recording ? "Stop and send" : "Record",
                          systemImage: recorder.recording ? "stop.fill" : "mic.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(recorder.recording ? .red : .accentColor)
                if sync.pending > 0 {
                    Text("Sending to iPhone…").font(.caption2).foregroundStyle(.secondary)
                }
                if let message = recorder.error ?? sync.error {
                    Text(message).font(.caption2).foregroundStyle(.red).multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var elapsed: String {
        let seconds = Int(recorder.elapsed)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func toggle() {
        if recorder.recording {
            if let url = recorder.stop() { sync.send(url) }
        } else {
            Task { await recorder.start() }
        }
    }
}
