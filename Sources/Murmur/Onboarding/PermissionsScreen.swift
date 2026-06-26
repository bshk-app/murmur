import SwiftUI

/// Step 1 — Permissions (design: MurMur Onboarding.dc.html STEP 1). Two cards:
/// Microphone (the hard gate — `OnboardingFlow.canContinue` needs it) and
/// Accessibility (skippable — HUD-only dictation works without it). Each card's
/// Grant button calls the model and flips to a green "Granted" pill once the
/// matching `flow` flag is set. The model reflects already-granted state on
/// appear and polls AX trust while this screen is up.
struct PermissionsScreen: View {
    @Bindable var model: OnboardingModel
    @Environment(\.colorScheme) private var scheme

    private var t: OnTheme { OnTheme(scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Permissions")
                    .font(.system(size: 11, weight: .bold)).tracking(1.4)
                    .foregroundStyle(Mur.accent)
                Text("Two quick permissions")
                    .font(.system(size: 32, weight: .semibold, design: .serif))
                    .foregroundStyle(t.ink).padding(.top, 10)
                Text("macOS will pop up a confirmation for each. Grant both and I’m good to go — here’s what they’re for.")
                    .font(.system(size: 14.5)).lineSpacing(4)
                    .foregroundStyle(t.muted(0.66))
                    .frame(maxWidth: 444, alignment: .leading).padding(.top, 11)
            }

            VStack(spacing: 12) {
                permissionCard(
                    icon: { micIcon },
                    title: "Microphone",
                    badge: nil,
                    why: "So I can hear you while you’re holding the shortcut.",
                    granted: model.flow.micGranted,
                    grant: { model.requestMic() })

                permissionCard(
                    icon: { accessibilityIcon },
                    title: "Accessibility",
                    badge: "Input · typing",
                    why: "So I can type the words straight into whatever field has focus.",
                    granted: model.flow.accessibilityGranted,
                    grant: { model.promptAccessibility() })
            }
            .padding(.top, 22)

            Text("You can change these anytime in System Settings → Privacy & Security.")
                .font(.system(size: 12.5)).lineSpacing(3)
                .foregroundStyle(t.muted(0.5))
                .padding(.top, 14)

            if !model.flow.accessibilityGranted {
                Text("Accessibility is optional — you can set up typing later from the menu.")
                    .font(.system(size: 12.5)).lineSpacing(3)
                    .foregroundStyle(t.muted(0.42))
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { model.refreshPermissions() }
        // Stop the AX-trust poll when leaving for ANY reason — step change OR a
        // window close (the model is app-lifetime, so nothing else invalidates it).
        .onDisappear { model.stopAccessibilityPolling() }
    }

    // MARK: - Card

    private func permissionCard<Icon: View>(
        @ViewBuilder icon: () -> Icon,
        title: LocalizedStringKey,
        badge: LocalizedStringKey?,
        why: LocalizedStringKey,
        granted: Bool,
        grant: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 15) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Mur.accent.opacity(0.1))
                .frame(width: 48, height: 48)
                .overlay { icon() }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(t.ink)
                    if let badge {
                        Text(badge)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(t.muted(0.55))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(t.line(0.06), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                }
                Text(why).font(.system(size: 13)).lineSpacing(2).foregroundStyle(t.muted(0.6))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if granted {
                grantedPill
            } else {
                Button(action: grant) {
                    Text("Grant")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Mur.accent)
                        .padding(.horizontal, 17).padding(.vertical, 9)
                        .background(Mur.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Mur.accent, lineWidth: 1.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(t.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(t.line(0.1), lineWidth: 1))
    }

    private var grantedPill: some View {
        HStack(spacing: 6) {
            Text(verbatim: "✓").font(.system(size: 12, weight: .bold))
            Text("Granted").font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(t.ok)
        .padding(.horizontal, 15).padding(.vertical, 9)
        .background(t.ok.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    // MARK: - Icons (glyph tiles from the mock)

    private var micIcon: some View {
        VStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Mur.accent).frame(width: 12, height: 18)
            Rectangle().fill(t.muted(0.4)).frame(width: 2, height: 4)
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(t.muted(0.4)).frame(width: 13, height: 2)
        }
    }

    private var accessibilityIcon: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .strokeBorder(Mur.accent, lineWidth: 1.5)
            .frame(width: 30, height: 20)
            .overlay {
                VStack(spacing: 2.5) {
                    HStack(spacing: 2.5) {
                        ForEach(0 ..< 3, id: \.self) { _ in
                            Circle().fill(t.muted(0.5)).frame(width: 2.5, height: 2.5)
                        }
                    }
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(t.muted(0.5)).frame(width: 16, height: 2.5)
                }
            }
    }
}
