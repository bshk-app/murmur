import Foundation

/// Owns the loaded translation models and runs one segment at a time.
///
/// An actor rather than a lock because `Translator` wraps a non-reentrant C++
/// service: two concurrent calls into one handle corrupt its state, and the
/// dictation path has no reason to translate two utterances at once.
///
/// Models are kept resident because loading one costs ~150 ms — more than
/// translating with it — and the user changes language far less often than
/// they speak. The cache is bounded: each model is ~32 MB of weights plus
/// runtime, and a pivot needs two of them at once.
public actor TranslationService {
    /// Which leg of a route failed, so a caller can say "could not translate
    /// into German" rather than a bare engine message. A pivot has two legs and
    /// either can fail on its own.
    public struct Failure: Error, CustomStringConvertible {
        public let leg: LanguagePair
        public let underlying: Error

        public var description: String { "\(leg): \(underlying)" }
    }

    public struct Unsupported: Error, CustomStringConvertible {
        public let source: String
        public let target: String

        public var description: String {
            "no route from \(source) to \(target)"
        }
    }

    private let modelsRoot: URL
    private let residentLimit: Int
    /// Most-recently-used last. Small enough that an array beats a dictionary
    /// plus a recency list.
    private var resident: [(pair: LanguagePair, translator: Translator)] = []

    /// `residentLimit` must be at least 2 or a pivot would evict its own first
    /// leg while loading the second, reloading on every single utterance.
    public init(modelsRoot: URL, residentLimit: Int = 2) {
        self.modelsRoot = modelsRoot
        self.residentLimit = max(2, residentLimit)
    }

    /// How `source -> target` will be served, without loading anything.
    /// Callers that want to warn about pivot quality can match on this.
    public nonisolated func route(from source: String, to target: String) -> LanguagePair.Route? {
        LanguagePair.route(from: source, to: target)
    }

    /// Loads the models a route needs, so the first utterance does not pay for
    /// it. Safe to call repeatedly.
    public func prepare(from source: String, to target: String) throws {
        guard let route = LanguagePair.route(from: source, to: target) else {
            throw Unsupported(source: source, target: target)
        }
        for leg in legs(of: route) {
            _ = try translator(for: leg)
        }
    }

    /// Translates one committed utterance.
    ///
    /// Identity and empty input short-circuit: asking to translate Russian into
    /// Russian is not an error, and neither is a segment the recogniser found
    /// no words in.
    public func translate(_ text: String, from source: String, to target: String) throws -> String {
        if source == target { return text }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
        guard let route = LanguagePair.route(from: source, to: target) else {
            throw Unsupported(source: source, target: target)
        }
        var carried = text
        for leg in legs(of: route) {
            let engine = try translator(for: leg)
            do {
                carried = try engine.translate(carried)
            } catch {
                // Name the leg that failed and stop: running the second leg on
                // a failed first one would translate the previous language's
                // text and return something confidently wrong.
                throw Failure(leg: leg, underlying: error)
            }
            // A leg that produces nothing ends the route. Feeding "" onward
            // would return "" anyway, having paid for a second model load.
            if carried.isEmpty { return "" }
        }
        return carried
    }

    /// Best-effort translation for the dictation path: returns "" when there is
    /// no route, no model on disk, or a leg fails.
    ///
    /// Swallowing is right *here* and nowhere else. A user has just spoken; the
    /// worst outcome is losing what they said. Returning "" lets the caller
    /// paste the original transcript, which is a degraded result rather than a
    /// lost one. Callers that need to know why — a settings screen validating a
    /// language pair, say — use `translate` and read the error.
    public func translateOrEmpty(_ text: String, from source: String, to target: String) -> String {
        do {
            return try translate(text, from: source, to: target)
        } catch {
            failures.append("\(error)")
            return ""
        }
    }

    /// Why recent translations failed, newest last. Bounded; for diagnostics and
    /// for a settings screen to explain a target that never produces anything.
    public private(set) var failures: [String] = [] {
        didSet { if failures.count > 8 { failures.removeFirst(failures.count - 8) } }
    }

    /// Drops every loaded model. For a language change that will not come back,
    /// or memory pressure.
    public func evictAll() {
        resident.removeAll()
    }

    public var residentPairs: [LanguagePair] { resident.map(\.pair) }

    private func legs(of route: LanguagePair.Route) -> [LanguagePair] {
        switch route {
        case let .direct(pair): return [pair]
        case let .pivot(first, second): return [first, second]
        }
    }

    private func translator(for pair: LanguagePair) throws -> Translator {
        if let index = resident.firstIndex(where: { $0.pair == pair }) {
            let hit = resident.remove(at: index)
            resident.append(hit)
            return hit.translator
        }
        let loaded: Translator
        do {
            loaded = try Translator(pair: pair, modelsRoot: modelsRoot)
        } catch {
            throw Failure(leg: pair, underlying: error)
        }
        resident.append((pair, loaded))
        if resident.count > residentLimit {
            resident.removeFirst()
        }
        return loaded
    }
}
