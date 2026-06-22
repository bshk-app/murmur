import AppKit
import CoreGraphics

/// Global push-to-talk hotkey via a CGEvent tap.
///
/// Fires `onPress` when the chord (default ⌃⌥Space) goes down and `onRelease`
/// when it lets go — and SWALLOWS those key events so the Space never leaks into
/// the focused app. The tap needs Accessibility trust; `start()` returns `false`
/// if the tap couldn't be created (not yet trusted), so the caller can prompt.
///
/// Callbacks fire on the main run loop (where the tap source is attached) and
/// are hopped onto the main actor.
final class HotkeyMonitor {
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}

    private let keyCode: Int64 = 49                       // Space
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var active = false                            // chord currently held

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                return monitor.handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        active = false
    }

    /// Required modifiers present (Control+Option, but not Command).
    private func chordHeld(_ flags: CGEventFlags) -> Bool {
        flags.contains(.maskControl) && flags.contains(.maskAlternate) && !flags.contains(.maskCommand)
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        // The OS disables a tap that runs long or is force-quit; re-arm it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .keyDown where event.getIntegerValueField(.keyboardEventKeycode) == keyCode:
            if chordHeld(event.flags), !active {
                active = true
                fire(onPress)
                return nil                                // swallow the chord
            }
            if active { return nil }                      // swallow auto-repeat while held

        case .keyUp where event.getIntegerValueField(.keyboardEventKeycode) == keyCode:
            if active {
                active = false
                fire(onRelease)
                return nil
            }

        case .flagsChanged where active && !chordHeld(event.flags):
            // A required modifier let go mid-hold ends the gesture.
            active = false
            fire(onRelease)

        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private func fire(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { block() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { block() } }
        }
    }
}
