import Observation

/// AppKit → SwiftUI window bridge. A menu-bar (`.accessory`) app has no AppKit
/// handle to `openWindow`, so the `AppDelegate` flips `showOnboarding` and the
/// App scene observes it (`.onChange`) to call `openWindow(id: "onboarding")`.
@MainActor
@Observable
final class AppRouter {
    /// Set true to request the onboarding window; the scene resets it after opening.
    var showOnboarding = false
}
