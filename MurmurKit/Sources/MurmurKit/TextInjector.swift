import CoreGraphics
import Foundation

/// Types text into the focused field of the frontmost app by posting synthetic
/// key events that carry the Unicode payload — no keycode mapping, no clipboard
/// clobber. Requires Accessibility trust.
public enum TextInjector {
    /// Post `text` one character at a time into the focused field.
    public static func type(_ text: String) {
        guard !text.isEmpty else { return }
        // A private source so synthetic events don't inherit currently-held
        // physical modifiers (you may still be holding the hotkey's ⌃⌥).
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
