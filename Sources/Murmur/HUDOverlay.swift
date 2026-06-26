import AppKit
import Observation
import SwiftUI

/// Floating dictation HUD (design: MurMur.dc.html). A non-activating, click-through
/// borderless NSPanel (we type into another app's field at the same time) hosting a
/// SwiftUI glass pill that adapts to light/dark. Three states — listening,
/// transcribing (two-tier coloured text), error — plus a larger "presentation"
/// subtitle variant for HUD-only mode.

@Observable
final class HUDModel {
    enum Phase { case listening, transcribing, error }
    var phase: Phase = .listening
    var confirmed = ""
    var partial = ""
    var lang = "Auto"
    var errorText = "Open Privacy in Settings →"
    var presentation = false      // HUD-only / subtitles
    var recording = false
    var showStop = false          // toggle-mode: HUD shows a clickable Stop
    var onStop: () -> Void = {}
}

// MARK: - Building blocks

/// Animated orange level bars (the `murbar` keyframe: scaleY .32↔1, staggered).
private struct LevelBars: View {
    var color: Color
    var count: Int = 4
    var barHeight: CGFloat = 13
    @State private var up = false
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0 ..< count, id: \.self) { i in
                Capsule().fill(color)
                    .frame(width: 2.5, height: barHeight)
                    .scaleEffect(y: up ? 1 : 0.32, anchor: .center)
                    .animation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.12), value: up)
            }
        }
        .onAppear { up = true }
    }
}

/// Pulsing status dot (`murpulse`).
private struct PulseDot: View {
    var color: Color
    var size: CGFloat = 8
    @State private var on = false
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .opacity(on ? 0.4 : 1).scaleEffect(on ? 0.78 : 1)
            .animation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

private func catIcon(_ size: CGFloat) -> some View {
    Image("cat_fill").renderingMode(.original).resizable().scaledToFit()
        .frame(width: size, height: size)
}

// MARK: - HUD view

private struct HUDView: View {
    let model: HUDModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            switch model.phase {
            case .error:        errorPill
            case .listening:    listeningPill
            case .transcribing: transcribePill
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 30)
        .padding(.horizontal, 40)
    }

