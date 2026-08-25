import XCTest
@testable import MurmurKit

/// The pure rule is covered elsewhere; this exercises the part that touches a real
/// directory, because that is where "deletes the wrong thing" would happen.
final class DiagnosticSweepTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("murmur-sweep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ name: String, daysAgo: Double) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("wav".utf8).write(to: url)
        let date = Date().addingTimeInterval(-daysAgo * 86_400)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        return url
    }

    func test_sweep_removes_only_expired_recordings() throws {
        let old = try write("utterance-old.wav", daysAgo: 9)
        let fresh = try write("utterance-fresh.wav", daysAgo: 0.1)

        XCTAssertEqual(DiagnosticRecordings.sweep(directory: directory), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    /// Anything that is not a recording is none of this sweep's business.
    func test_sweep_ignores_unrelated_files() throws {
        let stranger = directory.appendingPathComponent("notes.txt")
        try Data("keep me".utf8).write(to: stranger)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-30 * 86_400)], ofItemAtPath: stranger.path)

        XCTAssertEqual(DiagnosticRecordings.sweep(directory: directory), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stranger.path))
    }

    func test_delete_all_clears_every_recording() throws {
        let first = try write("utterance-a.wav", daysAgo: 0.01)
        let second = try write("utterance-b.wav", daysAgo: 0.02)

        XCTAssertEqual(DiagnosticRecordings.deleteAll(directory: directory), 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    /// A missing directory is the normal state before the first recording.
    func test_sweep_on_missing_directory_is_a_no_op() {
        let absent = directory.appendingPathComponent("nope", isDirectory: true)
        XCTAssertEqual(DiagnosticRecordings.sweep(directory: absent), 0)
    }
}

final class DiagnosticRecordingsTests: XCTestCase {
    private func entry(_ name: String, minutesAgo: Double, now: Date) -> DiagnosticRecordings.Entry {
        DiagnosticRecordings.Entry(url: URL(fileURLWithPath: "/tmp/\(name)"),
                                   modified: now.addingTimeInterval(-minutesAgo * 60))
    }

    func test_keeps_recent_recordings() {
        let now = Date()
        let entries = (0 ..< 5).map { entry("utterance-\($0).wav", minutesAgo: Double($0), now: now) }
        XCTAssertTrue(DiagnosticRecordings.expired(entries, now: now).isEmpty)
    }

    func test_drops_everything_past_the_age_limit() {
        let now = Date()
        let old = entry("utterance-old.wav", minutesAgo: 8 * 24 * 60, now: now)
        let fresh = entry("utterance-fresh.wav", minutesAgo: 1, now: now)
        XCTAssertEqual(DiagnosticRecordings.expired([old, fresh], now: now), [old])
    }

    /// The count cap holds even when every file is well inside the age window.
    func test_drops_the_oldest_beyond_the_count_cap() {
        let now = Date()
        let entries = (0 ..< 25).map { entry("utterance-\($0).wav", minutesAgo: Double($0), now: now) }
        let victims = DiagnosticRecordings.expired(entries, now: now)
        XCTAssertEqual(victims.count, 5)
        XCTAssertEqual(Set(victims.map(\.url.lastPathComponent)),
                       Set((20 ..< 25).map { "utterance-\($0).wav" }))
    }

    /// A zero cap is a valid "keep none" and must not crash on the index maths.
    func test_zero_cap_drops_all() {
        let now = Date()
        let entries = [entry("utterance-a.wav", minutesAgo: 1, now: now)]
        XCTAssertEqual(DiagnosticRecordings.expired(entries, now: now, keepNewest: 0), entries)
    }
}
