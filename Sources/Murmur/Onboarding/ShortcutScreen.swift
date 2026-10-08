import AppKit
import KeyboardShortcuts
import SwiftUI

/// Step 2 — Shortcut (design: MurMur Onboarding.dc.html STEP 2). A
/// `KeyboardShortcuts.Recorder` inside the mock's dashed record box, plus preset
/// chips that write straight to `.dictate` via `KeyboardShortcuts.setShortcut`.
/// The default is the mock's ⌥Space (`Shortcuts.swift`), the first preset.
/// Continue is always enabled.
struct ShortcutScreen: View {
    @Bindable var model: OnboardingModel
    @Environment(\.colorScheme) private var scheme

    /// Mirrors the stored shortcut so chips + box re-render on every change
    /// (recorder edit or preset tap).
    @State private var current = KeyboardShortcuts.getShortcut(for: .dictate)
    /// What macOS keeps for itself right now. The chips write the shortcut
    /// without the recorder's own check, so they must not offer one of these,
    /// and the box says so when the chord in it is one.
    @State private var systemTaken: [KeyboardShortcuts.Shortcut] = []

    private var t: OnTheme { OnTheme(scheme) }

    /// Selectable presets. Each is a representable `Shortcut` (modifiers + a key).
    /// ⌥Space is our default; the rest are common hold-to-talk combos.
    private static let presets: [Preset] = [
        Preset(label: "⌥Space", shortcut: .init(.space, modifiers: [.option])),
        Preset(label: "⌃⌥Space", shortcut: .init(.space, modifiers: [.control, .option])),
        Preset(label: "⌃Space", shortcut: .init(.space, modifiers: [.control])),
        Preset(label: "⌘⇧D", shortcut: .init(.d, modifiers: [.command, .shift])),
        Preset(label: "⌥`", shortcut: .init(.backtick, modifiers: [.option])),
    ]

    /// A preset macOS already answers to is left out - unless it is the one
    /// chosen, which stays visible so the user can see what they have.
    private var offeredPresets: [Preset] {
        Self.presets.filter { $0.shortcut == current || !systemTaken.contains($0.shortcut) }
    }

    private var clash: SystemShortcutClash? {
        SystemShortcuts.clash(for: current, among: systemTaken)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Shortcut")
                    .tracking(1.4).murFont(11, weight: .bold)
                    .foregroundStyle(Mur.accent)
                Text("Choose your push-to-talk")
                    .murFont(32, weight: .semibold, design: .serif)
                    .foregroundStyle(t.ink).padding(.top, 10)
                Text("Pick the keys you’ll hold down while speaking. A hold-to-talk combo like ⌥Space feels best.")
                    .murFont(14.5).lineSpacing(4)
                    .foregroundStyle(t.muted(0.66))
                    .frame(maxWidth: 440, alignment: .leading).padding(.top, 11)
            }

            recorderBox.padding(.top, 20)

            if let clash, let chord = current?.description {
                clashNote(clash, chord: chord).padding(.top, 12)
            }

            presetRow.padding(.top, 20)

            // Not a preset: a lone modifier is not something the recorder can
            // hold, and it works without choosing anything.
            Text("No chord needed: tap right ⌘, speak, then press Return to insert.")
                .murFont(12.5).foregroundStyle(t.muted(0.55))
                .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { systemTaken = SystemShortcuts.enabled() }
        // Back from System Settings, where the macOS one may have been turned off.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            systemTaken = SystemShortcuts.enabled()
        }
    }

    private func clashNote(_ clash: SystemShortcutClash, chord: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Mur.accent)
            VStack(alignment: .leading, spacing: 6) {
                Text(SystemShortcuts.warning(clash, chord: chord))
                    .murFont(12.5).lineSpacing(3)
                    .foregroundStyle(t.muted(0.78))
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Keyboard Settings…") { NSWorkspace.shared.open(SystemShortcuts.settingsURL) }
                    .buttonStyle(.link)
                    .font(.system(size: 12.5, weight: .semibold))
            }
        }
        .frame(maxWidth: 440, alignment: .leading)
    }

    // MARK: - Recorder box (dashed)

    private var recorderBox: some View {
        VStack(spacing: 11) {
            KeyboardShortcuts.Recorder(for: .dictate) { newValue in
                current = newValue
            }
            Text("Click above to record a new shortcut")
                .murFont(12.5).foregroundStyle(t.muted(0.55))
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(t.surface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(t.line(0.24), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        }
    }

    // MARK: - Presets

    private var presetRow: some View {
        HStack(spacing: 10) {
            Text("Presets")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(t.muted(0.5))
            ForEach(offeredPresets) { preset in
                presetChip(preset)
            }
        }
    }

    private func presetChip(_ preset: Preset) -> some View {
        let active = current == preset.shortcut
        return Button {
            KeyboardShortcuts.setShortcut(preset.shortcut, for: .dictate)
            current = preset.shortcut
        } label: {
            Text(verbatim: preset.label)
                .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(active ? OnTheme.rgb(26, 18, 12) : t.muted(0.78))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(active ? AnyShapeStyle(Mur.accent) : AnyShapeStyle(t.card),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(active ? Mur.accent : t.line(0.14), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private struct Preset: Identifiable {
        let label: String
        let shortcut: KeyboardShortcuts.Shortcut
        var id: String { label }
    }
}
