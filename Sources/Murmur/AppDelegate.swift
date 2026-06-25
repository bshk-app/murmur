import AppKit
import SwiftUI

/// Runs Murmur as a menu-bar agent, owns the dictation controller, and hosts the
/// onboarding window.
///
/// `.accessory` keeps the process alive in the background (so the global hotkey
/// keeps working) while staying out of the Dock and ⌘-Tab switcher.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// Drives the menu-bar item's visibility (`@AppStorage` in `MurmurApp`). A
    /// transient session flag — reset to false at every launch, set true only when
    /// the menu app actually starts (onboarding finished, or a returning user).
    static let menuReadyKey = "murmur.menuReady"

    let dictation = DictationController()

    /// Drives the onboarding window. Lazy so it builds after `dictation` exists,
    /// reusing the controller's already-warmed `DictationSession`.
    lazy var onboarding = OnboardingModel(session: dictation.dictationSession)

    private var onboardingWindow: NSWindow?
    private var didStartMenuApp = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UserDefaults.standard.set(false, forKey: Self.menuReadyKey)   // hide the icon until setup is done
        // Router: first run → onboarding ONLY. The live menu app (hotkey, mic prompt,
        // model warm-up) and its menu-bar icon appear only when onboarding finishes —
        // so nothing prompts or loads at launch, and the app is never half-configured.
        // A returning user goes straight to the menu app.
        onboarding.onFinished = { [weak self] in self?.startMenuApp() }
        if OnboardingModel.shouldShow {
            presentOnboarding()
        } else {
            startMenuApp()
        }
    }

    /// Wire up live dictation + reveal the menu-bar icon. Idempotent — for a first
    /// run this runs once onboarding completes (mic granted, models cached), for a
    /// returning user it runs at launch.
    private func startMenuApp() {
        guard !didStartMenuApp else { return }
        didStartMenuApp = true
        UserDefaults.standard.set(true, forKey: Self.menuReadyKey)    // reveal the menu-bar icon
        dictation.bootstrap()
    }

    /// Show (or re-show) the onboarding window. AppKit-owned `NSWindow` rather than a
    /// SwiftUI `Window` scene: a menu-bar (`.accessory`) app can't open a scene window
    /// reliably at launch, and a scene window hides on deactivation. This one persists
    /// (`isReleasedWhenClosed = false`) so "Setup tour…" can re-open it.
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
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 880, height: 580))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    /// Closing the setup window before finishing (initial onboarding) cancels setup →
    /// quit, so the app never lingers half-configured. A returning user's "Setup tour…"
    /// replay (menu app already running) just closes the window.
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === onboardingWindow else { return }
        if !didStartMenuApp { NSApp.terminate(nil) }
    }
}
