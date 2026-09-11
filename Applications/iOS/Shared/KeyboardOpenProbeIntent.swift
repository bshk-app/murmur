#if DEBUG
import AppIntents

@available(iOS 26.0, *)
struct KeyboardOpenProbeIntent: AppIntent {
    static let title: LocalizedStringResource = "Keyboard navigation probe"
    static let isDiscoverable = false
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    func perform() async throws -> some IntentResult { .result() }
}
#endif
