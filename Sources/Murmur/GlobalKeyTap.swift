import AppKit
// CFMachPort and CFRunLoopSource are thread-safe CF objects; the tap thread
// only ever adds the one to its own run loop.
@preconcurrency import CoreFoundation
import CoreGraphics
import MurmurKit

/// Where `DictationController` sends the capture mode. A protocol so tests can
/// see what the controller asks for without installing a real event tap.
protocol KeyCaptureSink: AnyObject {
    func setCapture(_ capture: KeyCapture)
    /// Stop holding keys back, and say whether a Return was held back as
    /// "and send it" - in one step. The gesture for that Return travels to
    /// the main thread on its own and can arrive after the paste has already
    /// been sent; read this way, a Return pressed in the instant the text
    /// lands is either counted here or reaches the app itself, never eaten.
    func endCapture() -> Bool
}

/// Watches the keyboard system-wide for the right-⌘ tap and, while a tap-on
/// dictation runs, keeps Return and Escape from the frontmost app.
///
/// An active `CGEventTap` on its own thread. Every keystroke on the Mac passes
/// through the callback before any app sees it, and the system switches off a
/// tap whose callback is slow, so the callback only consults the recognizer
/// under a lock and hands gestures to the main thread asynchronously. On the
/// main run loop the same tap would stall all typing whenever the HUD was busy
/// drawing.
///
/// Holding events back needs an active tap, and an active tap needs
/// Accessibility trust - the same grant pasting already needs. Until it is
/// granted `start()` keeps retrying quietly, so granting it later from the
/// menu makes the key work without a relaunch.
final class GlobalKeyTap: KeyCaptureSink, @unchecked Sendable {
    private let onGesture: @MainActor (KeyGesture) -> Void

    // Guarded by `lock`: written on the main thread, read on the tap thread.
    private let lock = NSLock()
    private var recognizer = KeyGestureRecognizer()
    private var capture: KeyCapture = .off
    /// A Return was held back while finishing, and nobody has asked yet.
    private var submitPending = false
    private var tap: CFMachPort?

    // Main thread only.
    private var retryTimer: Timer?

    private static let ownPID = Int64(ProcessInfo.processInfo.processIdentifier)

    init(onGesture: @escaping @MainActor (KeyGesture) -> Void) {
        self.onGesture = onGesture
    }

    func setCapture(_ capture: KeyCapture) {
        lock.lock()
        self.capture = capture
        // Only finishing can carry a pending "send it" forward. Anything else
        // means that session is over, and its Return must not send the next
        // one.
        if capture != .finishing { submitPending = false }
        lock.unlock()
    }

    func endCapture() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        capture = .off
        let pending = submitPending
        submitPending = false
        return pending
    }

    private var isInstalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return tap != nil
    }

    /// Install the tap now, or as soon as Accessibility is granted. Idempotent.
    @MainActor func start() {
        guard !isInstalled, retryTimer == nil else { return }
        if install() { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.install() else { return }
                timer.invalidate()
                self.retryTimer = nil
            }
        }
    }

    @MainActor private func install() -> Bool {
        guard Accessibility.isTrusted else { return false }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp,
                                    .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: globalKeyTapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        lock.lock()
        self.tap = tap
        lock.unlock()
        // Lives as long as the app: the controller that owns this never goes away.
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "Murmur key tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    /// Runs on the tap thread for every event of interest. Returns whether to
    /// keep the event from the app. Internal rather than private so tests can
    /// feed it synthetic events without installing the tap.
    func handle(type: CGEventType, event: CGEvent) -> Bool {
        let input: KeyInput
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system gave up on us once; without this the key would stop
            // working until relaunch.
            lock.lock()
            let tap = self.tap
            lock.unlock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        case .flagsChanged:
            input = .modifiersChanged(keyCode: Self.keyCode(event), modifiers: KeyModifiers(event.flags),
                                      time: ProcessInfo.processInfo.systemUptime)
        case .keyDown:
            // Our own ⌘V and Return must reach the app untouched.
            guard event.getIntegerValueField(.eventSourceUnixProcessID) != Self.ownPID else { return false }
            input = .keyDown(keyCode: Self.keyCode(event), modifiers: KeyModifiers(event.flags),
                             isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        case .keyUp:
            guard event.getIntegerValueField(.eventSourceUnixProcessID) != Self.ownPID else { return false }
            input = .keyUp(keyCode: Self.keyCode(event))
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            input = .pointerDown
        default:
            return false
        }
        lock.lock()
        let outcome = recognizer.handle(input, capture: capture)
        // Act on the gesture here as well as on the main thread. The
        // controller's own update arrives a moment later, and a second Return
        // in that moment must already count as "send it", not as a second
        // "stop" that does nothing.
        switch outcome.gesture {
        case .confirm?: capture = .finishing
        case .cancel?: capture = .off; submitPending = false
        case .submitWhenDone?: submitPending = true
        default: break
        }
        lock.unlock()
        if let gesture = outcome.gesture { deliver(gesture) }
        if let pressedAt = outcome.holdCheck {
            // On this thread's run loop rather than the main queue: decided
            // here, in turn with the key events around it, the hold reaches
            // the controller in order with them. A busy main thread can then
            // delay a hold-to-talk take, but not lose it - checked from the
            // main queue, a release the tap saw first left it unreported.
            let timer = CFRunLoopTimerCreateWithHandler(
                kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + KeyGestureRecognizer.holdDelay, 0, 0, 0
            ) { [weak self] _ in
                self?.holdDelayPassed(pressedAt: pressedAt)
            }
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
        }
        return outcome.swallow
    }

    /// `holdDelay` after a right-⌘ press: is that press still down on its own?
    /// The decision is the recognizer's (`holdDelayPassed(pressedAt:)`), and
    /// is tested there.
    private func holdDelayPassed(pressedAt: TimeInterval) {
        lock.lock()
        let gesture = recognizer.holdDelayPassed(pressedAt: pressedAt)
        lock.unlock()
        if let gesture { deliver(gesture) }
    }

    private func deliver(_ gesture: KeyGesture) {
        let onGesture = self.onGesture
        // FIFO, unlike a Task per gesture: Return-then-Return must arrive
        // as confirm-then-submit, never the other way round.
        DispatchQueue.main.async { MainActor.assumeIsolated { onGesture(gesture) } }
    }

    private static func keyCode(_ event: CGEvent) -> Int {
        Int(event.getIntegerValueField(.keyboardEventKeycode))
    }
}

private func globalKeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                  refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let owner = Unmanaged<GlobalKeyTap>.fromOpaque(refcon).takeUnretainedValue()
    return owner.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
}
