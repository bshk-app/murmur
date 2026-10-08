import Carbon.HIToolbox
import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Push-to-talk: hold to dictate, release to finish. Default ⌥Space;
    /// user-rebindable via the Recorder in Settings. Backed by Carbon
    /// `RegisterEventHotKey` — needs no Accessibility permission.
    ///
    /// Not ⌃⌥Space, the default before right ⌘: that is macOS's own "Select
    /// next source in Input menu", switched on out of the box, so on a Mac
    /// with two keyboard layouts the chord also switched the layout and popped
    /// the system's language bubble at the text cursor. Only fresh installs
    /// get the new default - the library writes the default into
    /// UserDefaults the first time the name is touched, so everyone who ran
    /// an older Murmur keeps the chord they had, and Settings and the menu
    /// tell them if macOS shares it (`SystemShortcuts`).
    static let dictate = Self("dictate", default: .init(.space, modifiers: [.option]))

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

/// macOS answers to the same chord through one of its own keyboard shortcuts
/// (System Settings → Keyboard → Keyboard Shortcuts), so pressing it does
/// that too - or only that.
enum SystemShortcutClash: Equatable {
    /// One of the two that switch the keyboard layout.
    case inputSource
    case other
}

/// The chords macOS keeps for itself, as the KeyboardShortcuts recorder sees
/// them when it refuses one - but checked for a shortcut already stored, which
/// the recorder never looks at again: a default, a preset chip, or a chord set
/// before the user turned the macOS one on.
enum SystemShortcuts {
    /// macOS's defaults for "Select the previous input source" and "Select next
    /// source in Input menu". The list it hands out does not say which entry is
    /// which, so a chord is only called a layout switch when it is one of
    /// these; a remapped layout switch reads as `.other`, which is still true.
    static let inputSourceDefaults: Set<KeyboardShortcuts.Shortcut> = [
        .init(.space, modifiers: [.control]),
        .init(.space, modifiers: [.control, .option]),
    ]

    /// The ones switched on right now. Read on every call, not cached: the user
    /// can change them in System Settings while Murmur runs.
    static func enabled() -> [KeyboardShortcuts.Shortcut] {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let entries = unmanaged?.takeRetainedValue() as? [[String: Any]]
        else { return [] }
        return entries.compactMap { entry in
            guard (entry[kHISymbolicHotKeyEnabled] as? Bool) == true,
                  let keyCode = entry[kHISymbolicHotKeyCode] as? Int,
                  let modifiers = entry[kHISymbolicHotKeyModifiers] as? Int
            else { return nil }
            return KeyboardShortcuts.Shortcut(carbonKeyCode: keyCode, carbonModifiers: modifiers)
        }
    }

    static func clash(for shortcut: KeyboardShortcuts.Shortcut?,
                      among enabled: [KeyboardShortcuts.Shortcut]) -> SystemShortcutClash? {
        guard let shortcut, enabled.contains(shortcut) else { return nil }
        return inputSourceDefaults.contains(shortcut) ? .inputSource : .other
    }

    static func clash(for name: KeyboardShortcuts.Name) -> SystemShortcutClash? {
        clash(for: KeyboardShortcuts.getShortcut(for: name), among: enabled())
    }

    /// Where the user turns the macOS one off. The Keyboard Shortcuts sheet
    /// itself has no URL; this opens the pane its button is on.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!

    /// One line for under the shortcut, naming the chord.
    static func warning(_ clash: SystemShortcutClash, chord: String) -> String {
        switch clash {
        case .inputSource:
            String(localized: "macOS also uses \(chord) to switch keyboard layouts, so pressing it can change your layout. Pick another shortcut, or turn the macOS one off in Keyboard Shortcuts → Input Sources.")
        case .other:
            String(localized: "macOS also uses \(chord) for one of its own shortcuts, so it may not start dictation. Pick another shortcut, or turn the macOS one off in Keyboard Shortcuts.")
        }
    }
}
