import AppKit
import Observation
import SwiftUI

/// A floating caption HUD that shows the live two-tier transcription while you
/// dictate: confirmed (Voxtral) text solid, the volatile Nemotron `⟨partial⟩`
/// tail dimmed. It must sit above every window **without taking keyboard focus**
/// — we're typing into another app's field at the same moment — so it's a
/// non-activating borderless `NSPanel`, click-through, hosting a SwiftUI pill.

/// Observable text state driving the pill.
@Observable
final class HUDModel {
    var confirmed = ""
    var partial = ""
    var recording = false
}

/// The styled pill. Reads `HUDModel` (auto-tracked via Observation).
private struct HUDView: View {
    let model: HUDModel

    @State private var pulse = false

    private var isEmpty: Bool { model.confirmed.isEmpty && model.partial.isEmpty }

    var body: some View {
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
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 540, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        .padding(10)                                 // room so the SwiftUI shadow isn't clipped by the window
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

    /// Live update during the hold.
    func update(confirmed: String, partial: String) {
        model.confirmed = confirmed
        model.partial = partial
        // The window auto-sizes to the new content; recenter after that layout pass.
        if let panel { DispatchQueue.main.async { [weak self] in self?.position(panel) } }
    }

    /// Show the final text for a beat, then fade out.
    func finish(_ finalText: String) {
        guard let panel else { return }
        model.recording = false
        model.partial = ""
        if !finalText.isEmpty { model.confirmed = finalText }
        DispatchQueue.main.async { [weak self] in self?.position(panel) }

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
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 64),
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

        let host = NSHostingController(rootView: HUDView(model: model))
        host.sizingOptions = [.preferredContentSize] // window tracks the SwiftUI fitting size
        panel.contentViewController = host
        self.panel = panel
        return panel
    }

    /// Bottom-center on the active screen.
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 120))
    }
}
