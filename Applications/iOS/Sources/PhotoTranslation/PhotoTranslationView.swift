import SwiftUI
import PhotosUI
import AVFoundation
import MurmurCore
import MurmurOCR

private enum PhotoStyle {
    static let accent = Color(red: 224/255, green: 122/255, blue: 47/255)
    static let sheet = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 30/255, green: 25/255, blue: 22/255, alpha: 1) : UIColor(red: 1, green: 253/255, blue: 249/255, alpha: 1) })
    static let ink = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.95) : UIColor(red: 42/255, green: 37/255, blue: 32/255, alpha: 1) })
    static let failure = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 240/255, green: 161/255, blue: 148/255, alpha: 1) : UIColor(red: 165/255, green: 42/255, blue: 23/255, alpha: 1) })
}

struct PhotoTranslationView: View {
    @State private var controller: PhotoTranslationController
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showLibrary = false
    @State private var showCamera = false
    @State private var selectedBlock: PhotoTextBlock?
    @State private var showOriginal = false
    @State private var closing = false
    @State private var importing = false
    @State private var importGeneration = UUID()
    @State private var confirmRemoveModels = false
    @State private var expanded = false
    @State private var retryingID: UUID?
    @State private var showSuccess = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isPresented) private var isPresented
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var initialPhotoURL: URL? = nil
    private let embedded: Bool

    init(initialPhotoURL: URL? = nil, source: String = TranslationPreferences.source, target: String = TranslationPreferences.target, controller: PhotoTranslationController? = nil, embedded: Bool = false) {
        self.initialPhotoURL = initialPhotoURL
        self.embedded = embedded
        _controller = State(initialValue: controller ?? PhotoTranslationController(source: source, target: target))
    }
    private var locked: Bool { controller.isBusy || closing || importing }
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    ZStack(alignment: .bottom) {
                        Color(red: 0.12, green: 0.15, blue: 0.14)
                        if let image = controller.image {
                            PhotoTranslationOverlay(image: image, blocks: controller.blocks, original: showOriginal,
                                failed: controller.failedBlockIDs, focused: selectedBlock?.id ?? retryingID) {
                                if !locked { selectedBlock = $0 }
                            }.padding(.top, 62).padding(.bottom, 66)
                        } else {
                            VStack(spacing: 16) {
                                Image("PhotoMascot").resizable().renderingMode(.template).scaledToFit().frame(width: 64, height: 64).accessibilityHidden(true)
                                Text("Point at text and take a photo").font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                                Text("Choose a photo or take a picture. Recognition and translation stay on this device.")
                                    .font(.subheadline).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
                            }.foregroundStyle(.white).padding(36).frame(maxHeight: .infinity)
                        }
                        VStack {
                            chrome
                            Spacer(minLength: 4)
                            if controller.isBusy || importing { progressCard.padding(.horizontal, 20).padding(.bottom, 10) }
                            else if controller.image != nil { photoActions.padding(.horizontal, 18).padding(.bottom, 12) }
                            else { captureActions.padding(.bottom, 28) }
                        }
                        if showSuccess {
                            Label("Block translated", systemImage: "checkmark.circle.fill")
                                .font(.subheadline.weight(.semibold)).padding(14)
                                .background(.black.opacity(0.8), in: .capsule).foregroundStyle(.white)
                                .padding(.bottom, 76).allowsHitTesting(false)
                        }
                    }.clipped()
                    if controller.image != nil {
                        resultsPanel.frame(maxHeight: geometry.size.height * (expanded ? 0.65 : 0.43))
                    } else if let error = controller.error {
                        Text(error).font(.callout).foregroundStyle(PhotoStyle.failure).padding()
                            .frame(maxWidth: .infinity).background(PhotoStyle.sheet).accessibilityIdentifier("photo-error")
                    }
                }.background(PhotoStyle.sheet)
            }
            .toolbar(.hidden, for: .navigationBar)
            .tint(PhotoStyle.accent)
            .alert("Remove recognition downloads?", isPresented: $confirmRemoveModels) {
                Button("Remove", role: .destructive) { Task { await controller.removeRecognitionDownloads() } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Recognition models will download again when needed. Your translations are not removed.") }
            .interactiveDismissDisabled(locked)
            .photosPicker(isPresented: $showLibrary, selection: $selectedPhoto, matching: .images)
            .task(id: selectedPhoto) {
                guard let selectedPhoto else { return }
                let generation = UUID(); importGeneration = generation; importing = true
                defer { if importGeneration == generation { importing = false } }
                do {
                    if let bytes = try await selectedPhoto.loadTransferable(type: Data.self) {
                        try Task.checkCancellation(); showOriginal = false; controller.start(data: bytes); self.selectedPhoto = nil
                    } else { controller.error = L10n.text("This photo could not be opened.") }
                } catch { if !Task.isCancelled { controller.error = error.localizedDescription } }
            }
            .fullScreenCover(isPresented: $showCamera) {
                PhotoCameraCapture { bytes in showCamera = false; if let bytes { showOriginal = false; controller.start(data: bytes) } }
            }
            .sheet(item: $selectedBlock) { block in
                PhotoBlockEditor(block: controller.blocks.first(where: { $0.id == block.id }) ?? block,
                                 failed: controller.failedBlockIDs.contains(block.id), editable: !locked,
                                 save: { controller.editBlock(id: block.id, text: $0) },
                                 retry: { retry(block.id) })
                    .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            }
            .onChange(of: scenePhase) { _, value in if value == .background { controller.cancel() } }
            .onChange(of: controller.isBusy) { _, busy in
                UIApplication.shared.isIdleTimerDisabled = busy
                if !busy, let id = retryingID {
                    showSuccess = controller.blocks.first(where: { $0.id == id })?.translation != nil
                    retryingID = nil
                }
            }
            .task(id: showSuccess) {
                guard showSuccess else { return }
                do { try await Task.sleep(for: .seconds(2.4)); showSuccess = false } catch {}
            }
            .task {
                if let initialPhotoURL, controller.image == nil {
                    do { controller.start(data: try Data(contentsOf: initialPhotoURL), captureProbe: true) } catch { controller.error = error.localizedDescription }
                }
            }
            .onDisappear {
                if !embedded && !showCamera && !showLibrary && selectedBlock == nil { Task { await controller.close() } }
            }
        }
    }
    private var chrome: some View {
        HStack(spacing: 8) {
            if !embedded { Button { Task { await finish() } } label: {
                Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 44, height: 44)
            }.accessibilityLabel("Done").accessibilityIdentifier("photo-close").disabled(closing) }
            HStack(spacing: 5) {
                LanguageMenu(selection: Binding(get: { controller.source }, set: controller.setSource), codes: OCRLanguageCatalog.languages.sorted(), preferred: [controller.source], identifier: "photo-source")
                Image(systemName: "arrow.right").accessibilityHidden(true)
                LanguageMenu(selection: Binding(get: { controller.target }, set: controller.setTarget), codes: controller.targets, preferred: [controller.target], identifier: "photo-target")
            }.font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                .padding(.horizontal, 10).background(.black.opacity(0.45), in: .capsule).disabled(locked)
            Spacer(minLength: 0)
            if controller.image != nil {
                Button { showOriginal.toggle() } label: { Text(L10n.text(showOriginal ? "Translation" : "Original text")).font(.caption.weight(.semibold)).frame(minHeight: 44) }
                    .accessibilityIdentifier("photo-original-toggle").accessibilityValue(showOriginal ? L10n.text("Original text") : L10n.text("Translation"))
            }
        }.foregroundStyle(.white).padding(.horizontal, 10).padding(.top, 4)
    }
    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ProgressView().tint(.white)
                Text(importing ? L10n.text("Opening photo…") : controller.status).font(.subheadline.weight(.semibold)).accessibilityIdentifier("photo-status")
                Spacer()
                if !importing { Button("Cancel") { controller.cancel() }.disabled(controller.phase == .cancelling).accessibilityIdentifier("photo-cancel") }
            }
            if let progress = controller.progress { ProgressView(value: progress).tint(PhotoStyle.accent) }
            Text(retryingID == nil ? "Translations appear as each block is ready." : "Other translations stay in place.")
                .font(.caption).foregroundStyle(.white.opacity(0.75))
        }.padding(16).foregroundStyle(.white).background(.black.opacity(0.7), in: .rect(cornerRadius: 18))
    }
    private var photoActions: some View {
        HStack {
            Button { controller.start(rotate: true) } label: { Image(systemName: "rotate.right").frame(width: 44, height: 44) }
                .accessibilityLabel("Rotate photo").accessibilityIdentifier("photo-rotate")
            Spacer()
            Menu {
                Button("Choose photo") { showLibrary = true }
                Button("Camera") { Task { await openCamera() } }.disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                Button("Remove recognition downloads", role: .destructive) { confirmRemoveModels = true }
            } label: { Label("Choose another photo", systemImage: "photo").font(.subheadline).padding(.horizontal, 14).frame(minHeight: 44) }
        }.foregroundStyle(.white).buttonStyle(PhotoChromeButton()).disabled(locked)
    }
    private var captureActions: some View {
        HStack(spacing: 44) {
            Button { showLibrary = true } label: { Label("Choose photo", systemImage: "photo.on.rectangle").labelStyle(.iconOnly).frame(width: 60, height: 60).background(.black.opacity(0.45), in: .rect(cornerRadius: 16)) }
                .accessibilityIdentifier("photo-import")
            Button { Task { await openCamera() } } label: {
                Circle().fill(.white).frame(width: 70, height: 70).padding(5).overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 3))
            }.accessibilityLabel("Camera").disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
            Menu { Button("Remove recognition downloads", role: .destructive) { confirmRemoveModels = true } } label: {
                Image(systemName: "ellipsis").frame(width: 60, height: 60).background(.black.opacity(0.45), in: .rect(cornerRadius: 16))
            }.accessibilityLabel("Photo options")
        }.foregroundStyle(.white).disabled(locked)
    }
    private var resultsPanel: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { expanded.toggle() }
            } label: { Capsule().fill(PhotoStyle.ink.opacity(0.18)).frame(width: 38, height: 5).frame(maxWidth: .infinity).frame(height: 28).contentShape(Rectangle()) }
                .accessibilityLabel(expanded ? "Collapse full text" : "Expand full text")
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Full text").font(.headline)
                    HStack(spacing: 8) {
                        Label("\(controller.blocks.filter { $0.translation != nil }.count)", systemImage: "checkmark.circle")
                        if !controller.failedBlockIDs.isEmpty { Label("\(controller.failedBlockIDs.count)", systemImage: "exclamationmark.circle").foregroundStyle(PhotoStyle.failure) }
                    }.font(.caption).foregroundStyle(PhotoStyle.ink.opacity(0.6))
                }
                Spacer()
                Button { controller.start() } label: { Image(systemName: "arrow.triangle.2.circlepath").frame(width: 44, height: 44) }
                    .accessibilityLabel("Translate photo").disabled(!controller.canTranslate || closing || importing).accessibilityIdentifier("photo-translate")
                if !controller.translatedText.isEmpty {
                    ShareLink(item: controller.translatedText) { Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44) }.accessibilityLabel("Share translation")
                }
            }.padding(.horizontal, 18).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let error = controller.error { Text(error).font(.footnote).foregroundStyle(PhotoStyle.failure).accessibilityIdentifier("photo-error") }
                    ForEach(Array(controller.blocks.enumerated()), id: \.element.id) { index, block in
                        blockRow(block, index: index)
                    }
                }.padding(.horizontal, 18).padding(.bottom, 20)
            }
        }.foregroundStyle(PhotoStyle.ink).background(PhotoStyle.sheet, in: .rect(topLeadingRadius: 18, topTrailingRadius: 18))
    }
    private func blockRow(_ block: PhotoTextBlock, index: Int) -> some View {
        let failed = controller.failedBlockIDs.contains(block.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button { if !locked { selectedBlock = block } } label: {
                HStack(alignment: .top, spacing: 12) {
                    Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(PhotoStyle.ink.opacity(0.5)).frame(width: 20)
                    VStack(alignment: .leading, spacing: 5) {
                        if failed { Label("Not translated", systemImage: "exclamationmark.circle.fill").font(.caption.weight(.semibold)).foregroundStyle(PhotoStyle.failure) }
                        Text(block.translation ?? block.source).font(.body).multilineTextAlignment(.leading).foregroundStyle(PhotoStyle.ink)
                        if block.translation != nil { Text(block.source).font(.caption).foregroundStyle(PhotoStyle.ink.opacity(0.6)).lineLimit(3).multilineTextAlignment(.leading) }
                        if failed { Label("Review block", systemImage: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(PhotoStyle.accent) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(12).background(failed ? PhotoStyle.failure.opacity(0.1) : .clear, in: .rect(cornerRadius: 12))
            }.buttonStyle(.plain).accessibilityLabel(block.translation ?? block.source).accessibilityIdentifier("photo-block-\(block.id.uuidString)")
                .accessibilityValue(failed ? L10n.text("Not translated") : "")
            if block.translation == nil {
                Button { retry(block.id) } label: { Text(L10n.text(failed ? "Retry translation" : "Translate block")) }
                    .font(.subheadline).frame(minHeight: 44).padding(.leading, 44).disabled(locked).accessibilityIdentifier("photo-retry-\(block.id.uuidString)")
            }
            Divider().overlay(PhotoStyle.ink.opacity(0.1))
        }
    }
    private func retry(_ id: UUID) { retryingID = id; controller.start(onlyBlockID: id) }
    private func finish() async {
        closing = true; selectedPhoto = nil; importGeneration = UUID(); importing = false; await controller.close()
        if isPresented { dismiss() } else { closing = false }
    }
    private func openCamera() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        var granted = status == .authorized
        if status == .notDetermined { granted = await AVCaptureDevice.requestAccess(for: .video) }
        if granted { showCamera = true }
        else { controller.error = L10n.text("Camera access is disabled. Enable it in Settings or choose a photo.") }
    }
}

private struct PhotoChromeButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(.black.opacity(configuration.isPressed ? 0.7 : 0.45), in: .capsule)
    }
}

