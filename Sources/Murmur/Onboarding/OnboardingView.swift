import MurmurKit
import SwiftUI

/// The first-run onboarding window (design: MurMur Onboarding.dc.html). A 6-step
/// wizard: title bar + left narrator rail + a right content pane that switches on
/// `OnboardingFlow.Step`, with a Back/Continue footer gated by `model.canContinue`.
/// Welcome + Done are fully built here; permissions/shortcut/download/try-it are
/// compiling placeholders filled in by later phases. Theme-adaptive via `OnTheme`.
struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    @Environment(\.colorScheme) private var scheme

    private var t: OnTheme { OnTheme(scheme) }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                OnboardingTitleBar(model: model)
                HStack(spacing: 0) {
                    OnboardingRail(model: model)
                    VStack(spacing: 0) {
                        ScrollView {
                            content.padding(.init(top: 30, leading: 36, bottom: 26, trailing: 36))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if !model.finished { OnboardingFooter(model: model) }
                    }
                    .background(t.surface)
                }
            }
            if model.finished { FinishedOverlay(model: model) }
        }
        .background(t.surface)
    }

    @ViewBuilder private var content: some View {
        switch model.flow.step {
        case .welcome:     WelcomeScreen()
        case .permissions: PermissionsScreen(model: model)   // Phase 2
        case .shortcut:    ShortcutScreen(model: model)       // Phase 2
        case .download:    DownloadScreen(model: model)       // Phase 3
        case .tryIt:       TryItScreen(model: model)          // Phase 4
        case .done:        DoneScreen(model: model)
        }
    }
}

// MARK: - Shared screen header (eyebrow + serif title + lede)

private struct ScreenHeader: View {
    let eyebrow: LocalizedStringKey
    let title: LocalizedStringKey
    let lede: LocalizedStringKey
    @Environment(\.colorScheme) private var scheme

    private var t: OnTheme { OnTheme(scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(eyebrow)
                .font(.system(size: 11, weight: .bold)).tracking(1.4)
                .foregroundStyle(Mur.accent)
            Text(title)
                .font(.system(size: 32, weight: .semibold, design: .serif))
                .foregroundStyle(t.ink).padding(.top, 10)
            Text(lede)
                .font(.system(size: 14.5)).lineSpacing(4)
                .foregroundStyle(t.muted(0.66))
                .frame(maxWidth: 444, alignment: .leading).padding(.top, 11)
        }
    }
}

// MARK: - Step 0: Welcome (full)

private struct WelcomeScreen: View {
    @Environment(\.colorScheme) private var scheme

    private var t: OnTheme { OnTheme(scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenHeader(
                eyebrow: "Welcome",
                title: "Just talk. I’ll type it.",
                lede: "A little menu-bar cat that turns your voice into text — instantly, in any app, completely on your Mac. Let’s get you set up in a minute.")

            HStack(spacing: 11) {
                featureCard(badge: { keyBadge("⌥ Space") },
                            title: "Hold the keys", caption: "One global shortcut, anywhere.")
                featureCard(badge: { speakBadge },
                            title: "Speak naturally", caption: "Real-time, no spinner.")
                featureCard(badge: { typedBadge },
                            title: "It’s typed for you", caption: "Straight into the field.")
            }
            .padding(.top, 22)

            modelsNote.padding(.top, 16)
        }
    }

    private func featureCard<Badge: View>(@ViewBuilder badge: () -> Badge,
                                           title: LocalizedStringKey, caption: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            badge()
            Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(t.ink).padding(.top, 11)
            Text(caption).font(.system(size: 12)).lineSpacing(2).foregroundStyle(t.muted(0.58)).padding(.top, 4)
        }
        .padding(.init(top: 15, leading: 14, bottom: 15, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(t.card, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(t.line(0.1), lineWidth: 1))
    }

    private func keyBadge(_ s: String) -> some View {
        Text(verbatim: s).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(t.ink)
            .padding(.horizontal, 11).frame(height: 30)
            .background(t.line(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(t.line(0.1), lineWidth: 1))
    }

    private var speakBadge: some View {
        HStack(spacing: 7) {
            Circle().fill(Mur.accent).frame(width: 7, height: 7)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0 ..< 3, id: \.self) { _ in
                    Capsule().fill(Mur.accent).frame(width: 2.5, height: 13)
                }
            }
        }
        .padding(.horizontal, 11).frame(height: 30)
        .background(Mur.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Mur.accent.opacity(0.2), lineWidth: 1))
    }

    private var typedBadge: some View {
        HStack(spacing: 1) {
            Text("text appears").font(.system(size: 13)).foregroundStyle(t.ink)
            Rectangle().fill(Mur.accent).frame(width: 1.5, height: 14)
        }
        .padding(.horizontal, 11).frame(height: 30)
        .background(t.line(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(t.line(0.1), lineWidth: 1))
    }

    /// "Two models, one trick … about 3.6 GB …" — size pulled from `OnboardingFlow`.
    private var modelsNote: some View {
        let gb = String(format: "%.1f GB", OnboardingFlow.totalGB)
        let body = Text("Two models, one trick. ").fontWeight(.bold).foregroundColor(t.ink)
            + Text("A fast model types an instant draft, then an accurate one sharpens each word a blink later. To do that on-device, setup installs both models — about ")
            + Text(verbatim: gb).fontWeight(.bold).foregroundColor(t.ink)   // "3.6 GB" — runtime value
            + Text(". Nothing you say ever leaves your Mac.")
        return HStack(alignment: .top, spacing: 11) {
            onboardingCat(30).padding(.top, 1)
            body.font(.system(size: 13)).lineSpacing(3).foregroundColor(t.muted(0.72))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.init(top: 14, leading: 16, bottom: 14, trailing: 16))
        .background(Mur.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Mur.accent.opacity(0.18), lineWidth: 1))
    }
}

