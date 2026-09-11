import SwiftUI
import MurmurCore

struct SpeechPriorityPicker: View {
    @Bindable var model: AppModel
    private var priority: Binding<DictationMode> {
        Binding(get: { model.mode == .fast ? .fast : .accurate }, set: {
            model.mode = $0.effective(for: model.source)
            model.recommendModel()
            Task { await model.updateSettings() }
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Transcription").font(.subheadline.weight(.semibold))
            Picker("Transcription", selection: priority) {
                if DictationMode.allowsLiveDraft(language: model.source) { Text("Fast mode").tag(DictationMode.fast) }
                Text("Quality mode").tag(DictationMode.accurate)
            }.pickerStyle(.segmented).accessibilityIdentifier("speech-priority")
        }.disabled(model.busy)
    }
}

struct ProcessingQualityPicker: View {
    var title: LocalizedStringKey = "Translation"
    @Binding var selection: ProcessingQuality
    var options: [ProcessingQuality]
    var identifier = "translation-priority"
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.subheadline.weight(.semibold))
            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { quality in Text(LocalizedStringKey(quality.title)).tag(quality) }
            }.pickerStyle(.segmented).accessibilityIdentifier(identifier)
            if options == [.quality] {
                Text("Only Quality is available for these languages.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
