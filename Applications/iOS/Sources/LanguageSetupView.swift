import SwiftUI
import MurmurCore

struct LanguageSetupView: View {
    @Bindable var model: AppModel
    var isSheetRoot = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var addSpeech = false
    @State private var addPair = false
    var body: some View {
        let p = MurmurPalette(scheme: scheme)
        VStack(alignment: .leading, spacing: 0) {
            if model.preparationPaused {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Download paused", systemImage: "pause.circle").font(.headline)
                    HStack {
                        Button("Resume download") { Task { await model.resumeLanguagePreparation() } }
                        Spacer()
                        Button("Cancel download") { Task { await model.cancel() } }
                    }.frame(minHeight: 44)
                }.padding(14).background(p.card, in: RoundedRectangle(cornerRadius: 14)).accessibilityIdentifier("download-paused")
            }
            LanguageSetupContent(model: model, addSpeech: { addSpeech = true }, addPair: { addPair = true })
        }.padding(.horizontal, 20).frame(maxWidth: 640).frame(maxWidth: .infinity)
            .foregroundStyle(p.ink).background(p.background).navigationTitle("Languages & offline").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .toolbar { if isSheetRoot { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } } }
            .sheet(isPresented: $addSpeech) { AddSpeechLanguageSheet(model: model) }
            .sheet(isPresented: $addPair) { AddTranslationLanguageSheet(model: model) }
            .safeAreaInset(edge: .bottom) {
                if model.languageLibrary.count > model.languageLibrary.preparedCount || model.preparingAll {
                VStack(spacing: 8) {
                    PrimaryButton(title: model.preparingAll || model.busy ? "Preparing…" : "Download", quiet: model.busy || model.preparingAll) {
                        Task { await model.prepareAllLanguages() }
                    }.disabled(model.busy || model.preparingAll || model.languageLibrary.count == model.languageLibrary.preparedCount)
                        .accessibilityIdentifier("prepare-all-languages")
                }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 6).frame(maxWidth: 640).frame(maxWidth: .infinity)
                    .background(LinearGradient(colors: [p.background.opacity(0), p.background, p.background], startPoint: .top, endPoint: .bottom))
                }
            }
            .alert("Murmator", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("OK", role: .cancel) { model.error = nil }
            } message: { Text(model.error ?? "") }
    }
}