// MARK: - Step 5: Done (full)

private struct DoneScreen: View {
    @Bindable var model: OnboardingModel
    @Environment(\.colorScheme) private var scheme

    private var t: OnTheme { OnTheme(scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenHeader(
                eyebrow: "All set",
                title: "You’re ready to talk",
                lede: "MurMur is now living quietly in your menu bar. Hold your shortcut in any app and just talk — the words land right where your cursor is.")

            VStack(spacing: 9) {
                checkRow(title: "Two voice models installed",
                         trailing: { Text("\(String(format: "%.1f GB", OnboardingFlow.totalGB)) · on-device")
                             .font(.system(size: 12.5)).foregroundStyle(t.muted(0.5)) })
                checkRow(title: "Microphone & Accessibility granted", trailing: { EmptyView() })
                checkRow(title: "Shortcut set to",
                         trailing: { keyChips(model.shortcutLabel) })
            }
            .padding(.top, 22)
        }
    }

    private func checkRow<Trailing: View>(title: LocalizedStringKey,
                                           @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            checkBadge
            Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(t.ink)
            Spacer(minLength: 6)
            trailing()
        }
        .padding(.init(top: 13, leading: 15, bottom: 13, trailing: 15))
        .background(t.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(t.line(0.1), lineWidth: 1))
    }

    private var checkBadge: some View {
        Circle().fill(OnTheme.rgb(95, 179, 106)).frame(width: 22, height: 22)
            .overlay(Text("✓").font(.system(size: 12, weight: .bold)).foregroundStyle(.white))
    }

    private func keyChips(_ label: String) -> some View {
        HStack(spacing: 5) {
            ForEach(splitShortcut(label), id: \.self) { key in
                Text(verbatim: key).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(t.ink)
                    .padding(.horizontal, 7).frame(minWidth: 24, minHeight: 24)
                    .background(t.line(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(t.line(0.14), lineWidth: 1))
            }
        }
    }

    /// Split a shortcut label ("⌃⌥Space") into chip tokens. KeyboardShortcuts
    /// renders modifiers glyph-adjacent; break before the trailing key name.
    private func splitShortcut(_ s: String) -> [String] {
        let mods = Set("⌃⌥⇧⌘")
        var out: [String] = []
        var key = ""
        for ch in s where ch != " " {
            if mods.contains(ch) { out.append(String(ch)) } else { key.append(ch) }
        }
        if !key.isEmpty { out.append(key) }
        return out.isEmpty ? [s] : out
    }
}

// MARK: - Placeholder screens (replaced by later phases)
//
// These are non-private so a later phase can delete the placeholder here and add
// a real `*Screen.swift` with the same top-level name (no duplicate-definition
// clash inside this file). Phase 2 → Permissions/Shortcut, 3 → Download, 4 → Try it.

struct PermissionsScreen: View {
    @Bindable var model: OnboardingModel
    var body: some View { OnboardingPlaceholder(eyebrow: "Permissions", note: "Mic + Accessibility — Phase 2.") }
}

struct ShortcutScreen: View {
    @Bindable var model: OnboardingModel
    var body: some View { OnboardingPlaceholder(eyebrow: "Shortcut", note: "Recorder + presets — Phase 2.") }
}

struct DownloadScreen: View {
    @Bindable var model: OnboardingModel
    var body: some View { OnboardingPlaceholder(eyebrow: "Downloading", note: "Per-repo progress — Phase 3.") }
}

struct TryItScreen: View {
    @Bindable var model: OnboardingModel
    var body: some View { OnboardingPlaceholder(eyebrow: "Try it", note: "In-window dictation — Phase 4.") }
}

/// Minimal eyebrow + note placeholder so the wizard compiles before the real
/// screens land. Strings still flow through the catalog.
struct OnboardingPlaceholder: View {
    let eyebrow: LocalizedStringKey
    let note: LocalizedStringKey
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = OnTheme(scheme)
        VStack(alignment: .leading, spacing: 10) {
            Text(eyebrow).font(.system(size: 11, weight: .bold)).tracking(1.4).foregroundStyle(Mur.accent)
            Text(note).font(.system(size: 14.5)).foregroundStyle(t.muted(0.66))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
