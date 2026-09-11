import SwiftUI
import MurmurCore

struct OnboardingView: View {
    @Bindable var model: AppModel
    let complete: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var step = 0
    @State private var selected: Set<String> = []
    @State private var preloadNow = true
    @State private var downloadScreen = false
    @State private var downloading = false
    @State private var downloadTask: Task<Void, Never>?
    @State private var qualityTranslation = false
    @State private var previousMode: DictationMode?
    @State private var previousTranslationQuality: ProcessingQuality?
    @State private var practiceNote: VoiceNote?

    private var p: MurmurPalette { .init(scheme: scheme) }
    private var plan: OfflinePreloadPlan { .init(languages: selected) }
    private var isDownloading: Bool { downloading || model.preparingAll || model.phase == .preparing }
    private var preloadComplete: Bool {
        plan.speech.allSatisfy { model.languageLibrary.isPrepared("speech:" + $0) } &&
        plan.translations.filter { model.availableTranslationTargets(from: $0.source).contains($0.target) }
            .allSatisfy { model.languageLibrary.isPrepared("translation:" + $0.source + "-" + $0.target) }
    }
    private var codes: [String] {
        AppLanguages.all.map(\.code)
            .filter { LanguagePair.qualityLanguages.contains($0) && !model.availableTranslationTargets(from: $0).isEmpty }
            .sorted {
                if $0 == $1 { return false }
                if $0 == model.source { return true }
                if $1 == model.source { return false }
                return AppLanguages.name($0).localizedStandardCompare(AppLanguages.name($1)) == .orderedAscending
            }
    }
    private var fastTranslationAvailable: Bool {
        ProcessingQuality.translationOptions(from: model.source, to: model.target).contains(.fast)
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    ForEach(0..<5) { index in
                        Capsule().fill(index == step ? MurmurPalette.accent : p.card2)
                            .frame(width: index == step ? 22 : 7, height: 6)
                    }
                }.padding(.top, 12).padding(.bottom, 16).accessibilityHidden(true)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if downloadScreen {
                            downloads
                        } else {
                            switch step {
                            case 0: languages
                            case 1:
                                title("Try transcription")
                                Text("Speak a few words and watch the text appear.")
                                screenshot("02-dictation", height: geometry.size.height * 0.30)
                                explanation("Live transcription uses the Fast model. Finished audio recordings use the Quality model. Both work offline after downloading.")
                                if let practiceNote {
                                    Text(practiceNote.text).lineLimit(3).font(.body).padding(14)
                                        .frame(maxWidth: .infinity, alignment: .leading).background(p.card, in: RoundedRectangle(cornerRadius: 14))
                                }
                            case 2:
                                title("Try translation")
                                Text("See a translation while you speak, or translate a finished text with the Quality model.")
                                HStack {
                                    LanguageMenu(selection: $model.source, codes: selected.sorted(), preferred: selected.sorted(), identifier: "practice-source")
                                    Image(systemName: "arrow.right").foregroundStyle(p.secondary)
                                    LanguageMenu(selection: $model.target, codes: plan.translationLanguages.filter { model.availableTranslationTargets(from: model.source).contains($0) }, preferred: [], identifier: "practice-target")
                                }.padding(12).background(p.card, in: RoundedRectangle(cornerRadius: 14))
                                screenshot("03-translation", height: geometry.size.height * 0.25)
                                explanation("Live translation uses the Fast model. For finished text and recordings, choose Quality. Both work offline after downloading.")
                                if !fastTranslationAvailable {
                                    Text("Only Quality is available for these languages.").font(.footnote).foregroundStyle(p.secondary)
                                }
                            case 3:
                                title("Transcribe recordings")
                                Text("Import an audio file and turn it into a note you can read and edit.")
                                screenshot("05-audio", height: geometry.size.height * 0.35, alignment: .top)
                                explanation("Open Import audio on the notes screen and choose a recording from Files. Audio files use Quality transcription.")
                            default:
                                title("Share only what you need")
                                Text("Open a note, select Original or Translation below the player, then tap Share or Copy.")
                                screenshot("04-note", height: geometry.size.height * 0.35, alignment: .bottom)
                                explanation("Only the selected text is exported. Use the player's share button to export the audio recording.")
                            }
                        }
                    }.frame(maxWidth: 420).frame(maxWidth: .infinity).padding(.horizontal, 20).padding(.bottom, 20)
                }.id(downloadScreen ? -1 : step).scrollBounceBehavior(.basedOnSize)
                footer
            }.frame(maxWidth: 640).frame(maxWidth: .infinity)
                .background(p.background).foregroundStyle(p.ink).tint(MurmurPalette.accent)
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { if selected.isEmpty, codes.contains(model.source) { selected = [model.source] } }
        .onChange(of: model.source) {
            model.recommendModel()
            if !model.availableTranslationTargets(from: model.source).contains(model.target) || model.target == model.source {
                model.target = plan.translationLanguages.first { model.availableTranslationTargets(from: model.source).contains($0) } ?? "en"
            }
        }
        .fullScreenCover(isPresented: $model.showRecorder, onDismiss: finishPractice) {
            RecordingView(model: model).interactiveDismissDisabled()
        }
        .sheet(isPresented: $qualityTranslation, onDismiss: { model.textTranslator.cancel() }) {
            NavigationStack {
                TextTranslationView(controller: model.textTranslator, canStart: !model.busy) { Task { await model.startTextTranslation() } }
                    .navigationTitle("Translation")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { qualityTranslation = false } } }
            }
        }
        .alert("Murmator", isPresented: Binding(get: { model.error != nil && !model.showRecorder }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .onDisappear { downloadTask?.cancel() }
    }
    private var languages: some View {
        Group {
            title("Choose your languages")
            Text("Which languages should work immediately and offline? You can download more later in Settings.").foregroundStyle(p.secondary)
            HStack {
                Text("Preload for offline use").font(.subheadline.weight(.semibold))
                Spacer(minLength: 12)
                Toggle("Preload for offline use", isOn: $preloadNow).labelsHidden().fixedSize()
                    .tint(MurmurPalette.accent).accessibilityIdentifier("preload-now")
            }
            Text("Includes transcription and translation.").font(.subheadline)
            if !selected.isEmpty {
                Text(L10n.format("Translation between: %@.", plan.translationLanguages.map(AppLanguages.name).joined(separator: ", ")))
                    .font(.footnote).foregroundStyle(p.secondary)
            }
            LazyVStack(spacing: 8) {
                ForEach(codes, id: \.self) { code in
                    Button {
                        if selected.contains(code) { selected.remove(code) } else { selected.insert(code) }
                    } label: {
                        HStack {
                            Text(AppLanguages.name(code))
                            Spacer()
                            Image(systemName: selected.contains(code) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected.contains(code) ? MurmurPalette.accent : p.muted)
                        }.padding(15).background(p.card, in: RoundedRectangle(cornerRadius: 14))
                    }.buttonStyle(.plain).accessibilityIdentifier("preload-language-" + code)
                        .accessibilityAddTraits(selected.contains(code) ? .isSelected : [])
                }
            }
        }
    }
    private var downloads: some View {
        Group {
            title(isDownloading ? "Downloading languages" : preloadComplete ? "Ready for offline use" : "Download interrupted")
            if isDownloading {
                PreparationStatusView(model: model)
                explanation("Downloading transcription and translation. Recording will not start automatically.")
            } else if preloadComplete {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 54)).foregroundStyle(MurmurPalette.accent)
                    .frame(maxWidth: .infinity)
                Text("Your languages are ready. Try the features next.").multilineTextAlignment(.center).frame(maxWidth: .infinity)
            } else {
                ForEach(model.preparationErrors.keys.sorted(), id: \.self) { key in
                    Text(model.preparationErrors[key] ?? "").font(.footnote).foregroundStyle(p.secondary)
                }
            }
        }
    }
    private var footer: some View {
        VStack(spacing: 10) {
            if step == 0 && !downloadScreen {
                PrimaryButton(title: preloadNow ? "Download and continue" : "Continue") { confirmLanguages() }
                    .disabled(selected.isEmpty || model.busy).accessibilityIdentifier("onboarding-download")
            } else if downloadScreen {
                if !isDownloading {
                    PrimaryButton(title: preloadComplete ? "Continue" : "Retry") {
                        if preloadComplete { downloadScreen = false; step = 1 } else { beginDownloads() }
                    }.accessibilityIdentifier("onboarding-download-next")
                }
                if !preloadComplete || isDownloading {
                    Button("Download later") {
                        downloadTask?.cancel()
                        Task { if isDownloading { await model.cancel() }; downloading = false; downloadScreen = false; step = 1 }
                    }.frame(minHeight: 44).accessibilityIdentifier("onboarding-download-later")
                }
            } else {
                if step == 1, DictationMode.allowsLiveDraft(language: model.source) {
                    PrimaryButton(title: "Try live transcription", symbol: "mic.fill") { practice(translating: false) }
                        .disabled(model.busy).accessibilityIdentifier("try-transcription")
                } else if step == 2 {
                    HStack(spacing: 10) {
                        if fastTranslationAvailable {
                            PrimaryButton(title: "Fast mode", symbol: "waveform") { practice(translating: true) }
                                .accessibilityIdentifier("try-live-translation")
                        }
                        PrimaryButton(title: "Quality mode", quiet: fastTranslationAvailable) { tryQualityTranslation() }
                            .accessibilityIdentifier("try-quality-translation")
                    }.disabled(model.busy)
                }
                if step <= 2 {
                    HStack(spacing: 12) {
                        DesignButton(title: "Continue", kind: .secondary) { step += 1 }
                            .accessibilityIdentifier("onboarding-next")
                        Button("Skip tour") { finish() }.font(.subheadline).frame(maxWidth: .infinity, minHeight: 44)
                            .accessibilityIdentifier("onboarding-skip")
                    }.disabled(model.busy)
                } else {
                    PrimaryButton(title: step == 4 ? "Start using Murmator" : "Continue") {
                        if step == 4 { finish() } else { step += 1 }
                    }.disabled(model.busy).accessibilityIdentifier("onboarding-next")
                    if step < 4 {
                        Button("Skip tour") { finish() }.font(.subheadline).frame(minHeight: 44)
                            .disabled(model.busy).accessibilityIdentifier("onboarding-skip")
                    }
                }
            }
        }.padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 12)
    }
    private func title(_ key: String) -> some View {
        Text(LocalizedStringKey(key)).font(.title.bold()).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity).accessibilityIdentifier("onboarding-title")
    }
    private func explanation(_ key: LocalizedStringKey) -> some View {
        Text(key).font(.subheadline).foregroundStyle(p.secondary)
    }
    @ViewBuilder private func screenshot(_ name: String, height: CGFloat, alignment: Alignment = .center) -> some View {
        if let url = Bundle.main.url(forResource: "onboarding-" + name, withExtension: "png"), let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image).resizable().scaledToFill()
                .frame(height: min(300, max(160, height)), alignment: alignment)
                .clipped().clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(p.border))
                .accessibilityLabel("Feature example").accessibilityIdentifier("onboarding-screenshot")
        }
    }
    private func confirmLanguages() {
        guard !selected.isEmpty else { return }
        if !selected.contains(model.source) { model.source = selected.sorted()[0] }
        for code in plan.speech { model.languageLibrary.addSpeech(code) }
        for pair in plan.translations where model.availableTranslationTargets(from: pair.source).contains(pair.target) {
            model.languageLibrary.addTranslation(from: pair.source, to: pair.target)
        }
        if !plan.translationLanguages.contains(model.target) || model.target == model.source {
            model.target = plan.translationLanguages.first { model.availableTranslationTargets(from: model.source).contains($0) } ?? "en"
        }
        model.recommendModel()
        if preloadNow { beginDownloads() }
        else { Task { await model.updateSettings() }; step = 1 }
    }
    private func beginDownloads() {
        downloadScreen = true; downloading = true
        let languages = selected
        downloadTask = Task {
            await model.updateSettings()
            await model.preloadLanguages(languages)
            guard !Task.isCancelled else { return }
            downloading = false
        }
    }
    private func practice(translating: Bool) {
        guard !model.busy else { return }
        previousMode = model.mode; previousTranslationQuality = model.translationQuality
        model.mode = .fast
        if translating { model.translationQuality = .fast }
        Task {
            await model.start(translating: translating)
            if !model.showRecorder { finishPractice() }
        }
    }
    private func finishPractice() {
        if let note = model.selectedNote { practiceNote = note; model.selectedNote = nil }
        if let previousMode { model.mode = previousMode }
        if let previousTranslationQuality { model.translationQuality = previousTranslationQuality }
        previousMode = nil; previousTranslationQuality = nil
    }
    private func tryQualityTranslation() {
        let controller = model.textTranslator
        let from = model.source
        controller.setSource(from); controller.setTarget(model.target)
        TranslationPreferences.quality = .quality
        controller.setQuality(.quality)
        controller.input = (practiceNote?.sourceLanguage == from ? practiceNote?.text : nil) ?? [
            "ru": "Давайте встретимся в три часа.", "en": "Let's meet at three.",
            "fi": "Tavataan kello kolme.", "de": "Treffen wir uns um drei.",
            "fr": "Retrouvons-nous à trois heures.", "es": "Nos vemos a las tres."
        ][from] ?? ""
        qualityTranslation = true
    }
    private func finish() {
        guard !model.busy else { return }
        model.selectedNote = nil
        UserDefaults.standard.set(false, forKey: "pendingRecording")
        complete()
    }
}
