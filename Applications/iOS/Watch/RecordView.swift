import SwiftUI

/// One screen, five states, one composition: the language overhead, a content
/// band, and a single action band the thumb can hit without looking.
struct RecordView: View {
    let recorder: WatchRecorder
    let sync: WatchSync

    @Environment(\.isLuminanceReduced) private var dimmed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let metrics = WatchMetrics.current

    private enum Stage { case ready, recording, sending, transcript }
    private var stage: Stage {
        if recorder.recording { return .recording }
        if sync.pending > 0 { return .sending }
        // A failed attempt outranks an old answer: the transcript screen has
        // nowhere to say what went wrong, and the person needs to read it.
        if sync.transcript != nil, recorder.error == nil { return .transcript }
        return .ready
    }

    var body: some View {
        content
            .containerBackground(dimmed ? Color.black : WatchPalette.background, for: .navigation)
            .navigationTitle { Text(sync.languageName ?? "").foregroundStyle(WatchPalette.accentText) }
            .task { consumeRecordingRequest() }
            .onReceive(NotificationCenter.default.publisher(for: .murmatorWatchRecordRequested)) { _ in
                consumeRecordingRequest()
            }
    }

    @ViewBuilder private var content: some View {
        switch stage {
        case .transcript: transcriptScreen
        default: actionScreen
        }
    }

    // MARK: - Ready, recording and sending share one skeleton

    private var actionScreen: some View {
        VStack(spacing: 0) {
            middle.frame(maxWidth: .infinity, maxHeight: .infinity)
            actionBand
            hintLine
        }
    }

