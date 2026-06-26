import ApplicationServices

/// Thin wrapper over the Accessibility trust check. Text injection (typing into
/// other apps) only works once the user grants the app Accessibility access.
public enum Accessibility {
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Trust check that also shows the system prompt deep-linking to
    /// Privacy & Security → Accessibility. Returns the current trust state.
    @discardableResult
    public static func prompt() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
