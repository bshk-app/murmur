import Foundation

public enum LanguageDownloadRemoval {
    public static func speech(_ items: [ModelStorageItem], removing code: String, remaining: [String]) -> [ModelStorageItem] {
        items.filter { item in
            item.kind == .speech && item.downloadable &&
                !SpeechModelChoice.languages(forStorageID: item.id, selected: [code]).isEmpty &&
                SpeechModelChoice.languages(forStorageID: item.id, selected: remaining).isEmpty
        }
    }
    public static func translation(_ items: [ModelStorageItem], removing pair: LanguagePair, remaining: [LanguagePair],
                                   uses: (ModelStorageItem, LanguagePair) -> Bool) -> [ModelStorageItem] {
        items.filter { item in
            (item.kind == .translationQuality || item.kind == .translationPreview) && item.downloadable &&
                uses(item, pair) && !remaining.contains { uses(item, $0) }
        }
    }
}
