import AppKit
import Observation
import SwiftUI

/// A floating caption HUD that shows the live two-tier transcription while you
/// dictate: confirmed (Voxtral) text solid, the volatile Nemotron `⟨partial⟩`
/// tail dimmed. It must sit above every window **without taking keyboard focus**
/// — we're typing into another app's field at the same moment — so it's a
/// non-activating borderless `NSPanel`, click-through, hosting a SwiftUI pill.
///
/// IMPORTANT: the panel is a **fixed size**. An earlier version let the window
/// auto-size to the SwiftUI content (`NSHostingController.preferredContentSize`)
/// and repositioned it every update — that made the window frame and the content
/// size drive each other through AutoLayout, recursing
/// `_changeWindowFrameFromConstraintsIfNecessary` ↔ `NSPerformVisuallyAtomicChange`
/// until the main-thread stack overflowed (EXC_BAD_ACCESS). The window must NOT
/// resize from its content. So: fixed transparent window, the pill sizes itself
/// inside it, positioned once on show.

/// Observable text state driving the pill.
@Observable
final class HUDModel {
    var confirmed = ""
    var partial = ""
    var recording = false
}

/// The styled pill, centered inside the fixed transparent window.
private struct HUDView: View {
    let model: HUDModel

    @State private var pulse = false

    private var isEmpty: Bool { model.confirmed.isEmpty && model.partial.isEmpty }

    var body: some View {
        pill
            // Fill the fixed window and center the pill; the window never resizes
            // to fit, so there is no content↔frame layout feedback loop.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private var pill: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(model.recording ? Color.red : Color.secondary)
                .frame(width: 9, height: 9)
                .opacity(pulse ? 1 : 0.35)
                .onAppear { pulse = true }
                .animation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true), value: pulse)

            transcript
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .lineLimit(2)
                .truncationMode(.head)               // keep the most recent words visible
                .multilineTextAlignment(.leading)
                .frame(maxWidth: 520, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        .fixedSize()                                  // pill hugs its content within the fixed window
    }

    /// Confirmed prefix (primary) + provisional tail (secondary, in ⟨⟩).
    private var transcript: Text {
        if isEmpty {
            return Text("Listening…").foregroundStyle(.secondary)
        }
        let head = Text(model.confirmed).foregroundStyle(.primary)
        guard !model.partial.isEmpty else { return head }
        let sep = model.confirmed.isEmpty ? "" : " "
        return head + Text("\(sep)⟨\(model.partial)⟩").foregroundStyle(.secondary)
    }
}

/// Owns the panel and its lifecycle. MainActor — all window work is on the main
/// thread; the controller pushes `(confirmed, partial)` here from the UI side.
@MainActor
final class HUDController {
    private let model = HUDModel()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    // Fixed window footprint: a wide, short transparent band near the bottom.
    // The pill floats inside it; the window itself never changes size.
    private let size = NSSize(width: 760, height: 120)

    /// Reveal the HUD for a new utterance (fade in, reset text).
    func show() {
        hideWork?.cancel(); hideWork = nil
        let panel = ensurePanel()
        model.recording = true
        model.confirmed = ""
        model.partial = ""
        position(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()                 // show without activating the app
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 }
    }

    /// Live update during the hold. Text-only — the window is fixed, so there is
    /// nothing to resize or reposition here (that was the crash).
    func update(confirmed: String, partial: String) {
        model.confirmed = confirmed
        model.partial = partial
    }

    /// Show the final text for a beat, then fade out.
    func finish(_ finalText: String) {
        guard panel != nil else { return }
        model.recording = false
        model.partial = ""
        if !finalText.isEmpty { model.confirmed = finalText }

        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    private func fadeOut() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 },
                                             completionHandler: { panel.orderOut(nil) })
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false                      // the SwiftUI pill draws its own
        panel.level = .statusBar                     // float above normal windows
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true              // click-through to the app underneath

        // No .preferredContentSize: the window stays fixed; the hosting view fills
        // it and the pill centers, so content never drives the window frame.
        let host = NSHostingView(rootView: HUDView(model: model))
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        self.panel = panel
        return panel
    }

    /// Bottom-center on the active screen (fixed size, so once is enough).
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        panel.setFrame(
            NSRect(x: visible.midX - size.width / 2, y: visible.minY + 80, width: size.width, height: size.height),
            display: true
        )
    }
}
