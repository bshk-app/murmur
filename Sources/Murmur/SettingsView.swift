import SwiftUI

/// Murmur's preferences window (a SwiftUI `Settings` scene). Step E will grow
/// language/model/insertion options; for now it hosts the hotkey recorder.
struct SettingsView: View {
    @Bindable var settings: HotkeySettings

    var body: some View {
        Form {
            Section {
                HotkeyRecorderView(settings: settings)
            } header: {
                Text("Push-to-talk shortcut")
            } footer: {
                Text("Hold the shortcut to dictate; release to finish.")
            }
            Section {
                Button("Reset to default (⌃⌥Space)") { settings.hotkey = .default }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .frame(minHeight: 200)
    }
}

/// Records a new chord: click Change, then hold ≥1 modifier + a key. A local
/// `NSEvent` monitor captures (and swallows) the next key press while the
/// Settings window is key.
private struct HotkeyRecorderView: View {
    @Bindable var settings: HotkeySettings
    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint = ""

    var body: some View {
        HStack {
            Text("Shortcut")
            Spacer()
            Text(settings.hotkey.displayString)
                .font(.title3)
                .monospaced()
                .foregroundStyle(recording ? .secondary : .primary)
            Button(recording ? "Press keys… (⎋ cancels)" : "Change") { toggle() }
        }
        if !hint.isEmpty {
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func toggle() { recording ? stop() : start() }

    private func start() {
        recording = true
        hint = "Hold at least one modifier (⌃ ⌥ ⇧ ⌘) + a key"
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            capture(event)
            return nil                                   // swallow while recording
        }
    }

    private func capture(_ e: NSEvent) {
        if e.keyCode == 53 { stop(); return }            // ⎋ cancels
        let m = e.modifierFlags
        let hk = Hotkey(keyCode: Int(e.keyCode),
                        control: m.contains(.control),
                        option: m.contains(.option),
                        shift: m.contains(.shift),
                        command: m.contains(.command))
        guard hk.hasModifier else {
            hint = "Need at least one modifier (⌃ ⌥ ⇧ ⌘)"
            return
        }
        settings.hotkey = hk
        stop()
    }

    private func stop() {
        recording = false
        hint = ""
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
