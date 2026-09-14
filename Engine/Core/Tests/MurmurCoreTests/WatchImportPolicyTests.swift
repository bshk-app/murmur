import XCTest
@testable import MurmurCore

final class WatchImportPolicyTests: XCTestCase {
    private func candidate(_ id: UUID, at seconds: TimeInterval, queued: Bool = false,
                           autoStart: Bool = true, prepared: Bool = true) -> WatchImportPolicy.Candidate {
        .init(id: id, createdAt: Date(timeIntervalSince1970: seconds), queued: queued, autoStart: autoStart, prepared: prepared)
    }

    func testOldestRecordingWithAPreparedLanguageStarts() {
        let older = UUID(), newer = UUID()
        let candidates = [candidate(newer, at: 20), candidate(older, at: 10)]
        XCTAssertEqual(WatchImportPolicy.next(activeID: nil, receiving: false, foreground: true, keyboardActive: false,
                                              memoryReleasable: true, candidates: candidates), older)
    }

    func testRecordingsWaitForALanguageThePhonePrepared() {
        let unprepared = UUID(), prepared = UUID()
        let candidates = [candidate(unprepared, at: 10, prepared: false), candidate(prepared, at: 20)]
        XCTAssertEqual(WatchImportPolicy.next(activeID: nil, receiving: false, foreground: true, keyboardActive: false,
                                              memoryReleasable: true, candidates: candidates), prepared)
        XCTAssertNil(WatchImportPolicy.next(activeID: nil, receiving: false, foreground: true, keyboardActive: false,
                                            memoryReleasable: true, candidates: [candidate(unprepared, at: 10, prepared: false)]))
    }

    func testARunningImportTakesEachRecordingIntoItsQueueOnlyOnce() {
        let running = UUID(), waiting = UUID()
        XCTAssertEqual(WatchImportPolicy.next(activeID: running, receiving: false, foreground: true, keyboardActive: false,
                                              memoryReleasable: false, candidates: [candidate(waiting, at: 10)]), waiting)
        XCTAssertNil(WatchImportPolicy.next(activeID: running, receiving: false, foreground: true, keyboardActive: false,
                                            memoryReleasable: false, candidates: [candidate(waiting, at: 10, queued: true)]))
    }

    func testTheRunningImportIsNeverHandedBackForAnotherStart() {
        let running = UUID()
        XCTAssertNil(WatchImportPolicy.next(activeID: running, receiving: false, foreground: true, keyboardActive: false,
                                            memoryReleasable: false, candidates: [candidate(running, at: 10)]))
    }

    func testBackgroundReceiptAndDictationKeepRecordingsWaiting() {
        let candidates = [candidate(UUID(), at: 10)]
        XCTAssertNil(WatchImportPolicy.next(activeID: nil, receiving: false, foreground: false, keyboardActive: false,
                                            memoryReleasable: true, candidates: candidates))
        XCTAssertNil(WatchImportPolicy.next(activeID: nil, receiving: true, foreground: true, keyboardActive: false,
                                            memoryReleasable: true, candidates: candidates))
        XCTAssertNil(WatchImportPolicy.next(activeID: nil, receiving: false, foreground: true, keyboardActive: true,
                                            memoryReleasable: true, candidates: candidates))
    }

    func testAnIdleStartWaitsForMemoryButAQueuedOneDoesNot() {
        let waiting = UUID()
        XCTAssertNil(WatchImportPolicy.next(activeID: nil, receiving: false, foreground: true, keyboardActive: false,
                                            memoryReleasable: false, candidates: [candidate(waiting, at: 10)]))
        XCTAssertEqual(WatchImportPolicy.next(activeID: UUID(), receiving: false, foreground: true, keyboardActive: false,
                                              memoryReleasable: false, candidates: [candidate(waiting, at: 10)]), waiting)
    }

    func testAPausedRecordingStaysPausedWhenTheUserPausedIt() {
        XCTAssertNil(WatchImportPolicy.next(activeID: nil, receiving: false, foreground: true, keyboardActive: false,
                                            memoryReleasable: true, candidates: [candidate(UUID(), at: 10, autoStart: false)]))
    }

    func testNothingToStartWithoutRecordings() {
        XCTAssertNil(WatchImportPolicy.next(activeID: nil, receiving: false, foreground: true, keyboardActive: false,
                                            memoryReleasable: true, candidates: []))
    }

    func testNotificationsAreOfferedOnceAWatchIsInPlay() {
        XCTAssertTrue(WatchImportPolicy.shouldAskAboutNotifications(watchAppInstalled: true, hasRecordings: false,
                                                                    foreground: true, undecided: true))
    }

    /// A side-loaded watch app never reports as installed, but a recording that
    /// arrived is proof enough that notifications are worth offering.
    func testARecordingCountsEvenWhenTheWatchAppLooksAbsent() {
        XCTAssertTrue(WatchImportPolicy.shouldAskAboutNotifications(watchAppInstalled: false, hasRecordings: true,
                                                                    foreground: true, undecided: true))
    }

    func testNothingIsAskedBeforeAWatchIsInvolved() {
        XCTAssertFalse(WatchImportPolicy.shouldAskAboutNotifications(watchAppInstalled: false, hasRecordings: false,
                                                                     foreground: true, undecided: true))
    }

    func testTheBackgroundCannotAskAndADecisionIsNotReopened() {
        XCTAssertFalse(WatchImportPolicy.shouldAskAboutNotifications(watchAppInstalled: true, hasRecordings: true,
                                                                     foreground: false, undecided: true))
        XCTAssertFalse(WatchImportPolicy.shouldAskAboutNotifications(watchAppInstalled: true, hasRecordings: true,
                                                                     foreground: true, undecided: false))
    }
}
