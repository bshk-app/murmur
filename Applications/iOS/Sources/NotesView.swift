import SwiftUI
import MurmurCore
import UniformTypeIdentifiers

struct NotesView: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var keyboardHelp = false
    @State private var editNoteID: UUID?
    private var palette: MurmurPalette { .init(scheme: scheme) }


    private var navigationContent: some View {
        NavigationStack {
            if !onboardingComplete {
                OnboardingView(model: model) { onboardingComplete = true }
            } else {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Notes").font(.system(size: 33, weight: .bold)).tracking(-0.5)
                        Spacer()
                        Button { model.requestUtilityRoute("audio-import") } label: {
                            Image(systemName: "square.and.arrow.down").font(.system(size: 18)).frame(width: 44, height: 44).background(palette.card, in: Circle()).overlay(Circle().stroke(palette.border))
                        }.buttonStyle(.plain).accessibilityLabel("Import audio").accessibilityIdentifier("import-audio")
                        Button { model.showSettings = true } label: { Image(systemName: "gearshape").font(.system(size: 18)).frame(width:44,height:44).background(palette.card,in:Circle()).overlay(Circle().stroke(palette.border)) }
                            .accessibilityLabel("Settings").accessibilityIdentifier("settings")
                    }
                    HStack(spacing: 10) {
                        Image(systemName:"magnifyingglass").foregroundStyle(palette.secondary)
                        TextField("Search transcripts", text:$query).accessibilityIdentifier("search-notes")
                            .focused($searchFocused).submitLabel(.search)
                            .onSubmit { searchFocused = false }
                        if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Clear search") }
                    }.padding(12).background(palette.card,in:RoundedRectangle(cornerRadius:12))
                    if let job = model.audioImports.jobs.first(where: { $0.id == model.audioImports.activeID }) ?? model.audioImports.jobs.first(where: { $0.status == .paused || $0.status == .queued }) {
                        Button { model.audioImports.selectedID = job.id; model.requestUtilityRoute("audio-import") } label: {
                            ImportStatusBanner(job: job)
                        }.buttonStyle(.plain).accessibilityIdentifier("audio-imports")
                    }
                    if model.keyboard.isActive {
                        Button { model.showKeyboardSetup = true } label: { Label(LocalizedStringKey(model.keyboard.summaryTitle), systemImage: "keyboard").font(.footnote).frame(maxWidth: .infinity, alignment: .leading).murmurCard() }.buttonStyle(.plain)
                    }
                    if model.phase == .preparing || !model.preparationErrors.isEmpty {
                        NavigationLink { LanguageSetupView(model: model) } label: { PreparationStatusView(model: model) }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 20).padding(.bottom, 12)
                ActionList {
                    if model.noteList.items.isEmpty && model.noteList.isLoading {
                        ProgressView().frame(maxWidth: .infinity).padding()
                    } else if model.noteList.items.isEmpty && model.noteList.query.isEmpty && model.noteList.error == nil {
                        VStack(spacing: 16) {
                            MurmurMascot().accessibilityHidden(true)
                            Text("No notes yet").font(.system(size: 20, weight: .semibold)).multilineTextAlignment(.center)
                            Text("Tap the mic and say the first one.").font(.system(size: 14)).lineSpacing(5).foregroundStyle(palette.secondary).multilineTextAlignment(.center).frame(maxWidth: 260)
                        }.frame(maxWidth:.infinity).padding(.top,26)
                    } else if model.noteList.items.isEmpty && model.noteList.error == nil {
                        VStack(spacing: 14) {
                            MurmurMascot().accessibilityHidden(true)
                            Text("No matches").font(.system(size: 20, weight: .semibold))
                            Text(query).font(.system(size: 14)).foregroundStyle(palette.secondary)
                            Button("Clear search") { query = "" }.buttonStyle(.bordered)
                        }.multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.top, 26)
                    } else {
                        ForEach(model.noteList.items) { note in
                            NoteListRow(note: note, model: model,
                                open: { openNote(note.id, editing: false) },
                                edit: { openNote(note.id, editing: true) })
                        }
                    }
                    if let message = model.noteList.error {
                        VStack(spacing: 8) {
                            Text(message).font(.footnote).foregroundStyle(.secondary)
                            Button("Retry") { Task { await model.noteList.retry() } }
                        }.frame(maxWidth: .infinity).padding()
                    } else if let cursor = model.noteList.next {
                        ProgressView().frame(maxWidth: .infinity).padding()
                            .id(cursor)
                            .accessibilityIdentifier("notes-load-more")
                            .task { await model.noteList.loadMore() }
                    }
                }.scrollDismissesKeyboard(.interactively)
                    .accessibilityIdentifier("notes-list")
                    .refreshable { await model.refresh() }
            }.frame(maxWidth:680).frame(maxWidth: .infinity)
            .background(palette.background).foregroundStyle(palette.ink)
            .safeAreaInset(edge:.bottom) { dock }
            .navigationTitle("Notes").toolbar(.hidden, for:.navigationBar)
            .navigationDestination(item:$model.selectedNote) { note in NoteDetailView(note: note, model:model, editOnOpen: editNoteID == note.id) }
            .navigationDestination(isPresented: $model.showSettings) { SettingsView(model: model) }
            }
        }
    }
    private var utilitySheets: some View {
        navigationContent.tint(MurmurPalette.accent)
        .sheet(isPresented: $model.showAudioImport, onDismiss: { model.audioImports.dismissCompleted(); model.consumeUtilityRoute(); Task { await model.refresh() } }) { AudioImportView(model: model) }
        #if !MURMUR_UI_HOST
        .sheet(isPresented: $model.showCanary, onDismiss: { model.consumeUtilityRoute(); Task { await model.refresh() } }) {
            CanaryExperimentView(model: model.canary, prepareExclusive: { try await model.prepareForCanary() })
        }
        .onChange(of: model.canary.isBusy) { _, busy in
            if !busy {
                if model.pendingUtilityRoute != nil { model.showCanary = false }
                else { Task { await model.refresh() } }
            }
        }
        #endif
        .sheet(isPresented: $model.showStorage, onDismiss: { model.consumeUtilityRoute() }) { StorageView(model: model) }
        .sheet(isPresented: $model.showMemory, onDismiss: { model.consumeUtilityRoute() }) { MemoryView(model: model) }
        .sheet(isPresented: $model.showLanguages, onDismiss: { model.consumeUtilityRoute() }) { NavigationStack { LanguageSetupView(model: model, isSheetRoot: true) } }
    }
    private var observedContent: some View {
        utilitySheets
        .onChange(of: model.managingStorage) { if !model.managingStorage { model.consumeUtilityRoute() } }
        .onChange(of: model.textTranslator.phase) { model.publishWidgetState(); if !model.textTranslator.isBusy { model.consumeUtilityRoute() } }
        .onChange(of: model.textTranslator.modelsLoaded) { model.publishWidgetState() }
        .onChange(of: model.audioImports.activeID) { model.publishWidgetState() }
        .onChange(of: model.audioImports.preparing) { model.publishWidgetState() }
        .onChange(of: model.modelReady) { model.publishWidgetState() }
        .onChange(of: model.phase) { model.publishWidgetState(); UIApplication.shared.isIdleTimerDisabled = model.busy && model.phase != .ready }
        .onChange(of: model.keyboard.state.phase) { model.publishWidgetState() }
        .onChange(of: model.keyboard.isActive) { model.publishWidgetState() }
    }
    private var recordingPresented: Binding<Bool> {
        Binding(get: { model.showRecorder && onboardingComplete }, set: { model.showRecorder = $0 })
    }
    private var presentedContent: some View {
        observedContent
        .sheet(isPresented:$model.showTranslation, onDismiss: { model.consumeUtilityRoute() }) { TranslationSetupView(model:model) { model.showTranslation=false; Task { await model.start(translating:true) } } }
        .sheet(isPresented:$keyboardHelp) { KeyboardHelpView() }
        .sheet(isPresented: $model.showKeyboardSetup, onDismiss: { model.consumeUtilityRoute(); Task { await model.refresh() } }) { KeyboardDictationView(controller: model.keyboard) { await model.enableKeyboard() } }
        .fullScreenCover(isPresented: recordingPresented) { RecordingView(model:model).interactiveDismissDisabled() }
        .alert("Murmator",isPresented:Binding(get:{model.error != nil && onboardingComplete && !model.showRecorder && !model.showSettings && !model.showTranslation},set:{if !$0 {model.error=nil}})) {
            Button("OK",role:.cancel) { model.error=nil }
        } message: { Text(model.error ?? "") }
    }
    var body: some View {
        presentedContent
        .onChange(of:model.busy) { _,value in UIApplication.shared.isIdleTimerDisabled = value && model.phase != .ready }
        .onChange(of:onboardingComplete) { _,_ in consumeRecordingRequest() }
        .onChange(of:scenePhase) { _,phase in
            if phase != .active { Task { await model.pauseLanguagePreparation() } }
            if phase == .background { model.audioImports.pause(); model.textTranslator.cancel() }
            if phase == .active {
                Task { await model.resumeLanguagePreparation(); await model.refresh() }
                consumeRecordingRequest()
                if model.keyboardActivationRequested { Task { await model.consumeKeyboardActivation() } }
            }
            else if model.phase == .recording { Task { await model.interrupted() } }
        }
        .onReceive(NotificationCenter.default.publisher(for:.murmurRecordRequested)) { _ in consumeRecordingRequest() }
        .task { await initialize() }
        .task(id: query) {
            do {
                if !query.isEmpty { try await Task.sleep(for: .milliseconds(200)) }
                try Task.checkCancellation()
                await model.noteList.search(query)
            } catch is CancellationError { }
            catch { model.error = error.localizedDescription }
        }
    }
    private func openNote(_ id: UUID, editing: Bool) {
        Task {
            guard let note = await model.loadNote(id) else { return }
            editNoteID = editing ? id : nil
            model.selectedNote = note
        }
    }
    @MainActor private func initialize() async {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--onboarding-ui-testing") { onboardingComplete=false; return }
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") { onboardingComplete=true; model.seedUITest(); return }
            #endif
            if UserDefaults.standard.integer(forKey: "onboardingVersion") < 4 {
                onboardingComplete = false
                UserDefaults.standard.set(4, forKey: "onboardingVersion")
            }
            await model.refresh(); model.publishWidgetState(); consumeRecordingRequest()
            await model.resumeLanguagePreparation()
            }
    private var dock: some View {
        VStack(spacing:14) {
            SpeechPriorityPicker(model: model).frame(maxWidth: 340).padding(.horizontal, 20)
            HStack(spacing:18) {
                dockAction("Translate", symbol:"character.bubble") { model.showTranslation=true }
                Button { Task { await model.start() } } label: {
                    Image(systemName:"waveform").font(.system(size:34,weight:.semibold)).foregroundStyle(Color(hex:0x241f1c))
                        .frame(width:78,height:78).background(MurmurPalette.accent,in:Circle())
                        .shadow(color:MurmurPalette.accent.opacity(0.3),radius:18,y:8)
                }.accessibilityLabel("Record a note").accessibilityIdentifier("record-note")
                dockAction("Keyboard",symbol:"keyboard") { model.showKeyboardSetup=true }
            }
        }.frame(maxWidth:.infinity).padding(.top,22).padding(.bottom,12)
            .background(LinearGradient(colors:[palette.background.opacity(0),palette.background,palette.background],startPoint:.top,endPoint:.bottom))
            .disabled(model.busy)
    }
    private func dockAction(_ title: LocalizedStringKey,symbol:String,action:@escaping()->Void)->some View {
        Button(action:action) { VStack(spacing:7) {
            Image(systemName:symbol).font(.title3).frame(width:52,height:52).background(palette.card,in:Circle())
            Text(title).font(.caption)
        }.frame(width:76).foregroundStyle(palette.secondary) }.buttonStyle(.plain)
    }
    private func consumeRecordingRequest() {
        guard onboardingComplete, scenePhase == .active, UserDefaults.standard.bool(forKey:"pendingRecording") else { return }
        UserDefaults.standard.set(false,forKey:"pendingRecording")
        if model.phase == .recording { Task { await model.stop() } }
        else if model.phase == .idle { model.requestUtilityRoute("record") }
    }
}

private struct ImportStatusBanner: View {
    let job: AudioImportJob
    @Environment(\.colorScheme) private var scheme
    private var p: MurmurPalette { .init(scheme: scheme) }
    var body: some View {
                            HStack(spacing: 10) {
                                Image(systemName: job.status == .paused ? "pause" : "waveform").frame(width: 34, height: 34).background(MurmurPalette.accent.opacity(0.13), in: Circle())
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(job.filename).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    ProgressView(value: job.savedFraction ?? 0).tint(MurmurPalette.accent)
                                    Text("\(AudioImportJob.time(job.processedSeconds)) \(L10n.text("of")) \(AudioImportJob.time(job.duration))").font(.caption).monospacedDigit().foregroundStyle(p.secondary)
                                }
                                Spacer(minLength: 0)
                                VStack(alignment: .trailing, spacing: 6) {
                                    StatusTag(title: job.status == .paused ? "Paused" : job.status == .queued ? "Waiting" : "Transcribing audio…", tone: job.status == .queued ? .neutral : .accent)
                                    Text("Open").font(.caption.weight(.semibold))
                                }
                            }.padding(12).background(MurmurPalette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
    }
}
