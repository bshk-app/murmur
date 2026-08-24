import AppKit
import MurmurKit
import PostHog
import SwiftUI

/// The menu-bar dropdown (design: MurMur.dc.html) shown as a `.window`-style
/// MenuBarExtra: mascot + master toggle, live status + hotkey, a mic meter, the
/// Model / Insert / Hotkey segmented controls, and a Settings/Quit footer.
struct MenuPopover: View {
    let dictation: DictationController
    /// Re-open the onboarding window (resets to Welcome + presents it).
    let onSetupTour: () -> Void
    /// Ask Sparkle to check for app updates (AppDelegate brackets the activation policy).
    let onCheckForUpdates: () -> Void
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorScheme) private var scheme

    @AppStorage(DictationEnabled.key) private var enabled = true
    @AppStorage(AppMode.defaultsKey) private var appModeRaw = AppMode.dictation.rawValue
    @AppStorage(TriggerMode.defaultsKey) private var triggerRaw = TriggerMode.hold.rawValue
    @AppStorage(ModelSetting.key) private var modelRaw = DictationMode.hybrid.rawValue
    @AppStorage(SpeechLanguage.defaultsKey) private var languageRaw = SpeechLanguage.systemDefault
    @AppStorage(MicrophoneSetting.defaultsKey)
    private var microphoneUID = MicrophoneSetting.systemDefaultUID

    var body: some View {
        VStack(spacing: 0) {
            head
            divider
            micRow
            divider
            settings
            divider
            footer
        }
        .frame(width: 300)
        .background(scheme == .dark
            ? Color(red: 36 / 255, green: 31 / 255, blue: 28 / 255)
            : Mur.cream)
        // Switching model loads the newly selected mode's models (lazy by mode).
        .onChange(of: modelRaw) { oldValue, newValue in
            dictation.prepareCurrentMode()
            PostHogSDK.shared.capture("model_mode_changed", properties: [
                "from_mode": oldValue,
                "to_mode": newValue,
            ])
        }
        // Captions needs the boundary detector on top of the dictation models, so
        // switching mode warms whatever the new one is missing.
        .onChange(of: appModeRaw) { oldValue, newValue in
            dictation.prepareCurrentMode()
            PostHogSDK.shared.capture("app_mode_changed", properties: [
                "from_mode": oldValue,
                "to_mode": newValue,
            ])
        }
        .onAppear {
            let validUID = dictation.refreshMicrophones(preferredUID: microphoneUID)
            if validUID != microphoneUID { microphoneUID = validUID }
        }
    }

    // MARK: head

    private var head: some View {
        VStack(spacing: 9) {
            HStack(spacing: 10) {
                DictatorMascot(mood: dictation.mascotMood, size: 30)
                Text("MurMur").font(.system(size: 15, weight: .semibold)).foregroundStyle(primary)
                Spacer()
                Toggle("", isOn: $enabled).toggleStyle(.switch).tint(Mur.accent).labelsHidden()
            }
            HStack(spacing: 8) {
                Circle().fill(dictation.isActive ? Mur.accent : secondary.opacity(0.45))
                    .frame(width: 7, height: 7)
                Text(dictation.shortStatus).font(.system(size: 12)).foregroundStyle(secondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(dictation.shortcutLabel).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(secondary)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(fieldBG, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
        }
        .padding(.horizontal, 16).padding(.top, 15).padding(.bottom, 12)
    }

    // MARK: mic meter (animated for now; live level is a later pass)

    private var micRow: some View {
        HStack(spacing: 11) {
            Text("Microphone").font(.system(size: 12)).foregroundStyle(secondary)
                .frame(width: 74, alignment: .leading)
            MeterBars(active: dictation.isActive)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    // MARK: segmented settings

    private var languageCodes: [String] {
        let codes = Set(dictation.supportedLanguageCodes + [SpeechLanguage.automatic, languageRaw])
        return codes.sorted {
            if $0 == SpeechLanguage.automatic { return true }
            if $1 == SpeechLanguage.automatic { return false }
            return SpeechLanguage.displayName(for: $0)
                .localizedCaseInsensitiveCompare(SpeechLanguage.displayName(for: $1)) == .orderedAscending
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 0) {
            label("Microphone")
            Picker("Microphone", selection: $microphoneUID) {
                Text("System Default").tag(MicrophoneSetting.systemDefaultUID)
                ForEach(dictation.microphones) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(dictation.isActive)
            label("Mode").padding(.top, 11)
            MurSegment(selection: $appModeRaw,
                       options: [(AppMode.dictation.rawValue, "Dictation"),
                                 (AppMode.captions.rawValue, "Captions")])
                // Switching pipelines under a live session is not a state worth
                // supporting — the running one owns the mic until it stops.
                .disabled(dictation.isActive)
            if appModeRaw == AppMode.captions.rawValue {
                Text("Tap the shortcut to start, tap again to stop. Nothing is typed into other apps.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 7)
            }
            label("Model").padding(.top, 11)
            MurSegment(selection: $modelRaw,
                       options: [(DictationMode.fast.rawValue, "Fast"),
                                 (DictationMode.hybrid.rawValue, "Hybrid"),
                                 (DictationMode.accurate.rawValue, "Accurate")])
            label("Language").padding(.top, 11)
            Picker("Language", selection: $languageRaw) {
                ForEach(languageCodes, id: \.self) { code in
                    Text(SpeechLanguage.displayName(for: code)).tag(code)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            label("Hotkey").padding(.top, 11)
            MurSegment(selection: $triggerRaw,
                       options: [(TriggerMode.hold.rawValue, "Hold"),
                                 (TriggerMode.toggle.rawValue, "Toggle")])
                .disabled(dictation.isActive)
            if dictation.needsAccessibilityToType {
                Button { dictation.requestAccessibility() } label: {
                    Text("Grant Accessibility to type…")
                        .font(.system(size: 11.5)).foregroundStyle(Mur.accent)
                }
                .buttonStyle(.plain).padding(.top, 10)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.system(size: 12)).foregroundStyle(tertiary)
            .padding(.bottom, 7).frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: footer

    private var footer: some View {
        VStack(spacing: 0) {
            footerRow("Settings…", "⌘ ,") {
                PostHogSDK.shared.capture("settings_opened")
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            footerRow("Check for Updates…", "") {
                PostHogSDK.shared.capture("check_for_updates")
                onCheckForUpdates()
            }
            // Re-run the first-run tour: reset to Welcome, then ask the App scene
            // (via the router) to open the onboarding window.
            footerRow("Setup tour…", "") { onSetupTour() }
            footerRow("Quit MurMur", "⌘ Q") { NSApplication.shared.terminate(nil) }
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
    }

    private func footerRow(_ title: LocalizedStringKey, _ key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 13)).foregroundStyle(primary)
                Spacer()
                Text(verbatim: key).font(.system(size: 11, design: .monospaced)).foregroundStyle(tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 7).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: chrome

    private var divider: some View {
        Rectangle().fill(scheme == .dark ? Color.white.opacity(0.07) : Mur.ink.opacity(0.07)).frame(height: 1)
    }
    private var primary: Color { scheme == .dark ? Color.white.opacity(0.92) : Mur.ink }
    private var secondary: Color { scheme == .dark ? Color.white.opacity(0.6) : Mur.ink.opacity(0.65) }
    private var tertiary: Color { scheme == .dark ? Color.white.opacity(0.5) : Mur.ink.opacity(0.55) }
    private var fieldBG: Color { scheme == .dark ? Color.white.opacity(0.1) : Mur.ink.opacity(0.07) }
}

/// Pill segmented control matching the handoff (selected: white/accent fill).
private struct MurSegment: View {
    @Binding var selection: String
    let options: [(value: String, label: String)]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { opt in
                let sel = selection == opt.value
                Text(opt.label)
                    .font(.system(size: 12, weight: sel ? .semibold : .regular))
                    .foregroundStyle(sel ? (scheme == .dark ? Mur.ink : Mur.accent)
                                         : (scheme == .dark ? Color.white.opacity(0.6) : Mur.ink.opacity(0.65)))
                    .frame(maxWidth: .infinity).padding(.vertical, 5)
                    .background {
                        if sel {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(scheme == .dark ? Mur.accent : Color.white)
                                .shadow(color: scheme == .dark ? .clear : Mur.ink.opacity(0.12), radius: 1, y: 1)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selection = opt.value }
            }
        }
        .padding(2)
        .background(scheme == .dark ? Color.white.opacity(0.07) : Mur.ink.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Mic level meter — animated bars (live RMS is a later pass).
private struct MeterBars: View {
    var active: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var up = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0 ..< 8, id: \.self) { i in
                let lit = active && i < 5
                Capsule()
                    .fill(lit ? Mur.accent : (scheme == .dark ? Color.white.opacity(0.16) : Mur.ink.opacity(0.18)))
                    .frame(width: 3, height: 18)
                    .scaleEffect(y: (up || reduceMotion) && lit ? 1 : 0.4, anchor: .center)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.45).repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.07), value: up)
            }
        }
        .frame(height: 18)
        .accessibilityHidden(true)   // decorative meter
        .onAppear { up = true }
    }
}
