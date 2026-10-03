import SwiftUI
@main struct PhotoPreviewApp: App {
    init() { try? TranslationStorageSetup.prepare() }
    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("--photo-translation-probe") {
                PhotoTranslationView(initialPhotoURL: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("photo-probe.jpg"), source: ProcessInfo.processInfo.environment["PHOTO_PROBE_SOURCE"] ?? "en", target: ProcessInfo.processInfo.environment["PHOTO_PROBE_TARGET"] ?? "fi")
            } else { PhotoTranslationView() }
        }
    }
}
