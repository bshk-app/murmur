import SwiftUI
import AVFoundation
import MurmurCore

@MainActor @Observable private final class RecordingPlayback: NSObject, AVAudioPlayerDelegate {
    var playing = false
    var position = 0.0
    var duration = 0.0
    var error: String?
    private var player: AVAudioPlayer?
    private var timer: Timer?
    func toggle(_ url: URL) {
        do {
            if player == nil {
                player = try AVAudioPlayer(contentsOf: url); player?.delegate = self
                duration = player?.duration ?? 0
                player?.currentTime = min(position, duration)
            }
            if playing { player?.pause(); playing = false; timer?.invalidate() }
            else {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers])
                try AVAudioSession.sharedInstance().setActive(true)
                if position >= duration { seek(0) }
                playing = player?.play() ?? false
                timer?.invalidate()
                timer = .scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.position = self?.player?.currentTime ?? 0 }
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    func seek(_ value: Double) { position = value; player?.currentTime = value }
    func stop() { player?.stop(); player = nil; playing = false; timer?.invalidate(); timer = nil }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.playing = false; self.timer?.invalidate(); self.position = self.duration }
    }
}

struct RecordingAudioControls: View {
    let url: URL
    let duration: Double
    let disabled: Bool
    let retranscribe: () -> Void
    @State private var playback = RecordingPlayback()
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button { playback.toggle(url) } label: {
                    Image(systemName: playback.playing ? "pause.fill" : "play.fill").frame(width: 44, height: 44)
                }.accessibilityLabel(L10n.text(playback.playing ? "Pause recording" : "Play recording")).accessibilityIdentifier("play-recording")
                Slider(value: Binding(get: { playback.position }, set: { playback.seek($0) }), in: 0...max(1, playback.duration > 0 ? playback.duration : duration))
                    .accessibilityLabel("Recording position")
                Text(AudioImportJob.time(playback.position)).font(.caption.monospacedDigit())
                ShareLink(item: url) { Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44) }.accessibilityLabel("Share recording")
            }
            Button("Transcribe again") { playback.stop(); retranscribe() }.frame(minHeight: 44).accessibilityIdentifier("retranscribe-recording")
            if let error = playback.error { Text(error).font(.footnote).foregroundStyle(.red) }
        }.disabled(disabled).onDisappear { playback.stop() }.onChange(of: disabled) { if disabled { playback.stop() } }
    }
}

struct TranscriptHistoryView: View {
    let versions: [TranscriptVersion]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List(versions.reversed()) { version in
                NavigationLink {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            TranscriptText(text: version.text, size: 22)
                            if let translation = version.translation, !translation.isEmpty {
                                Divider(); TranscriptText(text: translation, size: 22)
                            }
                        }.padding(20)
                    }.toolbar { ShareLink(item: version.text + (version.translation.map { "\n\n" + $0 } ?? "")) }
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(version.savedAt, format: .dateTime.day().month().hour().minute())
                        Text(version.text).font(.subheadline).lineLimit(2)
                    }
                }
            }.navigationTitle("Previous versions").toolbar { Button("Done") { dismiss() } }
        }
    }
}
