import Foundation

public enum KeyboardRecognitionMode: String, Codable, CaseIterable, Sendable { case fast, accurate }

public struct KeyboardConfiguration: Codable, Equatable, Sendable {
    public var source: String
    public var target: String?
    public var mode: KeyboardRecognitionMode
    public init(source: String = "ru", target: String? = nil, mode: KeyboardRecognitionMode = .fast) {
        self.source = source; self.target = target; self.mode = mode
    }
    public var isValid: Bool {
        SpeechModelChoice.parakeetLanguages.contains(source) && (target == nil || target != source && LanguagePair.qualityLanguages.contains(target!))
    }
}

public struct KeyboardSessionState: Codable, Equatable, Sendable {
    public enum Presentation: Equatable, Sendable { case activationRequired, preparing, resumePreparation, ready }
    public enum Phase: String, Codable, Sendable { case inactive, preparing, ready, recording, finalizing, result, failed }
    public var sessionID: UUID
    public var phase: Phase
    public var updatedAt: Date
    public var configuration: KeyboardConfiguration
    public var utteranceID: UUID?
    public var text: String
    public var translation: String
    public var error: String?
    public var level: Float
    public var recordingStartedAt: Date?
    public var preparationDetail: String?
    public var microphoneActive: Bool
    public init(sessionID: UUID = UUID(), phase: Phase = .inactive, configuration: KeyboardConfiguration = .init()) {
        self.sessionID = sessionID; self.phase = phase; self.configuration = configuration
        updatedAt = Date(); text = ""; translation = ""; level = 0; microphoneActive = false
    }
    public func isFresh(at now: Date = Date()) -> Bool { now.timeIntervalSince(updatedAt) >= -2 && now.timeIntervalSince(updatedAt) < 4 }
    public var output: String { configuration.target == nil ? text : translation }
    public func presentation(for requested: KeyboardConfiguration, hasFullAccess: Bool, at now: Date = Date()) -> Presentation {
        guard hasFullAccess else { return .activationRequired }
        if phase == .preparing {
            return isFresh(at: now) && configuration == requested ? .preparing : .resumePreparation
        }
        guard hasFullAccess, isFresh(at: now), microphoneActive, configuration == requested else { return .activationRequired }
        return .ready
    }
}

public struct KeyboardCommand: Codable, Sendable {
    public enum Action: String, Codable, Sendable { case start, stop, cancel, end }
    public let id: UUID
    public let sessionID: UUID
    public let utteranceID: UUID?
    public let action: Action
    public let createdAt: Date
    public init(sessionID: UUID, utteranceID: UUID? = nil, action: Action, createdAt: Date = Date(), id: UUID = UUID()) {
        self.id = id; self.sessionID = sessionID; self.utteranceID = utteranceID; self.action = action; self.createdAt = createdAt
    }
    public func isValid(for state: KeyboardSessionState, lastCommandID: UUID?, at now: Date = Date()) -> Bool {
        guard id != lastCommandID, sessionID == state.sessionID,
              now.timeIntervalSince(createdAt) >= -2, now.timeIntervalSince(createdAt) < 15 else { return false }
        switch action {
        case .start: return utteranceID != nil && (state.phase == .ready || state.phase == .result)
        case .stop, .cancel: return state.phase == .recording && utteranceID == state.utteranceID
        case .end: return state.microphoneActive || state.phase == .preparing
        }
    }
}

public struct KeyboardHeartbeat: Codable, Sendable {
    public let sessionID: UUID
    public let date: Date
    public init(sessionID: UUID, date: Date = Date()) { self.sessionID = sessionID; self.date = date }
}

/// A final result may be inserted automatically only into the untouched field
/// where that utterance began. Drafts never edit a host application's text.
public struct KeyboardInsertionAnchor: Equatable, Sendable {
    public let documentID: UUID
    public let before: String?
    public let after: String?
    public let selection: String?
    public let editRevision: UInt64
    public init(documentID: UUID, before: String?, after: String?, selection: String?, editRevision: UInt64 = 0) {
        self.documentID = documentID; self.before = before; self.after = after; self.selection = selection; self.editRevision = editRevision
    }
    public func matches(_ current: Self) -> Bool {
        // Empty fields may expose nil context. The edit revision also changes
        // for host text/selection callbacks, including edits that were undone.
        self == current
    }
}
