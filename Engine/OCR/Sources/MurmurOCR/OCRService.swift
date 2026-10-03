import Foundation
import CoreGraphics

import CryptoKit
import COCR

public struct OCRLine: Sendable {
    public let text: String
    public let confidence: Double
    /// Coordinates normalized to the upright source image; origin at top left.
    public let bounds: CGRect
}

public enum OCRLanguageCatalog {
    public static let languages: Set<String> = ["ar","be","bg","bs","ca","cs","da","de","el","en","es","et","fi","fr","ga","hr","hu","is","it","lt","lv","mk","mt","nb","nl","pl","pt","ro","ru","sk","sl","sr","sv","uk"]
    public static func model(for language: String) -> String? {
        guard languages.contains(language) else { return nil }
        if language == "ar" { return "arabic_PP-OCRv5_rec_mobile.onnx" }
        if language == "el" { return "el_PP-OCRv5_rec_mobile.onnx" }
        if ["be","bg","mk","ru","sr","uk"].contains(language) { return "cyrillic_PP-OCRv5_rec_mobile.onnx" }
        return "PP-OCRv6_rec_tiny.onnx"
    }
}

/// Serial, worker-only access to downloads and native model instances.
/// Native sessions are scoped to one request and released before translation starts.
public actor OCRService {
    public enum Failure: LocalizedError {
        case unsupported, missingResource, invalidDownload, invalidResult, busy
        public var errorDescription: String? {
            switch self {
            case .busy: return "Photo recognition is already in progress."
            case .unsupported: return "This source language is not available for photo recognition."
            case .missingResource: return "The photo recognition resources are missing."
            case .invalidDownload: return "The recognition download could not be verified. Please try again."
            case .invalidResult: return "The image could not be recognized. Try a clearer or closer photo."
            }
        }
    }
    private struct Asset: Decodable { let url: URL; let sha256: String }
    private var active = false
    private let root: URL
    public init(modelsRoot: URL) { root = modelsRoot }

    public func recognize(imageURL: URL, portrait: Bool, language: String,
                          preparing: @escaping @Sendable (Bool) async -> Void) async throws -> [OCRLine] {
        guard !active else { throw Failure.busy }
        active = true; defer { active = false }
        guard let name = OCRLanguageCatalog.model(for: language) else { throw Failure.unsupported }
        guard let catalogURL = Bundle.module.url(forResource: "model-provenance", withExtension: "json"),
              let dictURL = Bundle.module.url(forResource: "dictionaries", withExtension: "json"),
              let detector = Bundle.module.url(forResource: portrait ? "detector-portrait" : "detector-landscape", withExtension: "onnx") else { throw Failure.missingResource }
        let catalog = try JSONDecoder().decode([String: Asset].self, from: Data(contentsOf: catalogURL))
        let dicts = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: dictURL))
        guard let asset = catalog[name], let dictionary = dicts[name] else { throw Failure.missingResource }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var noBackup = root; var values = URLResourceValues(); values.isExcludedFromBackup = true; try noBackup.setResourceValues(values)
        let model = root.appendingPathComponent(name)
        if !((try? Self.digest(model)) == asset.sha256) {
            await preparing(true)
            let (temporary, response) = try await URLSession.shared.download(from: asset.url)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try Task.checkCancellation()
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  try Self.digest(temporary) == asset.sha256 else { throw Failure.invalidDownload }
            if FileManager.default.fileExists(atPath: model.path) { try FileManager.default.removeItem(at: model) }
            try FileManager.default.moveItem(at: temporary, to: model)
        }
        try Task.checkCancellation(); await preparing(false)
        try Task.checkCancellation()
        var detectorPath = detector.path
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--photo-translation-probe"),
           let variant = ProcessInfo.processInfo.environment["OCR_PROBE_DETECTOR"],
           ["v6-small", "v5-mobile"].contains(variant) {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            detectorPath = documents.appendingPathComponent("probe-detectors/\(variant)-\(portrait ? "portrait" : "landscape").onnx").path
        }
        #endif
        let result = try MROCRBridge.recognizeImage(atPath: imageURL.path, detectorPath: detectorPath,
                                                  recognizerPath: model.path, dictionary: dictionary,
                                                  cachePath: root.path)
        try Task.checkCancellation()
        guard let texts = result["texts"] as? [String], let scores = result["scores"] as? [Double],
              let boxes = result["boxes"] as? [[[Double]]], let width = result["image_width"] as? Double,
              let height = result["image_height"] as? Double, width > 0, height > 0,
              texts.count == scores.count, texts.count == boxes.count else { throw Failure.invalidResult }
        var lines: [OCRLine] = []
        for i in 0..<texts.count {
            let points = boxes[i]
            guard points.count == 4, points.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }), scores[i].isFinite else { throw Failure.invalidResult }
            let xs = points.map { $0[0] / width }, ys = points.map { $0[1] / height }
            let bounds = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { throw Failure.invalidResult }
            lines.append(OCRLine(text: texts[i], confidence: scores[i], bounds: bounds))
        }
        return lines
    }
    private static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 65536), !chunk.isEmpty { try Task.checkCancellation(); hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public extension OCRService {
    func removeDownloadedModels() throws {
        guard !active else { throw Failure.busy }
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
}
