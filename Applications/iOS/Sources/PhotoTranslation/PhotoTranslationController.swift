import SwiftUI
import ImageIO
import MurmurCore
import MurmurOCR
import MurmurTranslation
#if DEBUG
import Darwin
#endif

@MainActor @Observable final class PhotoTranslationController {
    enum Phase { case idle, loading, downloadingOCR, recognizing, preparingTranslation, translating, cancelling }
    private(set) var phase: Phase = .idle
    private(set) var image: UIImage?
    private(set) var blocks: [PhotoTextBlock] = []
    private(set) var failedBlockIDs: Set<UUID> = []
    private(set) var source: String
    private(set) var target: String
    var error: String?
    private(set) var completed = 0
    private(set) var progress: Double?
    private var photoURL: URL?
    private var recognizedLanguage: String?
    @ObservationIgnored private var work: Task<Void, Never>?
    private static let sharedOCR = OCRService(modelsRoot: StoragePaths.support.appendingPathComponent("OCR"))
    @ObservationIgnored private let ocr: OCRService
    @ObservationIgnored private let translator: TextTranslationSession
    private let translationRoot: URL
    init(source: String = TranslationPreferences.source, target: String = TranslationPreferences.target) {
        self.source = OCRLanguageCatalog.languages.contains(source) ? source : "en"
        self.target = target; translationRoot = StoragePaths.translation
        ocr = Self.sharedOCR
        translator = TextTranslationSession(modelsRoot: StoragePaths.translation)
        if self.target == self.source || !targets.contains(self.target) { self.target = targets.first ?? "en" }
    }
    var isBusy: Bool { phase != .idle }
    var targets: [String] { TextTranslationSession.availableTargets(from: source, modelsRoot: translationRoot) }
    var translatedText: String { blocks.compactMap(\.translation).joined(separator: "\n\n") }
    var canTranslate: Bool { !isBusy && image != nil && source != target && targets.contains(target) && (recognizedLanguage != source || blocks.contains(where: { $0.translation == nil })) }
    var status: String {
        switch phase {
        case .idle: return ""
        case .loading: return L10n.text("Opening photo…")
        case .downloadingOCR: return L10n.text("Downloading recognition model…")
        case .recognizing: return L10n.text("Reading text…")
        case .preparingTranslation: return L10n.text("Preparing translation…")
        case .translating: return "\(L10n.text("Translating blocks…")) \(completed)/\(blocks.count)"
        case .cancelling: return L10n.text("Cancelling…")
        }
    }
    func setSource(_ value: String) {
        guard !isBusy, OCRLanguageCatalog.languages.contains(value), value != source else { return }
        let oldSource = source
        source = value; recognizedLanguage = nil; blocks = []; failedBlockIDs = []; error = nil
        if target == source || !targets.contains(target) {
            target = targets.contains(oldSource) ? oldSource : (targets.contains("en") ? "en" : targets.first ?? target)
        }
    }
    func setTarget(_ value: String) {
        guard !isBusy, targets.contains(value), value != target else { return }
        target = value; clearTranslations()
    }
    func editBlock(id: UUID, text: String) {
        guard !isBusy, let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        blocks[index].source = text; blocks[index].translation = nil; error = nil
        failedBlockIDs.remove(id)
    }
    private func clearTranslations() {
        for index in blocks.indices { blocks[index].translation = nil }; failedBlockIDs = []; completed = 0; error = nil
    }
    func start(data: Data? = nil, rotate: Bool = false, captureProbe: Bool = false, onlyBlockID: UUID? = nil) {
        guard !isBusy else { return }
        error = nil; progress = nil; completed = 0; phase = data != nil || rotate ? .loading : .recognizing
        let began = Date()
        work = Task {
            var recognizedThisRun = false
            var translatedThisRun = 0
            do {
                if data != nil || rotate {
                    let oldURL = photoURL
                    let loading = Task.detached(priority: .userInitiated) { try PhotoPreparation.prepare(data: data, file: oldURL, rotate: rotate) }
                    let prepared = try await withTaskCancellationHandler(operation: { try await loading.value }, onCancel: { loading.cancel() })
                    if Task.isCancelled { try? FileManager.default.removeItem(at: prepared.url); throw CancellationError() }
                    if let photoURL { try? FileManager.default.removeItem(at: photoURL) }
                    photoURL = prepared.url; image = prepared.image; blocks = []; failedBlockIDs = []; recognizedLanguage = nil
                }
                #if DEBUG
                // A cancellable boundary for UI regression tests, never a substituted OCR/MT result.
                if rotate && ProcessInfo.processInfo.environment["PHOTO_CANCEL_TEST_DELAY"] == "1" {
                    try await Task.sleep(for: .seconds(8))
                }
                #endif
                guard let photoURL, let image else { throw PhotoPreparation.Failure.invalid }
                if recognizedLanguage != source {
                    phase = .recognizing
                    let lines = try await ocr.recognize(imageURL: photoURL, portrait: image.size.height > image.size.width, language: source) { [weak self] downloading in
                        await self?.updateRecognitionPhase(downloading)
                    }
                    try Task.checkCancellation()
                    recognizedThisRun = true
                    blocks = PhotoTextGrouping.blocks(from: lines.map { PhotoTextLine(text: $0.text, confidence: $0.confidence, bounds: $0.bounds) }, rightToLeft: source == "ar")
                    failedBlockIDs = []
                    recognizedLanguage = source
                }
                guard !blocks.isEmpty else { throw PhotoPreparation.Failure.noText }
                guard blocks.reduce(0, { $0 + $1.source.count }) <= 10_000 else { throw PhotoPreparation.Failure.tooMuchText }
                guard source != target, targets.contains(target) else { throw PhotoPreparation.Failure.direction }
                if blocks.contains(where: { $0.translation == nil && $0.requiresTranslation && (onlyBlockID == nil || $0.id == onlyBlockID) }) {
                    phase = .preparingTranslation
                    try await translator.prepare(from: source, to: target) { [weak self] value in
                        guard let self, self.phase == .preparingTranslation else { return }; self.progress = value
                    }
                }
                try Task.checkCancellation(); phase = .translating; progress = nil
                for index in blocks.indices {
                    try Task.checkCancellation()
                    if onlyBlockID == nil || blocks[index].id == onlyBlockID {
                        do {
                            let text = blocks[index].source.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard text.count <= 1_500 else { throw PhotoPreparation.Failure.longBlock }
                            if blocks[index].translation == nil {
                                guard !text.isEmpty else { throw PhotoPreparation.Failure.translation }
                                let translated: String
                                if blocks[index].requiresTranslation { translated = try await translator.translate(text, from: source, to: target) }
                                else { translated = text }
                                try Task.checkCancellation()
                                guard !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PhotoPreparation.Failure.translation }
                                blocks[index].translation = translated
                                failedBlockIDs.remove(blocks[index].id)
                                translatedThisRun += 1
                            }
                        } catch {
                            // Cancellation ends the job; a content-specific failure only ends this block.
                            if Task.isCancelled || error is CancellationError { throw CancellationError() }
                            failedBlockIDs.insert(blocks[index].id)
                        }
                    }
                    completed = index + 1
                }
                if !failedBlockIDs.isEmpty { error = L10n.text("Some blocks could not be translated. You can edit them or try again.") }
            } catch {
                if !Task.isCancelled { self.error = L10n.text(error.localizedDescription) }
            }
            // Keep OCR and MT residency separate; don't retain translation weights behind this screen.
            await translator.unload()
            #if DEBUG
            if captureProbe && ProcessInfo.processInfo.arguments.contains("--photo-translation-probe") {
                var result: [String: Any] = ["source": source, "target": target, "didOCR": recognizedThisRun, "translatedBlocks": translatedThisRun, "failedBlocks": failedBlockIDs.count, "seconds": Date().timeIntervalSince(began), "error": error ?? "", "blocks": blocks.map { ["source": $0.source, "translation": $0.translation ?? "", "failed": failedBlockIDs.contains($0.id), "bounds": [$0.bounds.minX, $0.bounds.minY, $0.bounds.width, $0.bounds.height]] }]
                var info = task_vm_info_data_t()
                var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
                let code = withUnsafeMutablePointer(to: &info) { pointer in
                    pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                    }
                }
                if code == KERN_SUCCESS, info.ledger_phys_footprint_peak > 0 {
                    result["physical_footprint_peak_bytes"] = info.ledger_phys_footprint_peak
                    result["physical_footprint_after_unload_bytes"] = info.phys_footprint
                }
                if let bytes = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted),
                   let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                    try? bytes.write(to: dir.appendingPathComponent("photo-probe-result.json"), options: .atomic)
                }
            }
            #endif
            progress = nil; phase = .idle; work = nil
        }
    }
    private func updateRecognitionPhase(_ downloading: Bool) {
        guard phase != .cancelling else { return }
        phase = downloading ? .downloadingOCR : .recognizing
    }
    func removeRecognitionDownloads() async {
        guard !isBusy else { return }
        do { try await ocr.removeDownloadedModels() } catch { self.error = error.localizedDescription }
    }
    func cancel() { guard isBusy else { return }; phase = .cancelling; work?.cancel() }
    func close() async {
        let pending = work; cancel(); await pending?.value; await translator.unload()
        if let photoURL { try? FileManager.default.removeItem(at: photoURL) }
        photoURL = nil; image = nil; blocks = []; failedBlockIDs = []; recognizedLanguage = nil
    }
}

