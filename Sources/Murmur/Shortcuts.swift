import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Push-to-talk: hold to dictate, release to finish. Default ⌃⌥Space;
    /// user-rebindable via the Recorder in Settings. Backed by Carbon
    /// `RegisterEventHotKey` — needs no Accessibility permission.
    static let dictate = Self("dictate", default: .init(.space, modifiers: [.control, .option]))

    /// Push-to-talk that also presses Return once the transcript lands — dictating
    /// and sending as one gesture, for chat fields.
    ///
    /// Deliberately unbound by default. Return means "send" in a chat and "new
    /// line" in an editor, so a global setting would make the user carry the mode
    /// in their head; a stray Return in a code file or an email body is a worse
    /// failure than pressing it yourself. Binding this shortcut IS the opt-in, and
    /// choosing which key to hold expresses the intent per utterance.
    static let dictateAndSend = Self("dictateAndSend")
}
