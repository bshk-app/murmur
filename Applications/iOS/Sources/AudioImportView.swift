import SwiftUI
import UniformTypeIdentifiers

struct AudioImportView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var choosingFile = false
    @State private var removing: AudioImportJob?
    @ScaledMetric(relativeTo: .body) private var bodySize = 14.0
    @ScaledMetric(relativeTo: .caption) private var smallSize = 12.5
    private var p: MurmurPalette { .init(scheme: scheme) }
    private var jobs: [AudioImportJob] {
        model.audioImports.jobs.sorted { a, b in
            if a.id == b.id { return false }
            if a.id == model.audioImports.activeID { return true }
            if b.id == model.audioImports.activeID { return false }
            if a.status == .queued && b.status == .queued { return (a.queuedAt ?? a.createdAt) < (b.queuedAt ?? b.createdAt) }
            if a.status == .queued { return true }
            if b.status == .queued { return false }
            return a.createdAt > b.createdAt
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Audio imports").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.frame(minWidth: 44, minHeight: 44).foregroundStyle(p.accentText).disabled(model.audioImports.busy)
            }.padding(.horizontal, 20).padding(.top, 10)
            Divider().overlay(p.border)
            ScrollViewReader { scroll in
                ActionList(spacing: 16) {
                        Text(jobs.isEmpty ? "No imports in progress" : "Transcribe a recording").font(.title2.bold())
                        if model.audioImports.receiving { receivingCard }
                        if let error = model.audioImports.receiveError { receivingError(error) }
                        if jobs.isEmpty && !model.audioImports.receiving && model.audioImports.receiveError == nil {
                            DesignButton(title: "Choose audio", symbol: "waveform.badge.plus") { choosingFile = true }
                        }
                        ForEach(jobs) { job in card(job).id(job.id) }
                        if !jobs.isEmpty { DesignButton(title: "Import another recording", symbol: "plus", kind: .secondary) { choosingFile = true }.disabled(model.audioImports.receiving) }
                }.frame(maxWidth: 640).frame(maxWidth: .infinity)
                    .onChange(of: model.audioImports.selectedID) { _, id in if let id { withAnimation { scroll.scrollTo(id, anchor: .top) } } }
            }
        }.foregroundStyle(p.ink).presentationBackground(p.sheet).presentationCornerRadius(26)
            .presentationDetents([.fraction(0.92), .large]).presentationDragIndicator(.visible)
            .tint(p.accentText).interactiveDismissDisabled(model.audioImports.busy)
            .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.audio]) { result in
                switch result {
                case .success(let url): Task { await model.receiveAudio(url) }
                case .failure(let error): model.audioImports.receiveError = error.localizedDescription
                }
            }
            .alert("Murmator", isPresented: Binding(get: { model.audioImports.error != nil }, set: { if !$0 { model.audioImports.error = nil } })) {
                Button("OK", role: .cancel) { model.audioImports.error = nil }
            } message: { Text(model.audioImports.error ?? "") }
            .alert("Remove this import?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                if let job = removing {
                    Button("Remove import", role: .destructive) { removing = nil; Task { await model.audioImports.remove(job.id) } }.accessibilityIdentifier("confirm-import-remove")
                }
                Button("Cancel", role: .cancel) { removing = nil }
            } message: { Text("Saved notes and audio stay.") }
    }
    private var receivingCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(model.audioImports.receivingFilename ?? L10n.text("Audio recording"), systemImage: "doc.badge.arrow.up").font(.headline)
            Text("Importing audio…").font(.subheadline)
            ProgressTrack()
            DesignButton(title: "Transcribe", action: {}).disabled(true)
        }.murmurCard(radius: 18, padding: 16)
    }
    private func receivingError(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Label("Could not receive the file", systemImage: "exclamationmark.circle").font(.headline)
            StatusTag(title: "File transfer", tone: .error)
            Text("Transcription has not started. Choose the recording again or share it from Files.").font(.system(size: bodySize)).foregroundStyle(p.secondary)
            DesignButton(title: "Retry import") { model.audioImports.receiveError = nil; choosingFile = true }
            DisclosureGroup("Details") { Text(error).font(.footnote).textSelection(.enabled) }
        }.murmurCard(radius: 18, padding: 16)
    }
    private func card(_ job: AudioImportJob) -> some View {
        let active = model.audioImports.activeID == job.id
        let silent = job.status == .completed && job.text.isEmpty
        let completed = job.status == .completed && !silent
        let tone: DesignTone = job.status == .failed ? .error : completed ? .success : job.status == .paused ? .accent : .neutral
        return VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: completed ? "checkmark" : silent ? "waveform.slash" : job.status == .failed ? "exclamationmark" : "waveform")
                    .frame(width: 38, height: 38).foregroundStyle(completed ? Color(hex: scheme == .dark ? 0x8dcca1 : 0x1f6640) : job.status == .failed ? Color(hex: scheme == .dark ? 0xf0a194 : 0xa52a17) : p.secondary)
                    .background(p.card2, in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 5) {
                    Text(job.filename).font(.headline).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("import-item-\(job.id)")
                    if job.duration > 0 { Text(AudioImportJob.time(job.duration)).font(.system(size: smallSize)).monospacedDigit().foregroundStyle(p.muted) }
                }
                Spacer(minLength: 0)
                if FileManager.default.fileExists(atPath: job.audioURL.path) {
                    ShareLink(item: job.audioURL) { Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44) }.accessibilityLabel("Share recording")
                }
            }
            HStack(alignment: .top) {
                if active && (model.audioImports.preparing || model.audioImports.pausing) { ProgressView().controlSize(.small) }
                Text(status(job)).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            }
            if job.origin == .watch { StatusTag(title: "From Apple Watch") }
            if job.status == .queued { StatusTag(title: "Waiting") }
            else if job.status == .paused { StatusTag(title: "Partial transcript", tone: tone) }
            else if job.status == .failed { StatusTag(title: "Recognition", tone: .error) }
            else if silent { StatusTag(title: "No speech") }
            if !completed && (active || !job.segments.isEmpty) {
                ProgressTrack(value: model.audioImports.preparing && active ? nil : job.savedFraction, tone: tone)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(AudioImportJob.time(completed ? job.duration : job.processedSeconds)) \(L10n.text("of")) \(job.duration > 0 ? AudioImportJob.time(job.duration) : "—")")
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                    if let fraction = job.savedFraction {
                        Text("\(Int(fraction*100))%").font(.system(size: smallSize)).foregroundStyle(p.secondary)
                    }
                }
            }
            if !completed && job.status != .queued {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Language of the recording").font(.caption).foregroundStyle(p.muted)
                    Picker("Language of the recording", selection: Binding(get: { job.language }, set: { model.audioImports.setLanguage($0, for: job.id) })) {
                        ForEach(AppLanguages.all, id: \.code) { Text($0.name).tag($0.code) }
                    }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                        .disabled(active || !job.segments.isEmpty && !silent)
                }.padding(13).background(p.card2, in: RoundedRectangle(cornerRadius: 13))
            }
            if silent { Text("No text note was saved. Check the language of the recording or pick another file.").font(.system(size: bodySize)).foregroundStyle(p.secondary) }
            if !job.text.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text(LocalizedStringKey(completed ? "Transcript" : "Saved so far")).font(.caption).textCase(.uppercase).foregroundStyle(p.muted)
                    TranscriptPreview(text: job.text, identifier: "import-transcript-" + job.id.uuidString)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(p.card2, in: RoundedRectangle(cornerRadius: 13))
            }
            VStack(spacing: 9) {
                if active {
                    DesignButton(title: "Pause", symbol: "pause", kind: .secondary) { model.audioImports.pause() }.disabled(model.audioImports.pausing)
                } else if completed {
                    DesignButton(title: "Open transcript", symbol: "doc.text") { open(job) }
                } else {
                    if job.status != .queued || model.audioImports.activeID == nil {
                        DesignButton(title: LocalizedStringKey(startTitle(job))) { start(job) }
                            .disabled(!canStart)
                            .accessibilityIdentifier("transcribe-audio")
                    }
                    if !job.text.isEmpty { DesignButton(title: "Open transcript", kind: .secondary) { open(job) } }
                    if let error = job.error { DisclosureGroup("Details") { Text(error).font(.footnote).textSelection(.enabled) } }
                    DesignButton(title: "Remove import", kind: .destructive) { removing = job }
                }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(job.status == .queued ? .clear : p.card, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(p.border))
            .rowActions(actions(for: job))
    }
    private var canStart: Bool { !model.audioImports.receiving && (model.audioImports.activeID != nil || model.canReleaseMemory) }
    private func startTitle(_ job: AudioImportJob) -> String {
        if job.status == .completed && job.text.isEmpty { return "Choose another language and retry" }
        if model.audioImports.activeID != nil { return "Add to queue" }
        return job.segments.isEmpty ? "Transcribe" : "Continue transcription"
    }
    private func start(_ job: AudioImportJob) {
        guard canStart else { return }
        if job.status == .completed && job.text.isEmpty && !FileManager.default.fileExists(atPath: job.audioURL.path) { choosingFile = true }
        else { Task { await model.startAudioImport(job.id) } }
    }
    private func actions(for job: AudioImportJob) -> [RowAction] {
        if model.audioImports.activeID == job.id {
            return [RowAction(id: "import-pause", title: "Pause", symbol: "pause", enabled: !model.audioImports.pausing) { model.audioImports.pause() }]
        }
        var actions: [RowAction] = []
        if !job.text.isEmpty {
            actions.append(RowAction(id: "import-open", title: "Open transcript", symbol: "doc.text", edge: .leading) { open(job) })
        }
        if job.status != .completed || job.text.isEmpty {
            if job.status != .queued || model.audioImports.activeID == nil {
                actions.append(RowAction(id: "import-start", title: startTitle(job), symbol: "play", edge: .leading, enabled: canStart) { start(job) })
            }
            actions.append(RowAction(id: "import-remove", title: "Remove import", symbol: "trash", destructive: true) { removing = job })
        }
        return actions
    }
    private func status(_ job: AudioImportJob) -> LocalizedStringKey {
        if model.audioImports.activeID == job.id { return model.audioImports.pausing ? "Pausing…" : model.audioImports.preparing ? "Preparing transcription…" : "Transcribing audio…" }
        switch job.status { case .pending: return "File received"; case .queued: return "Waiting"; case .processing: return "Transcribing audio…"; case .paused: return "Paused. Continue when you are ready."; case .completed: return job.text.isEmpty ? "No speech detected in this file." : "Transcription saved"; case .failed: return "Could not transcribe this recording" }
    }
    private func open(_ job: AudioImportJob) {
        Task { await model.refresh(); if let note = await model.loadNote(job.id) { dismiss(); model.selectedNote = note } }
    }
}
