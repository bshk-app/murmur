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
        if flow.step == .welcome { startDownload() }          // overlap download with later steps
        if flow.step == .done { finish(); return }
        flow.step = OnboardingFlow.next(flow.step)
    }
    func back() { flow.step = OnboardingFlow.back(flow.step) }

    func finish() {
        UserDefaults.standard.set(true, forKey: Self.didOnboardKey)
        finished = true
    }
    func replay() {
        flow = OnboardingFlow.State(); finished = false; downloadError = nil
    }

    // MARK: subsystem hooks — implemented in later phases

    func requestMic() {}            // Task 2.1
    func promptAccessibility() {}   // Task 2.1
    func startDownload() {}         // Task 3.2
    func tryStart() {}              // Task 4.1
    func tryEnd() {}                // Task 4.1

    /// Should onboarding be shown at launch?
    static var shouldShow: Bool {
        !UserDefaults.standard.bool(forKey: didOnboardKey)
    }
}
