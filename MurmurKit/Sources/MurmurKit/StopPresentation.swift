import Foundation

/// What happened to the transcript when the utterance ended.
public enum TranscriptDelivery: Equatable, Sendable {
    /// Typed into the focused field. The user can already see it there.
    case typed
    /// Captions never type: the overlay was the whole point, and the user just
    /// asked for it to stop.
    case displayedOnly
    /// The text exists nowhere but the overlay, and the reason must be readable.
    case failed(String)
}

/// How long the overlay stays after the utterance ends.
///
/// An explicit stop — releasing the hotkey, pressing Stop, tapping the toggle —
/// already says "done", so lingering only takes the screen away from whatever the
/// user turned back to. The one case that earns a wait is a transcript that could
/// not be delivered: then the overlay is the only copy, and dismissing it loses
/// the words.
public struct StopPresentation: Equatable, Sendable {
    /// Seconds to hold the overlay. Zero means dismiss now.
    public let linger: TimeInterval
    /// Whether the final text is worth showing at all.
    public let showsText: Bool
    /// Message to show instead of the transcript, when delivery failed.
    public let message: String?

    public static let dismiss = StopPresentation(linger: 0, showsText: false, message: nil)

    /// Long enough to read a sentence and reach for the clipboard, since this is
    /// the only place the text now lives.
    public static let undeliveredLinger: TimeInterval = 6

    public static func policy(for delivery: TranscriptDelivery, textIsEmpty: Bool) -> StopPresentation {
        switch delivery {
        case .typed, .displayedOnly:
            return .dismiss
        case let .failed(reason):
            // Nothing was said, so there is nothing to rescue and nothing to read.
            guard !textIsEmpty else { return .dismiss }
            return StopPresentation(linger: undeliveredLinger, showsText: true, message: reason)
        }
    }
}
