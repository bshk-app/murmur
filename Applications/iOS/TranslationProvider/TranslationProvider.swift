import SwiftUI
import TranslationUIProvider
import NaturalLanguage
import Darwin
import MurmurCore
import MurmurTranslation

@main final class MurmatorTranslationProvider: TranslationUIProviderExtension {
    required init() { setenv("CT2_MMAP_WEIGHTS", "1", 1) }
    var body: some TranslationUIProviderExtensionScene {
        TranslationUIProviderSelectedTextScene { context in SelectedTextTranslationView(context: context) }
    }
}

@MainActor private struct SelectedTextTranslationView: View {
    let context: any TranslationUIProviderContext
    @State private var controller: TextTranslationModel
    @State private var operation: Task<Void, Never>?
    @State private var needsSourceChoice: Bool
    @Environment(\.colorScheme) private var scheme

    init(context: any TranslationUIProviderContext) {
        self.context=context
        let source=TranslationPreferences.source
        let target=TranslationPreferences.target
        let model=TextTranslationModel(engine:TextTranslationSession(modelsRoot:TranslationPaths.models),source:source,target:target,
            availableTargets:{ TextTranslationSession.availableTargets(from:$0,modelsRoot:TranslationPaths.models) })
        _controller=State(initialValue:model)
        _needsSourceChoice=State(initialValue:false)
    }
    var body: some View {
        let palette=MurmurPalette(scheme:scheme)
        VStack(spacing:0) {
            if !TranslationPaths.isReady {
                VStack(spacing:18) {
                    Text("Open Murmator once to prepare system translation.").font(.headline)
                    Text("Your selected text is kept. Return here after opening the app.").foregroundStyle(palette.secondary)
                    Button("Done") { context.finish(translation:nil) }.frame(minHeight:44)
                }.padding(24)
            } else {
                CompactTranslationSheet(controller:controller,sourceNeedsReview:needsSourceChoice,replace:context.allowsReplacement ? { output in
                    guard !output.isEmpty, !controller.isBusy else { return }
                    context.finish(translation:AttributedString(output))
                } : nil,translate:startTranslation,close:{
                    controller.cancel()
                    context.finish(translation:nil)
                },expand:{ context.expandSheet() })
            }
        }.foregroundStyle(palette.ink).tint(palette.accentText)
            .task(id: selectedText) {
                guard let text=selectedText else { return }
                controller.cancel()
                await operation?.value
                guard !Task.isCancelled else { return }
                receive(text)
                if TranslationPaths.isReady, !needsSourceChoice { startTranslation() }
            }
            .onDisappear {
                controller.cancel()
                let pending=operation
                Task { await pending?.value; await controller.unload() }
            }
    }
    private var selectedText: String? { context.inputText.map { String($0.characters) } }
    private func receive(_ text: String) {
        let preferredSource=TranslationPreferences.source
        let preferredTarget=TranslationPreferences.target
        let detected=NLLanguageRecognizer.dominantLanguage(for:String(text.prefix(1500)))?.rawValue
        needsSourceChoice=detected.map { !LanguagePair.qualityLanguages.contains($0) } ?? false
        let source=detected.flatMap { LanguagePair.qualityLanguages.contains($0) ? $0 : nil }
            ?? (LanguagePair.qualityLanguages.contains(preferredSource) ? preferredSource : "ru")
        controller.input=text
        controller.setSource(source)
        let target=[preferredTarget,preferredSource,"en","ru"].first { $0 != source && controller.availableTargets.contains($0) }
            ?? controller.availableTargets.first
        if let target { controller.setTarget(target) }
    }
    private func startTranslation() {
        needsSourceChoice=false
        if let task=controller.start() { operation=task }
    }
}
