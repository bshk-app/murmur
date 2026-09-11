import SwiftUI
import MurmurCore

struct TextTranslationView: View {
    @Bindable var controller: TextTranslationModel
    let canStart: Bool
    var replace: ((String) -> Void)? = nil
    let translate: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @FocusState private var editing: Bool
    @State private var copiedAt: Date?
    @State private var expandedSource = false
    @State private var swapped = false
    private var p: MurmurPalette { .init(scheme: scheme) }
    private var errorColor: Color { Color(hex: scheme == .dark ? 0xf0a194 : 0xa52a17) }
    private var overLimit: Bool { controller.input.count > TextTranslationModel.characterLimit }
    private var collapsed: Bool { !controller.output.isEmpty && !expandedSource }
    private var phaseTitle: LocalizedStringKey {
        controller.phase == .preparing ? "Preparing translation…" : controller.phase == .cancelling ? "Cancelling…" : "Translating text…"
    }
    private var input: Binding<String> {
        Binding(get: { controller.input }, set: { controller.input = $0; copiedAt = nil; swapped = false })
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                languages
                ProcessingQualityPicker(selection: Binding(get: { controller.quality }, set: { controller.setQuality($0) }), options: controller.availableQualities, identifier: "text-translation-priority")
                    .disabled(controller.isBusy).murmurCard(radius: 15, padding: 14)
                if swapped { Text("The translation became the source text and the direction is reversed. The previous result is no longer shown.").font(.footnote).foregroundStyle(p.secondary).padding(13).background(p.card2, in: RoundedRectangle(cornerRadius: 13)) }
                inputCard
                if controller.isBusy { progressCard }
                if let error = controller.error { errorCard(error) }
                if !controller.output.isEmpty { resultCard }
                if !controller.isBusy && !editing {
                    Text("Text is translated on this iPhone. Language packs may need a one-time download.").font(.footnote).foregroundStyle(p.muted)
                    Text("Text is not saved as a note automatically.").font(.footnote).foregroundStyle(p.muted)
                }
            }.padding(.horizontal, 18).padding(.bottom, 16).frame(maxWidth: 640).frame(maxWidth: .infinity)
        }.scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) { footer }
            .onAppear { controller.setQuality(TranslationPreferences.quality) }
            .onChange(of: controller.quality) { TranslationPreferences.quality = controller.quality }
            .onChange(of: controller.output) { copiedAt = nil; if !controller.output.isEmpty { expandedSource = false; editing = false } }
            .onChange(of: controller.source) { TranslationPreferences.save(source: controller.source, target: controller.target); copiedAt = nil }
            .onChange(of: controller.target) { TranslationPreferences.save(source: controller.source, target: controller.target); copiedAt = nil }
            .task(id: copiedAt) {
                guard copiedAt != nil else { return }
                do { try await Task.sleep(for: .seconds(5)); copiedAt = nil } catch {}
            }
    }
    private var languages: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
        return layout {
            picker("From language", selection: Binding(get: { controller.source }, set: { controller.setSource($0); swapped = false }), codes: LanguagePair.qualityLanguages.sorted(), id: "text-source-language")
            Button {
                let hadResult = !controller.output.isEmpty
                controller.swap(); copiedAt = nil; expandedSource = false; swapped = hadResult
            } label: { Image(systemName: "arrow.left.arrow.right").frame(width: 44, height: 44).background(p.card2, in: Circle()) }
                .accessibilityLabel("Swap languages").accessibilityIdentifier("text-swap-languages").disabled(!controller.canSwap)
            picker("Translate to", selection: Binding(get: { controller.target }, set: { controller.setTarget($0); swapped = false }), codes: controller.availableTargets, id: "text-target-language")
        }.disabled(controller.isBusy)
    }
    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Text to translate").font(.subheadline.weight(.semibold))
                Spacer(minLength: 6)
                if collapsed {
                    Button("Edit") { expandedSource = true; editing = true }.frame(minHeight: 44)
                } else if controller.input.isEmpty {
                    PasteButton(payloadType: String.self) { values in input.wrappedValue = values.joined(separator: "\n") }
                        .buttonStyle(.bordered).tint(.secondary).controlSize(.small).disabled(controller.isBusy)
                } else {
                    Button("Clear") { input.wrappedValue = "" }.frame(minHeight: 44).disabled(controller.isBusy).accessibilityIdentifier("text-clear")
                }
            }
            if collapsed {
                Text(controller.input).font(.body).lineLimit(3).foregroundStyle(p.secondary).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ZStack(alignment: .topLeading) {
                    if controller.input.isEmpty { Text("Type or paste text here").foregroundStyle(p.muted).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false) }
                    TextEditor(text: input).scrollContentBackground(.hidden).frame(height: editing ? 96 : 132).focused($editing)
                        .accessibilityLabel("Text to translate").accessibilityIdentifier("text-translation-input").disabled(controller.isBusy)
                }.font(.body)
                ViewThatFits(in: .horizontal) {
                    HStack { limitHint; Spacer(); counter }
                    VStack(alignment: .leading, spacing: 4) { limitHint; counter }
                }
                if overLimit { Text("The text is not trimmed automatically. Shorten it to start the translation.").font(.footnote).foregroundStyle(errorColor) }
            }
        }.murmurCard(radius: 15, padding: 14)
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(overLimit ? errorColor : .clear))
    }
    private var limitHint: some View {
        Text(overLimit ? "Over 10,000 characters" : "Up to 10,000 characters at a time").font(.caption).foregroundStyle(overLimit ? errorColor : p.muted)
    }
    private var counter: some View {
        Text(verbatim: "\(controller.input.count.formatted()) / \(TextTranslationModel.characterLimit.formatted())")
            .font(.caption).monospacedDigit().foregroundStyle(overLimit ? errorColor : p.muted).fixedSize()
    }
    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(phaseTitle).font(.subheadline.weight(.semibold)).accessibilityIdentifier("text-translation-progress")
                Spacer(minLength: 4)
                if controller.phase == .preparing, let fraction = controller.fraction {
                    Text(fraction, format: .percent.precision(.fractionLength(0))).font(.caption).monospacedDigit()
                }
            }
            ProgressTrack(value: controller.phase == .preparing ? controller.fraction : nil, tone: controller.phase == .cancelling ? .neutral : .accent)
                .accessibilityLabel(phaseTitle)
        }.murmurCard(radius: 15, padding: 14)
    }
    private func errorCard(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Could not translate. Your text is kept.", systemImage: "exclamationmark.circle").font(.subheadline.weight(.semibold))
            DisclosureGroup("Details") { Text(error).font(.footnote).textSelection(.enabled) }
        }.foregroundStyle(errorColor).padding(14).background(errorColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 15)).accessibilityIdentifier("text-translation-error")
    }
    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Translation"); Spacer(); Text(AppLanguages.name(controller.target)) }.font(.caption.weight(.semibold)).foregroundStyle(p.accentText)
            TranscriptText(text: controller.output, size: 18, identifier: "text-translation-output")
            HStack(spacing: 8) {
                DesignButton(title: copiedAt == nil ? "Copy translation" : "Copied", symbol: copiedAt == nil ? "doc.on.doc" : "checkmark", kind: .secondary) { UIPasteboard.general.string = controller.output; copiedAt = .now }
                ShareLink(item: controller.output) {
                    Image(systemName: "square.and.arrow.up").frame(width: 48, height: 48).background(p.card2, in: RoundedRectangle(cornerRadius: 13))
                }.accessibilityLabel("Share")
            }
            if let replace {
                DesignButton(title: "Replace with translation", symbol: "text.badge.checkmark") { replace(controller.output) }
                    .disabled(controller.isBusy).accessibilityIdentifier("replace-translation")
            }
        }.padding(14).background(MurmurPalette.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 15))
    }
    private var footer: some View {
        VStack(spacing: 8) {
            if editing {
                Button { editing = false } label: { Label("Hide keyboard", systemImage: "keyboard.chevron.compact.down").frame(minHeight: 44) }.font(.footnote).accessibilityIdentifier("text-hide-keyboard")
            }
            if controller.isBusy {
                Text(phaseTitle).font(.footnote).foregroundStyle(p.secondary)
                DesignButton(title: "Cancel", kind: .secondary) { controller.cancel() }.disabled(controller.phase == .cancelling)
            } else {
                DesignButton(title: controller.output.isEmpty ? "Translate text" : "Translate again", symbol: "character.bubble") { editing = false; copiedAt = nil; swapped = false; translate() }
                    .disabled(!controller.canTranslate || !canStart).accessibilityIdentifier("translate-text")
            }
        }.padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 8).frame(maxWidth: 640).frame(maxWidth: .infinity).background(p.sheet)
    }
    private func picker(_ title: LocalizedStringKey, selection: Binding<String>, codes: [String], id: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(p.muted)
            LanguageMenu(selection: selection, codes: codes,
                preferred: id == "text-source-language" ? TranslationPaths.offlineRoutes.sources : TranslationPaths.offlineRoutes.targets(from: controller.source), identifier: id)
        }.frame(maxWidth: .infinity, alignment: .leading).murmurCard(radius: 15, padding: 10)
    }
}
