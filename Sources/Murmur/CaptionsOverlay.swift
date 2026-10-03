import AppKit
import Observation
import QuartzCore
import SwiftUI

/// Three lines per language, using smaller type to leave the presentation visible.
struct CaptionsLayout: Equatable {
    let fontSize: CGFloat
    let translationFontSize: CGFloat
    let fontFamily: String
    let bandWidth: CGFloat
    let transcriptLines: Int
    let translationLines: Int
    let padding: CGFloat
    let bottomInset: CGFloat
    private let customHeight: CGFloat?

    init(screen: CGSize, translating: Bool, appearance: CaptionsAppearance = CaptionsAppearance(), size: CGSize? = nil) {
        fontSize = appearance.pointSize(screenHeight: screen.height)
        translationFontSize = (fontSize * 0.92).rounded()
        fontFamily = appearance.fontFamily
        bandWidth = size?.width ?? (screen.width * 0.8).rounded()
        padding = max(6, (fontSize * 0.25).rounded())
        bottomInset = (screen.height * 0.05).rounded()
        customHeight = size?.height
        let gap = (padding * 0.6).rounded()
        let original = Self.trackHeight(lines: 3, size: fontSize, family: fontFamily)
        let translated = translating ? Self.trackHeight(lines: 3, size: translationFontSize, family: fontFamily) : 0
        let available = max(original + translated, (size?.height ?? 0) - padding * 2 - (translating ? gap : 0))
        let share = translating ? original / (original + translated) : 1
        func lines(height: CGFloat, font: CGFloat) -> Int {
            let spacing = Self.lineSpacing(font)
            let line = Self.trackHeight(lines: 1, size: font, family: appearance.fontFamily)
            return max(3, Int((height + spacing) / (line + spacing)))
        }
        transcriptLines = lines(height: available * share, font: fontSize)
        translationLines = translating ? lines(height: available * (1 - share), font: translationFontSize) : 0
    }

    var trackGap: CGFloat { (padding * 0.6).rounded() }
    static func lineSpacing(_ size: CGFloat) -> CGFloat { (size * 0.12).rounded() }

    static func trackHeight(lines: Int, size: CGFloat, family: String = "") -> CGFloat {
        guard lines > 0 else { return 0 }
        let font = CaptionsAppearance.font(size: size, family: family)
        let line = ceil(font.ascender - font.descender + font.leading)
        return CGFloat(lines) * line + CGFloat(lines - 1) * lineSpacing(size)
    }

    var minimumSize: CGSize {
        var height = padding * 2 + Self.trackHeight(lines: 3, size: fontSize, family: fontFamily)
        if translationLines > 0 {
            height += trackGap + Self.trackHeight(lines: 3, size: translationFontSize, family: fontFamily)
        }
        return CGSize(width: 320, height: ceil(height))
    }

    var bandSize: CGSize {
        CGSize(width: bandWidth, height: max(minimumSize.height, customHeight ?? 0))
    }
}

/// An edit in the OLD string's UTF-16 coordinates. Apply edits back to front.
struct CaptionsTextEdit: Equatable {
    let range: NSRange
    let replacement: String
}

enum CaptionsTextDiff {
    static func edits(from old: String, to new: String) -> [CaptionsTextEdit] {
        // Trim the shared history before diffing. Boundaries are grapheme-safe;
        // literal UTF-16 equality also distinguishes é from e + combining acute.
        var oldStart = old.startIndex, newStart = new.startIndex
        while oldStart < old.endIndex, newStart < new.endIndex {
            let a = old.index(after: oldStart), b = new.index(after: newStart)
            guard old[oldStart..<a].utf16.elementsEqual(new[newStart..<b].utf16) else { break }
            oldStart = a; newStart = b
        }
        var oldEnd = old.endIndex, newEnd = new.endIndex
        while oldEnd > oldStart, newEnd > newStart {
            let a = old.index(before: oldEnd), b = new.index(before: newEnd)
            guard old[a..<oldEnd].utf16.elementsEqual(new[b..<newEnd].utf16) else { break }
            oldEnd = a; newEnd = b
        }
        let oldMiddle = old[oldStart..<oldEnd], newMiddle = new[newStart..<newEnd]
        guard !oldMiddle.isEmpty || !newMiddle.isEmpty else { return [] }
        let base = oldStart.utf16Offset(in: old)
        let replacement = CaptionsTextEdit(range: NSRange(location: base, length: oldMiddle.utf16.count),
                                          replacement: String(newMiddle))
        // Appends and clears need no alignment. A wholesale replacement of an
        // unusually large transcript must also stay bounded on the main thread.
        guard !oldMiddle.isEmpty, !newMiddle.isEmpty,
              oldMiddle.utf16.count <= 4096, newMiddle.utf16.count <= 4096 else { return [replacement] }
        let before = oldMiddle.map(String.init), after = newMiddle.map(String.init)
        guard before.count * after.count <= 1_000_000 else { return [replacement] }
        let difference = after.difference(from: before) { $0.utf16.elementsEqual($1.utf16) }
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        var offsets = [base]
        for character in before { offsets.append(offsets.last! + character.utf16.count) }
        var edits: [CaptionsTextEdit] = []
        var i = 0, j = 0
        while i < before.count || j < after.count {
            if removed.contains(i) || inserted.contains(j) {
                let start = i, replacementStart = j
                while removed.contains(i) { i += 1 }
                while inserted.contains(j) { j += 1 }
                edits.append(CaptionsTextEdit(
                    range: NSRange(location: offsets[start], length: offsets[i] - offsets[start]),
                    replacement: after[replacementStart..<j].joined()
                ))
            } else {
                // A matching island stays in NSTextStorage with its attributes.
                i += 1; j += 1
            }
        }
        return edits
    }
}