struct LanguageSetupContent: View {
    @Bindable var model: AppModel
    let addSpeech: () -> Void
    let addPair: () -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let p = MurmurPalette(scheme: scheme)
        ActionList(horizontalPadding: 0, spacing: 9) {
            section("Dictation languages")
            ForEach(model.languageLibrary.speech, id: \.self) { code in
                packCard(title: AppLanguages.name(code), id: "speech:" + code,
                    remove: { Task { await model.removeSpeechLanguage(code) } }, prepare: { await model.prepareSpeechLanguage(code) })
            }
            addButton("Add speech language", id: "add-speech-language", action: addSpeech)
            section("Translation languages").padding(.top, 15)
            ForEach(model.languageLibrary.translations) { pack in
                packCard(title: "\(AppLanguages.name(pack.source)) → \(AppLanguages.name(pack.target))", id: "translation:" + pack.id,
                    remove: { Task { await model.removeTranslationLanguage(pack) } }, prepare: { await model.prepareTranslationLanguage(pack) })
            }
            addButton("Add translation language", id: "add-translation-language", action: addPair)
            DesignButton(title: "Manage storage", symbol: "internaldrive", kind: .secondary) { model.requestUtilityRoute("storage") }
        }
    }
    private func section(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.system(size: 11.5, weight: .medium)).tracking(0.65).textCase(.uppercase)
            .foregroundStyle(MurmurPalette(scheme: scheme).muted)
    }
    private func addButton(_ title: LocalizedStringKey, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Text("+").font(.system(size: 13, weight: .semibold)).frame(width: 20, height: 20).background(MurmurPalette.accent.opacity(0.16), in: Circle())
                Text(title).font(.system(size: 15, weight: .medium))
                Spacer()
            }.padding(14).foregroundStyle(MurmurPalette.accent)
                .background(MurmurPalette(scheme: scheme).card, in: RoundedRectangle(cornerRadius: 15))
                .overlay(RoundedRectangle(cornerRadius: 15).stroke(MurmurPalette(scheme: scheme).border, style: StrokeStyle(lineWidth: 1, dash: [4,3])))
        }.buttonStyle(.plain).disabled(model.busy || model.preparingAll).accessibilityIdentifier(id)
    }
    private func packCard(title: String, id: String, remove: @escaping () -> Void, prepare: @escaping () async -> Void) -> some View {
        let p = MurmurPalette(scheme: scheme)
        let active = model.activePreparationID == id
        let ready = model.languageLibrary.isPrepared(id)
        let failure = model.preparationErrors[id]
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                }
                Spacer(minLength: 2)
                PackStatusBadge(title: active ? (model.warmingModels ? "Preparing…" : "Downloading") : failure != nil ? "Failed" : ready ? "Downloaded" : "Preparation needed", ready: active || ready)
                    .accessibilityIdentifier("language-status-" + id)
            }
            if active {
                PackProgressView(model: model)
                Button("Cancel download") { Task { await model.cancel() } }.font(.footnote).frame(minHeight: 44)
            }
            if let failure { Text(failure).font(.system(size: 12)).foregroundStyle(Color(hex: 0xd6603c)) }
            if !active {
                VStack(spacing: 8) {
                    if !ready || failure != nil {
                        DesignButton(title: failure != nil ? "Retry" : "Download", kind: .secondary) { Task { await prepare() } }.accessibilityIdentifier("prepare-" + id)
                    }
                    Button("Delete language", role: .destructive, action: remove).font(.footnote).frame(minHeight: 44)
                        .accessibilityIdentifier("delete-language-" + id)
                }.disabled(model.busy || model.preparingAll)
            }
        }.murmurCard(radius: 15, padding: 14)
            .rowActions((!ready || failure != nil ? [
                RowAction(id: "language-prepare", title: failure != nil ? "Retry" : "Download", symbol: "arrow.down.circle", edge: .leading,
                          enabled: !model.busy && !model.preparingAll) { Task { await prepare() } }
            ] : []) + [
                RowAction(id: "language-remove", title: "Delete language", symbol: "minus.circle", destructive: true,
                          enabled: !model.busy && !model.preparingAll, perform: remove),
                RowAction(id: "language-storage", title: "Manage storage", symbol: "internaldrive", enabled: !model.managingStorage) { model.requestUtilityRoute("storage") }
            ])
    }
}

struct PackProgressView: View {
    @Bindable var model: AppModel
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.3)) { _ in
            VStack(alignment: .leading, spacing: 5) {
                Text(model.preparationStageLabel).font(.caption).accessibilityIdentifier("preparation-stage")
            if model.warmingModels { ProgressView().frame(maxWidth: .infinity, alignment: .leading) }
            else if let fraction = model.preparationFraction {
                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(value: fraction)
                    Text(fraction, format: .percent.precision(.fractionLength(0))).font(.system(size: 11.5)).monospacedDigit()
                }
            } else { ProgressView().frame(maxWidth: .infinity, alignment: .leading) }
            }
        }.tint(MurmurPalette.accent)
    }
}

struct PreparationStatusView: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let p = MurmurPalette(scheme: scheme)
        VStack(alignment: .leading, spacing: 9) {
            if model.phase == .preparing {
                Text(model.preparationModel).font(.system(size: 14, weight: .medium))
                PackProgressView(model: model)
            } else if let failure = model.preparationErrors.sorted(by: { $0.key < $1.key }).first?.value {
                Text("Failed").font(.system(size: 14, weight: .medium)).foregroundStyle(Color(hex: 0xd6603c))
                Text(failure).font(.system(size: 12)).foregroundStyle(p.secondary)
            } else if model.languageLibrary.count > 0 && model.languageLibrary.preparedCount == model.languageLibrary.count {
                Label("Ready offline", systemImage: "checkmark.circle").font(.system(size: 14, weight: .medium)).foregroundStyle(MurmurPalette.accent)
            } else {
                Text("Choose languages").font(.system(size: 14, weight: .medium))
            }
        }.frame(maxWidth: .infinity, alignment: .leading).murmurCard(radius: 14, padding: 14).accessibilityIdentifier("preparation-status")
    }
}