    // Header: cat + animated bars + language badge.
    private var header: some View {
        HStack(spacing: 10) {
            catIcon(18)
            LevelBars(color: Mur.accent, count: 4, barHeight: 13)
            Spacer(minLength: 8)
            Text(model.lang.uppercased())
                .font(.system(size: 10, weight: .medium)).tracking(0.4)
                .foregroundStyle(scheme == .dark ? Color.white.opacity(0.4) : Mur.ink.opacity(0.5))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(scheme == .dark ? Color.white.opacity(0.08) : Mur.ink.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            if model.showStop { stopButton }
        }
    }

    /// Clickable Stop (toggle mode). The panel accepts mouse events while this shows.
    private var stopButton: some View {
        Button(action: model.onStop) {
            Image(systemName: "stop.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(scheme == .dark ? Color.white.opacity(0.85) : Mur.ink.opacity(0.7))
                .frame(width: 22, height: 22)
                .background(Circle().fill(scheme == .dark ? Color.white.opacity(0.12) : Mur.ink.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    // Two-tier coloured transcript + blinking accent caret.
    private var transcribePill: some View {
        let big = model.presentation
        return VStack(alignment: .leading, spacing: big ? 12 : 9) {
            header
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                let on = Int(ctx.date.timeIntervalSinceReferenceDate / 0.5) % 2 == 0
                (transcript + Text("▏").foregroundStyle(Mur.accent.opacity(on ? 1 : 0)))
                    .font(.system(size: big ? 30 : 21))
                    .lineSpacing(big ? 8 : 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, big ? 24 : 16)
        .padding(.vertical, big ? 18 : 13)
        .frame(maxWidth: big ? 820 : 460, alignment: .leading)
        .murPill(scheme, radius: big ? 18 : 16, border: borderColor)
    }

    private var transcript: Text {
        let crisp = Mur.crisp(scheme), draft = Mur.draft(scheme)
        let conf = Self.words(model.confirmed)
        let part = Self.words(model.partial)
        var t = Text("")
        for (i, w) in conf.enumerated() {
            // Approximated "refine flash": the newest confirmed word glows accent.
            let hot = i == conf.count - 1
            t = t + Text(w).foregroundColor(hot ? Mur.accent : crisp).fontWeight(.medium) + Text(" ")
        }
        for w in part {
            t = t + Text(w).foregroundColor(draft).fontWeight(.regular) + Text(" ")
        }
        if conf.isEmpty, part.isEmpty {
            return Text("Listening…").foregroundColor(draft)
        }
        return t
    }

    private var listeningPill: some View {
        HStack(spacing: 13) {
            PulseDot(color: Mur.accent, size: 8)
            Text("Listening…").font(.system(size: 15))
                .foregroundStyle(scheme == .dark ? Color.white.opacity(0.92) : Mur.ink)
            LevelBars(color: Mur.accent, count: 5, barHeight: 16)
            if model.showStop { stopButton } else { hotkeyBadge }
        }
        .padding(.horizontal, 17).padding(.vertical, 11)
        .murPill(scheme, radius: 14, border: borderColor)
    }

    private var errorPill: some View {
        HStack(spacing: 12) {
            catIcon(22).overlay(alignment: .bottomTrailing) {
                Circle().fill(Mur.error).frame(width: 12, height: 12)
                    .overlay(Text("!").font(.system(size: 9, weight: .bold)).foregroundStyle(.white))
                    .offset(x: 4, y: 2)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("No microphone access").font(.system(size: 13, weight: .medium))
                    .foregroundStyle(scheme == .dark ? Color.white.opacity(0.95) : Mur.ink)
                Text(model.errorText).font(.system(size: 11.5))
                    .foregroundStyle(scheme == .dark ? Color.white.opacity(0.55) : Mur.ink.opacity(0.6))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .murPill(scheme, radius: 14, border: Mur.error.opacity(0.4))
    }

    private var hotkeyBadge: some View {
        Text("⌥ Space").font(.system(size: 11, design: .monospaced))
            .foregroundStyle(scheme == .dark ? Color.white.opacity(0.5) : Mur.ink.opacity(0.55))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(scheme == .dark ? Color.white.opacity(0.09) : Mur.ink.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private var borderColor: Color {
        scheme == .dark ? Color.white.opacity(0.1) : Mur.ink.opacity(0.1)
    }

    private static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    }
}

/// Glass-pill background: blurred material + warm tint + hairline border + shadow.
private extension View {
    func murPill(_ scheme: ColorScheme, radius: CGFloat, border: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .background(Mur.glass(scheme), in: shape)
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.strokeBorder(border, lineWidth: 1))
            .shadow(color: .black.opacity(scheme == .dark ? 0.42 : 0.18), radius: 22, y: 14)
    }
}

// MARK: - Panel controller

@MainActor
final class HUDController {
    private let model = HUDModel()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private let size = NSSize(width: 940, height: 260)

    /// Reveal the HUD for a new utterance. `interactive` (toggle mode) makes the
    /// panel accept clicks so the Stop button works.
    func begin(presentation: Bool, lang: String, interactive: Bool = false, onStop: @escaping () -> Void = {}) {
        hideWork?.cancel(); hideWork = nil
        let panel = ensurePanel()
        model.presentation = presentation
        model.lang = lang
        model.phase = .listening
        model.confirmed = ""; model.partial = ""
        model.recording = true
        model.showStop = interactive
        model.onStop = onStop
        panel.ignoresMouseEvents = !interactive
        position(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 }
    }

    /// Live two-tier update.
    func update(confirmed: String, partial: String) {
        model.confirmed = confirmed
        model.partial = partial
        if model.phase != .error {
            model.phase = (confirmed.isEmpty && partial.isEmpty) ? .listening : .transcribing
        }
    }

    /// Surface a mic/permission error in the HUD.
    func error(_ text: String) {
        let panel = ensurePanel()
        model.phase = .error
        if !text.isEmpty { model.errorText = text }
        model.recording = false
        position(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 }
        scheduleHide(after: 3.2)
    }

    /// Show the final text, then fade — lingering longer in presentation mode.
    func finish(_ finalText: String) {
        guard panel != nil else { return }
        model.recording = false
        model.showStop = false
        if !finalText.isEmpty {
            model.confirmed = finalText; model.partial = ""; model.phase = .transcribing
        }
        scheduleHide(after: model.presentation ? 4.0 : 1.0)
    }

    private func scheduleHide(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func fadeOut() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 },
                                             completionHandler: { panel.orderOut(nil) })
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        let host = NSHostingView(rootView: HUDView(model: model))
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let v = screen.visibleFrame
        panel.setFrame(NSRect(x: v.midX - size.width / 2, y: v.minY + 24,
                              width: size.width, height: size.height), display: true)
    }
}