@MainActor
@Observable
final class CaptionsOverlayModel {
    var appearance = CaptionsAppearance()
    var editing = false
    var confirmed = ""
    var partial = ""
    var translation = ""
    /// Badge tag of the translation language, or `""` when the talk is not
    /// translated — which also takes the translation track off the band.
    var target = ""
    var layout = CaptionsLayout(screen: CGSize(width: 1920, height: 1080), translating: false)
}

/// Stable native text layout with a smoothly scrolling viewport. Keeping the
/// prefix is intentional: cutting an arbitrary word off the head rewraps every
/// visible line. TextKit receives only diff hunks, preserving matching text when
/// the accurate lane corrects the fast draft in several places at once.
@MainActor
final class CaptionsTextView: NSView {
    let clipView = NSClipView()
    let textView = NSTextView()
    private var fontSize: CGFloat = 0
    private var fontFamily = ""
    private var ink = NSColor.white
    private var confirmedLength = 0
    private var scrollTarget: CGFloat = 0
    private var scrollGeneration = 0
    private var hasText = false
    var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        clipView.drawsBackground = false
        clipView.wantsLayer = true
        addSubview(clipView)
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = false
        textView.isRichText = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        clipView.documentView = textView
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(confirmed: String, partial: String, size: CGFloat, color: NSColor, family: String = "") {
        guard let storage = textView.textStorage else { return }
        let separator = confirmed.isEmpty || partial.isEmpty ? "" : " "
        let empty = confirmed.isEmpty && partial.isEmpty
        let text = empty ? "…" : confirmed + separator + partial
        let newConfirmedLength = (confirmed as NSString).length
        let styleChanged = fontSize != size || ink != color || fontFamily != family
        let wasEmpty = !hasText
        hasText = !empty
        let edits = CaptionsTextDiff.edits(from: storage.string, to: text)
        guard !edits.isEmpty || confirmedLength != newConfirmedLength || styleChanged else { return }
        storage.beginEditing()
        for edit in edits.reversed() {
            storage.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        fontSize = size
        fontFamily = family
        ink = color
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = CaptionsLayout.lineSpacing(size)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: CaptionsAppearance.font(size: size, family: family),
            .paragraphStyle: paragraph,
            .foregroundColor: color,
        ]
        if styleChanged {
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        } else {
            var delta = 0
            for edit in edits {
                let length = edit.replacement.utf16.count
                storage.setAttributes(attributes, range: NSRange(location: edit.range.location + delta, length: length))
                delta += length - edit.range.length
            }
        }
        // Promotion may move the boundary even without any text edits. Change
        // color only; do not replace the matching draft or erase its attributes.
        if newConfirmedLength > 0 {
            storage.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: newConfirmedLength))
        }
        if newConfirmedLength < storage.length {
            storage.addAttribute(.foregroundColor, value: color.withAlphaComponent(0.72),
                                 range: NSRange(location: newConfirmedLength, length: storage.length - newConfirmedLength))
        }
        confirmedLength = newConfirmedLength
        storage.endEditing()
        positionText(animated: !wasEmpty && !empty && !styleChanged)
    }

    override func layout() {
        super.layout()
        guard clipView.frame != bounds else { return }
        clipView.frame = bounds
        positionText(animated: false)
    }

    private func positionText(animated: Bool) {
        guard bounds.width > 0,
              let container = textView.textContainer,
              let manager = textView.layoutManager else { return }
        let containerSize = CGSize(width: bounds.width, height: .greatestFiniteMagnitude)
        if container.containerSize != containerSize { container.containerSize = containerSize }
        manager.ensureLayout(for: container)
        let height = max(bounds.height, ceil(manager.usedRect(for: container).height))
        // A corrected draft can get shorter. Shrinking the document immediately
        // makes NSClipView clamp its bounds, bypassing the scroll animation.
        textView.setFrameSize(CGSize(width: bounds.width, height: max(height, clipView.bounds.maxY)))
        let target = max(0, height - bounds.height)
        guard target != scrollTarget || !animated else { return }
        scrollTarget = target
        scrollGeneration &+= 1
        let generation = scrollGeneration
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = animated && !reduceMotion ? 0.28 : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            clipView.animator().setBoundsOrigin(CGPoint(x: 0, y: target))
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.scrollGeneration == generation else { return }
                self.textView.setFrameSize(CGSize(width: self.bounds.width, height: height))
            }
        })
    }
}

