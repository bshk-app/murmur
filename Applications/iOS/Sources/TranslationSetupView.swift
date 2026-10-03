import SwiftUI
import MurmurCore

struct TranslationSetupView: View {
    @Bindable var model: AppModel
    let start: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @AppStorage("translationInputMode") private var inputMode = "text"
    @State private var closing = false
    #if !MURMUR_UI_HOST
    @State private var photoController = PhotoTranslationController()
    @State private var preparingPhoto = false
    @State private var photoReady = false
    #endif
    private var p: MurmurPalette { .init(scheme: scheme) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Translate").font(.title.bold())
                Spacer()
                Button("Done", action: close).frame(minHeight: 44).accessibilityIdentifier("translation-close")
            }.padding(.horizontal, 18).padding(.top, 10)
            Picker("Translation mode", selection: Binding(get: { inputMode }, set: selectMode)) {
                Text("Text").tag("text"); Text("Voice").tag("voice")
                #if !MURMUR_UI_HOST
                Text("Photo").tag("photo")
                #endif
            }.pickerStyle(.segmented).padding(.horizontal, 18).padding(.bottom, 12)
                .disabled(modeLocked).opacity(modeLocked ? 0.38 : 1).accessibilityIdentifier("translation-mode")
            if inputMode == "text" {
                TextTranslationView(controller: model.textTranslator, canStart: !model.busy) { Task { await model.startTextTranslation() } }
            } else if inputMode == "voice" { ScrollView { voiceControls.padding(18) } }
            #if !MURMUR_UI_HOST
            if inputMode == "photo" {
                if photoReady { PhotoTranslationView(controller: photoController, embedded: true).disabled(preparingPhoto) }
                else { ProgressView("Preparing translation…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            #endif
        }.foregroundStyle(p.ink).presentationBackground(p.sheet).presentationDetents([.large]).presentationDragIndicator(.visible).presentationCornerRadius(26).tint(p.accentText)
            .interactiveDismissDisabled(modeLocked)
            .task {
                #if !MURMUR_UI_HOST
                if inputMode == "photo", !photoReady { await preparePhoto() }
                #else
                if inputMode == "photo" { inputMode = "text" }
                #endif
            }
            .onDisappear {
                // Camera/library covers can hide this view without dismissing Translate.
                guard !model.showTranslation else { return }
                closing = true
                model.textTranslator.cancel()
                #if !MURMUR_UI_HOST
                Task { await photoController.close(); model.photoTranslationActive = false; model.consumeUtilityRoute() }
                #endif
            }
    }
    private var modeLocked: Bool {
        #if !MURMUR_UI_HOST
        return closing || model.textTranslator.isBusy || photoController.isBusy || preparingPhoto
        #else
        return closing || model.textTranslator.isBusy
        #endif
    }
    private func selectMode(_ mode: String) {
        guard !modeLocked else { return }
        #if !MURMUR_UI_HOST
        if mode == "photo" {
            inputMode = mode
            Task { await preparePhoto() }
        } else {
            model.photoTranslationActive = false
            inputMode = mode
        }
        #else
        inputMode = mode
        #endif
    }
    #if !MURMUR_UI_HOST
    private func preparePhoto() async {
        guard !preparingPhoto else { return }
        preparingPhoto = true
        defer { preparingPhoto = false }
        await model.releaseModels()
        guard inputMode == "photo", !Task.isCancelled, !closing else { return }
        if photoController.image == nil {
            photoController.setSource(model.textTranslator.source)
            photoController.setTarget(model.textTranslator.target)
        }
        model.photoTranslationActive = true; photoReady = true
    }
    #endif
    private func close() {
        guard !closing else { return }
        closing = true
        model.textTranslator.cancel()
        #if !MURMUR_UI_HOST
        Task { await photoController.close(); model.photoTranslationActive = false; dismiss() }
        #else
        dismiss()
        #endif
    }
    private var voiceControls: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                languagePicker("I speak", selection: $model.source, codes: AppLanguages.all.map(\.code), sourceMenu: true)
                Image(systemName: "arrow.right").foregroundStyle(p.muted)
                languagePicker("Translate to", selection: $model.target, codes: LanguagePair.qualityLanguages.sorted())
            }
            if !model.directTranslationSelected {
                SpeechPriorityPicker(model: model).murmurCard(radius: 16, padding: 15)
                ProcessingQualityPicker(selection: $model.translationQuality, options: ProcessingQuality.translationOptions(from: model.source, to: model.target))
                    .disabled(model.busy).murmurCard(radius: 16, padding: 15)
            }
            if model.directTranslationUnavailableOnDevice {
                Label("Direct translation is unavailable on this device. Translation through text will be used.", systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(p.secondary)
            }
            if !model.translationOptions.contains(model.target) {
                Label("Translation is not available for this language yet. You can still record a note.", systemImage: "info.circle").font(.subheadline).foregroundStyle(p.secondary)
            }
            PrimaryButton(title: "Speak & translate", symbol: "waveform", action: start).disabled(!model.translationOptions.contains(model.target) || model.busy).accessibilityIdentifier("start-translation")
        }.onChange(of: model.source) { model.recommendModel(); model.validateTranslationQuality(); Task { await model.updateSettings() } }
            .onChange(of: model.target) { model.validateTranslationQuality(); Task { await model.updateSettings() } }
    }
    private func languagePicker(_ title: LocalizedStringKey, selection: Binding<String>, codes: [String], sourceMenu: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(p.muted)
            LanguageMenu(selection: selection, codes: codes, preferred: sourceMenu ? model.languageLibrary.speech : TranslationPaths.offlineRoutes.targets(from: model.source), identifier: sourceMenu ? "voice-source-language" : "voice-target-language")
        }.frame(maxWidth: .infinity, alignment: .leading).murmurCard(radius: 14, padding: 12)
    }
}
