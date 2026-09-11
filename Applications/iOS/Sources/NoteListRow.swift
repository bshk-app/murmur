import SwiftUI
import MurmurCore

struct NoteListRow: View {
    let note: NoteSummary
    @Bindable var model: AppModel
    let open: () -> Void
    let edit: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var shareNote: VoiceNote?
    @State private var deleting = false
    private var p: MurmurPalette { .init(scheme: scheme) }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    NoteBadge(text: note.targetLanguage.map { "\(note.sourceLanguage.uppercased()) → \($0.uppercased())" } ?? L10n.text("NOTE"))
                    Spacer()
                    Text(note.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.caption).foregroundStyle(p.secondary)
                }
                if note.transcriptionComplete == false { Text("Partial transcript").font(.caption).foregroundStyle(MurmurPalette.accent) }
                Text(note.title).font(.system(size: 16, weight: .semibold)).lineLimit(2).multilineTextAlignment(.leading)
                Text(note.preview).font(.system(size: 14)).foregroundStyle(p.secondary).lineLimit(3).multilineTextAlignment(.leading)
            }.frame(maxWidth: .infinity, alignment: .leading).murmurCard(radius: 16, padding: 15)
        }.buttonStyle(.plain).accessibilityIdentifier("note-\(note.id)")
            .rowActions([
                RowAction(id: "note-open", title: "Open", symbol: "doc.text", edge: nil, perform: open),
                RowAction(id: "note-edit", title: "Edit", symbol: "pencil", edge: .leading, enabled: !model.importMayUpdate(note), perform: edit),
                RowAction(id: "note-copy", title: "Copy", symbol: "doc.on.doc", edge: .leading) {
                    Task {
                        guard let fullNote = await model.loadNote(note.id) else { return }
                        UIPasteboard.general.string = NoteContent.translation.text(in: fullNote)
                        UIAccessibility.post(notification: .announcement, argument: L10n.text("Copied"))
                    }
                },
                RowAction(id: "note-delete", title: "Delete", symbol: "trash", destructive: true, enabled: !model.importMayUpdate(note)) { deleting = true },
                RowAction(id: "note-share", title: "Share", symbol: "square.and.arrow.up") { Task { shareNote = await model.loadNote(note.id) } }
            ])
            .sheet(item: $shareNote) { ShareSheet(items: [NoteContent.translation.text(in: $0)]) }
            .alert("Delete this note?", isPresented: $deleting) {
                Button("Delete note", role: .destructive) { Task { if let fullNote = await model.loadNote(note.id) { await model.delete(fullNote) } } }.accessibilityIdentifier("confirm-note-delete")
                Button("Cancel", role: .cancel) {}
            }
    }
}
