// Actual native coordinator and Core processor, deterministic engine dependency.
import Foundation
import MurmurTranslation

enum TranslationPaths {
    static let models = FileManager.default.temporaryDirectory
    static let isReady = true
}
enum TranslationPreferences {
    static var source = "en"
    static var target = "fi"
    static func save(source: String, target: String) { self.source = source; self.target = target }
}
enum SafariTranslationHandoff {
    static func consume(token: String, pageURL: String) throws { throw SafariNativeRequest.Invalid.value }
}

@main enum CoordinatorTests {
    @MainActor static func main() async throws {
        var checks = 0
        let coordinator = SafariTranslationCoordinator()
        func request(_ dictionary: [String: Any]) throws -> SafariNativeRequest {
            try JSONDecoder().decode(SafariNativeRequest.self, from: JSONSerialization.data(withJSONObject: dictionary))
        }
        func sync(_ dictionary: [String: Any]) throws -> [String: Any] {
            var reply: [String: Any]?
            coordinator.receive(try request(dictionary)) { reply = $0 }
            precondition(reply != nil, "Control requests must reply without awaiting the engine")
            return reply!
        }
        func batch(_ run: String, _ id: String, _ text: String = "Hello world") -> [String: Any] {
            ["type": "translate", "runId": run, "requestId": id, "source": "en", "target": "fi",
             "groups": [["id": "g", "runs": [["id": "r", "text": text]]]], "totalCharacters": text.utf16.count]
        }
        func control(_ type: String, _ run: String = "one", _ id: String = "a") -> [String: Any] {
            ["type": type, "runId": run, "requestId": id]
        }
        await SafariEngineProbe.shared.reset(pausePreparation: true, pauseUnload: true)
        var first: [String: Any]?
        coordinator.receive(try request(batch("one", "a"))) { first = $0 }
        while await SafariEngineProbe.shared.preparing == 0 { await Task.yield() }
        let preparing = try sync(control("progress"))
        precondition(preparing["phase"] as? String == "preparing"); checks += 1
        let hidden = try sync(control("progress", "other"))
        precondition(hidden["phase"] as? String == "idle" && hidden["fraction"] == nil); checks += 1
        _ = try sync(control("cancel", "other"))
        precondition(first == nil, "Unrelated cancellation must not cancel the active batch"); checks += 1
        let busy = try sync(batch("two", "b"))
        precondition(busy["code"] as? String == "busy"); checks += 1
        let config = try sync(["type": "config", "sample": "", "documentLanguage": "en-US", "url": "https://example.org"])
        precondition(config["ok"] as? Bool == true && config["source"] as? String == "en"); checks += 1
        _ = try sync(control("cancel"))
        let cancelling = try sync(control("progress"))
        precondition(cancelling["phase"] as? String == "cancelling"); checks += 1
        let cleanupBusy = try sync(batch("two", "b"))
        precondition(cleanupBusy["code"] as? String == "busy", "The slot must remain held while unloading"); checks += 1
        while first == nil { await Task.yield() }
        precondition(first?["code"] as? String == "cancelled"); checks += 1
        let unloads = await SafariEngineProbe.shared.unloaded
        let inference = await SafariEngineProbe.shared.inference
        let peak = await SafariEngineProbe.shared.peak
        precondition(unloads == 1 && inference == 0 && peak == 1); checks += 1
        let idle = try sync(control("progress"))
        precondition(idle["phase"] as? String == "idle"); checks += 1
        await SafariEngineProbe.shared.reset(pausePreparation: false, pauseUnload: false)
        var second: [String: Any]?
        coordinator.receive(try request(batch("two", "b"))) { second = $0 }
        while second == nil { await Task.yield() }
        precondition(second?["ok"] as? Bool == true && second?["requestId"] as? String == "b"); checks += 1
        let successUnloads = await SafariEngineProbe.shared.unloaded
        precondition(successUnloads == 1); checks += 1
        let oversized = try sync(batch("large", "c", String(repeating: "😀", count: 2401)))
        precondition(oversized["code"] as? String == "invalidRequest"); checks += 1
        var mismatched = batch("bad", "d"); mismatched["totalCharacters"] = 1
        let mismatchReply = try sync(mismatched)
        precondition(mismatchReply["code"] as? String == "invalidRequest"); checks += 1
        var duplicate = batch("bad", "e")
        duplicate["groups"] = [["id": "g", "runs": [["id": "r", "text": "a"], ["id": "r", "text": "b"]]]]
        duplicate["totalCharacters"] = 2
        let duplicateReply = try sync(duplicate)
        precondition(duplicateReply["code"] as? String == "invalidRequest"); checks += 1
        print("Native coordinator: \(checks) checks passed (real Core processor, deterministic engine)")
    }
}
