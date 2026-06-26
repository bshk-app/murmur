import AVFoundation
import Foundation
import KeyboardShortcuts
import MurmurKit
import Observation
import PostHog
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

    /// Called once the user completes onboarding — the AppDelegate uses it to boot
    /// the live menu app (mic now granted, models now cached). Set before launch.
    var onFinished: (() -> Void)?

    /// Bring the onboarding window back to the front. A TCC permission dialog steals
    /// focus and, for a menu-bar (`.accessory`) app with no Dock icon, leaves the
    /// setup window buried behind other apps — so we re-front it after the mic prompt.
    var onReactivate: (() -> Void)?

    /// Guards `startDownload` so the overlap-from-Welcome trigger and a manual
    /// Retry never spawn two concurrent downloads.
    @ObservationIgnored private var downloadStarted = false

    private let session: DictationSession

    /// Polls AX trust while the Permissions step is open — there's no
    /// notification for Accessibility-trust changes, so we have to ask.
    @ObservationIgnored private var accPollTimer: Timer?

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
        if flow.step == .tryIt { tryEnd() }                   // stop + restore onUpdate on leave
        if flow.step == .done { finish(); return }
        // Download starts when the Download step itself appears (DownloadScreen
        // .onAppear) — no preemptive background load during earlier steps.
        flow.step = OnboardingFlow.next(flow.step)
    }
    func back() {
        if flow.step == .permissions { stopAccessibilityPolling() }
        if flow.step == .tryIt { tryEnd() }                   // stop + restore onUpdate on leave
        flow.step = OnboardingFlow.back(flow.step)
    }

    func finish() {
        PostHogSDK.shared.capture("onboarding_completed", properties: [
            "accessibility_granted": flow.accessibilityGranted,
        ])
        UserDefaults.standard.set(true, forKey: Self.didOnboardKey)
        finished = true
        onFinished?()                 // boot the live menu app (mic granted, models cached)
    }
    func replay() {
        flow = OnboardingFlow.State(); finished = false; downloadError = nil
        tryConfirmed = ""; tryPartial = ""
        // Re-arm the download trigger; the models are already on disk from the first
        // run, so show the Download step as instantly complete instead of a 0-bar
        // soft-lock (the guard would otherwise early-return and never gate-open).
        downloadStarted = false
        if session.isReady(.hybrid) {
            flow.fastFraction = 1
            flow.accurateFraction = 1
        }
    }

    // MARK: permissions — mic (hard gate) + accessibility (skippable)

    /// Ask for microphone access; the system shows its dialog on first call and
    /// returns the cached answer after. Reflects the result into the flow gate.
    func requestMic() {
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            Task { @MainActor in
                self.flow.micGranted = ok
                if ok { PostHogSDK.shared.capture("mic_permission_granted") }
                self.onReactivate?()   // the TCC dialog stole focus — pull the window back
            }
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
                let trusted = Accessibility.isTrusted
                let wasGranted = self.flow.accessibilityGranted
                self.flow.accessibilityGranted = trusted
                if trusted && !wasGranted { PostHogSDK.shared.capture("accessibility_permission_granted") }
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
    /// re-download). Triggered by the Download step's `.onAppear` (nothing loads
    /// before then); re-callable as Retry after `downloadError` clears `downloadStarted`.
    func startDownload() {
        guard !downloadStarted else { return }
        downloadStarted = true
        downloadError = nil
        PostHogSDK.shared.capture("model_download_started")
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
                self.modelsReady = true                       // pipeline in memory → try-it button enables
                PostHogSDK.shared.capture("model_download_completed", properties: [
                    "total_gb": OnboardingFlow.totalGB,
                ])
            } catch {
                self.downloadError = error.localizedDescription
                self.downloadStarted = false                 // allow Retry
                PostHogSDK.shared.capture("model_download_failed", properties: [
                    "error": error.localizedDescription,
                ])
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
        modelsReady = session.isReady(.hybrid)    // already loaded on a replay → try-it works at once
        startDownload()
    }

    // MARK: try-it — real in-window Hybrid dictation (Task 4.1)

    /// Live two-tier transcript rendered into the try-it field (confirmed crisp +
    /// newest-word accent flash; partial in draft). Empty until the user holds.
    var tryConfirmed = ""
    var tryPartial = ""
    var tryListening = false

    /// True once the Hybrid pipeline is loaded into memory (set after the Download
    /// step's `session.load`). Observable — so the try-it button re-enables the moment
    /// loading finishes, which lags the download bars (`session.isReady` isn't tracked).
    var modelsReady = false
    var tryReady: Bool { modelsReady }

    /// The controller's HUD `onUpdate` handler, parked while the try-it field
    /// borrows `session.onUpdate`, and restored when the dictation ends — the
    /// session is app-lifetime, so the main app must keep driving the HUD after.
    @ObservationIgnored private var savedOnUpdate: ((String, String) -> Void)?

    /// True while a previous `tryEnd` is still draining `stop()` off-main. Blocks a
    /// rapid re-press from starting a new utterance before teardown finishes —
    /// otherwise it would overlap start()/stop() on the shared session AND re-save
    /// the borrowed closure as `savedOnUpdate`, permanently losing the controller's
    /// HUD handler (and killing the main app's HUD).
    @ObservationIgnored private var tryBusy = false

    /// Press: borrow the warmed session, redirect its updates into our field, and
    /// start a Hybrid utterance. No-op if the pipeline isn't ready, already live,
    /// or a previous stop is still draining.
    func tryStart() {
        guard session.isReady(.hybrid), !tryListening, !tryBusy else { return }
        savedOnUpdate = session.onUpdate
        tryConfirmed = ""
        tryPartial = ""
        session.onUpdate = { c, p in
            Task { @MainActor in
                self.tryConfirmed = c
                self.tryPartial = p
            }
        }
        do {
            try session.start(mode: .hybrid)
            tryListening = true
        } catch {
            tryListening = false
            session.onUpdate = savedOnUpdate
            savedOnUpdate = nil
        }
    }

    /// Release: stop off-main (drains the backlog), settle the final text, mark the
    /// try-it gate, and restore the controller's HUD handler. Idempotent via the
    /// `tryListening` guard, so `.onDisappear` can call it safely.
    func tryEnd() {
        guard tryListening else { return }
        tryListening = false
        tryBusy = true
        // Restore the controller's HUD handler SYNCHRONOUSLY (it's just a property
        // write) so a re-press can never observe the borrowed closure as the saved
        // one. Only the draining `stop()` goes off-main (like endRecording); capture
        // `session` directly so it doesn't touch main-actor `self` there.
        session.onUpdate = savedOnUpdate
        savedOnUpdate = nil
        Task.detached(priority: .userInitiated) { [session] in
            let final = session.stop()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.tryConfirmed = final
                self.tryPartial = ""
                let wasFirst = !self.flow.didTry
                self.flow.didTry = self.flow.didTry || !final.isEmpty   // monotonic: one success is enough
                if wasFirst && !final.isEmpty {
                    PostHogSDK.shared.capture("try_it_completed", properties: [
                        "word_count": final.split(separator: " ").count,
                    ])
                }
                self.tryBusy = false
            }
        }
    }

    /// Clear the try-it field for another attempt ("Try again"). Leaves `didTry`
    /// set — one success is enough to keep Continue unlocked.
    func tryReset() {
        tryConfirmed = ""
        tryPartial = ""
    }

    /// VoiceOver can't hold a key — double-tap toggles the utterance instead.
    func tryToggle() {
        if tryListening { tryEnd() } else { tryStart() }
    }

    /// Should onboarding be shown at launch?
    static var shouldShow: Bool {
        !UserDefaults.standard.bool(forKey: didOnboardKey)
    }
}
