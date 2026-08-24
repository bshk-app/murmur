import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Puts the final transcript into the focused field of the frontmost app.
///
/// Primary path is **paste** (the production standard — Handy, Superwhisper,
/// TypeVox all paste): stash the pasteboard, write the text, synthesize ⌘V, then
/// restore the previous contents. Paste is atomic and reliable across resistant
/// targets (Terminal, Electron, VS Code) where per-key synthetic events drop.
/// Per-character Unicode typing is kept as an opt-in fallback (`type`).
///
/// Both paths post synthetic events, so both need Accessibility trust and both
/// are blocked by **secure input** (password fields / secure-keyboard terminals).
/// We detect that and refuse gracefully rather than silently dropping text.
public enum TextInjector {
    public enum Result: Sendable {
        case pasted              // ⌘V sent into the field; clipboard restored
        case copiedSecureInput   // secure input on → left on the clipboard for manual ⌘V
        case failed              // couldn't synthesize the events
    }

    /// What actually goes on the pasteboard. The trailing space exists to butt the
    /// next utterance against this one; submitting ends the message, so it would
    /// only ever travel as trailing whitespace.
    public static func payload(_ text: String, submit: Bool) -> String {
        submit ? text : text + " "
    }

    /// True when some process has secure event input enabled — synthetic key
    /// events (including ⌘V) are dropped while it is. Anti-keylogger by design;
    /// there is no supported bypass, so callers should surface it, not retry.
    public static var secureInputActive: Bool { IsSecureEventInputEnabled() }

    /// How long after ⌘V we assume the target has consumed the pasteboard.
    ///
    /// A heuristic, not a measurement: there is no observable "paste applied"
    /// signal. `changeCount` says *we* wrote, not that *they* read, and reading the
    /// focused element over Accessibility is unreliable on the web fields this
    /// matters most for. Both the Return and the clipboard restore hang off this
    /// one assumption, so it is stated once instead of appearing twice as a number.
    private static let pasteSettleDelay = 0.12

    /// Insert `text` by pasting, optionally pressing Return afterwards. Requires
    /// Accessibility trust to post ⌘V. On secure input the text is left on the
    /// clipboard (not pasted, not submitted) so it isn't lost. Call on the main
    /// thread (pasteboard + a short async tail).
    @discardableResult
    public static func paste(_ text: String, submit: Bool = false) -> Result {
        guard !text.isEmpty else { return .failed }
        let pb = NSPasteboard.general
        let body = payload(text, submit: submit)

        // Secure input → ⌘V won't reach the field. Leave the text on the clipboard.
        if secureInputActive {
            pb.clearContents()
            pb.setString(body, forType: .string)
            return .copiedSecureInput
        }

        let saved = snapshot(pb)
        pb.clearContents()
        pb.setString(body, forType: .string)
        let mine = pb.changeCount
        guard postPasteShortcut() else { return .failed }

        // One deferred block, so the order is guaranteed rather than inferred from
        // two racing delays: submit first, then put the user's clipboard back. The
        // restore is still guarded by changeCount so we never clobber a copy the
        // user made in between.
        DispatchQueue.main.asyncAfter(deadline: .now() + pasteSettleDelay) {
            if submit { postReturn() }
            guard pb.changeCount == mine else { return }
            pb.clearContents()
            if let saved, !saved.isEmpty { pb.writeObjects(saved) }
        }
        return .pasted
    }

    /// Deep-copy the current pasteboard items so we can put them back after paste.
    private static func snapshot(_ pb: NSPasteboard) -> [NSPasteboardItem]? {
        pb.pasteboardItems?.compactMap { item in
            let copy = NSPasteboardItem()
            var any = false
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type); any = true }
            }
            return any ? copy : nil
        }
    }

    /// Synthesize ⌘V via a private event source (so it doesn't inherit any
    /// physical modifiers still held from the hotkey).
    private static func postPasteShortcut() -> Bool {
        let v = CGKeyCode(kVK_ANSI_V)
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// Press Return, to send the message we just pasted. Flags are cleared
    /// explicitly: a Cmd- or Shift-based dictation hotkey may still be physically
    /// held, and ⌘Return or ⇧Return means something else entirely in chat apps.
    private static func postReturn() {
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Return), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Return), keyDown: false)
        else { return }
        down.flags = []
        up.flags = []
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Per-character Unicode typing — the fragile fallback, kept for an opt-in
    /// "Type" insert mode. Carries the Unicode payload directly (no keycode
    /// mapping), but some apps drop fast synthetic key events. Blocked by secure
    /// input like paste.
    public static func type(_ text: String) {
        guard !text.isEmpty, !secureInputActive else { return }
        let source = CGEventSource(stateID: .privateState)
        for character in text {
            post(character, source: source)
        }
    }

    private static func post(_ character: Character, source: CGEventSource?) {
        let utf16 = Array(String(character).utf16)
        guard !utf16.isEmpty,
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return }

        down.flags = []                                  // clear ambient modifiers
        up.flags = []
        utf16.withUnsafeBufferPointer { buf in
            down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
