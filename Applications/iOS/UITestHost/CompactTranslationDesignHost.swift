import SwiftUI
import MurmurCore

/// Deterministic UI fixtures; excluded from the production app and extension.
struct CompactTranslationDesignHost: View {
    @State private var controller: TextTranslationModel
    @State private var presented = true
    @State private var replacement = ""
    @State private var expanded = false
    private let readOnly: Bool

    init() {
        let args = ProcessInfo.processInfo.arguments
        readOnly = args.contains("--compact-read-only")
        let engine = CompactSheetFixtureEngine(long: args.contains("--compact-long"), slow: args.contains("--compact-slow"), failure: args.contains("--compact-error"))
        let model = TextTranslationModel(engine: engine, source: "fi", target: "ru", availableTargets: { source in ["en", "fi", "ru"].filter { $0 != source } })
        model.input = args.contains("--compact-long") ? "Kiitos eilisestä palaverista. Lähetän sopimuspaperit huomenna aamulla ja liitän mukaan kolmannen vaiheen budjetin sekä aikataulun." : "Lähetän paperit huomenna."
        _controller = State(initialValue: model)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Palaveri 12.9.").font(.title.bold())
            Text(replacement.isEmpty ? "Kiitos eilisestä palaverista. Sovimme, että tarkistan sopimusluonnoksen ja lähetän kommentit ennen viikonloppua." : replacement)
                .accessibilityIdentifier("compact-host-text")
            Text("Lähetän paperit huomenna.").padding(3).background(MurmurPalette.accent.opacity(0.25))
            Spacer()
            Button("Show translation") { presented = true }
        }.padding(24)
            .sheet(isPresented: $presented) {
                CompactTranslationSheet(controller: controller, replace: readOnly ? nil : { replacement = $0; presented = false },
                    translate: { controller.start() }, close: { controller.cancel(); presented = false }, expand: { expanded = true })
                    .presentationDetents(expanded ? [.large] : [.height(388)])
                    .presentationDragIndicator(.visible)
                    .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("--compact-dark") ? .dark : .light)
                    .environment(\.dynamicTypeSize, ProcessInfo.processInfo.arguments.contains("--compact-accessibility") ? .accessibility3 : .large)
            }
            .task { controller.start() }
    }
}

private actor CompactSheetFixtureEngine: TextTranslationEngine {
    let long: Bool
    let slow: Bool
    let failure: Bool
    init(long: Bool, slow: Bool, failure: Bool) { self.long = long; self.slow = slow; self.failure = failure }
    var residentModelCount: Int { 0 }
    func prepare(from: String, to: String, onProgress: @escaping @MainActor @Sendable (Double) -> Void) async throws {
        if failure { throw CocoaError(.fileReadNoSuchFile) }
        await onProgress(1)
    }
    func translate(_ text: String, from: String, to: String) async throws -> String {
        if slow { try await Task.sleep(for: .seconds(30)) }
        if long { return String(repeating: "Спасибо за вчерашнюю встречу. Завтра утром пришлю бумаги по договору и приложу смету по третьему этапу вместе с графиком работ. ", count: 10) + "КОНЕЦ ПЕРЕВОДА" }
        return text == "Lähetän paperit huomenna." ? "Завтра пришлю бумаги." : "Updated translation: \(text)"
    }
    func unload() async {}
}
// Exercises the production keyboard view with deterministic result/receipt states.
struct KeyboardResultTestHost: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> KeyboardViewController {
        let controller = KeyboardViewController()
        let handled = ProcessInfo.processInfo.arguments.contains("--result-handled")
        let inactive = handled || ProcessInfo.processInfo.arguments.contains("--result-inactive")
        var state = KeyboardSessionState(phase: inactive ? .inactive : .result, configuration: .init(source: "ru", target: "fi"))
        state.utteranceID = UUID(); state.text = "Раз, два, три."; state.translation = "Yksi, kaksi, kolme."
        if LongConversationHost.scenario == "keyboard" {
            state.translation = "Ensimmäinen lause on tallessa.\n\n" + String(repeating: "Vanhempainillassa puhutaan koulupäivästä ja lasten hyvinvoinnista.\n\n", count: 45) + "Viimeinen lause on tallessa."
        }
        state.microphoneActive = !inactive
        controller.setDesignSnapshot(state, handledID: handled ? state.utteranceID : nil)
        return controller
    }
    func updateUIViewController(_ controller: KeyboardViewController, context: Context) {}
}
