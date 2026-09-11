import Foundation
import Observation

struct TranslationLanguagePack: Identifiable, Codable, Hashable {
    let source: String
    let target: String
    var id: String { source + "-" + target }
}

@MainActor @Observable final class LanguageLibrary {
    @ObservationIgnored private let defaults: UserDefaults
    var speech: [String] {
        didSet { defaults.set(speech, forKey: "addedSpeechLanguages") }
    }
    var translations: [TranslationLanguagePack] {
        didSet { if let data = try? JSONEncoder().encode(translations) { defaults.set(data, forKey: "addedTranslationLanguages") } }
    }
    private(set) var prepared: Set<String>
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        speech = defaults.stringArray(forKey: "addedSpeechLanguages") ?? [defaults.string(forKey: "speechLanguage") ?? "ru"]
        translations = defaults.data(forKey: "addedTranslationLanguages").flatMap { try? JSONDecoder().decode([TranslationLanguagePack].self, from: $0) } ?? []
        prepared = Set(defaults.stringArray(forKey: "preparedLanguagePacks") ?? [])
    }
    func addSpeech(_ code: String) { if !speech.contains(code) { speech.append(code) } }
    func removeSpeech(_ code: String) { speech.removeAll { $0 == code } }
    func removeTranslation(_ pack: TranslationLanguagePack) { translations.removeAll { $0.id == pack.id } }
    var count: Int { speech.count + translations.count }
    var preparedCount: Int { speech.filter { isPrepared("speech:" + $0) }.count + translations.filter { isPrepared("translation:" + $0.id) }.count }
    func addTranslation(from: String, to: String) {
        let pack = TranslationLanguagePack(source: from, target: to)
        if !translations.contains(pack) { translations.append(pack) }
    }
    func markPrepared(_ id: String) {
        prepared.insert(id)
        defaults.set(Array(prepared), forKey: "preparedLanguagePacks")
    }
    func invalidatePrepared(_ ids: Set<String>) {
        prepared.subtract(ids)
        defaults.set(Array(prepared), forKey: "preparedLanguagePacks")
    }
    func invalidateSpeechPreparation() { invalidatePrepared(Set(prepared.filter { $0.hasPrefix("speech:") })) }
    func isPrepared(_ id: String) -> Bool { prepared.contains(id) }
}
