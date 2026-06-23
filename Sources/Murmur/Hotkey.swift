import Foundation

/// A push-to-talk shortcut: a virtual key code plus the modifiers that must be
/// held with it. The single source of truth shared by the recorder (`NSEvent`),
/// the global tap (`CGEventFlags`), and the UI label — `NSEvent.keyCode` and
/// `CGEvent`'s `.keyboardEventKeycode` use the same virtual key codes.
struct Hotkey: Codable, Equatable {
    var keyCode: Int
    var control: Bool
    var option: Bool
    var shift: Bool
    var command: Bool

    /// ⌃⌥Space.
    static let `default` = Hotkey(keyCode: 49, control: true, option: true, shift: false, command: false)

    var hasModifier: Bool { control || option || shift || command }

    /// Canonical Apple order: ⌃ ⌥ ⇧ ⌘ + key.
    var displayString: String {
        var s = ""
        if control { s += "⌃" }
        if option { s += "⌥" }
        if shift { s += "⇧" }
        if command { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    static func keyName(_ code: Int) -> String {
        switch code {
        case 49: return "Space"
        case 36: return "↩"
        case 48: return "⇥"
        case 53: return "⎋"
        case 51: return "⌫"
        case 117: return "⌦"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            return letters[code] ?? digits[code] ?? fkeys[code] ?? "key\(code)"
        }
    }

    private static let letters: [Int: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I",
        38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q",
        15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
    ]
    private static let digits: [Int: String] = [
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
    ]
    private static let fkeys: [Int: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]
}
