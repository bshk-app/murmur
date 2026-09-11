import SwiftUI
import MurmurCore

struct StorageView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var deleting: ModelStorageItem?
    private var p: MurmurPalette { .init(scheme: scheme) }
    private var translations: [ModelStorageItem] { model.storageInventory.items.filter { $0.kind == .translationQuality || $0.kind == .translationPreview } }
    private var speech: [ModelStorageItem] { model.storageInventory.items.filter { $0.kind == .speech || $0.kind == .importedSpeech } }
    private var incomplete: [ModelStorageItem] { model.storageInventory.items.filter { $0.kind == .incomplete } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Storage").font(.title2.bold())
                Spacer()
                Button { Task { await model.refreshStorage() } } label: { Image(systemName:"arrow.clockwise").frame(width:44,height:44) }.accessibilityLabel("Refresh").disabled(model.storageLoading || model.managingStorage)
                Button("Done") { dismiss() }.frame(minHeight:44).foregroundStyle(p.accentText).disabled(model.managingStorage)
            }.padding(.horizontal,20).padding(.top,10)
            ActionList(spacing: 18) {
                    VStack(alignment:.leading,spacing:8) {
                        Text("Downloads").font(.subheadline).foregroundStyle(p.secondary)
                        Text(model.storageReadFailed ? "—" : bytes(model.storageInventory.totalBytes)).font(.largeTitle.bold()).monospacedDigit().accessibilityIdentifier("model-storage-total")
                        if let free=model.storageInventory.availableDiskBytes { Text(L10n.text("Available on this iPhone") + ": " + bytes(free)).font(.footnote).foregroundStyle(p.muted) }
                    }.frame(maxWidth:.infinity,alignment:.leading).murmurCard(radius:18,padding:16)
                    if model.storageReadFailed { Text("Storage information unavailable").font(.footnote).foregroundStyle(.red) }
                    if model.storageLoading { ProgressView("Calculating storage…").frame(maxWidth:.infinity) }
                    if !model.canManageStorage && !model.managingStorage {
                        Label("Finish the current task to delete downloads.",systemImage:"info.circle").font(.footnote).foregroundStyle(p.secondary).murmurCard(radius:14,padding:14)
                        if model.keyboard.isActive { DesignButton(title:"Keyboard dictation",kind:.secondary) { model.requestUtilityRoute("keyboard") } }
                    }
                    if model.managingStorage { ProgressView("Deleting download…") }
                    if let message=model.storageMessage { Text(message).font(.footnote).foregroundStyle(p.accentText).accessibilityIdentifier("storage-message") }
                    if !model.storageLoading && !model.storageReadFailed && model.storageInventory.items.isEmpty {
                        Text("No downloads").font(.headline).padding(.vertical,12).accessibilityIdentifier("storage-empty")
                    }
                    if !translations.isEmpty { section("Translation", items:translations) }
                    if !speech.isEmpty { section("Speech recognition", items:speech) }
                    if !incomplete.isEmpty { section("Unfinished downloads", items:incomplete) }
                    DesignButton(title:"Languages & offline",symbol:"globe",kind:.secondary) { model.requestUtilityRoute("languages") }.disabled(model.managingStorage)
            }.frame(maxWidth:640).frame(maxWidth:.infinity)
        }.foregroundStyle(p.ink).tint(p.accentText).presentationBackground(p.sheet).presentationDetents([.large]).presentationCornerRadius(26).presentationDragIndicator(.visible).interactiveDismissDisabled(model.managingStorage)
            .task { await model.refreshStorage() }
            .alert("Delete download?",isPresented:Binding(get:{deleting != nil},set:{if !$0 {deleting=nil}})) {
                if let item=deleting { Button("Delete download",role:.destructive) { deleting=nil; Task { await model.deleteStoredModel(item) } }.accessibilityIdentifier("confirm-storage-delete") }
                Button("Cancel",role:.cancel) { deleting=nil }
            } message: {
                if let item=deleting {
                    Text(title(item) + " · " + bytes(item.bytes) + "\n\n" + L10n.text(item.downloadable ? "Notes and recordings stay. Download this language again to use it offline." : "Notes and recordings stay. Keep the original files to restore this download."))
                }
            }
            .alert("Murmator",isPresented:Binding(get:{model.storageError != nil},set:{if !$0 {model.storageError=nil}})) {
                Button("OK",role:.cancel) { model.storageError=nil }
            } message: { Text(model.storageError ?? "") }
    }
    private func section(_ title: LocalizedStringKey, items: [ModelStorageItem]) -> some View {
        Section {
            ForEach(items) { item in
                VStack(alignment:.leading,spacing:10) {
                    HStack(alignment:.top,spacing:12) {
                        Image(systemName:item.kind == .speech || item.kind == .importedSpeech ? "waveform" : "globe").foregroundStyle(p.accentText).frame(width:24)
                        VStack(alignment:.leading,spacing:5) {
                            Text(self.title(item)).font(.headline).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("storage-item-"+item.id)
                        }
                        Spacer(minLength:0)
                    }
                    Text(bytes(item.bytes)).font(.subheadline.weight(.semibold)).monospacedDigit()
                    let languages = SpeechModelChoice.languages(forStorageID: item.id, selected: model.languageLibrary.speech)
                    if !languages.isEmpty {
                        Text(L10n.text("Selected languages") + ": " + languages.map(AppLanguages.name).joined(separator: ", "))
                            .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("storage-languages-" + item.id)
                    }
                    DesignButton(title:"Delete download",symbol:"trash",kind:.destructive) { deleting=item }.disabled(!model.canManageStorage || model.storageLoading).accessibilityIdentifier("delete-storage-"+item.id)
                }.frame(maxWidth:.infinity,alignment:.leading).murmurCard(radius:16,padding:15)
                    .rowActions([
                        RowAction(id: "storage-delete", title: "Delete download", symbol: "trash", destructive: true,
                                  enabled: model.canManageStorage && !model.storageLoading) { deleting = item },
                        RowAction(id: "storage-languages", title: "Languages & offline", symbol: "globe", edge: .leading,
                                  enabled: !model.managingStorage) { model.requestUtilityRoute("languages") }
                    ])
            }
        } header: { Text(title).font(.headline).foregroundStyle(p.ink).textCase(nil) }
    }
    private func title(_ item: ModelStorageItem) -> String {
        if let from=item.source,let to=item.target { return AppLanguages.name(from) + " → " + AppLanguages.name(to) }
        return L10n.text(item.title)
    }
    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount:max(0,value),countStyle:.file) }
}
