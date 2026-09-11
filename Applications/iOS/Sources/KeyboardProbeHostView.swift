#if DEBUG
import SwiftUI
import AVFoundation
import MediaPlayer

/// Local input target. The opt-in fixture uses a real output-to-microphone
/// acoustic path. Its Send action is local and never contacts a messaging app.
struct KeyboardProbeHostView: View {
    @State private var value = ""
    @State private var sends = 0
    @State private var player: AVAudioPlayer?
    @State private var audioStatus = ""
    @Environment(\.scenePhase) private var scenePhase
    @State private var awakeUntil = Date().addingTimeInterval(1800)
    private var acoustic: Bool { ProcessInfo.processInfo.arguments.contains("--keyboard-acoustic-fixture") }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keyboard device probe").font(.title2)
            LocalMessageField(value: $value) { sends += 1; save() }.frame(height: 90)
            Text("Local send count: \(sends)").font(.caption).accessibilityIdentifier("keyboard-local-sends")
            if acoustic {
                TestVolumeControl().frame(height: 34)
                Button("Play fixture in 3 seconds") { Task { await playFixture() } }.accessibilityIdentifier("keyboard-play-fixture")
                Text(audioStatus).font(.caption).accessibilityIdentifier("keyboard-fixture-status")
            }
            Spacer()
        }.padding().onChange(of: value) { save() }.task {
            UIApplication.shared.isIdleTimerDisabled = true
            try? await Task.sleep(for: .seconds(1800))
            UIApplication.shared.isIdleTimerDisabled = false
        }.onChange(of: scenePhase) { _, phase in
            if phase == .active { UIApplication.shared.isIdleTimerDisabled = Date() < awakeUntil }
        }.onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
    private func save() {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("keyboard-host-result.json")
        if let data = try? JSONSerialization.data(withJSONObject: ["text": value, "sendCount": sends, "fixtureStatus": audioStatus,
            "outputVolume": AVAudioSession.sharedInstance().outputVolume,
            "outputRoute": AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType.rawValue },
            "updatedAt": ISO8601DateFormatter().string(from: Date())]) { try? data.write(to: url, options: .atomic) }
    }
    private func playFixture() async {
        do {
            audioStatus = "Playback scheduled"
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("keyboard-acoustic-fixture.wav")
            let audio = try AVAudioPlayer(contentsOf: url); audio.prepareToPlay(); player = audio
            try await Task.sleep(for: .seconds(3))
            try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            audio.volume = 1; audioStatus = audio.play() ? "Fixture playing through device audio" : "Playback failed to start"; save()
        } catch { audioStatus = error.localizedDescription; save() }
    }
}

private struct TestVolumeControl: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView { let view = MPVolumeView(); view.showsRouteButton = false; return view }
    func updateUIView(_ view: MPVolumeView, context: Context) {}
}

private struct LocalMessageField: UIViewRepresentable {
    @Binding var value: String
    let onSend: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(); view.font = .preferredFont(forTextStyle: .body); view.backgroundColor = .secondarySystemBackground
        view.layer.cornerRadius = 10; view.returnKeyType = .send; view.autocorrectionType = .no
        view.accessibilityIdentifier = "keyboard-probe-input"; view.delegate = context.coordinator
        DispatchQueue.main.async { view.becomeFirstResponder() }
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) { context.coordinator.parent = self; if view.text != value { view.text = value } }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: LocalMessageField
        init(_ parent: LocalMessageField) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) { parent.value = textView.text }
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            if text == "\n" { parent.onSend(); return false }
            return true
        }
    }
}
#endif
