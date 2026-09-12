import SwiftUI
import AppIntents

@main struct MurMurApp: App {
    @State private var model: AppModel
    init() {
        var preparationError: Error?
        do { try TranslationStorageSetup.prepare() } catch { preparationError = error }
        let appModel=AppModel()
        if let preparationError { appModel.error=preparationError.localizedDescription }
        _model=State(initialValue:appModel)
    }
    @AppStorage("appearance") private var appearance = "system"
    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                #if !MURMUR_UI_HOST
                if ProcessInfo.processInfo.arguments.contains("--quality-qualification-probe") { QualityQualificationProbe() }
                else if ProcessInfo.processInfo.arguments.contains("--keyboard-stream-replay") { KeyboardStreamReplayView() }
                else if ProcessInfo.processInfo.arguments.contains("--storage-probe") { StorageProbe() }
                else if ProcessInfo.processInfo.arguments.contains("--text-translation-probe") { TextTranslationProbe() }
                else if ProcessInfo.processInfo.arguments.contains("--audio-import-probe") { AudioImportProbe() }
                else if ProcessInfo.processInfo.arguments.contains("--european-translation-probe") { EuropeanTranslationProbe() }
                else if ProcessInfo.processInfo.arguments.contains("--finnish-translation-probe") { FinnishTranslationProbe() }
                else if ProcessInfo.processInfo.arguments.contains("--keyboard-background-probe") { MobileKeyboardBackgroundProbeView() }
                else { standardDebugRoot }
                #else
                standardDebugRoot
                #endif
                #else
                NotesView(model: model)
                #endif
            }
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
                .sheet(isPresented: $model.showSafariSetup, onDismiss: { model.consumeUtilityRoute() }) {
                    NavigationStack {
                        PageTranslationHelpView().toolbar {
                            ToolbarItem(placement: .confirmationAction) { Button("Done") { model.showSafariSetup = false } }
                        }
                    }
                }
                .onOpenURL { url in
                    if url.isFileURL { Task { await model.receiveAudio(url) }; return }
                    if url.scheme == "murmur" {
                        if url.host == "safari-setup" {
                            model.requestUtilityRoute("safari-setup")
                            return
                        }
                        if let route = url.host, ["settings", "languages", "translate", "memory", "release-memory"].contains(route) { model.requestUtilityRoute(route) }
                    }
                    if url.scheme == "murmur", url.host == "keyboard" {
                        if model.phase == .idle {
                            model.showKeyboardSetup = true
                            model.keyboardActivationRequested = true
                            Task { await model.consumeKeyboardActivation() }
                        }
                    }
                    if url.scheme == "murmur", url.host == "record" {
                        UserDefaults.standard.set(true, forKey: "pendingRecording")
                        NotificationCenter.default.post(name: .murmurRecordRequested, object: nil)
                    }
                }
        }
    }
    #if DEBUG
    @ViewBuilder private var standardDebugRoot: some View {
        #if MURMUR_UI_HOST
        if LongConversationHost.scenario != nil { LongConversationHost() }
        else if ProcessInfo.processInfo.arguments.contains("--keyboard-result-test") { KeyboardResultTestHost() }
        else if ProcessInfo.processInfo.arguments.contains("--compact-translation-sheet") { CompactTranslationDesignHost() }
        else if ProcessInfo.processInfo.arguments.contains("--design-capture") { DesignCaptureView() }
        else if ProcessInfo.processInfo.arguments.contains("--widget-preview") { WidgetPreviewView() }
        else { debugNotesRoot }
        #else
        debugNotesRoot
        #endif
    }
    @ViewBuilder private var debugNotesRoot: some View {
        if ProcessInfo.processInfo.arguments.contains("--keyboard-host-probe") { KeyboardProbeHostView() }
        else { NotesView(model: model) }
    }
    #endif
}

extension Notification.Name { static let murmurRecordRequested = Notification.Name("murmur.record.requested") }

struct StartRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Record a Murmator note"
    static var description = IntentDescription("Open Murmator and start on-device dictation.")
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(true, forKey: "pendingRecording")
        NotificationCenter.default.post(name: .murmurRecordRequested, object: nil)
        return .result()
    }
}
struct MurMurShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartRecordingIntent(), phrases: ["Record a note with \(.applicationName)"],
                    shortTitle: "Record a note", systemImageName: "waveform")
    }
}
