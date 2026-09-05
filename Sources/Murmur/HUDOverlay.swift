import AppKit
import MurmurKit
import Observation
import SwiftUI

/// Floating dictation HUD (design: MurMur.dc.html). A non-activating, click-through
/// borderless NSPanel (we type into another app's field at the same time) hosting a
/// SwiftUI glass pill that adapts to light/dark. Three states — listening,
/// transcribing (two-tier coloured text), error.
///
/// Room-scale subtitles are deliberately NOT a variant of this panel: they need
/// geometry derived from the target screen, an opaque backdrop and a session that
/// outlives one utterance. See the conference-captions design.

@Observable
final class HUDModel {
    /// `finalizing` is the gap between the stop gesture and the corrected text:
    /// the microphone is already off, so the level bars must stop with it.
    enum Phase { case listening, transcribing, finalizing, finished, error }
    var phase: Phase = .listening
    var confirmed = ""
    var partial = ""
    var lang = "Auto"
    var errorText = "Open Privacy in Settings →"
    var truncated = false         // older words were dropped — the view leads with an ellipsis
    var submits = false           // this utterance ends with Return
    var recording = false
    var showStop = false          // toggle-mode: HUD shows a clickable Stop
    var shortcutLabel = ""
    /// Two-line translate mode. Empty means the mode is off or the translation
    /// has not arrived, and the pill stays one line — the row is not reserved,
    /// so plain dictation looks exactly as it did.
    var translation = ""
    /// Whether `translation` came from the CTranslate2 quality engine rather
    /// than the fast fallback. Purely informational - the same text is pasted
    /// either way - so it drives a small label, not a layout change.
    var translationIsQuality = false
    /// The translation is being produced. Shown as its own line so the pill
    /// does not resize twice: once for the placeholder, once for the text.
    var translating = false
    /// Single source of truth for "is the second line on screen right now" -
    /// shared by the view (whether to render `translationLine`) and the panel
    /// (whether to reserve the extra height it needs), so the two can never
    /// drift into a window sized for one answer while the view renders the
    /// other.
    var showsTranslationRow: Bool { !translation.isEmpty || translating }
    /// The language being translated into, as a badge tag ("EN"), or empty
    /// when the mode is off. The design pairs it with `lang` as
    /// `{{ langTag }} → {{ targetTag }}`: the second line is much easier to
    /// read as deliberate once the header says where it is going.
    var target = ""
    var onStop: () -> Void = {}
}

/// How much text the pill can hold, derived from its own geometry: a 460pt column
/// at 21pt fits ~36 characters per line, and 230pt of usable panel height at 31pt
/// per line fits 5. The character budget targets one line LESS, which is what keeps
/// `maxLines` an emergency guard instead of a routine truncation. Recompute both
/// together if the font, the column width or the panel size changes.
enum HUDCapacity {
    static let maxChars = 145
    static let maxLines = 5
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

// MARK: - HUD view

private struct HUDView: View {
    let model: HUDModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            switch model.phase {
            case .error:        mascotBubble(.error) { errorPill }
            case .listening:    mascotBubble(.listening) { listeningPill }
            case .transcribing: mascotBubble(.transcribing) { transcribePill }
            // Same face as live decoding: the work is the same, only the audio has
            // stopped arriving. A dedicated mascot state can slot in here.
            case .finalizing:   mascotBubble(.transcribing) { transcribePill }
            case .finished:     mascotBubble(.success) { transcribePill }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 30)
        .padding(.horizontal, 40)
    }

