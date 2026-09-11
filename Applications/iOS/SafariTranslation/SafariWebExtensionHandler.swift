import Foundation
import SafariServices
import NaturalLanguage
import MurmurCore
import MurmurTranslation

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        // The request context is retained until its own response is delivered.
        // Translation never continues after completing that context.
        Task { @MainActor in
            let finish: ([String: Any]) -> Void = { response in
                let item = NSExtensionItem()
                if JSONSerialization.isValidJSONObject(response) {
                    item.userInfo = [SFExtensionMessageKey: response]
                } else {
                    item.userInfo = [SFExtensionMessageKey: ["ok": false, "code": "translationFailed"]]
                }
                context.completeRequest(returningItems: [item], completionHandler: nil)
            }
            do {
                guard let item = context.inputItems.first as? NSExtensionItem,
                      let message = item.userInfo?[SFExtensionMessageKey],
                      JSONSerialization.isValidJSONObject(message) else { throw SafariNativeRequest.Invalid.value }
                let data = try JSONSerialization.data(withJSONObject: message)
                guard data.count <= 160_000 else { throw SafariNativeRequest.Invalid.value }
                let request = try JSONDecoder().decode(SafariNativeRequest.self, from: data)
                SafariTranslationCoordinator.shared.receive(request, finish: finish)
            } catch { finish(["ok": false, "code": "invalidRequest"]) }
        }
    }
}

struct SafariNativeRequest: Decodable {
    enum Invalid: Error { case value }
    enum Kind: String, Decodable { case config, translate, progress, cancel }
    let type: Kind
    var sample: String?
    var documentLanguage: String?
    var url: String?
    var ticket: String?
    var runId: String?
    var requestId: String?
    var source: String?
    var target: String?
    var groups: [PageTextGroup]?
    var totalCharacters: Int?

    func identifiers() throws -> (String, String) {
        guard let runId, let requestId, !runId.isEmpty, !requestId.isEmpty,
              runId.utf16.count <= 128, requestId.utf16.count <= 128 else { throw Invalid.value }
        return (runId, requestId)
    }

    func page() throws -> PageTranslationRequest {
        let (runId, _) = try identifiers()
        guard let groups, let totalCharacters, groups.count <= 8,
              groups.reduce(0, { $0 + $1.runs.count }) <= 32,
              (0...4800).contains(totalCharacters) else { throw Invalid.value }
        let page = PageTranslationRequest(runId: runId, groups: groups, totalCharacters: totalCharacters)
        try page.validate()
        return page
    }
}

/// Main-actor state changes are synchronous; model work always suspends elsewhere.
/// `active` stays occupied through cancellation AND engine unload, so actor
/// reentrancy cannot start a second prepare/inference operation in this process.
@MainActor final class SafariTranslationCoordinator {
    static let shared = SafariTranslationCoordinator()
    private struct Work {
        let token: UUID
        let runId: String
        let requestId: String
        var task: Task<Void, Never>?
        var phase = "preparing"
        var fraction = 0.0
        var completed = 0
        var total: Int
    }
    private var active: Work?

    func receive(_ request: SafariNativeRequest, finish: @escaping ([String: Any]) -> Void) {
        do {
            switch request.type {
            case .config: finish(try configuration(request))
            case .translate: try translate(request, finish: finish)
            case .progress:
                let (run, batch) = try request.identifiers()
                guard let work = active, work.runId == run, work.requestId == batch else {
                    finish(["ok": true, "phase": "idle"]); return
                }
                finish(["ok": true, "phase": work.phase, "fraction": work.fraction,
                        "completed": work.completed, "total": work.total])
            case .cancel:
                let (run, batch) = try request.identifiers()
                if active?.runId == run, active?.requestId == batch {
                    active?.phase = "cancelling"
                    active?.task?.cancel()
                }
                finish(["ok": true])
            }
        } catch { finish(["ok": false, "code": "invalidRequest"]) }
    }

