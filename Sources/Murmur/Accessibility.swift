import ApplicationServices

/// Thin wrapper over the Accessibility trust check. The CGEvent hotkey tap (and,
/// later, text injection) only work once the user grants Murmur Accessibility
/// access in Privacy & Security.
enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Trust check that also shows the system prompt deep-linking to
    /// Privacy & Security → Accessibility. Returns the current trust state.
    @discardableResult
    static func prompt() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
