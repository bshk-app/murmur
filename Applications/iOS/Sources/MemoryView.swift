import SwiftUI
import MurmurCore

struct MemoryView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let p = MurmurPalette(scheme: scheme)
        VStack(spacing: 0) {
            HStack { Text("Memory").font(.title2.bold()); Spacer(); Button("Done") { dismiss() }.frame(minHeight: 44).foregroundStyle(p.accentText) }.padding(.horizontal, 20).padding(.top, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("On device") {
                        if model.storageLoading { ProgressView() }
                        else if model.storageReadFailed { Text("Could not read storage.").font(.footnote).foregroundStyle(p.secondary) }
                        else {
                            diskRow("Speech recognition", symbol: "waveform", kinds: [.speech, .importedSpeech])
                            Divider()
                            diskRow("Live translation preview", symbol: "quote.bubble", kinds: [.translationPreview])
                            Divider()
                            diskRow("Text translation", symbol: "character.bubble", kinds: [.translationQuality])
                        }
                        DesignButton(title: "Manage storage", symbol: "internaldrive", kind: .secondary) { model.requestUtilityRoute("storage") }
                    }
                    section("In memory") {
                        memoryRow("Speech recognition", active: model.modelReady || model.keyboard.isActive || model.audioImports.activeID != nil,
                                  preparing: model.phase == .preparing || model.keyboard.state.phase == .preparing || model.audioImports.preparing)
                        memoryRow("Voice translation", active: model.translationLoaded || model.keyboard.modelsReady && model.keyboard.state.configuration.target != nil, preparing: model.keyboard.state.phase == .preparing && model.keyboard.state.configuration.target != nil)
                        memoryRow("Text translation", active: model.textTranslator.modelsLoaded, preparing: model.textTranslator.phase == .preparing)
                    }
                    if !model.canReleaseMemory && !model.releasingMemory {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Finish the current task to free memory.").font(.footnote).foregroundStyle(p.secondary)
                        }.padding(15).background(MurmurPalette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
                    }
                    if model.releasingMemory { ProgressTrack(); Text("Freeing memory…").font(.subheadline) }
                    if model.hasLoadedModels || !model.canReleaseMemory {
                        DesignButton(title: "Free memory", symbol: "memorychip") { Task { await model.releaseModels() } }.disabled(!model.canReleaseMemory).accessibilityIdentifier("unload-models")
                    } else {
                        DesignButton(title: "Keyboard dictation", symbol: "keyboard") { model.requestUtilityRoute("keyboard") }.disabled(model.busy)
                    }
                    if model.audioImports.busy { DesignButton(title: "Open the import and pause it", kind: .secondary) { model.requestUtilityRoute("audio-import") } }
                    else if model.keyboard.isActive && !model.canReleaseMemory { DesignButton(title: "Keyboard dictation", kind: .secondary) { model.requestUtilityRoute("keyboard") } }
                    DesignButton(title: "Languages & offline", symbol: "globe", kind: .secondary) { model.requestUtilityRoute("languages") }
                }.padding(20).frame(maxWidth: 640).frame(maxWidth: .infinity)
            }
        }.foregroundStyle(p.ink).presentationBackground(p.sheet).presentationDetents([.fraction(0.88), .large]).presentationCornerRadius(26).presentationDragIndicator(.visible)
            .task { await model.refreshMemoryState(); await model.refreshStorage() }
    }
    private func diskRow(_ title: LocalizedStringKey, symbol: String, kinds: Set<ModelStorageItem.Kind>) -> some View {
        let items = model.storageInventory.items.filter { kinds.contains($0.kind) }
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).frame(width: 22).foregroundStyle(MurmurPalette(scheme: scheme).accentText)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(items.isEmpty ? "No files on device" : "Files on device").font(.caption).foregroundStyle(MurmurPalette(scheme: scheme).secondary)
                if !items.isEmpty {
                    Text(items.map { item in
                        if let source = item.source, let target = item.target { return "\(source.uppercased()) → \(target.uppercased())" }
                        return L10n.text(item.title)
                    }.joined(separator: " · ")).font(.caption).foregroundStyle(MurmurPalette(scheme: scheme).secondary)
                }
            }
            Spacer(minLength: 4)
        }
    }
    private func memoryRow(_ title: LocalizedStringKey, active: Bool, preparing: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack { Text(title).font(.subheadline); Spacer(); StatusTag(title: preparing ? "Preparing…" : active ? "In use" : "Not in use", tone: active || preparing ? .accent : .neutral) }
            VStack(alignment: .leading, spacing: 6) { Text(title).font(.subheadline); StatusTag(title: preparing ? "Preparing…" : active ? "In use" : "Not in use", tone: active || preparing ? .accent : .neutral) }
        }
    }
    private func section<C: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.caption.weight(.semibold)).textCase(.uppercase).foregroundStyle(MurmurPalette(scheme: scheme).muted)
            VStack(alignment: .leading, spacing: 12, content: content).frame(maxWidth: .infinity, alignment: .leading).murmurCard(radius: 18, padding: 16)
        }
    }
}
