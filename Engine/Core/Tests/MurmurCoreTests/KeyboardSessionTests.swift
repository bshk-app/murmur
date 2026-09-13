import XCTest
@testable import MurmurCore

final class KeyboardSessionTests: XCTestCase {
    func testOldKeyboardStateDecodesWithoutTranslationMethod() throws {
        let old = """
        {"sessionID":"00000000-0000-0000-0000-000000000001","phase":"inactive","updatedAt":0,"configuration":{"source":"ru","mode":"fast"},"text":"","translation":"","level":0,"microphoneActive":false}
        """.data(using: .utf8)!
        let state = try JSONDecoder().decode(KeyboardSessionState.self, from: old)
        XCTAssertNil(state.translationMethod)
    }
    func test_preparation_does_not_request_enable_again() {
        let now = Date()
        var state = KeyboardSessionState(phase: .preparing, configuration: .init(source: "ru", target: "en"))
        state.updatedAt = now
        // The app has accepted Enable and is loading models; capture must not
        // be marked active before that work finishes.
        XCTAssertFalse(state.microphoneActive)
        XCTAssertEqual(state.presentation(for: state.configuration, hasFullAccess: true, at: now), .preparing)
        state.microphoneActive = true
        XCTAssertEqual(state.presentation(for: state.configuration, hasFullAccess: true, at: now), .preparing)
        XCTAssertEqual(state.presentation(for: state.configuration, hasFullAccess: true, at: now.addingTimeInterval(8)), .resumePreparation)
        state.phase = .ready; state.microphoneActive = true
        XCTAssertEqual(state.presentation(for: state.configuration, hasFullAccess: true, at: now), .ready)
        XCTAssertEqual(state.presentation(for: state.configuration, hasFullAccess: false, at: now), .activationRequired)
        XCTAssertEqual(state.presentation(for: .init(source: "en"), hasFullAccess: true, at: now), .activationRequired)
    }
    func test_only_current_fresh_nonduplicate_commands_are_accepted() {
        let now = Date()
        var state = KeyboardSessionState(phase: .ready)
        state.microphoneActive = true
        let id = UUID()
        let start = KeyboardCommand(sessionID: state.sessionID, utteranceID: id, action: .start, createdAt: now)
        XCTAssertTrue(start.isValid(for: state, lastCommandID: nil, at: now))
        XCTAssertFalse(start.isValid(for: state, lastCommandID: start.id, at: now))
        XCTAssertFalse(start.isValid(for: state, lastCommandID: nil, at: now.addingTimeInterval(16)))
        XCTAssertFalse(start.isValid(for: state, lastCommandID: nil, at: now.addingTimeInterval(-5)))
        let oldSession = KeyboardCommand(sessionID: UUID(), utteranceID: id, action: .start, createdAt: now)
        XCTAssertFalse(oldSession.isValid(for: state, lastCommandID: nil, at: now))
        XCTAssertFalse(KeyboardCommand(sessionID: state.sessionID, action: .start).isValid(for: state, lastCommandID: nil))
        state.phase = .recording; state.utteranceID = id
        XCTAssertFalse(start.isValid(for: state, lastCommandID: nil, at: now))
        XCTAssertTrue(KeyboardCommand(sessionID: state.sessionID, utteranceID: id, action: .stop).isValid(for: state, lastCommandID: nil))
        XCTAssertFalse(KeyboardCommand(sessionID: state.sessionID, utteranceID: UUID(), action: .stop).isValid(for: state, lastCommandID: nil))
    }
    func test_insertion_is_bound_to_field_context_and_host_edit_revision() {
        let doc = UUID()
        let anchor = KeyboardInsertionAnchor(documentID: doc, before: "Before", after: "after", selection: nil)
        XCTAssertTrue(anchor.matches(anchor))
        XCTAssertFalse(anchor.matches(.init(documentID: UUID(), before: "Before", after: "after", selection: nil)))
        XCTAssertFalse(anchor.matches(.init(documentID: doc, before: "Edited", after: "after", selection: nil)))
        XCTAssertFalse(anchor.matches(.init(documentID: doc, before: "Before", after: "elsewhere", selection: nil)))
        XCTAssertFalse(anchor.matches(.init(documentID: doc, before: "Before", after: "after", selection: "selected")))
        let empty = KeyboardInsertionAnchor(documentID: doc, before: nil, after: nil, selection: nil)
        XCTAssertTrue(empty.matches(empty))
        XCTAssertFalse(empty.matches(.init(documentID: doc, before: nil, after: nil, selection: nil, editRevision: 1)))
    }
    func test_freshness_and_configuration_reject_stale_or_unsupported_state() {
        var state = KeyboardSessionState()
        state.updatedAt = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(state.isFresh(at: Date(timeIntervalSince1970: 102)))
        XCTAssertFalse(state.isFresh(at: Date(timeIntervalSince1970: 105)))
        XCTAssertFalse(state.isFresh(at: Date(timeIntervalSince1970: 90)))
        XCTAssertTrue(KeyboardConfiguration(source: "ru", target: "en").isValid)
        XCTAssertFalse(KeyboardConfiguration(source: "ru", target: "ru").isValid)
        XCTAssertFalse(KeyboardConfiguration(source: "ar").isValid)
        XCTAssertFalse(KeyboardConfiguration(source: "not-a-language").isValid)
    }
}
