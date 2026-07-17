import AppKit
@testable import Murmur

@MainActor
final class ManualHUDScheduler: HUDHideScheduling {
    struct Entry {
        let delay: TimeInterval
        let action: @MainActor () -> Void
        let cancellation: HUDCancellation
    }

    private(set) var entries: [Entry] = []

    func schedule(after delay: TimeInterval,
                  action: @escaping @MainActor () -> Void) -> HUDCancellation {
        let cancellation = HUDCancellation {}
        entries.append(Entry(delay: delay, action: action, cancellation: cancellation))
        return cancellation
    }

    func fire(_ index: Int, evenIfCancelled: Bool = false) {
        let entry = entries[index]
        guard evenIfCancelled || !entry.cancellation.isCancelled else { return }
        entry.action()
    }
}

@MainActor
final class ManualHUDAnimator: HUDAnimating {
    private(set) var shownPanels: [NSPanel] = []
    private(set) var hiddenPanels: [NSPanel] = []
    private var hideCompletions: [@MainActor () -> Void] = []

    func show(_ panel: NSPanel) {
        panel.alphaValue = 1
        shownPanels.append(panel)
    }

    func hide(_ panel: NSPanel, completion: @escaping @MainActor () -> Void) {
        panel.alphaValue = 0
        hiddenPanels.append(panel)
        hideCompletions.append(completion)
    }

    func completeHide(_ index: Int = 0) {
        hideCompletions[index]()
    }
}

@MainActor
func makeHUDController() -> (HUDController, ManualHUDScheduler, ManualHUDAnimator) {
    let scheduler = ManualHUDScheduler()
    let animator = ManualHUDAnimator()
    return (HUDController(scheduler: scheduler, animator: animator), scheduler, animator)
}

@MainActor
func tearDownHUD(_ controller: HUDController) {
    controller.panel?.orderOut(nil)
    controller.panel?.contentView = nil
}

@MainActor
func waitForHUDCondition(timeout: Duration = .seconds(3),
                         _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition(), clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}
