// Standalone host test runner; not an iOS target source. See run-native-tests.sh.
import Foundation

// The production helper is compiled unchanged; only the app-group path differs.
enum TranslationPaths { static let shared: URL? = nil }

@main enum HandoffTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("murmator-handoff-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SafariTranslationTicketStore(root: directory)
        let url = "https://example.org/article?q=1#first"
        let now = Date()
        var checks = 0
        func rejects(_ action: () throws -> Void) {
            do { try action(); fatalError("Expected rejection") } catch { checks += 1 }
        }
        let token = try store.create(pageURL: url, now: now)
        try store.consume(token: token, pageURL: "https://example.org/article?q=1#second", now: now.addingTimeInterval(1)); checks += 1
        rejects { try store.consume(token: token, pageURL: url, now: now.addingTimeInterval(1)) }
        rejects { try store.consume(token: "../../.lock", pageURL: url, now: now) }
        rejects { _ = try store.create(pageURL: "file:///etc/passwd", now: now) }
        rejects { _ = try store.create(pageURL: "https://user:password@example.org/a", now: now) }
        let mismatch = try store.create(pageURL: url, now: now)
        rejects { try store.consume(token: mismatch, pageURL: "https://other.example/article?q=1", now: now) }
        rejects { try store.consume(token: mismatch, pageURL: "https://example.org/article?q=2", now: now) }
        try store.consume(token: mismatch, pageURL: url, now: now); checks += 1
        let expired = try store.create(pageURL: url, now: now)
        rejects { try store.consume(token: expired, pageURL: url, now: now.addingTimeInterval(60)) }
        let concurrent = try store.create(pageURL: url, now: now)
        let lock = NSLock()
        var successes = 0
        DispatchQueue.concurrentPerform(iterations: 24) { _ in
            do {
                try store.consume(token: concurrent, pageURL: url, now: now)
                lock.lock(); successes += 1; lock.unlock()
            } catch {}
        }
        precondition(successes == 1, "Only one concurrent claimant may succeed"); checks += 1
        for _ in 0..<80 { _ = try store.create(pageURL: url, now: now) }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        precondition(files.count == 64, "Ticket storage must be capped"); checks += 1
        let contents = try String(contentsOf: files[0], encoding: .utf8)
        precondition(!contents.contains("example.org") && !contents.contains("article"), "Tickets store a digest, never raw URL or page text"); checks += 1
        _ = try store.create(pageURL: url, now: now.addingTimeInterval(61))
        let pruned = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        precondition(pruned.count == 1, "Expired tickets must be pruned"); checks += 1
        print("Handoff tests: \(checks) checks passed (including 24 simultaneous consumers)")
    }
}