private struct PhotoTranslationOverlay: View {
    let image: UIImage
    let blocks: [PhotoTextBlock]
    let original: Bool
    let failed: Set<UUID>
    let focused: UUID?
    let select: (PhotoTextBlock) -> Void
    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / image.size.width, proxy.size.height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let offset = CGPoint(x: (proxy.size.width - size.width) / 2, y: (proxy.size.height - size.height) / 2)
            ZStack(alignment: .topLeading) {
                Image(uiImage: image).resizable().frame(width: size.width, height: size.height).offset(x: offset.x, y: offset.y).accessibilityLabel("Selected photo")
                ForEach(blocks) { block in
                    let isFailed = failed.contains(block.id)
                    Button { select(block) } label: {
                        Group {
                            if original { Rectangle().fill(.white.opacity(0.001)) }
                            else if let translated = block.translation {
                                Text(translated).font(.system(size: 15, weight: .medium)).lineLimit(max(1, block.lineCount + 1)).minimumScaleFactor(0.7)
                                    .foregroundStyle(PhotoStyle.ink).padding(3).frame(maxWidth: .infinity, maxHeight: .infinity).background(PhotoStyle.sheet.opacity(0.96))
                            } else if isFailed {
                                HStack(spacing: 3) { Image(systemName: "exclamationmark.circle.fill"); Text(block.source).lineLimit(1) }
                                    .font(.system(size: 12, weight: .medium)).foregroundStyle(PhotoStyle.failure).padding(3)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(PhotoStyle.sheet.opacity(0.94))
                            } else { Rectangle().fill(PhotoStyle.sheet.opacity(0.45)) }
                        }.clipShape(.rect(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(focused == block.id ? PhotoStyle.accent : (isFailed && !original ? PhotoStyle.failure : .clear), style: StrokeStyle(lineWidth: focused == block.id ? 2.5 : 1, dash: isFailed ? [4,3] : [])))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .frame(width: max(20, block.bounds.width * size.width), height: max(20, block.bounds.height * size.height))
                        .offset(x: offset.x + block.bounds.minX * size.width, y: offset.y + block.bounds.minY * size.height)
                        .accessibilityLabel(block.translation ?? block.source).accessibilityValue(isFailed ? L10n.text("Not translated") : "")
                        .accessibilityIdentifier("photo-region-\(block.id.uuidString)")
                }
            }.frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading).clipped()
        }
    }
}