private enum PhotoPreparation {
    struct Prepared: @unchecked Sendable { let image: UIImage; let url: URL }
    enum Failure: LocalizedError {
        case invalid, tooLarge, noText, tooMuchText, longBlock, direction, translation
        var errorDescription: String? {
            switch self {
            case .invalid: return L10n.text("This photo could not be opened.")
            case .tooLarge: return L10n.text("This photo is too large. Choose a smaller image.")
            case .noText: return L10n.text("No text found. Try rotating the photo or taking a closer picture.")
            case .tooMuchText: return L10n.text("There is too much text in this photo. Choose a smaller area in Photos and try again.")
            case .longBlock: return L10n.text("A text block is too long. Edit it before translating.")
            case .direction: return L10n.text("Choose an available translation language.")
            case .translation: return L10n.text("Translation returned no text. Please try again.")
            }
        }
    }
    static func prepare(data: Data?, file: URL?, rotate: Bool) throws -> Prepared {
        try Task.checkCancellation()
        let bytes: Data
        if let data { bytes = data } else if let file { bytes = try Data(contentsOf: file) } else { throw Failure.invalid }
        guard bytes.count <= 60 * 1024 * 1024 else { throw Failure.tooLarge }
        var maxPixels = 2048
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--photo-translation-probe"),
           let requested = Int(ProcessInfo.processInfo.environment["PHOTO_PROBE_MAX_PIXELS"] ?? ""),
           [2048, 4096].contains(requested) { maxPixels = requested }
        #endif
        guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw Failure.invalid }
        let original = UIImage(cgImage: thumb)
        let size = rotate ? CGSize(width: original.size.height, height: original.size.width) : original.size
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let upright = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            if rotate { ctx.cgContext.translateBy(x: size.width / 2, y: size.height / 2); ctx.cgContext.rotate(by: .pi / 2); original.draw(in: CGRect(x: -original.size.width / 2, y: -original.size.height / 2, width: original.size.width, height: original.size.height)) }
            else { original.draw(at: .zero) }
        }
        try Task.checkCancellation()
        guard let encoded = upright.jpegData(compressionQuality: 0.94) else { throw Failure.invalid }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-photo-\(UUID().uuidString).jpg")
        try encoded.write(to: url, options: .atomic)
        return Prepared(image: upright, url: url)
    }
}
