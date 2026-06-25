import AppKit
import SwiftUI

/// Runs Murmur as a menu-bar agent, owns the dictation controller, and hosts the
/// onboarding window.
///
/// `.accessory` keeps the process alive in the background (so the global hotkey
/// keeps working) while staying out of the Dock and ⌘-Tab switcher.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let dictation = DictationController()

    /// Drives the onboarding window. Lazy so it builds after `dictation` exists,
    /// reusing the controller's already-warmed `DictationSession`.
    lazy var onboarding = OnboardingModel(session: dictation.dictationSession)

    private var onboardingWindow: NSWindow?
    private var didStartMenuApp = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Router: first run → onboarding ONLY (it requests the mic on the Permissions
        // screen and downloads models on the Download step). The live menu app boots
        // only when onboarding finishes — so nothing prompts for mic or loads models
        // at launch. A returning user goes straight to the menu app.
        onboarding.onFinished = { [weak self] in self?.startMenuApp() }
        if OnboardingModel.shouldShow {
            presentOnboarding()
        } else {
            startMenuApp()
        }
    }

    /// Wire up live dictation (hotkey, mic prompt, model warm-up). Idempotent — for a
    /// first run this runs once onboarding completes (mic already granted, models
    /// already cached), for a returning user it runs at launch.
    private func startMenuApp() {
        guard !didStartMenuApp else { return }
        didStartMenuApp = true
        dictation.bootstrap()
    }

    /// Show (or re-show) the onboarding window. AppKit-owned `NSWindow` rather than
    /// a SwiftUI `Window` scene: a menu-bar (`.accessory`) app can't open a scene
    /// window reliably at launch, and a scene window hides on deactivation. This one
    /// persists (`isReleasedWhenClosed = false`) so "Setup tour…" can re-open it.
    func presentOnboarding() {
        let window = onboardingWindow ?? makeOnboardingWindow()
        onboardingWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// "Setup tour…" — reset to Welcome, then present.
    func replayOnboarding() {
        onboarding.replay()
        presentOnboarding()
    }

    private func makeOnboardingWindow() -> NSWindow {
        let host = NSHostingController(rootView: OnboardingView(model: onboarding).frame(width: 880, height: 580))
        host.safeAreaRegions = []   // content runs under the transparent title bar (our drawn row IS the bar)
        let window = NSWindow(contentViewController: host)
        window.title = "MurMur Setup"
        // Transparent, full-size-content title bar → the SwiftUI title row IS the
        // title bar (one colour, one set of traffic lights — the real ones).
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 880, height: 580))
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}