    // Header: animated bars + language badge; the mascot overlaps the pill edge.
    private var header: some View {
        HStack(spacing: 10) {
            // Bars mean "we are hearing you". Once the microphone is off they would
            // be a lie, so the same slot carries the wait instead.
            if model.phase == .finalizing {
                Text("Finalizing…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Mur.accent)
            } else {
                LevelBars(color: Mur.accent, count: 4, barHeight: 13)
            }
            Spacer(minLength: 8)
            if model.submits { submitBadge }
            langBadge
            if model.showStop { stopButton }
        }
    }

    /// `RU` alone, or `RU → EN` while translating, with the target in accent.
    ///
    /// The arrow is what makes the second line legible as a translation rather
    /// than as a stray grey paragraph, so it is the badge - not the type - that
    /// carries the explanation. Accent is safe on the target tag: it sits in
    /// the header, far from the transcript's newest-word flash, so the two
    /// never merge into one block the way an accent-coloured second line did.
    private var langBadge: some View {
        let translating = !model.target.isEmpty
        return HStack(spacing: 5) {
            Text(model.lang.uppercased())
            if translating {
                Text("\u{2192}").opacity(0.5)
                Text(model.target.uppercased()).foregroundStyle(Mur.accent)
            }
        }
        .font(.system(size: 10, weight: .medium)).tracking(0.4)
        .foregroundStyle(scheme == .dark
                         ? Color.white.opacity(translating ? 0.45 : 0.4)
                         : Mur.ink.opacity(0.5))
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(scheme == .dark ? Color.white.opacity(0.08) : Mur.ink.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
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
        let translating = model.showsTranslationRow
        return VStack(alignment: .leading, spacing: 9) {
            header
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                let on = Int(ctx.date.timeIntervalSinceReferenceDate / 0.5) % 2 == 0
                // The caret means "more is still coming here". In translate mode
                // the live edge is the second line, so a caret on the first one
                // points at the wrong place - the design drops it there, and
                // shrinks this line 21 -> 20 to give the translation its room.
                (translating
                 ? transcript
                 : transcript + Text("▏").foregroundStyle(Mur.accent.opacity(on ? 1 : 0)))
                    .font(.system(size: translating ? 20 : 21))
                    .lineSpacing(6)
                    // Hard layout guard behind the character clamp: whatever slips past
                    // the estimate, the text still cannot outgrow the panel.
                    .lineLimit(HUDCapacity.maxLines)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if translating {
                translationLine
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: 460, alignment: .leading)
        .murPill(scheme, radius: 16, border: borderColor)
    }

    /// The translation, under a hairline separator.
    ///
    /// Per MurMur.dc.html's "Live translation" block: `400 17px/1.5` in
    /// `rgba(255,255,255,.66)`, under a `rgba(255,255,255,.1)` rule with 11pt
    /// of air either side. The hierarchy against the 20pt/500 transcript is
    /// deliberate - this line is what the machine made of what you said, and
    /// the header's `RU → EN` badge, not the type, is what explains it.
    /// No accent here either: accent marks the newest confirmed word directly
    /// above, and painting the translation with it merged the two into a
    /// single orange block.
    private var translationLine: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Mur.hairline(scheme))
                .frame(height: 1)
                // 9 from the enclosing VStack + 2 = the design's 11 above the
                // rule; 11 below it.
                .padding(.top, 2)
                .padding(.bottom, 11)
            if model.translating {
                Text("Translating\u{2026}")
                    .font(.system(size: 15))
                    .foregroundStyle(Mur.draft(scheme))
            } else {
                Text(model.translation)
                    .font(.system(size: 17))
                    .lineSpacing(5)
                    .foregroundStyle(Mur.secondary(scheme))
                    .lineLimit(HUDCapacity.maxLines)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                // Quiet by design: it says which engine won, not that the fast
                // one is somehow inferior - most directions have no quality
                // model at all, and that is the ordinary case, not a warning.
                if model.translationIsQuality {
                    Text("Quality translation")
                        .font(.system(size: 11))
                        .foregroundStyle(Mur.draft(scheme))
                        .padding(.top, 7)
                }
            }
        }
    }

