import Foundation
import CryptoKit
import Darwin

/// A short-lived capability for the Share Action → Safari handoff. The translation
/// group stores only a URL digest and expiry here, never webpage text or notes.
enum SafariTranslationHandoff {
    static func create(pageURL: String) throws -> String {
        try store().create(pageURL: pageURL)
    }

    static func consume(token: String, pageURL: String) throws {
        try store().consume(token: token, pageURL: pageURL)
    }

    private static func store() throws -> SafariTranslationTicketStore {
        guard let shared = TranslationPaths.shared else { throw SafariTranslationTicketStore.Failure.unavailable }
        return SafariTranslationTicketStore(root: shared.appendingPathComponent("SafariHandoff", isDirectory: true))
    }
}

struct SafariTranslationTicketStore {
    enum Failure: Error { case unavailable, invalidTicket, invalidURL }
    private struct Ticket: Codable {
        let urlDigest: String
        let expires: Date
    }
    let root: URL
    private let lifetime: TimeInterval = 60
    private let capacity = 64

    func create(pageURL: String, now: Date = Date()) throws -> String {
        let digest = try Self.digest(pageURL)
        return try locked {
            var tickets = try prune(now: now)
            // Bound storage even if many valid actions are opened without completion.
            while tickets.count >= capacity {
                try FileManager.default.removeItem(at: tickets.removeFirst().0)
            }
            let token = UUID().uuidString
            let data = try JSONEncoder().encode(Ticket(urlDigest: digest, expires: now.addingTimeInterval(lifetime)))
            try data.write(to: ticketURL(token), options: .atomic)
            return token
        }
    }

    func consume(token: String, pageURL: String, now: Date = Date()) throws {
        guard let uuid = UUID(uuidString: token), token.lowercased() == uuid.uuidString.lowercased() else { throw Failure.invalidTicket }
        let digest = try Self.digest(pageURL)
        try locked {
            _ = try prune(now: now)
            let url = ticketURL(uuid.uuidString)
            guard let data = try? Data(contentsOf: url), data.count <= 1024,
                  let ticket = try? JSONDecoder().decode(Ticket.self, from: data),
                  ticket.expires > now, ticket.expires <= now.addingTimeInterval(lifetime),
                  ticket.urlDigest == digest else { throw Failure.invalidTicket }
            // Validation and deletion share one cross-process lock: concurrent
            // consumes cannot both succeed, even in different extension processes.
            try FileManager.default.removeItem(at: url)
        }
    }

    private func ticketURL(_ token: String) -> URL { root.appendingPathComponent(token + ".json") }

    private static func digest(_ rawURL: String) throws -> String {
        guard rawURL.utf16.count <= 16384,
              var components = URLComponents(string: rawURL),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { throw Failure.invalidURL }
        components.scheme = scheme
        components.host = host.lowercased()
        components.fragment = nil
        guard let value = components.string else { throw Failure.invalidURL }
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let descriptor = open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw Failure.unavailable }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw Failure.unavailable }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func prune(now: Date) throws -> [(URL, Date)] {
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        var valid: [(URL, Date)] = []
        for url in files where url.pathExtension == "json" {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true, (values?.fileSize ?? Int.max) <= 1024,
               let data = try? Data(contentsOf: url), let ticket = try? JSONDecoder().decode(Ticket.self, from: data),
               ticket.expires > now, ticket.expires <= now.addingTimeInterval(lifetime) {
                valid.append((url, ticket.expires))
            } else { try FileManager.default.removeItem(at: url) }
        }
        return valid.sorted { $0.1 < $1.1 }
    }
}