private struct CaptionsTrack: NSViewRepresentable {
    let confirmed: String
    var partial = ""
    let size: CGFloat
    var color = NSColor.white
    var family = ""

    func makeNSView(context: Context) -> CaptionsTextView { CaptionsTextView() }

    func updateNSView(_ view: CaptionsTextView, context: Context) {
        view.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        view.update(confirmed: confirmed, partial: partial, size: size, color: color, family: family)
    }
}

private struct CaptionsOverlayView: View {
    let model: CaptionsOverlayModel
    let onFrameChange: (NSRect) -> Void
    let onLock: () -> Void

    var body: some View {
        let layout = model.layout
        let appearance = model.appearance
        VStack(alignment: .leading, spacing: layout.trackGap) {
            CaptionsTrack(confirmed: model.confirmed, partial: model.partial, size: layout.fontSize,
                          color: appearance.textColor.nsColor, family: appearance.fontFamily)
                .frame(height: CaptionsLayout.trackHeight(lines: layout.transcriptLines, size: layout.fontSize, family: layout.fontFamily))
            if layout.translationLines > 0 {
                CaptionsTrack(confirmed: model.translation, size: layout.translationFontSize,
                              color: appearance.translationColor.nsColor, family: appearance.fontFamily)
                    .frame(height: CaptionsLayout.trackHeight(lines: layout.translationLines, size: layout.translationFontSize, family: layout.fontFamily))
            }
        }
        .padding(layout.padding)
        .frame(width: layout.bandSize.width, height: layout.bandSize.height, alignment: .topLeading)
        .background(Color(nsColor: appearance.backgroundColor.nsColor).opacity(appearance.backgroundOpacity),
                    in: RoundedRectangle(cornerRadius: layout.padding * 0.5, style: .continuous))
        .overlay {
            if model.editing {
                CaptionsInteractionSurface(minimumSize: layout.minimumSize, onChange: onFrameChange)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.cyan, style: StrokeStyle(lineWidth: 2, dash: [6, 4])).allowsHitTesting(false))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if model.editing {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                    .padding(5).background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
                    .accessibilityLabel("Resize captions")
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.editing {
                Button("Done", action: onLock).buttonStyle(.borderedProminent).padding(5)
            }
        }
    }
}

/// The captions surface: one click-through band on the chosen screen for the
/// whole talk. Separate from `HUDController` by design — the HUD is a progress
/// indicator for one utterance, this is the result itself.
@MainActor
final class CaptionsOverlay {
    // Not private: tests assert on what the band shows and where it sits.
    let model = CaptionsOverlayModel()
    let preferences: CaptionsPreferences
    private var previewing = false
    private var layoutScreen: NSScreen?
    var panelFrame: NSRect? { panel?.frame }
    var acceptsInteraction: Bool { panel?.ignoresMouseEvents == false }
    private var panel: NSPanel?
    /// `CaptionsDisplay` value; the picker stays live, so this can change mid-talk.
    private var display = CaptionsDisplay.followCursor
    nonisolated(unsafe) private var screenObserver: NSObjectProtocol?
    /// Bumped per talk, so a fade-out still running from the previous stop
    /// cannot order out a band that a quick restart just brought back.
    private var presentation = 0
    var isVisible: Bool { panel?.isVisible == true }

