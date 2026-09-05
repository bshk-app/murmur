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
    /// Quality models are ~250 MB each against the fast tier's ~22 MB, and only
    /// one route is ever pasted at a time, so they get their own slot with a
    /// limit of one rather than sharing `residentLimit`. A pivot therefore
    /// reloads its second leg; that costs a model load on a path that already
    /// costs 378 ms per leg, and is the right trade against holding 500 MB.
    private var residentQuality: [(pair: LanguagePair, translator: QualityTranslator)] = []

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
        try perform(text, from: source, to: target, tier: .fast).text
    }

    /// What a tiered translation produced, and whether it got the engine it
    /// asked for.
    ///
    /// `usedQuality` is false when *any* leg fell back, not when the route as a
    /// whole did: a pivot with one quality leg and one fast leg is not a
    /// quality translation and should not be presented as one.
    public struct Outcome: Sendable {
        public let text: String
        public let usedQuality: Bool
    }

    /// Translates with the quality engine where it is installed, falling back
    /// per leg to the fast one where it is not.
    ///
    /// Falling back is the expected case, not a failure: quality models are
    /// downloaded on demand and most directions will never have one. Nothing is
    /// appended to `failures` for it.
    public func translateBest(_ text: String, from source: String, to target: String) throws -> Outcome {
        try perform(text, from: source, to: target, tier: .best)
    }

    private func perform(_ text: String, from source: String, to target: String,
                         tier: TranslationTier) throws -> Outcome {
        if source == target { return Outcome(text: text, usedQuality: false) }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Outcome(text: "", usedQuality: false)
        }
        guard let route = LanguagePair.route(from: source, to: target) else {
            throw Unsupported(source: source, target: target)
        }
        var carried = text
        var everyLegWasQuality = tier == .best
        for leg in legs(of: route) {
            let engine: any TextTranslating
            if tier == .best, let quality = qualityTranslator(for: leg) {
                engine = quality
            } else {
                everyLegWasQuality = false
                engine = try translator(for: leg)
            }
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
            if carried.isEmpty {
                return Outcome(text: "", usedQuality: false)
            }
        }
        return Outcome(text: carried, usedQuality: everyLegWasQuality)
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

    /// Same swallow-on-failure contract as `translateOrEmpty`, for the paste
    /// path that wants the quality engine.
    ///
    /// Per-leg fallback to the fast engine already lives inside `translateBest`
    /// itself and is not a failure - most directions have no quality model, and
    /// that is the ordinary case, not something to catch here. This only
    /// catches what `translateBest` actually throws: no route, or a leg whose
    /// *fast* engine also failed to load. `usedQuality` is false on every path
    /// through this catch, matching "any leg fell back" - a route that never
    /// finished is not a quality translation by any reading.
    public func translateBestOrEmpty(_ text: String, from source: String,
                                     to target: String) -> Outcome {
        do {
            return try translateBest(text, from: source, to: target)
        } catch {
            failures.append("\(error)")
            return Outcome(text: "", usedQuality: false)
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
        residentQuality.removeAll()
    }

    public var residentPairs: [LanguagePair] { resident.map(\.pair) }

    /// Whether a quality model is installed for this direction, without
    /// loading it. For a settings screen that offers the download.
    public nonisolated func hasQualityModel(for pair: LanguagePair) -> Bool {
        let directory = modelsRoot
            .appendingPathComponent(pair.qualityModelDirectoryName)
        return FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("model.bin").path)
    }

    /// Returns the quality engine for `pair`, or nil when none is installed.
    ///
    /// Nil rather than throwing because absence is the normal state and the
    /// caller's response is to use the fast engine, not to report anything. A
    /// model that is present but *broken* is different, and does surface: it
    /// lands in `failures` before the fallback.
    private func qualityTranslator(for pair: LanguagePair) -> QualityTranslator? {
        if let index = residentQuality.firstIndex(where: { $0.pair == pair }) {
            let hit = residentQuality.remove(at: index)
            residentQuality.append(hit)
            return hit.translator
        }
        guard hasQualityModel(for: pair) else { return nil }
        do {
            let loaded = try QualityTranslator(pair: pair, modelsRoot: modelsRoot)
            residentQuality.append((pair, loaded))
            if residentQuality.count > 1 { residentQuality.removeFirst() }
            return loaded
        } catch {
            failures.append("quality model for \(pair) is present but unusable: \(error)")
            return nil
        }
    }

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
