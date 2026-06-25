import AppKit

/// Runs Murmur as a menu-bar agent and owns the dictation controller.
///
/// `.accessory` keeps the process alive in the background (so the global hotkey
/// keeps working) while staying out of the Dock and ⌘-Tab switcher.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let dictation = DictationController()
    let router = AppRouter()

    /// Drives the onboarding window. Lazy so it builds after `dictation` exists,
    /// reusing the controller's already-warmed `DictationSession`.
    lazy var onboarding = OnboardingModel(session: dictation.dictationSession)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        dictation.bootstrap()
        if OnboardingModel.shouldShow {
            NSApp.activate(ignoringOtherApps: true)
            router.showOnboarding = true              // App scene opens the window (.onChange)
        }
    }
}