private struct PhotoBlockEditor: View {
    let block: PhotoTextBlock
    let failed: Bool
    let editable: Bool
    let save: (String) -> Void
    let retry: () -> Void
    @State private var draft: String
    @State private var editing: Bool
    @Environment(\.dismiss) private var dismiss
    init(block: PhotoTextBlock, failed: Bool, editable: Bool, save: @escaping (String) -> Void, retry: @escaping () -> Void) {
        self.block = block; self.failed = failed; self.editable = editable; self.save = save; self.retry = retry
        _draft = State(initialValue: block.source); _editing = State(initialValue: !failed)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if failed && !editing {
                        Text("This block could not be translated").font(.title2.weight(.bold))
                        Text("Could not translate this block. Edit the original text or try again.").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Original text").font(.caption.weight(.semibold)).textCase(.uppercase).foregroundStyle(.secondary)
                            Text(block.source).font(.body).textSelection(.enabled)
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(PhotoStyle.failure.opacity(0.08), in: .rect(cornerRadius: 14))
                        Button("Edit text") { editing = true }.buttonStyle(PhotoPrimaryButton()).accessibilityIdentifier("photo-edit-failed")
                        Button("Retry translation") { dismiss(); retry() }.frame(maxWidth: .infinity, minHeight: 50).buttonStyle(.bordered).disabled(!editable)
                        Button("Skip") { dismiss() }.frame(maxWidth: .infinity, minHeight: 44)
                    } else {
                        Text("Original text").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        TextEditor(text: $draft).frame(minHeight: 140).scrollContentBackground(.hidden).padding(10)
                            .background(PhotoStyle.ink.opacity(0.04), in: .rect(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(PhotoStyle.accent, lineWidth: 2))
                            .disabled(!editable).accessibilityIdentifier("photo-original-editor")
                        Text("Changes affect only this block.").font(.footnote).foregroundStyle(.secondary)
                        if let translation = block.translation { Text(translation).textSelection(.enabled) }
                        if draft.count > 1500 { Text("A text block is too long. Edit it before translating.").foregroundStyle(PhotoStyle.failure) }
                        Button("Translate block") { save(draft); dismiss(); retry() }.buttonStyle(PhotoPrimaryButton()).disabled(!valid).accessibilityIdentifier("photo-translate-edited")
                        Button("Save correction") { save(draft); dismiss() }.frame(maxWidth: .infinity, minHeight: 44).disabled(!valid).accessibilityIdentifier("photo-save-correction")
                    }
                }.padding(20)
            }.background(PhotoStyle.sheet).foregroundStyle(PhotoStyle.ink)
                .navigationTitle(editing ? "Edit text" : "Text block").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
                .tint(PhotoStyle.accent)
        }
    }
    private var valid: Bool { editable && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.count <= 1500 }
}
private struct PhotoPrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 50)
            .foregroundStyle(.white).background(PhotoStyle.accent.opacity(configuration.isPressed ? 0.75 : 1), in: .rect(cornerRadius: 14))
    }
}

private struct PhotoCameraCapture: UIViewControllerRepresentable {
    let completed: (Data?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completed: completed) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController(); controller.sourceType = .camera; controller.delegate = context.coordinator; return controller
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let completed: (Data?) -> Void
        init(completed: @escaping (Data?) -> Void) { self.completed = completed }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { completed(nil) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            completed((info[.originalImage] as? UIImage)?.jpegData(compressionQuality: 0.95))
        }
    }
}
