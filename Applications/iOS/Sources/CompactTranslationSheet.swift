import SwiftUI
import MurmurCore

/// Selected-text UI shared with the simulator design host. The system owns the outer sheet.
struct CompactTranslationSheet: View {
    @Bindable var controller: TextTranslationModel
    var sourceNeedsReview = false
    var replace: ((String) -> Void)?
    let translate: () -> Void
    let close: () -> Void
    let expand: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title3) private var shortSize = 21.0
    @ScaledMetric(relativeTo: .body) private var smallSize = 19.0
    @ScaledMetric(relativeTo: .body) private var mediumSize = 17.0
    @ScaledMetric(relativeTo: .body) private var longSize = 15.0
    @State private var resultHeight: CGFloat = 28
    @State private var editing = false
    @State private var draft = ""
    @State private var copied = false
    @State private var showingError = false
    @FocusState private var editorFocused: Bool

    private var p: MurmurPalette { .init(scheme: scheme) }
    private var outputSize: Double {
        switch controller.output.count {
        case ...40: return shortSize
        case ...110: return smallSize
        case ...220: return mediumSize
        default: return longSize
        }
    }
    private var phaseTitle: LocalizedStringKey {
        controller.phase == .preparing ? "Preparing translation…" : controller.phase == .cancelling ? "Cancelling…" : "Translating text…"
    }

    var body: some View {
        ViewThatFits(in: .vertical) {
            content.fixedSize(horizontal: false, vertical: true)
            ScrollView { content }
        }
        .frame(maxWidth: 640, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(p.ink).tint(p.accentText)
        .onChange(of: controller.input) { editing = false; editorFocused = false; copied = false }
        .onChange(of: controller.output) { copied = false }
        .onChange(of: controller.output) { if controller.output.count > 220 { expand() } }
        .onChange(of: controller.source) { saveLanguages() }
        .onChange(of: controller.target) { saveLanguages() }
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(3)); copied = false } catch {}
        }
        .task { if typeSize.isAccessibilitySize { expand() } }
        .onChange(of: typeSize) { if typeSize.isAccessibilitySize { expand() } }
        .sheet(isPresented: $showingError) {
            NavigationStack {
                ScrollView { Text(controller.error ?? "").textSelection(.enabled).padding() }
                    .navigationTitle("Details")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingError = false } } }
            }
        }
    }

    private var content: some View {
        VStack(spacing: 12) {
            header
            if editing { sourceEditor } else { translationCard }
            actions
        }.padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 12)
    }

    private var header: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 4))
        return layout {
            languageMenu("From language", code: controller.source, codes: LanguagePair.qualityLanguages.sorted(), id: "compact-source-language") {
                controller.setSource($0); start()
            }
            Button { controller.swap(); start() } label: {
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 15)).frame(width: 36, height: 36).background(p.card2, in: Circle()).frame(width: 44, height: 44)
            }.buttonStyle(.plain).foregroundStyle(p.secondary).accessibilityLabel("Swap languages").accessibilityIdentifier("compact-swap")
                .disabled(!controller.canSwap || editing)
            languageMenu("Translate to", code: controller.target, codes: controller.availableTargets, id: "compact-target-language") {
                controller.setTarget($0); start()
            }
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 15, weight: .medium)).foregroundStyle(p.secondary)
                    .frame(width: 36, height: 36).background(p.card2, in: Circle()).frame(width: 44, height: 44)
            }.buttonStyle(.plain).accessibilityLabel("Done").accessibilityIdentifier("compact-close")
        }
    }

    private func languageMenu(_ title: LocalizedStringKey, code: String, codes: [String], id: String, select: @escaping (String) -> Void) -> some View {
        Menu {
            LanguageMenuChoices(selection: code, codes: codes, preferred: id == "compact-source-language" ? TranslationPaths.offlineRoutes.sources : TranslationPaths.offlineRoutes.targets(from: controller.source), select: select)
        } label: {
            HStack(spacing: 5) {
                Text(AppLanguages.name(code)).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.85)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }.frame(maxWidth: .infinity, minHeight: 36).padding(.horizontal, 7)
                .background(p.card2, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.border))
                .frame(minHeight: 44)
        }.foregroundStyle(p.accentText).accessibilityLabel(title).accessibilityValue(AppLanguages.name(code)).accessibilityIdentifier(id)
            .disabled(controller.isBusy || editing)
    }

    private var translationCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(controller.input).font(.footnote).foregroundStyle(p.muted).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("compact-original")
                Button("Edit", action: beginEditing).font(.footnote).foregroundStyle(p.accentText).frame(minWidth: 44, minHeight: 44)
                    .disabled(controller.isBusy).accessibilityIdentifier("compact-edit")
            }.padding(.horizontal, 14)
            Rectangle().fill(p.border).frame(height: 1)
            if !controller.output.isEmpty {
                ScrollView {
                    TranscriptText(text: controller.output, size: 18, identifier: "compact-output")
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { resultHeight = $0 }
                }.frame(height: min(max(28, resultHeight), typeSize.isAccessibilitySize ? 320 : 240))
                    .accessibilityIdentifier("compact-output-scroll")
                    .padding(.horizontal, 14).padding(.top, 9).padding(.bottom, 12)
            } else {
                status.padding(14)
            }
        }.background(scheme == .dark ? Color.white.opacity(0.05) : Color(hex: 0x3c2814).opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(p.border)).clipShape(.rect(cornerRadius: 16))
    }

    @ViewBuilder private var status: some View {
        if controller.isBusy {
            VStack(alignment: .leading, spacing: 8) {
                Text(phaseTitle).font(.subheadline).accessibilityIdentifier("compact-progress")
                ProgressTrack(value: controller.phase == .preparing ? controller.fraction : nil, tone: controller.phase == .cancelling ? .neutral : .accent)
                if controller.phase == .preparing, let fraction = controller.fraction {
                    Text(fraction, format: .percent.precision(.fractionLength(0))).font(.caption).monospacedDigit()
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        } else if controller.error != nil {
            VStack(alignment: .leading, spacing: 4) {
                Text("Could not translate. Your text is kept.").font(.subheadline)
                Button("Details") { showingError = true }.frame(minHeight: 44)
            }.frame(maxWidth: .infinity, alignment: .leading)
        } else if sourceNeedsReview || controller.input.count > TextTranslationModel.characterLimit {
            Text(sourceNeedsReview ? "Check the source language before translating this text." : "Over 10,000 characters")
                .font(.footnote).foregroundStyle(p.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sourceEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Text to translate").font(.subheadline.weight(.semibold))
            TextEditor(text: $draft).scrollContentBackground(.hidden).frame(height: typeSize.isAccessibilitySize ? 180 : 100)
                .focused($editorFocused).accessibilityLabel("Text to translate").accessibilityIdentifier("compact-source-editor")
            Text(verbatim: "\(draft.count.formatted()) / \(TextTranslationModel.characterLimit.formatted())").font(.caption).foregroundStyle(p.secondary)
        }.padding(14).background(p.card2, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder private var actions: some View {
        if editing {
            HStack(spacing: 8) {
                DesignButton(title: "Cancel", kind: .secondary) { editing = false; editorFocused = false }
                DesignButton(title: "Translate text") {
                    controller.input = draft; editing = false; editorFocused = false; start()
                }.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.count > TextTranslationModel.characterLimit)
                    .accessibilityIdentifier("compact-apply-edit")
            }
        } else if controller.isBusy {
            DesignButton(title: "Cancel", kind: .secondary) { controller.cancel() }
                .disabled(controller.phase == .cancelling).accessibilityIdentifier("compact-cancel")
        } else if !controller.output.isEmpty {
            VStack(spacing: 8) {
                if let replace {
                    Button { replace(controller.output) } label: {
                        Text("Replace with translation").font(.body.weight(.semibold)).multilineTextAlignment(.center).frame(maxWidth: .infinity, minHeight: 50)
                            .foregroundStyle(Color(hex: 0x241f1c)).background(MurmurPalette.accent, in: RoundedRectangle(cornerRadius: 15))
                    }.buttonStyle(.plain).accessibilityIdentifier("replace-translation")
                }
                HStack(spacing: 8) {
                    Button { UIPasteboard.general.string = controller.output; copied = true } label: {
                        actionLabel(copied ? "Copied" : "Copy", symbol: copied ? "checkmark" : "doc.on.doc")
                    }.buttonStyle(.plain).accessibilityIdentifier("compact-copy")
                    ShareLink(item: controller.output) { actionLabel("Share", symbol: "square.and.arrow.up") }
                        .accessibilityIdentifier("compact-share")
                }
            }
        } else {
            DesignButton(title: "Translate text", action: start).disabled(!controller.canTranslate).accessibilityIdentifier("compact-translate")
        }
    }

    private func actionLabel(_ title: LocalizedStringKey, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(p.accentText).background(p.card2, in: RoundedRectangle(cornerRadius: 13))
    }
    private func beginEditing() { draft = controller.input; editing = true; expand(); editorFocused = true }
    private func start() { copied = false; if controller.canTranslate { translate() } }
    private func saveLanguages() { TranslationPreferences.save(source: controller.source, target: controller.target); copied = false }
}
