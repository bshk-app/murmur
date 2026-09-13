import SwiftUI

struct RecordingView: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var showingOriginal = false
    private var palette: MurmurPalette { .init(scheme:scheme) }
    var body: some View {
        VStack(spacing:12) {
            HStack {
                HStack(spacing:7) {
                    Circle().fill(MurmurPalette.accent).frame(width:7,height:7)
                    Text(LocalizedStringKey(model.phase == .recording ? "Listening" : model.phase == .refining ? "Refining" : model.phase == .ready ? "Ready" : "Getting ready"))
                        .font(.subheadline.weight(.medium))
                }.padding(.horizontal,12).padding(.vertical,8).background(palette.card,in:Capsule())
                Spacer()
                if model.preparingLiveTranslation { ProgressView().accessibilityLabel("Preparing translation…") }
                else if !model.isTranslation && model.phase == .recording {
                    Menu {
                        LanguageMenuChoices(codes: model.translationOptions, preferred: TranslationPaths.offlineRoutes.targets(from: model.source)) { code in Task { await model.enableLiveTranslation(to: code) } }
                    } label: { Image(systemName: "character.bubble").frame(width: 44, height: 44) }
                        .accessibilityLabel("Translate").accessibilityIdentifier("enable-live-translation")
                }
                TimelineView(.periodic(from:.now,by:1)) { _ in
                    Text(String(format:"%d:%02d",Int(model.duration)/60,Int(model.duration)%60)).font(.subheadline.monospacedDigit()).foregroundStyle(palette.secondary)
                }
                Button { Task { await model.cancel() } } label: { Image(systemName:"xmark").frame(width:44,height:44).background(palette.card,in:Circle()) }
                    .accessibilityLabel("Close recording")
            }
            if model.isTranslation {
                Label(model.voiceTranslationMethod, systemImage: model.voiceTranslationMethod == L10n.text("Direct translation") ? "waveform.and.person.filled" : "text.bubble")
                    .font(.caption).foregroundStyle(palette.secondary)
                    .accessibilityIdentifier("voice-translation-method")
            }
            if model.isTranslation && !model.transcript.isEmpty {
                Picker("Reading view", selection: $showingOriginal) {
                    Text("Translation").tag(false)
                    Text("Original text").tag(true)
                }.pickerStyle(.segmented).accessibilityIdentifier("live-reading-mode")
                Text(AppLanguages.name(model.source) + " → " + AppLanguages.name(model.target)).font(.caption).foregroundStyle(palette.secondary)
            }
            if !model.transcript.isEmpty {
                if model.conversation.hasSnapshots {
                    ConversationLogView(conversation: model.conversation, translations: model.liveTranslationSegments,
                                        translated: model.isTranslation && !showingOriginal,
                                        identifier: model.isTranslation && !showingOriginal ? "live-translation" : "live-transcript")
                        .id(model.isTranslation && !showingOriginal ? "translation" : "original")
                } else {
                LiveTranscriptReader(
                    text: model.isTranslation && !showingOriginal ? model.translation : model.transcript,
                    display: model.isTranslation && !showingOriginal ? nil : model.captionDisplay,
                    identifier: model.isTranslation && !showingOriginal ? "live-translation" : "live-transcript"
                ).id(model.isTranslation && !showingOriginal ? "translation" : "original")
                }
            } else { ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    if model.transcript.isEmpty {
                        VStack(spacing:18) {
                            Image("Mascot").resizable().scaledToFit().frame(width:100,height:100).accessibilityHidden(true)
                            Text(LocalizedStringKey(model.phase == .recording ? "What's on your mind?" : model.phase == .ready ? "Ready to record" : "A moment for your words.")).font(.title2.weight(.medium))
                            Text(model.detail).font(.subheadline).foregroundStyle(palette.secondary).multilineTextAlignment(.center)
                            if model.phase == .preparing {
                                Text(model.preparationStageLabel).font(.caption)
                                TimelineView(.periodic(from:.now,by:0.3)) { _ in
                                    if let p=model.progress, p.totalUnitCount > 0 {
                                        ProgressView(value:model.preparationFraction)
                                        Text("\(ByteCountFormatter.string(fromByteCount:p.completedUnitCount,countStyle:.file)) / \(ByteCountFormatter.string(fromByteCount:p.totalUnitCount,countStyle:.file))").font(.caption).foregroundStyle(palette.secondary)
                                    } else if let fraction=model.translationFraction { ProgressView(value:fraction) }
                                    else { ProgressView() }
                                }
                            }
                        }.frame(maxWidth:.infinity).padding(.vertical,70)
                    }
                }.frame(maxWidth:640).padding(.vertical,24)
            } }
            if model.phase == .recording {
                HStack(spacing:4) {
                    ForEach(Array(model.levels.enumerated()),id:\.offset) { _, level in
                        Capsule().fill(MurmurPalette.accent).frame(width:4,height:4+16*level)
                    }
                }.frame(height:20).animation(.easeOut(duration:0.1),value:model.levels).accessibilityHidden(true)
            }
            if model.phase == .recording {
                PrimaryButton(title:"Stop recording",symbol:"stop.fill") { Task { await model.stop() } }
                    .accessibilityIdentifier("stop-recording")
            } else if model.phase == .ready {
                PrimaryButton(title: "Start recording", symbol: "mic.fill") { Task { await model.confirmRecording() } }
                    .accessibilityIdentifier("confirm-start-recording")
            } else if model.phase == .refining { ProgressView().padding(16) }
        }.padding(20).padding(.bottom,12).frame(maxWidth:.infinity,maxHeight:.infinity)
            .background(palette.background).foregroundStyle(palette.ink).tint(MurmurPalette.accent)
            .alert("Murmator",isPresented:Binding(get:{model.error != nil},set:{if !$0 {model.error=nil}})) {
                Button("OK",role:.cancel) {model.error=nil}
            } message: {Text(model.error ?? "")}
    }
}