    private var transcript: Text {
        let crisp = Mur.crisp(scheme), draft = Mur.draft(scheme)
        let conf = Self.words(model.confirmed)
        let part = Self.words(model.partial)
        // The marker is styling, not content: kept out of `model.confirmed` so it
        // can't be counted as a word and steal the newest-word accent below.
        var t = model.truncated ? Text("… ").foregroundColor(draft) : Text("")
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
            if model.submits { submitBadge }
            if model.showStop { stopButton } else { hotkeyBadge }
        }
        .padding(.horizontal, 17).padding(.vertical, 11)
        .murPill(scheme, radius: 14, border: borderColor)
    }

    private var errorPill: some View {
        HStack(spacing: 12) {
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

    private func mascotBubble<Content: View>(
        _ mood: DictatorMascotMood,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack(alignment: .topLeading) {
            content()
            mascotBadge(mood).offset(x: -38, y: -38)
        }
        .padding(.leading, 38)
        .padding(.top, 38)
    }

    private func mascotBadge(_ mood: DictatorMascotMood) -> some View {
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
        return DictatorMascot(mood: mood, size: 42)
            .padding(4)
            .background(Mur.glass(scheme), in: shape)
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.strokeBorder(mood == .error ? Mur.error.opacity(0.4) : borderColor,
                                        lineWidth: 1))
            .shadow(color: .black.opacity(scheme == .dark ? 0.38 : 0.16), radius: 10, y: 6)
            .overlay(alignment: .bottomTrailing) {
                if mood == .error {
                    Circle().fill(Mur.error).frame(width: 12, height: 12)
                        .overlay(Text("!").font(.system(size: 9, weight: .bold)).foregroundStyle(.white))
                        .offset(x: 3, y: 2)
                }
            }
    }

    /// Marks an utterance that will press Return when it lands. Two shortcuts only
    /// work if you can see which one you're holding, and this is the one moment the
    /// mistake is still catchable — before the message is sent.
    private var submitBadge: some View {
        Text("⏎").font(.system(size: 11, weight: .medium))
            .foregroundStyle(Mur.accent)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Mur.accent.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .accessibilityLabel(Text("Will press Return when finished"))
    }

    private var hotkeyBadge: some View {
        Text("Release \(model.shortcutLabel)").font(.system(size: 11, design: .monospaced))
            .foregroundStyle(scheme == .dark ? Color.white.opacity(0.5) : Mur.ink.opacity(0.55))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(scheme == .dark ? Color.white.opacity(0.09) : Mur.ink.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .accessibilityLabel(Text("Release \(model.shortcutLabel) to finish"))
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
    // Not private: MurmurTests reads it via @testable import to catch state
    // (like the quality-translation label) leaking across sessions - a real
    // regression here reads as an obviously wrong label on screen, which is
    // exactly the kind of bug a test should catch before a person does.
    let model = HUDModel()
    private var panel: NSPanel?
    // Not private: a test confirms the panel actually grows to fit a
    // translation row rather than clipping it - the exact defect a live
    // screenshot caught, where the fixed-height panel clipped the
    // translation's last line at the window edge.
    var panelSize: CGSize? { panel?.frame.size }
    private var hideWork: DispatchWorkItem?
    private static let baseSize = NSSize(width: 940, height: 260)
    /// Extra room the translation row needs at its worst case: the hairline,
    /// the 11pt of air either side of it, up to `HUDCapacity.maxLines` lines
    /// at the translation's own 17pt/1.5 (25.5pt each, per the design), and
    /// the "Quality translation" label with its 7pt gap: 2 + 1 + 11 + 127.5 +
    /// 20 = 161.5, rounded up. `baseSize` was sized for the transcript alone -
    /// see `HUDCapacity`'s doc comment for that derivation - so a translation
    /// showing needs this added on top of it, not instead of it. Kept tight
    /// rather than generously over-reserved because in toggle mode the panel
    /// takes mouse events (`ignoresMouseEvents = !interactive`), so spare
    /// height is not free: it would swallow clicks above the pill.
    private static let translationExtraHeight: CGFloat = 165
    /// `baseSize` plus room for the translation row exactly when one is on
    /// screen (`HUDModel.showsTranslationRow`), so plain dictation keeps the
    /// panel it always had and nothing is clipped when a second line joins
    /// it. Read fresh rather than cached: it must reflect `model` at the
    /// moment a resize actually happens, not whatever it was when the panel
    /// was first created.
    private var currentSize: NSSize {
        NSSize(width: Self.baseSize.width,
               height: Self.baseSize.height + (model.showsTranslationRow ? Self.translationExtraHeight : 0))
    }

    /// Reveal the HUD for a new utterance. `interactive` (toggle mode) makes the
    /// panel accept clicks so the Stop button works.
    func begin(lang: String, target: String = "", interactive: Bool = false, submits: Bool = false,
               shortcutLabel: String = "", onStop: @escaping () -> Void = {}) {
        hideWork?.cancel(); hideWork = nil
        let panel = ensurePanel()
        model.lang = lang
        model.target = target
        model.submits = submits
        model.shortcutLabel = shortcutLabel
        model.phase = .listening
        show(confirmed: "", partial: "")      // also clears a carried-over ellipsis
        // A translation left from the previous utterance under a fresh one
        // would read as a translation of it - and the quality label would
        // misdescribe it too, since captions never use the quality engine.
        model.translation = ""
        model.translationIsQuality = false
        model.translating = false
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
    /// The rolling translation of a caption session.
    ///
    /// Separate from `finish(_:delivery:translation:)` because captions have no
    /// finish: the second line is rewritten as phrases close, for as long as
    /// the talk runs. Clearing it when it goes empty means switching translation
    /// off mid-session takes the line away rather than freezing the last value
    /// on screen.
    /// Repoint the header badge mid-talk.
    ///
    /// `begin` stamps the target once, which is enough for dictation - one
    /// utterance, one setting. Captions run for as long as the talk does and
    /// the picker stays live throughout, so the badge has to follow it: a
    /// header reading `RU → EN` over German, or over a second line that
    /// translation was just switched off for, is a promise the pill no longer
    /// keeps. `""` means "no target", which drops the arrow entirely.
    func setTranslationTarget(_ target: String) {
        guard panel != nil else { return }
        model.target = target
    }
    func showTranslation(_ text: String) {
        model.translating = false
        model.translation = text
        // Captions only ever run the fast engine (CaptionTranslator has no
        // quality path) - explicit here rather than relying on `begin` having
        // zeroed it once, so a caption session can never show a label a
        // previous dictation utterance left set.
        model.translationIsQuality = false
        resizeForCurrentTranslationState()
    }

    func update(confirmed: String, partial: String) {
        show(confirmed: confirmed, partial: partial)
        if model.phase != .error, model.recording {
            model.phase = (model.confirmed.isEmpty && model.partial.isEmpty) ? .listening : .transcribing
        }
    }

    /// The single door into the model's text — both entry points clamp through here,
    /// so what reaches the view is already known to fit the panel.
    private func show(confirmed: String, partial: String) {
        let fitted = HUDTranscript.clamped(confirmed: confirmed, partial: partial,
                                           maxChars: HUDCapacity.maxChars)
        model.confirmed = fitted.confirmed
        model.partial = fitted.partial
        model.truncated = fitted.truncated
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

    /// The stop gesture landed; the corrected text is still being decoded. The mic
    /// is off, so stop pretending to listen and say what is happening instead.
    func finalizing() {
        guard panel != nil else { return }
        hideWork?.cancel(); hideWork = nil
        model.recording = false
        model.showStop = false
        model.phase = .finalizing
    }

    /// The transcript is ready and the translation is not. Shown as its own
    /// state because translating a long utterance takes long enough to notice,
    /// and a pill that simply sat there would read as finished-but-wrong.
    func translating() {
        guard panel != nil else { return }
        model.translating = true
        resizeForCurrentTranslationState()
    }

    /// End the presentation according to what happened to the transcript. An
    /// explicit stop dismisses at once; only undelivered text earns a wait.
    func finish(_ finalText: String, delivery: TranscriptDelivery, translation: String = "",
               translationIsQuality: Bool = false) {
        guard panel != nil else { return }
        model.recording = false
        model.showStop = false
        let policy = StopPresentation.policy(for: delivery, textIsEmpty: finalText.isEmpty)
        model.translating = false
        model.translation = translation
        model.translationIsQuality = translationIsQuality
        resizeForCurrentTranslationState()
        if policy.showsText, !finalText.isEmpty {
            show(confirmed: finalText, partial: "")
            model.phase = .finished
            if let message = policy.message { model.errorText = message }
        }
        guard policy.linger > 0 else { return dismiss() }
        scheduleHide(after: policy.linger)
    }

    /// Fade now, cancelling any pending hide.
    func dismiss() {
        hideWork?.cancel(); hideWork = nil
        fadeOut()
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
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: currentSize),
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
        host.frame = NSRect(origin: .zero, size: currentSize)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        self.panel = panel
        return panel
    }

    /// Height only, growing upward: the panel's bottom-left origin (AppKit's
    /// frame is bottom-anchored) is exactly where the pill's own
    /// `alignment: .bottom` already sits it, so changing only `size.height`
    /// and leaving `origin` alone extends the frame upward without moving
    /// the pill or re-querying which screen it belongs on. `position(_:)`
    /// does the fuller job (screen + both axes) for a new utterance;
    /// mid-utterance the translation row can arrive or clear on its own, and
    /// re-running the screen lookup then - the cursor may since have moved
    /// to a different display - would be a surprising reason for the panel
    /// to jump.
    private func resizeForCurrentTranslationState() {
        guard let panel else { return }
        var frame = panel.frame
        frame.size.height = currentSize.height
        panel.setFrame(frame, display: true)
    }

    private func position(_ panel: NSPanel) {
        guard let screen = Self.targetScreen() else { return }
        let v = screen.visibleFrame
        let size = currentSize
        panel.setFrame(NSRect(x: v.midX - size.width / 2, y: v.minY + 24,
                              width: size.width, height: size.height), display: true)
    }

    /// `NSScreen.main` is the screen holding the key window — but this app never has
    /// one (the panel is `.nonactivatingPanel` and we stay an `.accessory` agent), so
    /// on a multi-display setup it is not deterministic. The cursor is where the user
    /// is working, and it costs no Accessibility round-trip to ask.
    private static func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? .main ?? NSScreen.screens.first
    }
}
