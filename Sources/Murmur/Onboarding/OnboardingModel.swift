import AVFoundation
import Foundation
import KeyboardShortcuts
import MurmurKit
import Observation
import SwiftUI

/// App-side `@Observable` that drives the onboarding window. Wraps the pure
/// `OnboardingFlow.State`, delegates every transition/gate to `OnboardingFlow`,
/// and owns the real-subsystem hooks (mic, accessibility, download, try-it) —
/// implemented as stubs here and filled in by later phases. Reuses the already-
/// warmed `DictationSession` from `DictationController` so the try-it step does
/// not spin up a second pipeline.
@MainActor
@Observable
final class OnboardingModel {
    static let didOnboardKey = "murmur.didOnboard"

    var flow = OnboardingFlow.State()
    var finished = false
    var downloadError: String?

    private let session: DictationSession

    /// Polls AX trust while the Permissions step is open — there's no
    /// notification for Accessibility-trust changes, so we have to ask.
    private var accPollTimer: Timer?

    init(session: DictationSession) { self.session = session }

    deinit { accPollTimer?.invalidate() }

    // MARK: navigation

    var canContinue: Bool { OnboardingFlow.canContinue(flow) }
    var showBack: Bool { flow.step != .welcome && !finished }

    /// The current push-to-talk shortcut, for the Done screen's chips.
    var shortcutLabel: String {
        KeyboardShortcuts.getShortcut(for: .dictate)?.description ?? "⌃⌥Space"
    }

    func next() {
        guard canContinue else { return }
        if flow.step == .permissions { stopAccessibilityPolling() }
        if flow.step == .welcome { startDownload() }          // overlap download with later steps
        if flow.step == .done { finish(); return }
        flow.step = OnboardingFlow.next(flow.step)
    }
    func back() {
        if flow.step == .permissions { stopAccessibilityPolling() }
        flow.step = OnboardingFlow.back(flow.step)
    }

    func finish() {
        UserDefaults.standard.set(true, forKey: Self.didOnboardKey)
        finished = true
    }
    func replay() {
        flow = OnboardingFlow.State(); finished = false; downloadError = nil
    }

    // MARK: permissions — mic (hard gate) + accessibility (skippable)

    /// Ask for microphone access; the system shows its dialog on first call and
    /// returns the cached answer after. Reflects the result into the flow gate.
    func requestMic() {
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            Task { @MainActor in self.flow.micGranted = ok }
        }
    }

    /// Show the Accessibility-trust prompt (deep-links to System Settings), then
    /// poll until the user flips it on — there's no AX-trust notification.
    func promptAccessibility() {
        _ = Accessibility.prompt()
        startAccessibilityPolling()
    }

    /// Reflect already-granted permissions when the screen appears, so a returning
    /// user sees "Granted" without re-prompting.
    func refreshPermissions() {
        flow.micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        flow.accessibilityGranted = Accessibility.isTrusted
        if !flow.accessibilityGranted { startAccessibilityPolling() }
    }

    private func startAccessibilityPolling() {
        guard accPollTimer == nil else { return }
        accPollTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { _ in
            Task { @MainActor in
                self.flow.accessibilityGranted = Accessibility.isTrusted
                if self.flow.accessibilityGranted { self.stopAccessibilityPolling() }
            }
        }
    }

    func stopAccessibilityPolling() {
        accPollTimer?.invalidate()
        accPollTimer = nil
    }

    // MARK: subsystem hooks — implemented in later phases

    func startDownload() {}         // Task 3.2
    func tryStart() {}              // Task 4.1
    func tryEnd() {}                // Task 4.1

    /// Should onboarding be shown at launch?
    static var shouldShow: Bool {
        !UserDefaults.standard.bool(forKey: didOnboardKey)
    }
}
