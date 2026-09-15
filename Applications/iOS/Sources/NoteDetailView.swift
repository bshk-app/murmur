import SwiftUI
import MurmurCore

struct NoteDetailView: View {
    let note: VoiceNote
    @Bindable var model: AppModel
    var editOnOpen = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @State private var sharing = false
    @State private var copied = false
    @State private var deleting = false
    @State private var editing = false
    @State private var edited = ""
    @State private var didOpen = false
    @State private var showingOriginal = false
    @State private var translationTask: Task<Void, Never>?
    @State private var translationProgress: Double?
    @State private var translationError: String?
    @State private var showingVersions = false
    @FocusState private var editorFocused: Bool
    /// --mur-text-body: the reader and the editor show the transcript at the same size.
    private static let bodySize: CGFloat = 17
    private var palette: MurmurPalette { .init(scheme: scheme) }
    private var current: VoiceNote { model.currentNote(note) }
    private var selectedText: String { (showingOriginal ? NoteContent.original : .translation).text(in: current) }
    var body: some View {
        ScrollViewReader { proxy in
        VStack(spacing: 0) {
            if current.text.count > 4000 || (current.translation?.count ?? 0) > 4000 {
                HStack {
                    Button("Beginning") { proxy.scrollTo("note-start", anchor: .top) }.accessibilityIdentifier("note-beginning")
                    Spacer()
                    Button("End") { proxy.scrollTo("note-end", anchor: .bottom) }.accessibilityIdentifier("note-end-button")
                }.font(.footnote).frame(minHeight: 44).padding(.horizontal, 20)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Color.clear.frame(height: 1).id("note-start")
                    HStack(spacing: 7) {
                        NoteBadge(text: current.targetLanguage.map { "\(current.sourceLanguage.uppercased()) → \($0.uppercased())" } ?? current.sourceLanguage.uppercased())
                        StatusTag(value: AudioImportJob.time(current.duration))
                    }
                    if let audio = model.audioURL(for: current) {
                        RecordingAudioControls(url: audio, duration: current.duration, disabled: model.busy) {
                            Task { await model.retranscribe(current) }
                        }
                    }
                    if current.translation?.isEmpty == false && !editing {
                        Picker("Reading view", selection: $showingOriginal) {
                            Text("Translation").tag(false)
                            Text("Original text").tag(true)
                        }.pickerStyle(.segmented).padding(.vertical, 4)
                            .accessibilityIdentifier("note-reading-mode")
                    }
                    if current.transcriptionComplete == false {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Partial transcript", systemImage: "pause.circle").font(.subheadline.weight(.semibold))
                            if model.importMayUpdate(current) {
                                Text("Completed text is saved. Finish transcription before editing this note.").font(.footnote).foregroundStyle(palette.secondary)
                                DesignButton(title: "Continue transcription") { model.openImport(for: current) }
                            }
                        }.padding(15).background(MurmurPalette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 15))
                    }
                    if editing {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Original text").font(.system(size: 11, weight: .medium)).textCase(.uppercase).foregroundStyle(palette.muted)
                            TextEditor(text: $edited).font(.body).scrollContentBackground(.hidden)
                                .frame(height: 300).focused($editorFocused).accessibilityIdentifier("note-editor")
                                .onAppear { editorFocused = true }
                        }.murmurCard()
                            .overlay(RoundedRectangle(cornerRadius: 15).stroke(MurmurPalette.accent.opacity(0.45)))
                    } else if showingOriginal || current.translation?.isEmpty != false {
                        if let utterances = current.utterances, !utterances.isEmpty {
                            VStack(alignment: .leading, spacing: 16) {
                                ForEach(utterances) { entry in
                                    UtteranceRow(utterance: entry, translated: false, size: Self.bodySize, identifier: entry.id == utterances.first?.id ? "note-text" : "note-text-utterance-\(entry.id)")
                                }
                            }
                        } else {
                        TranscriptText(text: current.text, size: Self.bodySize, identifier: "note-text")
                        }
                    }
                    if let translation = current.translation, !translation.isEmpty, !showingOriginal || editing {
                        Divider().overlay(palette.border)
                        Text(AppLanguages.name(current.targetLanguage ?? "")).font(.system(size: 11, weight: .medium)).textCase(.uppercase).foregroundStyle(MurmurPalette.accent)
                        if let utterances = current.utterances, !utterances.isEmpty, utterances.allSatisfy({ $0.translation != nil || $0.translationFailed == true }) {
                            VStack(alignment: .leading, spacing: 16) {
                                ForEach(utterances) { entry in
                                    UtteranceRow(utterance: entry, translated: true, size: Self.bodySize, identifier: entry.id == utterances.first?.id ? "note-translation" : "note-translation-utterance-\(entry.id)")
                                }
                            }
                        } else { TranscriptText(text: translation, size: Self.bodySize, identifier: "note-translation").foregroundStyle(palette.ink) }
                        if current.translationIncomplete == true { Text("Translation incomplete").font(.footnote).foregroundStyle(.secondary) }
                        if current.translationNeedsUpdate == true || editing && edited != current.text {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Translation may not match the edited text.").font(.system(size: 13, weight: .semibold))
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(13)
                                .background(Color(hex: 0xd6603c).opacity(0.1), in: RoundedRectangle(cornerRadius: 15))
                                .overlay(RoundedRectangle(cornerRadius: 15).stroke(Color(hex: 0xd6603c).opacity(0.35)))
                        }
                    }
                    Color.clear.frame(height: 1).id("note-end")
                }.frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity, alignment: .center).padding(.horizontal, 20).padding(.bottom, 20)
            }.accessibilityIdentifier("note-reader")
                .onChange(of: showingOriginal) { copied = false; proxy.scrollTo("note-start", anchor: .top) }
                .onChange(of: current.translation) { proxy.scrollTo("note-start", anchor: .top) }
        }
        }.background(palette.background).foregroundStyle(palette.ink).navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) { Text(current.createdAt, style: .date).font(.subheadline).foregroundStyle(palette.muted) }
                ToolbarItem(placement: .topBarTrailing) {
                    if editing { Button("Save") { save() } }
                    else {
                        Menu {
                            Button("Edit", systemImage: "pencil") { beginEditing() }.disabled(model.importMayUpdate(current))
                            Button("Copy", systemImage: "doc.on.doc") { copy() }
                            Button("Share", systemImage: "square.and.arrow.up") { sharing = true }
                            if current.transcriptVersions?.isEmpty == false {
                                Button("Previous versions", systemImage: "clock.arrow.circlepath") { showingVersions = true }
                            }
                            Button("Delete", systemImage: "trash", role: .destructive) { deleting = true }.disabled(model.importMayUpdate(current))
                        } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Note actions").accessibilityIdentifier("note-actions")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 9) {
                    if translationTask != nil {
                        ProgressView("Translating note…", value: translationProgress)
                        Button("Cancel translation") { translationTask?.cancel() }
                    }
                    if let translationError { Text(translationError).font(.footnote).foregroundStyle(.red) }
                    if editing {
                        HStack(spacing: 9) {
                            PrimaryButton(title: "Cancel", quiet: true) { editing = false }
                            PrimaryButton(title: "Save") { save() }.accessibilityIdentifier("save-note")
                        }
                    } else {
                        PrimaryButton(title: "Share") { sharing = true }.accessibilityIdentifier("share-note")
                        HStack(spacing: 9) {
                            DesignButton(title: copied ? "Copied" : "Copy", kind: .secondary) { copy() }.accessibilityIdentifier("copy-note")
                            DesignButton(title: "Edit", kind: .secondary) { beginEditing() }.disabled(model.importMayUpdate(current) || translationTask != nil).accessibilityIdentifier("edit-note")
                            Menu {
                                Picker("Translation", selection: $model.translationQuality) {
                                    ForEach(ProcessingQuality.translationOptions(from: current.sourceLanguage, to: current.targetLanguage ?? (current.sourceLanguage == "en" ? "ru" : "en")), id: \.self) { quality in
                                        Text(LocalizedStringKey(quality.title)).tag(quality)
                                    }
                                }
                                LanguageMenuChoices(codes: model.translationTargets(from: current.sourceLanguage), preferred: TranslationPaths.offlineRoutes.targets(from: current.sourceLanguage), select: translate)
                            } label: {
                                Text("Translate").designButtonSurface(.secondary)
                            }.accessibilityIdentifier("translate-note").disabled(model.busy || model.importMayUpdate(current) || translationTask != nil)
                        }
                    }
                }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 6).frame(maxWidth: 640).frame(maxWidth: .infinity)
                    .background(LinearGradient(colors: [palette.background.opacity(0), palette.background, palette.background], startPoint: .top, endPoint: .bottom))
            }
            .sheet(isPresented: $sharing) { ShareSheet(items: [selectedText]) }
            .sheet(isPresented: $showingVersions) { TranscriptHistoryView(versions: current.transcriptVersions ?? []) }
            .onDisappear { translationTask?.cancel() }
            .onAppear {
                guard !didOpen else { return }
                didOpen = true
                if editOnOpen { beginEditing() }
            }
            .alert("Delete this note?", isPresented: $deleting) {
                Button("Delete note", role: .destructive) { Task { model.error = nil; await model.delete(current); if model.error == nil { dismiss() } } }
                Button("Cancel", role: .cancel) {}
            } message: {
                if current.audio != nil { Text("The note, its versions and recording will be deleted.") }
            }
    }
    private func beginEditing() { guard !model.importMayUpdate(current) else { return }; edited = current.text; editing = true }
    private func translate(to target: String) {
        let snapshot = current
        translationError = nil; translationProgress = 0
        translationTask = Task {
            defer { translationTask = nil }
            do {
                try await model.translateNote(snapshot, to: target) { translationProgress = $0 }
                if !Task.isCancelled { showingOriginal = false }
            } catch { if !Task.isCancelled { translationError = error.localizedDescription } }
        }
    }
    private func copy() { UIPasteboard.general.string = selectedText; copied = true }
    private func save() {
        var updated = current
        if updated.text != edited && updated.translation != nil { updated.translationNeedsUpdate = true }
        updated.text = edited; model.error = nil
        Task { await model.saveEdit(updated); if model.error == nil { editing = false } }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
