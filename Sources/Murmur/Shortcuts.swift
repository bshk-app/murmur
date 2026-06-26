import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Push-to-talk: hold to dictate, release to finish. Default ⌃⌥Space;
    /// user-rebindable via the Recorder in Settings. Backed by Carbon
    /// `RegisterEventHotKey` — needs no Accessibility permission.
    static let dictate = Self("dictate", default: .init(.space, modifiers: [.control, .option]))
}
