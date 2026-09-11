import SwiftUI
import MurmurCore

struct TranslationSetupView: View {
    @Bindable var model: AppModel
    let start: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @AppStorage("translationInputMode") private var inputMode = "text"
    private var p: MurmurPalette { .init(scheme: scheme) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Translate").font(.title.bold())
                Spacer()
                Button("Done") { model.textTranslator.cancel(); dismiss() }.frame(minHeight: 44)
            }.padding(.horizontal, 18).padding(.top, 10)
            Picker("Translation mode", selection: $inputMode) {
                Text("Text").tag("text"); Text("Voice").tag("voice")
            }.pickerStyle(.segmented).padding(.horizontal, 18).padding(.bottom, 12)
                .disabled(model.textTranslator.isBusy).opacity(model.textTranslator.isBusy ? 0.38 : 1)
            if inputMode == "text" {
                TextTranslationView(controller: model.textTranslator, canStart: !model.busy) { Task { await model.startTextTranslation() } }
            } else { ScrollView { voiceControls.padding(18) } }
        }.foregroundStyle(p.ink).presentationBackground(p.sheet).presentationDetents([.large]).presentationDragIndicator(.visible).presentationCornerRadius(26).tint(p.accentText)
            .onDisappear { model.textTranslator.cancel() }
    }
    private var voiceControls: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                languagePicker("I speak", selection: $model.source, codes: AppLanguages.all.map(\.code), sourceMenu: true)
                Image(systemName: "arrow.right").foregroundStyle(p.muted)
                languagePicker("Translate to", selection: $model.target, codes: LanguagePair.qualityLanguages.sorted())
            }
            SpeechPriorityPicker(model: model).murmurCard(radius: 16, padding: 15)
            ProcessingQualityPicker(selection: $model.translationQuality, options: ProcessingQuality.translationOptions(from: model.source, to: model.target))
                .disabled(model.busy).murmurCard(radius: 16, padding: 15)
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