    @ViewBuilder private var middle: some View {
        switch stage {
        case .recording:
            VStack(spacing: 10) {
                RecordingDot(size: metrics.dot, animates: !dimmed && !reduceMotion)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(elapsed(recorder.elapsed))
                        .font(.system(size: metrics.timer, weight: .medium, design: .monospaced))
                        .foregroundStyle(WatchPalette.ink)
                }
            }
        case .sending:
            // What went to the phone, so the length of the note is not a mystery
            // while it travels. No caption: the muted colour already says it stopped.
            Text(elapsed(recorder.lastDuration))
                .font(.system(size: metrics.sentTimer, weight: .medium, design: .monospaced))
                .foregroundStyle(WatchPalette.muted)
        case .ready where !sync.hasEverReceived:
            VStack(spacing: 12) {
                Image("MascotMark")
                    .resizable().scaledToFit()
                    .frame(width: metrics.mascot, height: metrics.mascot)
                    .foregroundStyle(WatchPalette.muted)
                Text("Audio stayed on this iPhone. Only the text is saved.")
                    .font(.system(size: metrics.hint))
                    .foregroundStyle(WatchPalette.muted)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 18)
        default:
            Color.clear
        }
    }

    /// One line under the action, never beside it. A warning leaves the button
    /// usable and stays quiet; a block takes the brighter ink, because the text
    /// matters more than the button it disables.
    @ViewBuilder private var hintLine: some View {
        if let failure = recorder.error ?? sync.error {
            hintText(Text(verbatim: failure), colour: WatchPalette.ink)
        } else if stage == .ready, !sync.speechReady {
            hintText(Text("Prepare this language on iPhone first"), colour: WatchPalette.secondary)
        }
    }

    private func hintText(_ text: Text, colour: Color) -> some View {
        text.font(.system(size: metrics.hint))
            .foregroundStyle(colour)
            .multilineTextAlignment(.center)
            .padding(.horizontal, metrics.hintSide)
            .padding(.bottom, metrics.bottom)
    }

    @ViewBuilder private var actionBand: some View {
        switch stage {
        case .sending: sendingCard
        case .recording: stopButton
        default: recordButton
        }
    }

    private var recordButton: some View {
        Button(action: toggle) {
            VStack(spacing: metrics.wide ? 9 : 7) {
                MicrophoneGlyph(height: metrics.wide ? 18 : 15)
                Text("Record").font(.system(size: metrics.recordLabel, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: hasHint ? metrics.shortButton : metrics.tallButton)
            .foregroundStyle(WatchPalette.onAccent)
            .background(WatchPalette.accent, in: RoundedRectangle(cornerRadius: metrics.radius))
        }
        .buttonStyle(.plain)
        .disabled(microphoneDenied)
        // The button keeps its footprint when it cannot be used: nothing is hidden
        // or shrunk because it is unavailable.
        .opacity(microphoneDenied ? 0.38 : 1)
        .padding(.horizontal, metrics.side)
        .padding(.bottom, hasHint ? 10 : metrics.bottom)
    }

    private var stopButton: some View {
        Button(action: toggle) {
            Text("Stop and send")
                .font(.system(size: metrics.stopLabel, weight: .semibold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10).padding(.horizontal, 12)
                .frame(minHeight: metrics.actionMinimum)
                .foregroundStyle(dimmed ? WatchPalette.secondary : .white)
                .background {
                    RoundedRectangle(cornerRadius: metrics.radius)
                        .fill(dimmed ? Color.clear : WatchPalette.recording)
                        .strokeBorder(dimmed ? WatchPalette.dimmedBorder : .clear, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, metrics.side)
        .padding(.bottom, metrics.bottom)
    }

    private var sendingCard: some View {
        VStack(spacing: 11) {
            Text("Sending to iPhone…")
                .font(.system(size: metrics.sendingLabel, weight: .medium))
                .foregroundStyle(WatchPalette.secondary)
                .multilineTextAlignment(.center)
            IndeterminateBar(animates: !dimmed && !reduceMotion)
        }
        .padding(.vertical, 12).padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .frame(minHeight: metrics.actionMinimum)
        .background {
            RoundedRectangle(cornerRadius: metrics.radius)
                .fill(WatchPalette.card)
                .strokeBorder(WatchPalette.border, lineWidth: 1)
        }
        .padding(.horizontal, metrics.side)
        .padding(.bottom, metrics.bottom)
    }

    // MARK: - The answer

    /// The action moves under the title and stays put, because the text below it
    /// scrolls. The bands keep their identity; only their order changes.
    private var transcriptScreen: some View {
        VStack(spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    MicrophoneGlyph(height: 12)
                    Text("Record").font(.system(size: metrics.pillLabel, weight: .semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(WatchPalette.onAccent)
                .background(WatchPalette.accent, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, metrics.side)
            .padding(.top, 8).padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Transcript")
                        .font(.system(size: metrics.transcriptTitle, weight: .semibold))
                        .tracking(0.36)
                        .foregroundStyle(WatchPalette.muted)
                    ForEach(paragraphs, id: \.self) { paragraph in
                        Text(paragraph)
                            .font(.system(size: metrics.transcriptBody))
                            .lineSpacing(metrics.transcriptBody * 0.45)
                            .foregroundStyle(WatchPalette.ink)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.bottom, 16)
            }
        }
    }

    private var paragraphs: [String] {
        (sync.transcript ?? "").components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Hints

    private var microphoneDenied: Bool { recorder.permissionDenied }
    private var hasHint: Bool {
        recorder.error != nil || sync.error != nil || (stage == .ready && !sync.speechReady)
    }

    private func elapsed(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func toggle() {
        if recorder.recording {
            if let url = recorder.stop() { sync.send(url) }
        } else {
            Task { await recorder.start() }
        }
    }

    /// The face and the Action Button ask for a recording before this view exists,
    /// so the request is picked up on arrival as well as while already open.
    private func consumeRecordingRequest() {
        // Consumed first on purpose. A request raised mid-recording is spent here
        // rather than left armed to start an unasked-for recording days later.
        guard WatchRecordingRequest.consume(), !recorder.recording else { return }
        Task { await recorder.start() }
    }
}

private struct RecordingDot: View {
    let size: CGFloat
    let animates: Bool
    @State private var faded = false
    var body: some View {
        Circle()
            .fill(WatchPalette.recording)
            .frame(width: size, height: size)
            .opacity(faded ? 0.35 : 1)
            .animation(animates ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : nil, value: faded)
            // Driven by the flag rather than by appearance: the wrist drops and
            // Reduce Motion turns on long after this view first showed up.
            .onAppear { faded = animates }
            .onChange(of: animates) { _, on in faded = on }
            .accessibilityHidden(true)
    }
}

/// No percentage and no estimate: the transfer takes a second or several minutes
/// depending on where the phone is, and neither number would be honest.
private struct IndeterminateBar: View {
    let animates: Bool
    @State private var shifted = false
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            Capsule().fill(WatchPalette.track)
                .overlay(alignment: .leading) {
                    Capsule().fill(WatchPalette.accent)
                        .frame(width: width * 0.4)
                        // Standing still, it rests at the start as a plain 40 %
                        // fill. Sliding it off-track would leave an empty bar.
                        .offset(x: animates ? (shifted ? width : -width * 0.4) : 0)
                        .animation(animates ? .linear(duration: 1.5).repeatForever(autoreverses: false) : nil,
                                   value: shifted)
                }
                .clipShape(Capsule())
                .onAppear { shifted = animates }
                .onChange(of: animates) { _, on in shifted = on }
        }
        .frame(height: 4)
    }
}
