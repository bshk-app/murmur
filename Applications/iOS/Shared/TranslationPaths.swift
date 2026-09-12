import Foundation
import MurmurCore

enum TranslationPaths {
    // Translation-only data: language packs, preferences and short-lived Share tickets.
    static let group = "group.app.bshk.murmur.ios.translation"
    static var shared: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) }
    static var models: URL {
        let fallback=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("MurMur/Models")
        return (shared ?? fallback).appendingPathComponent("TranslationModels")
    }
    static var ready: URL? { shared?.appendingPathComponent("translation-store-ready") }
    static var isReady: Bool { ready.map { FileManager.default.fileExists(atPath:$0.path) } ?? false }
    static var offlineRoutes: OfflineTranslationRoutes {
        #if MURMUR_UI_HOST
        if ProcessInfo.processInfo.arguments.contains("-longConversation") {
            return .init(pairs: [.init(source: "en", target: "fi"), .init(source: "fi", target: "en"), .init(source: "fi", target: "ru"), .init(source: "ru", target: "en")])
        }
        #endif
        let catalog = TranslationProfileCatalog.current
        let installed = catalog.registeredModels.filter { binding in
            let directory = models.appendingPathComponent(binding.directoryName)
            return (try? TranslationModelIdentity.cached(directory: directory)) == binding.modelID
        }
        return .init(installedModels: installed, catalog: catalog)
    }
}

enum TranslationPreferences {
    private static var defaults: UserDefaults { UserDefaults(suiteName: TranslationPaths.group) ?? .standard }
    static var quality: ProcessingQuality {
        get { ProcessingQuality(rawValue: defaults.string(forKey: "textTranslationQuality") ?? "quality") ?? .quality }
        set { defaults.set(newValue.rawValue, forKey: "textTranslationQuality") }
    }
    static var source: String { defaults.string(forKey:"textTranslationSource") ?? UserDefaults.standard.string(forKey:"textTranslationSource") ?? "ru" }
    static var target: String { defaults.string(forKey:"textTranslationTarget") ?? UserDefaults.standard.string(forKey:"textTranslationTarget") ?? "en" }
    static func save(source: String, target: String) {
        for store in [defaults, .standard] {
            store.set(source,forKey:"textTranslationSource")
            store.set(target,forKey:"textTranslationTarget")
        }
    }
}
