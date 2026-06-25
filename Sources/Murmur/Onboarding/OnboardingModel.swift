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

    /// Guards `startDownload` so the overlap-from-Welcome trigger and a manual
    /// Retry never spawn two concurrent downloads.
    private var downloadStarted = false

    private let session: DictationSession

    /// Polls AX trust while the Permissions step is open — there's no
    /// notification for Accessibility-trust changes, so we have to ask.
    private var accPollTimer: Timer?

    init(session: DictationSession) { self.session = session }

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

    // MARK: download — real per-repo progress (Task 3.2)

    /// Pre-download both model repos with live per-repo progress into the HF cache
    /// `*.fromPretrained` reads, then warm the Hybrid pipeline (cache hit, no
    /// re-download). Triggered on Welcome→next so it overlaps the later steps;
    /// re-callable as a Retry after `downloadError` clears `downloadStarted`.
    func startDownload() {
        guard !downloadStarted else { return }
        downloadStarted = true
        downloadError = nil
        Task {
            do {
                try await OnboardingDownloader.download { p in
                    // Monotonic: progress ticks arrive unordered (per-tick Tasks),
                    // so a stale sub-1.0 tick must never regress a finished lane —
                    // else the gate (both ≥ 1) could hang at full-looking bars (I1).
                    self.flow.fastFraction = max(self.flow.fastFraction, p.fast)
                    self.flow.accurateFraction = max(self.flow.accurateFraction, p.accurate)
                }
                try await self.session.load(mode: .hybrid)   // warm both (cache hit)
            } catch {
                self.downloadError = error.localizedDescription
                self.downloadStarted = false                 // allow Retry
            }
        }
    }

    /// Reset and re-run the download after a failure (Download screen "Retry").
    func retryDownload() {
        downloadError = nil
        // Only restart the unfinished lane(s) — don't blink an already-cached
        // model's bar from 1 → 0 → 1 (I2). The monotonic max-clamp keeps it stable.
        if flow.fastFraction < 1 { flow.fastFraction = 0 }
        if flow.accurateFraction < 1 { flow.accurateFraction = 0 }
        startDownload()
    }

    // MARK: subsystem hooks — implemented in later phases

    func tryStart() {}              // Task 4.1
    func tryEnd() {}                // Task 4.1

    /// Should onboarding be shown at launch?
    static var shouldShow: Bool {
        !UserDefaults.standard.bool(forKey: didOnboardKey)
    }
}
