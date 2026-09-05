import Foundation

/// Keeps a running translation of a caption transcript.
///
/// Captions differ from dictation in what can be translated and when. A
/// dictation is translated once, at stop, because there is exactly one final
/// text. A caption session emits a new snapshot every time the draft moves —
/// several times a second, for the length of a talk — so translating the whole
/// transcript on each one would re-translate the same sentences hundreds of
/// times and saturate the core the engine runs on.
///
/// So only *closed* phrases are translated, and each one only when its text is
/// new. The live draft is deliberately left out: it is rewritten on nearly
/// every snapshot, and a second line flickering through half-formed sentences
/// is harder to read than one that trails slightly behind.
/// The one thing `CaptionTranslator` needs from the engine.
///
/// A protocol so the caching and correction rules below can be tested without
/// 17 MB of models on disk: they are where this type can silently go wrong,
/// and an untestable cache is how stale translations survive a correction.
public protocol PhraseTranslating: Sendable {
    func translateOrEmpty(_ text: String, from source: String, to target: String) async -> String
}

extension TranslationService: PhraseTranslating {}

public actor CaptionTranslator {
    private let service: any PhraseTranslating
    /// Keyed by segment id, holding the source text it was made from — a batch
    /// pass rewrites a phrase in place, and the stale translation of the
    /// superseded text must not survive that correction.
    private var done: [UInt64: (source: String, translated: String)] = [:]
    /// The live tail, cached by its exact text. The draft is rewritten far more
    /// often than it actually changes wording, and re-translating an identical
    /// string would burn the core for nothing.
    private var draftCache: (source: String, translated: String)?

    public init(service: any PhraseTranslating) {
        self.service = service
    }

    /// Translation of every closed phrase, in order.
    ///
    /// Returns "" when nothing has closed yet, which reads on screen as a HUD
    /// with no second line rather than an empty one.
    /// - Parameter draft: the live tail. Passing it on translates speech as it
    ///   is still being said, at the cost of a line that rewrites itself: a
    ///   half-spoken sentence has a different translation from the finished one,
    ///   and machine translation of a fragment is often confidently wrong.
    ///   Passing "" keeps the second line to settled phrases only.
    public func translation(of segments: [CaptionSegment],
                            draft: String = "",
                            from source: String,
                            to target: String) async -> String {
        // Anything the transcript dropped is gone for good; without this the
        // map grows for the whole talk.
        let liveIDs = Set(segments.map(\.id))
        done = done.filter { liveIDs.contains($0.key) }

        var out: [String] = []
        out.reserveCapacity(segments.count)

        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            if let cached = done[segment.id], cached.source == text {
                out.append(cached.translated)
                continue
            }
            // Cancellation matters here: a talk can close many phrases at once
            // after a pause, and the session may end mid-way through them.
            if Task.isCancelled { break }

            let translated = await service.translateOrEmpty(text, from: source, to: target)
            done[segment.id] = (source: text, translated: translated)
            if !translated.isEmpty { out.append(translated) }
        }

        let tail = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty, !Task.isCancelled {
            if let cached = draftCache, cached.source == tail {
                out.append(cached.translated)
            } else {
                let translated = await service.translateOrEmpty(tail, from: source, to: target)
                draftCache = (source: tail, translated: translated)
                if !translated.isEmpty { out.append(translated) }
            }
        }

        return out.joined(separator: " ")
    }

    /// Forget everything — a new talk starts with an empty second line.
    public func reset() {
        done.removeAll()
        draftCache = nil
    }
}