    private func configuration(_ request: SafariNativeRequest) throws -> [String: Any] {
        guard let sample = request.sample, sample.utf16.count <= 1500,
              let hint = request.documentLanguage, hint.utf16.count <= 64,
              let url = request.url, url.utf16.count <= 16384,
              let components = URLComponents(string: url),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty else { throw SafariNativeRequest.Invalid.value }
        if let ticket = request.ticket {
            do { try SafariTranslationHandoff.consume(token: ticket, pageURL: url) }
            catch { return ["ok": false, "code": "invalidTicket"] }
        }
        let codes = LanguagePair.qualityLanguages.sorted {
            name($0).localizedStandardCompare(name($1)) == .orderedAscending
        }
        var targets: [String: [String]] = [:]
        for code in codes {
            targets[code] = TextTranslationSession.availableTargets(from: code, modelsRoot: TranslationPaths.models)
                .filter { $0 != code }.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
        }
        let detected = NLLanguageRecognizer.dominantLanguage(for: sample)?.rawValue
        let document = hint.lowercased().replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map(String.init)
        let source = [detected, document, TranslationPreferences.source, "en"].compactMap { $0 }
            .first { LanguagePair.qualityLanguages.contains($0) } ?? "en"
        let options = targets[source] ?? []
        let target = [TranslationPreferences.target, TranslationPreferences.source, "en", "fi"]
            .first { options.contains($0) } ?? options.first ?? ""
        return ["ok": true, "ready": TranslationPaths.isReady, "source": source, "target": target,
                "languages": codes.map { ["code": $0, "name": name($0)] }, "targets": targets]
    }

    private func name(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code)?.localizedCapitalized ?? code.uppercased()
    }

    private func translate(_ request: SafariNativeRequest, finish: @escaping ([String: Any]) -> Void) throws {
        let page = try request.page()
        let (runId, requestId) = try request.identifiers()
        guard let source = request.source, let target = request.target,
              source != target, LanguagePair.qualityLanguages.contains(source),
              LanguagePair.qualityLanguages.contains(target) else { throw SafariNativeRequest.Invalid.value }
        guard active == nil else { finish(["ok": false, "code": "busy"]); return }
        guard TranslationPaths.isReady else { finish(["ok": false, "code": "notReady"]); return }
        guard TextTranslationSession.availableTargets(from: source, modelsRoot: TranslationPaths.models).contains(target) else {
            throw SafariNativeRequest.Invalid.value
        }
        let token = UUID()
        active = Work(token: token, runId: runId, requestId: requestId, total: page.groups.count)
        TranslationPreferences.save(source: source, target: target)
        active?.task = Task { [self] in
            setenv("CT2_MMAP_WEIGHTS", "1", 1)
            let engine = PageTranslationSession(modelsRoot: TranslationPaths.models)
            let response: [String: Any]
            do {
                let output = try await PageTranslationProcessor.translate(page, from: source, to: target, engine: engine) { [weak self] progress in
                    guard let self, self.active?.token == token, self.active?.phase != "cancelling" else { return }
                    switch progress {
                    case .preparing(let fraction):
                        self.active?.fraction = fraction.isFinite ? min(1, max(0, fraction)) : 0
                    case .translating(let completed, let total):
                        self.active?.phase = "translating"
                        self.active?.completed = completed
                        self.active?.total = total
                        self.active?.fraction = Double(completed) / Double(max(1, total))
                    }
                }
                // Processor unloads on both success and failure; the fresh session
                // holds the shared model read lease until that unload completes.
                try Task.checkCancellation()
                guard output.translations.reduce(0, { $0 + $1.text.utf16.count }) <= 24_000 else {
                    throw SafariNativeRequest.Invalid.value
                }
                response = ["ok": true, "runId": runId, "requestId": requestId,
                            "translations": output.translations.map { ["id": $0.id, "text": $0.text] },
                            "fallbackGroups": output.fallbackGroups]
            } catch {
                // Never return engine errors: their descriptions can include text
                // or filesystem paths. The page localizes this bounded error code.
                response = ["ok": false, "code": Task.isCancelled ? "cancelled" : "translationFailed"]
            }
            if active?.token == token { active = nil }
            finish(response)
        }
    }
}
