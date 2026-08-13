import Foundation

/// The two-tier transcript trimmed to what the HUD panel can physically show.
public struct HUDTranscript: Equatable, Sendable {
    public let confirmed: String
    public let partial: String
    /// Text was dropped from the head — the view renders a leading ellipsis.
    public let truncated: Bool

    public static func clamped(confirmed: String, partial: String, maxChars: Int) -> HUDTranscript {
        // The fast lane's tail is the newest text and the reason to look at the HUD,
        // so it gets the budget first; the accurate prefix fills what is left.
        guard partial.count <= maxChars else {
            return HUDTranscript(confirmed: "", partial: wordTail(partial, budget: maxChars), truncated: true)
        }
        let separator = partial.isEmpty ? 0 : 1
        let forConfirmed = maxChars - partial.count - separator
        guard confirmed.count > forConfirmed else {
            return HUDTranscript(confirmed: confirmed, partial: partial, truncated: false)
        }
        return HUDTranscript(confirmed: wordTail(confirmed, budget: forConfirmed),
                             partial: partial, truncated: true)
    }

    /// Longest whole-word suffix of `s` that fits `budget`. Cutting mid-word reads
    /// as a typo, so we drop the straddling word instead.
    private static func wordTail(_ s: String, budget: Int) -> String {
        let words = s.split(whereSeparator: { $0 == " " || $0 == "\n" })
        var kept: [Substring] = []
        var length = 0
        for word in words.reversed() {
            let cost = kept.isEmpty ? word.count : word.count + 1
            if length + cost > budget { break }
            length += cost
            kept.append(word)
        }
        // Nothing fit: one word is wider than the whole budget. Show it anyway — an
        // empty HUD is worse than one overflowing word, and `.lineLimit` bounds layout.
        if kept.isEmpty, let last = words.last { return String(last) }
        return kept.reversed().joined(separator: " ")
    }
}
