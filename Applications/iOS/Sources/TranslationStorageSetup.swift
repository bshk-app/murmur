import Foundation
import MurmurCore

enum TranslationStorageSetup {
    static func prepare() throws {
        guard TranslationPaths.shared != nil else { return } // Unsigned simulator host.
        let legacy=StoragePaths.models.appendingPathComponent("TranslationModels")
        _ = try TranslationStoreMigration.migrate(from:legacy,to:TranslationPaths.models)
        TranslationPreferences.save(source:TranslationPreferences.source,target:TranslationPreferences.target)
        if let ready=TranslationPaths.ready, !FileManager.default.fileExists(atPath:ready.path) {
            try Data("1".utf8).write(to:ready,options:.atomic)
        }
    }
}
