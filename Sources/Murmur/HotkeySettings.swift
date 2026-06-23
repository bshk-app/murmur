import Foundation
import Observation

/// Persists the push-to-talk `Hotkey` in `UserDefaults` and notifies the
/// controller (via `onChange`) so it can re-point the live tap without a
/// relaunch. `@Observable` so the menu/settings labels track changes.
@MainActor
@Observable
final class HotkeySettings {
    private static let defaultsKey = "pushToTalkHotkey"

    var hotkey: Hotkey {
        didSet {
            guard hotkey != oldValue else { return }
            persist()
            onChange?(hotkey)
        }
    }

    /// Set by the controller; not part of observable state.
    @ObservationIgnored var onChange: ((Hotkey) -> Void)?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode(Hotkey.self, from: data) {
            hotkey = stored
        } else {
            hotkey = .default
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(hotkey) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
