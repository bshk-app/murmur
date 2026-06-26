import KeyboardShortcuts
import SwiftUI

/// Step 2 — Shortcut (design: MurMur Onboarding.dc.html STEP 2). A
/// `KeyboardShortcuts.Recorder` inside the mock's dashed record box, plus preset
/// chips that write straight to `.dictate` via `KeyboardShortcuts.setShortcut`.
/// Our real default is ⌃⌥Space (`Shortcuts.swift`), not the mock's ⌥Space — kept
/// as the first preset; ⌥Space is offered alongside. Continue is always enabled.
struct ShortcutScreen: View {
    @Bindable var model: OnboardingModel
    @Environment(\.colorScheme) private var scheme

    /// Mirrors the stored shortcut so chips + box re-render on every change
    /// (recorder edit or preset tap).
    @State private var current = KeyboardShortcuts.getShortcut(for: .dictate)

    private var t: OnTheme { OnTheme(scheme) }

    /// Selectable presets. Each is a representable `Shortcut` (modifiers + a key).
    /// ⌃⌥Space is our default; the rest are common hold-to-talk combos.
    private static let presets: [Preset] = [
        Preset(label: "⌃⌥Space", shortcut: .init(.space, modifiers: [.control, .option])),
        Preset(label: "⌥Space", shortcut: .init(.space, modifiers: [.option])),
        Preset(label: "⌃Space", shortcut: .init(.space, modifiers: [.control])),
        Preset(label: "⌘⇧D", shortcut: .init(.d, modifiers: [.command, .shift])),
        Preset(label: "⌥`", shortcut: .init(.backtick, modifiers: [.option])),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Shortcut")
                    .tracking(1.4).murFont(11, weight: .bold)
                    .foregroundStyle(Mur.accent)
                Text("Choose your push-to-talk")
                    .murFont(32, weight: .semibold, design: .serif)
                    .foregroundStyle(t.ink).padding(.top, 10)
                Text("Pick the keys you’ll hold down while speaking. A hold-to-talk combo like ⌃⌥Space feels best.")
                    .murFont(14.5).lineSpacing(4)
                    .foregroundStyle(t.muted(0.66))
                    .frame(maxWidth: 440, alignment: .leading).padding(.top, 11)
            }

            recorderBox.padding(.top, 20)

            presetRow.padding(.top, 20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            ForEach(Self.presets) { preset in
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
