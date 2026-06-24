import SwiftUI

/// MurMur design tokens (from the Claude Design handoff: MurMur.dc.html).
enum Mur {
    static let accent = Color(red: 0xE8 / 255, green: 0x89 / 255, blue: 0x3B / 255)  // #E8893B
    static let ink    = Color(red: 0x2A / 255, green: 0x25 / 255, blue: 0x20 / 255)  // #2A2520
    static let error  = Color(red: 0xC9 / 255, green: 0x4A / 255, blue: 0x3B / 255)  // #C94A3B
    static let cream  = Color(red: 0xFA / 255, green: 0xF7 / 255, blue: 0xF2 / 255)  // #FAF7F2

    /// Glass pill background per appearance (dark: warm near-black; light: warm cream).
    static func glass(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0x1A / 255, green: 0x16 / 255, blue: 0x13 / 255).opacity(0.82)
            : Color(red: 0xFC / 255, green: 0xFA / 255, blue: 0xF6 / 255).opacity(0.85)
    }

    /// Crisp (finalized) transcript ink per appearance.
    static func crisp(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.97) : ink
    }

    /// Fast-draft (provisional) transcript ink per appearance.
    static func draft(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.34) : ink.opacity(0.34)
    }
}

/// Where the transcript goes when you release the hotkey.
enum InsertMode: String, CaseIterable, Identifiable {
    case inField   // type into the focused field of any app (needs Accessibility)
    case hudOnly   // presentation/subtitles: show in the HUD only, never inject

    var id: String { rawValue }
    var label: String { self == .inField ? "In field" : "HUD only" }

    static let defaultsKey = "murmur.insertMode"
    static var current: InsertMode {
        InsertMode(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .inField
    }
}