private struct AddSpeechLanguageSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Add speech language").font(.system(size: 17, weight: .semibold)); Spacer(); Button("Done") { dismiss() } }
            ActionList(horizontalPadding: 10, spacing: 0) {
                    ForEach(AppLanguages.all, id: \.code) { language in
                        let added = model.languageLibrary.speech.contains(language.code)
                        Button { model.languageLibrary.addSpeech(language.code) } label: {
                            HStack {
                                Text(language.name); Spacer()
                                Image(systemName: added ? "checkmark" : "plus").frame(width: 44, height: 44).allowsHitTesting(false).accessibilityHidden(true)
                            }.font(.system(size: 16)).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                                .foregroundStyle(MurmurPalette(scheme: scheme).ink).contentShape(.interaction, Rectangle())
                        }.buttonStyle(.plain).disabled(model.busy || model.preparingAll).accessibilityIdentifier("add-speech-" + language.code)
                            .rowActions([
                                RowAction(id: "speech-selection", title: added ? "Delete language" : "Add", symbol: added ? "minus.circle" : "plus.circle",
                                          destructive: added, enabled: !model.busy && !model.preparingAll) {
                                    if added { Task { await model.removeSpeechLanguage(language.code) } }
                                    else { model.languageLibrary.addSpeech(language.code) }
                                }
                            ])
                            .listRowSeparator(.visible)
                    }
            }
        }.accessibilityElement(children: .contain).accessibilityAddTraits(.isModal)
        .padding(20).padding(.top, 8).presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            .presentationBackground(MurmurPalette(scheme: scheme).card).tint(MurmurPalette.accent)
    }
}

private struct AddTranslationLanguageSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var from = "ru"
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Add translation language").font(.system(size: 17, weight: .semibold)); Spacer(); Button("Done") { dismiss() } }
            LanguageMenu(selection: $from, codes: LanguagePair.qualityLanguages.sorted(), preferred: model.languageLibrary.speech + TranslationPaths.offlineRoutes.sources, identifier: "add-translation-source")
            ActionList(horizontalPadding: 10, spacing: 0) {
                    ForEach(LanguagePair.qualityLanguages.sorted().filter { $0 != from }, id: \.self) { code in
                        let available = model.availableTranslationTargets(from: from).contains(code)
                        let added = model.languageLibrary.translations.contains(TranslationLanguagePack(source: from, target: code))
                        Button { model.languageLibrary.addTranslation(from: from, to: code) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(AppLanguages.name(from)) → \(AppLanguages.name(code))").font(.system(size: 15, weight: .medium))
                                    if !available { Text("Not supported yet").font(.system(size: 11.5)).foregroundStyle(.secondary) }
                                }
                                Spacer(); Image(systemName: added ? "checkmark" : "plus").foregroundStyle(MurmurPalette.accent)
                                    .frame(width: 44, height: 44).allowsHitTesting(false).accessibilityHidden(true)
                            }.frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                                .foregroundStyle(MurmurPalette(scheme: scheme).ink).opacity(available ? 1 : 0.5).contentShape(.interaction, Rectangle())
                        }.buttonStyle(.plain).disabled(!available || model.busy || model.preparingAll).accessibilityIdentifier("add-translation-" + code)
                            .rowActions([
                                RowAction(id: "translation-selection", title: added ? "Delete language" : "Add", symbol: added ? "minus.circle" : "plus.circle",
                                          destructive: added, enabled: (available || added) && !model.busy && !model.preparingAll) {
                                    if added { Task { await model.removeTranslationLanguage(.init(source: from, target: code)) } }
                                    else { model.languageLibrary.addTranslation(from: from, to: code) }
                                }
                            ])
                            .listRowSeparator(.visible)
                    }
            }
        }.accessibilityElement(children: .contain).accessibilityAddTraits(.isModal)
        .padding(20).padding(.top, 8).onAppear { from = LanguagePair.qualityLanguages.contains(model.source) ? model.source : "en" }
            .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            .presentationBackground(MurmurPalette(scheme: scheme).card).tint(MurmurPalette.accent)
    }
}
