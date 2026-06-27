import SwiftUI

/// Step 4 — Try it (design: MurMur Onboarding.dc.html STEP 4). A real in-window
/// Hybrid dictation: hold the button, speak, and the two-tier transcript streams
/// into our own bordered field (no Accessibility needed — it's our field). The
/// field reuses the HUD colour rule (confirmed crisp + newest-word accent flash,
/// partial in draft). Releasing flushes the final and marks `flow.didTry`, which
/// unlocks Continue. Leaving the step stops the session and restores the
/// controller's HUD handler (`model.tryEnd()` is idempotent).
struct TryItScreen: View {
    @Bindable var model: OnboardingModel
    @Environment(\.colorScheme) private var scheme

    /// Local press latch so the drag gesture fires `tryStart` once on press and
    /// `tryEnd` once on release, regardless of intermediate `.onChanged` ticks.
    @State private var pressed = false

    private var t: OnTheme { OnTheme(scheme) }
    private var ready: Bool { model.tryReady }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Try it")
                    .tracking(1.4).murFont(11, weight: .bold)
                    .foregroundStyle(Mur.accent)
                Text("Give me a sentence")
                    .murFont(32, weight: .semibold, design: .serif)
                    .foregroundStyle(t.ink).padding(.top, 10)
                Text("Hold the button below and say anything. Watch the fast draft appear, then sharpen a blink later — that’s the two models working together.")
                    .murFont(14.5).lineSpacing(4)
                    .foregroundStyle(t.muted(0.66))
                    .frame(maxWidth: 444, alignment: .leading).padding(.top, 11)
            }

            testField.padding(.top, 22)
            statusLine.padding(.top, 14)
            holdButton.padding(.top, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Leaving the step (Continue while held, Back, or window close) must stop
        // the session AND restore the controller's onUpdate — tryEnd does both and
        // is a no-op when not listening.
        .onDisappear { model.tryEnd() }
    }

    // MARK: - Bordered test field (two-tier transcript)

    private var testField: some View {
        VStack(alignment: .leading, spacing: 0) {
            transcript
                .font(.system(size: 18)).lineSpacing(6)
                .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.init(top: 18, leading: 18, bottom: 18, trailing: 18))
        .background(t.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(model.tryListening ? Mur.accent : Mur.accent.opacity(0.35),
                              lineWidth: model.tryListening ? 2 : 1.5))
    }

    /// Two-tier coloured transcript, identical rule to the HUD: confirmed words in
    /// crisp ink with the newest one flashing accent, provisional words in draft.
    /// Empty → placeholder.
    private var transcript: Text {
        let crisp = Mur.crisp(scheme), draft = Mur.draft(scheme)
        let conf = Self.words(model.tryConfirmed)
        let part = Self.words(model.tryPartial)
        if conf.isEmpty, part.isEmpty {
            return Text("Hold the button below and speak…").foregroundColor(draft)
        }
        var out = Text("")
        for (i, w) in conf.enumerated() {
            let hot = i == conf.count - 1
            out = out + Text(w).foregroundColor(hot ? Mur.accent : crisp).fontWeight(.medium) + Text(" ")
        }
        for w in part {
            out = out + Text(w).foregroundColor(draft).fontWeight(.regular) + Text(" ")
        }
        return out
    }

    // MARK: - Status line

    @ViewBuilder private var statusLine: some View {
        if model.tryListening {
            label("Listening…", color: Mur.accent)
        } else if model.flow.didTry {
            HStack(spacing: 12) {
                label("Got it — that’s exactly what I said.", color: t.ok)
                Button { model.tryReset() } label: {
                    Text("Try again")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Mur.accent)
                }
                .buttonStyle(.plain)
            }
        } else if !ready {
            label("Warming up the models…", color: t.muted(0.5))
        } else {
            label("Ready when you are.", color: t.muted(0.5))
        }
    }

    private func label(_ key: LocalizedStringKey, color: Color) -> some View {
        Text(key).murFont(13, weight: .medium).foregroundStyle(color)
    }

    // MARK: - Hold-to-talk button

    private var holdButton: some View {
        HStack(spacing: 11) {
            if model.tryListening {
                LevelBars(color: OnTheme.rgb(26, 18, 12))
                Text("Listening…").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(OnTheme.rgb(26, 18, 12))
            } else {
                Text("Hold to talk").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ready ? OnTheme.rgb(26, 18, 12) : t.muted(0.4))
            }
        }
        .padding(.horizontal, 22).frame(height: 46)
        .background(buttonFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .scaleEffect(pressed ? 0.97 : 1)
        .animation(.easeOut(duration: 0.12), value: pressed)
        .gesture(holdGesture)
        .disabled(!ready)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Hold to talk")
        .accessibilityHint(ready
            ? "Double-tap to start dictation, double-tap again to stop"
            : "Models are still loading")
        .accessibilityValue(model.tryListening ? "Listening" : "")
        .accessibilityAction { if ready { model.tryToggle() } }
    }

    private var buttonFill: AnyShapeStyle {
        guard ready else { return AnyShapeStyle(t.line(0.1)) }
        return AnyShapeStyle(model.tryListening ? Mur.accent : Mur.accent.opacity(0.92))
    }

    /// Press-and-hold: `.onChanged` (first tick) latches `pressed` and starts the
    /// dictation once; `.onEnded` (release) clears it and ends once. `minimumDistance:
    /// 0` makes a simple press register without needing to drag.
    private var holdGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard ready, !pressed else { return }
                pressed = true
                model.tryStart()
            }
            .onEnded { _ in
                guard pressed else { return }
                pressed = false
                model.tryEnd()
            }
    }

    private static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    }
}

/// Animated level bars for the listening button (mirrors the HUD's `murbar`).
private struct LevelBars: View {
    var color: Color
    var count: Int = 4
    var barHeight: CGFloat = 14
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var up = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0 ..< count, id: \.self) { i in
                Capsule().fill(color)
                    .frame(width: 2.5, height: barHeight)
                    .scaleEffect(y: (up || reduceMotion) ? 1 : 0.32, anchor: .center)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.45).repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.12), value: up)
            }
        }
        .accessibilityHidden(true)   // decorative meter
        .onAppear { up = true }
    }
}
