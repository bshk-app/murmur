import SwiftUI
import MurmurSpeech
import MurmurCore
import UniformTypeIdentifiers

struct CanaryExperimentView: View {
    @Bindable var model: CanaryExperimentModel
    let prepareExclusive: @MainActor () async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var choosingFile = false
    @State private var importError: String?
    @State private var copied: String?
    @State private var closing = false
    private var p: MurmurPalette { .init(scheme: scheme) }
    private var sourceCodes: [String] { AppLanguages.all.map(\.code).filter { CanaryRuntime.supportedLanguages.contains($0) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Canary experiment").font(.headline)
                Spacer(minLength: 8)
                Button("Done") {
                    closing = true
                    Task { await model.close(); dismiss() }
                }.frame(minWidth: 44, minHeight: 44).disabled(model.isBusy || closing)
                    .accessibilityIdentifier("canary-done")
            }.padding(.horizontal, 20).padding(.top, 10)
            Divider().overlay(p.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    introduction
                    languageControls
                    if model.isBusy || model.phase == .finished { progressCard }
                    if let error = model.error ?? importError { errorCard(error) }
                    if !model.transcript.isEmpty { resultCard("Transcript", text: model.transcript, id: "transcript") }
                    if !model.translation.isEmpty { resultCard("Translation", text: model.translation, id: "translation") }
                    Text("Recordings and available text are saved in Notes. Closing this screen releases the models.")
                        .font(.footnote).foregroundStyle(p.muted)
                }.padding(18).frame(maxWidth: 640).frame(maxWidth: .infinity)
            }
        }.safeAreaInset(edge: .bottom, spacing: 0) { actions }
            .foregroundStyle(p.ink).tint(p.accentText)
            .presentationBackground(p.sheet).presentationCornerRadius(26)
            .presentationDetents([.large]).presentationDragIndicator(.visible)
            .interactiveDismissDisabled(model.isBusy || closing)
            .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.audio]) { result in
                switch result {
                case .success(let url):
                    importError = nil; copied = nil
                    model.processFile(url, prepareExclusive: prepareExclusive)
                case .failure(let error): importError = error.localizedDescription
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { Task { await model.close() } }
            }
            .onDisappear { Task { await model.close() } }
            .task(id: copied) {
                guard copied != nil else { return }
                do { try await Task.sleep(for: .seconds(5)); copied = nil } catch {}
            }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Experimental speech recognition", systemImage: "waveform").font(.title2.bold())
            Text("Record speech or choose an audio file. Canary processes it in short sections on this device.")
                .font(.body).foregroundStyle(p.secondary)
            Text("Models may need a one-time download. Keep this screen open while processing; results may contain mistakes.")
                .font(.footnote).foregroundStyle(p.muted)
        }
    }

    private var languageControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            layout {
                languagePicker("Language of the recording", selection: $model.source, codes: sourceCodes, id: "canary-source")
                if model.translateEnabled {
                    languagePicker("Translate to", selection: $model.target, codes: AppLanguages.all.map(\.code).filter { LanguagePair.qualityLanguages.contains($0) }, id: "canary-target")
                }
            }
            Toggle("Translate speech", isOn: $model.translateEnabled).accessibilityIdentifier("canary-translate-toggle")
            Label(model.routeDescription, systemImage: model.translateEnabled ? "character.bubble" : "text.alignleft")
                .font(.footnote.weight(.semibold)).foregroundStyle(p.accentText).accessibilityIdentifier("canary-route")
        }.disabled(model.isBusy || closing).murmurCard(radius: 15, padding: 14)
    }

    private func languagePicker(_ title: LocalizedStringKey, selection: Binding<String>, codes: [String], id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(p.muted)
            LanguageMenu(selection: selection, codes: codes, preferred: codes, identifier: id).accessibilityLabel(title)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var phaseTitle: LocalizedStringKey {
        switch model.phase {
        case .idle: "Ready"
        case .preparing: "Preparing Canary…"
        case .recording: "Recording…"
        case .processing: "Processing speech…"
        case .cancelling: "Cancelling…"
        case .finished: "Processing complete"
        case .failed: "Could not process this recording"
        }
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(phaseTitle).font(.headline).accessibilityIdentifier("canary-phase")
                Spacer(minLength: 8)
                if model.isRecording {
                    Text(time(model.recordedSeconds)).monospacedDigit().accessibilityIdentifier("canary-recording-duration")
                }
            }
            if !model.isRecording {
                ProgressTrack(value: model.progress, tone: model.phase == .finished ? .success : .accent)
                    .accessibilityLabel(phaseTitle).accessibilityIdentifier("canary-progress")
                if model.completedBatches > 0 {
                    HStack {
                        Text("Processed audio").font(.footnote)
                        Spacer(minLength: 8)
                        Text(processedTime).font(.footnote).monospacedDigit()
                    }.foregroundStyle(p.secondary)
                }
            } else {
                Text("Text appears as sections finish. Stop recording to finish the last section.").font(.footnote).foregroundStyle(p.secondary)
            }
        }.murmurCard(radius: 15, padding: 14)
    }

    private var processedTime: String {
        guard let total = model.totalSeconds else { return time(model.processedSeconds) }
        return "\(time(model.processedSeconds)) / \(time(total))"
    }
    private func time(_ seconds: Double) -> String {
        Duration.seconds(max(0, seconds)).formatted(.time(pattern: .minuteSecond))
    }

    private func resultCard(_ title: LocalizedStringKey, text: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(text).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("canary-\(id)")
            HStack(spacing: 8) {
                DesignButton(title: copied == id ? "Copied" : "Copy", symbol: copied == id ? "checkmark" : "doc.on.doc", kind: .secondary) {
                    UIPasteboard.general.string = text; copied = id
                }.accessibilityLabel(copied == id ? "Copied" : id == "transcript" ? "Copy transcript" : "Copy translation")
                    .accessibilityIdentifier("canary-copy-\(id)")
                ShareLink(item: text) {
                    Image(systemName: "square.and.arrow.up").frame(width: 48, height: 48)
                        .background(p.card2, in: RoundedRectangle(cornerRadius: 13))
                }.accessibilityLabel("Share").accessibilityIdentifier("canary-share-\(id)")
            }
        }.murmurCard(radius: 15, padding: 14)
    }

    private func errorCard(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Could not process this recording", systemImage: "exclamationmark.circle").font(.headline)
            DisclosureGroup("Details") { Text(error).font(.footnote).textSelection(.enabled) }
        }.murmurCard(radius: 15, padding: 14).accessibilityIdentifier("canary-error")
    }

    private var actions: some View {
        VStack(spacing: 8) {
            if model.isRecording {
                DesignButton(title: "Stop recording", symbol: "stop.fill") { model.stopRecording() }.accessibilityIdentifier("canary-stop")
            } else if !model.isBusy {
                DesignButton(title: "Record audio", symbol: "mic.fill") {
                    importError = nil; copied = nil
                    model.startRecording(prepareExclusive: prepareExclusive)
                }.accessibilityIdentifier("canary-record")
                DesignButton(title: "Choose audio", symbol: "waveform.badge.plus", kind: .secondary) { choosingFile = true }.accessibilityIdentifier("canary-import")
            }
            if model.isBusy {
                DesignButton(title: "Cancel", kind: .secondary) { model.cancel() }
                    .disabled(model.phase == .cancelling).accessibilityIdentifier("canary-cancel")
            }
        }.disabled(closing).padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 8)
            .frame(maxWidth: 640).frame(maxWidth: .infinity).background(p.sheet)
    }
}
