import Foundation

public struct VoiceNote: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var createdAt: Date
    public var text: String
    public var translation: String?
    public var sourceLanguage: String
    public var targetLanguage: String?
    public var duration: Double
    public var model: String
    public var sourceFileName: String?
    public var transcriptionComplete: Bool?
    public var translationNeedsUpdate: Bool?
    public var translationIncomplete: Bool?
    public var audio: RecordedAudio?
    public var utterances: [RecordedUtterance]?
    public var transcriptVersions: [TranscriptVersion]?
    public var captureRevision: UInt64?
    public var captureClosed: Bool?
    public var title: String { sourceFileName ?? String(text.split(separator: "\n").first.map(String.init)?.prefix(80) ?? "".prefix(80)) }
    public var shareText: String {
        guard let translation, !translation.isEmpty else { return text }
        return text + "\n\n" + translation
    }
    public init(id: UUID = UUID(), createdAt: Date = Date(), text: String, translation: String? = nil,
                sourceLanguage: String, targetLanguage: String? = nil, duration: Double, model: String) {
        self.id=id; self.createdAt=createdAt; self.text=text; self.translation=translation
        self.sourceLanguage=sourceLanguage; self.targetLanguage=targetLanguage; self.duration=duration; self.model=model
        self.translationNeedsUpdate = nil
    }
}

public struct TranscriptVersion: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let savedAt: Date
    public let text: String
    public let translation: String?
    public let sourceLanguage: String
    public let targetLanguage: String?
    public let utterances: [RecordedUtterance]?
    public init(note: VoiceNote, id: UUID = UUID(), savedAt: Date = Date()) {
        self.id = id; self.savedAt = savedAt; text = note.text; translation = note.translation
        sourceLanguage = note.sourceLanguage; targetLanguage = note.targetLanguage; utterances = note.utterances
    }
}