    init(defaults: UserDefaults = .standard) {
        preferences = CaptionsPreferences(defaults: defaults)
        model.appearance = preferences.appearance
        preferences.onChange = { [weak self] in
            guard let self else { return }
            self.model.appearance = self.preferences.appearance
            self.layoutPanel(resolveDisplay: false)
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    func begin(target: String, display: String) {
        self.display = display
        previewing = false
        model.editing = false
        panel?.ignoresMouseEvents = true
        presentation &+= 1
        model.confirmed = ""
        model.partial = ""
        model.translation = ""
        model.target = target
        let panel = ensurePanel()
        layoutPanel()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 }
    }

    func update(confirmed: String, partial: String) {
        model.confirmed = confirmed
        model.partial = partial
    }

    /// The rolling translation. `""` clears the track, so switching
    /// translation off mid-talk does not freeze the last line on screen.
    func showTranslation(_ text: String) {
        model.translation = text
    }

    /// Follow a Translate-to change mid-talk: the track appears, or goes away
    /// together with its text, and the band resizes once.
    func setTranslationTarget(_ target: String) {
        guard panel != nil else { return }
        model.target = target
        if target.isEmpty { model.translation = "" }
        layoutPanel(resolveDisplay: false)
    }

    func moveToDisplay(_ display: String) {
        self.display = display
        guard panel?.isVisible == true else { return }
        layoutPanel()
    }

    func dismiss() {
        model.editing = false
        previewing = false
        panel?.ignoresMouseEvents = true
        guard let panel else { return }
        let presentation = presentation
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 },
                                             completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard self?.presentation == presentation else { return }
                panel.orderOut(nil)
            }
        })
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.title = "Captions"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Above a full-screen slideshow; the HUD's `.statusBar` sits under it.
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        // The audience's screen: nothing on it is for clicking, and a band that
        // swallowed clicks would get in the way of the speaker's own slides.
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: CaptionsOverlayView(model: model,
            onFrameChange: { [weak self] in self?.setManualFrame($0) },
            onLock: { [weak self] in self?.setEditing(false) }))
        self.panel = panel
        // A projector plugged in (or yanked) mid-talk: re-resolve so the band
        // lands on the pinned screen once it appears, and falls back to one
        // that still exists when it goes.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel?.isVisible == true else { return }
                self.layoutPanel()
            }
        }
        return panel
    }

    func setEditing(_ editing: Bool, display: String? = nil, translating: Bool = false) {
        if editing && !isVisible {
            self.display = display ?? self.display
            previewing = true
            presentation &+= 1
            model.target = translating ? "preview" : ""
            model.confirmed = "Move this area to place your captions. Resize it using the lower-right corner. Your appearance and position are saved automatically."
            model.partial = ""
            model.translation = translating ? "Translation appears here. You can change its color independently from the original text." : ""
            let panel = ensurePanel()
            layoutPanel()
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
        model.editing = editing
        panel?.ignoresMouseEvents = !editing
        if !editing && previewing { dismiss() }
    }

    func resetPlacement(display: String) {
        guard let screen = CaptionsDisplay.resolve(display) else { return }
        preferences.resetPlacement(for: screenKey(screen))
    }

    func setManualFrame(_ proposed: NSRect) {
        guard model.editing, let panel, let screen = layoutScreen else { return }
        let frame = CaptionsPlacement.fitted(proposed, visible: screen.visibleFrame, minimum: model.layout.minimumSize)
        preferences.save(frame: frame, on: screenKey(screen), visible: screen.visibleFrame)
        apply(frame: frame, screen: screen)
        panel.setFrame(frame, display: true)
    }

    private func screenKey(_ screen: NSScreen) -> String {
        CaptionsDisplay.uuid(of: screen) ?? screen.localizedName
    }

    private func apply(frame: NSRect, screen: NSScreen) {
        model.layout = CaptionsLayout(screen: screen.frame.size, translating: !model.target.isEmpty,
                                      appearance: preferences.appearance, size: frame.size)
    }

    private func layoutPanel(resolveDisplay: Bool = true) {
        guard let panel else { return }
        let screen: NSScreen
        if !resolveDisplay, let current = layoutScreen, NSScreen.screens.contains(current) {
            screen = current
        } else if let resolved = CaptionsDisplay.resolve(display) {
            screen = resolved
        } else { return }
        layoutScreen = screen
        let layout = CaptionsLayout(screen: screen.frame.size, translating: !model.target.isEmpty,
                                    appearance: preferences.appearance)
        let visible = screen.visibleFrame
        let automatic = NSRect(x: (visible.midX - layout.bandSize.width / 2).rounded(),
                               y: visible.minY + layout.bottomInset,
                               width: layout.bandSize.width, height: layout.bandSize.height)
        let proposed = preferences.placement(for: screenKey(screen))?.frame(in: visible) ?? automatic
        let frame = CaptionsPlacement.fitted(proposed, visible: visible, minimum: layout.minimumSize)
        if preferences.placement(for: screenKey(screen)) == nil {
            model.layout = layout
        } else {
            apply(frame: frame, screen: screen)
        }
        panel.setFrame(frame, display: true)
    }
}
