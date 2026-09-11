import SwiftUI
import NaturalLanguage
import MurmurCore
import MurmurTranslation

@MainActor @Observable final class PageTranslationState {
    enum Phase { case reading, idle, preparing, translating, cancelling }
    var page: PageTranslationRequest?
    var phase = Phase.reading
    var source = "en"
    var target = "fi"
    var detected = false
    var validPage = false
    var error: String?
    var fraction = 0.0
    var completedBlocks = 0
    var task: Task<Void, Never>?
    private var operation: UUID?
    let engine = PageTranslationSession(modelsRoot: TranslationPaths.models)
    var finish: ((PageTranslationRequest, PageTranslationOutput, String, String) -> Void)?
    var dismiss: (() -> Void)?
    var busy: Bool { [.preparing, .translating, .cancelling].contains(phase) }
    var languages: [String] { LanguagePair.qualityLanguages.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending } }
    var targets: [String] { TextTranslationSession.availableTargets(from: source, modelsRoot: TranslationPaths.models).sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending } }
    func name(_ code: String) -> String { Locale.current.localizedString(forLanguageCode: code)?.localizedCapitalized ?? code.uppercased() }
    func receive(_ page: PageTranslationRequest) {
        self.page = page; phase = .idle
        do { try page.validate(); validPage = true; error = nil } catch { validPage = false; show(error); return }
        let sample = page.groups.flatMap(\.runs).map(\.text).joined(separator: " ").prefix(4000)
        let recognized = NLLanguageRecognizer.dominantLanguage(for: String(sample))?.rawValue
        let hint = page.documentLanguage.split(separator: "-").first.map(String.init)
        let choice = [recognized, hint].compactMap { $0 }.first { LanguagePair.qualityLanguages.contains($0) }
        detected = choice != nil
        source = choice ?? (LanguagePair.qualityLanguages.contains(TranslationPreferences.source) ? TranslationPreferences.source : "en")
        target = [TranslationPreferences.target, TranslationPreferences.source, "en", "fi"].first { targets.contains($0) } ?? targets.first ?? ""
        if !TranslationPaths.isReady { error = PageL10n.text("Open Murmator once before translating webpages.") }
    }
    func sourceChanged() { detected = false; if !targets.contains(target) { target = targets.first ?? "" } }
    func start() {
        guard let page, validPage, !busy, TranslationPaths.isReady, targets.contains(target) else { return }
        let from = source, to = target
        let token = UUID(); operation = token
        TranslationPreferences.save(source: from, target: to)
        phase = .preparing; fraction = 0; error = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let output = try await PageTranslationProcessor.translate(page, from: from, to: to, engine: engine) { [weak self] value in
                    guard let self, self.operation == token, self.busy, self.phase != .cancelling else { return }
                    switch value {
                    case .preparing(let fraction): if self.phase == .preparing { self.fraction = fraction }
                    case .translating(let count, let total): self.phase = .translating; self.completedBlocks = count; self.fraction = Double(count) / Double(max(1, total))
                    }
                }
                try Task.checkCancellation()
                operation = nil; phase = .idle; task = nil; finish?(page, output, from, to)
            } catch {
                operation = nil; task = nil
                if Task.isCancelled || phase == .cancelling { phase = .idle; dismiss?() }
                else { phase = .idle; show(error) }
            }
        }
    }
    func cancel() {
        if busy { operation = nil; phase = .cancelling; task?.cancel() }
        else { dismiss?() }
    }
    func show(_ error: Error) {
        switch error {
        case PageTranslationError.pageTooLarge: self.error = PageL10n.text("This page is too large to translate at once.")
        case PageTranslationError.invalidPage: self.error = PageL10n.text("No readable text was found on this page.")
        default: self.error = PageL10n.text("Translation failed. The original page is unchanged.") + "\n" + error.localizedDescription
        }
    }
}

struct PageTranslationView: View {
    @Bindable var state: PageTranslationState
    var body: some View {
        NavigationStack {
            Form {
                if let page = state.page {
                    Section {
                        Text(String(page.title.prefix(240))).font(.headline).lineLimit(3)
                        if let host = URL(string: page.url)?.host { Text(host).font(.footnote).foregroundStyle(.secondary) }
                    }
                }
                if state.phase == .reading { ProgressView(PageL10n.text("Reading webpage…")) }
                else {
                    Section {
                        HStack { Text(PageL10n.text("From language")); Spacer(); LanguageMenu(selection: Binding(get: { state.source }, set: { state.source = $0; state.sourceChanged() }), codes: state.languages, preferred: TranslationPaths.offlineRoutes.sources, identifier: "page-source") }
                        HStack { Text(PageL10n.text("Translate to")); Spacer(); LanguageMenu(selection: $state.target, codes: state.targets, preferred: TranslationPaths.offlineRoutes.targets(from: state.source), identifier: "page-target") }
                        if !state.detected { Text(PageL10n.text("Check the source language")).font(.footnote).foregroundStyle(.secondary) }
                    }.disabled(state.busy)
                    if let error = state.error { Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("page-translation-error") } }
                    Section {
                        if state.busy {
                            ProgressView(value: state.fraction)
                            Text(state.phase == .cancelling ? PageL10n.text("Stopping…") : state.phase == .preparing ? PageL10n.text("Preparing language packs…") : PageL10n.format("Translated %d of %d blocks", state.completedBlocks, state.page?.groups.count ?? 0))
                                .accessibilityIdentifier("page-translation-progress")
                        } else {
                            Button(PageL10n.text("Translate")) { state.start() }.accessibilityIdentifier("page-translate-start")
                                .disabled(!state.validPage || !TranslationPaths.isReady || state.target.isEmpty)
                        }
                    }
                }
            }.navigationTitle(PageL10n.text("Translate page")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(PageL10n.text("Cancel")) { state.cancel() }.disabled(state.phase == .cancelling).accessibilityIdentifier("page-translate-cancel") } }
                .interactiveDismissDisabled(state.busy)
        }.tint(Color(red: 0.79, green: 0.40, blue: 0.12))
    }
}
