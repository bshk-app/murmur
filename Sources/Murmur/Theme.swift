import MurmurKit
import PostHog
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

/// What the app is doing right now.
///
/// Captions is not a variant of dictation. A speaker cannot hold a key through a
/// forty-minute talk, and nothing they say should be typed into whichever window
/// happens to be focused — so the trigger and the output both differ, and one
/// enum value each is cheaper than threading two exceptions everywhere.
enum AppMode: String, CaseIterable, Identifiable {
    case dictation
    case captions

    var id: String { rawValue }

    static let defaultsKey = "murmur.appMode"
    static var current: AppMode {
        AppMode(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .dictation
    }
}

/// How the push-to-talk hotkey behaves.
enum TriggerMode: String, CaseIterable, Identifiable {
    case hold      // record while held, stop on release (push-to-talk)
    case toggle    // tap to start, tap again (or the HUD Stop button) to stop

    var id: String { rawValue }
    var label: String { self == .hold ? "Hold to talk" : "Tap on / off" }

    static let defaultsKey = "murmur.triggerMode"
    static var current: TriggerMode {
        TriggerMode(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .hold
    }
}

/// Language prompt for Nemotron's live draft. Parakeet final is multilingual.
enum SpeechLanguage {
    static let defaultsKey = "murmur.language"
    static let automatic = "auto"
    static let russian = "ru"
    static let english = "en"

    static var systemDefault: String {
        switch Locale.current.language.languageCode?.identifier {
        case "ru": return russian
        case "en": return english
        default: return automatic
        }
    }

    static var current: String {
        UserDefaults.standard.string(forKey: defaultsKey) ?? systemDefault
    }

    static func badge(for code: String) -> String {
        code == automatic ? "Auto" : code.uppercased()
    }

    static func displayName(for code: String) -> String {
        guard code != automatic else { return "Automatic" }
        return Locale.current.localizedString(forIdentifier: code) ?? code
    }
}

/// Master on/off — when off, the hotkey is ignored.
enum DictationEnabled {
    static let key = "murmur.enabled"
    /// Defaults to `true` when unset.
    static var value: Bool {
        UserDefaults.standard.object(forKey: key) == nil ? true : UserDefaults.standard.bool(forKey: key)
    }
}

/// Which model(s) transcribe — persisted; read by DictationController at begin.
enum ModelSetting {
    static let key = "murmur.model"

    /// Falls back to Hybrid: Nemotron + Parakeet keep realtime on base chips.
    /// An explicit choice still wins.
    static var current: DictationMode {
        DictationMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .hybrid
    }
}

/// Anonymous usage & error analytics (PostHog). **Opt-in**: off until the user
/// enables it on the onboarding Welcome step (or in Settings). While off,
/// `PostHogSDK.shared.optOut()` makes every `capture(…)` a no-op — no audio or
/// transcripts are ever sent regardless.
enum AnalyticsConsent {
    static let key = "murmur.analyticsEnabled"
    /// Defaults to `false` (opt-in) when unset.
    static var enabled: Bool { UserDefaults.standard.bool(forKey: key) }
    /// SSOT for applying consent: persists + flips PostHog. Call from any toggle.
    @MainActor static func set(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: key)
        on ? PostHogSDK.shared.optIn() : PostHogSDK.shared.optOut()
    }
}
