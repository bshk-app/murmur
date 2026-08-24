import XCTest
@testable import MurmurKit

final class BatchServeLoopTests: XCTestCase {
    /// Drives the loop over a fixed script of input lines, collecting what it wrote.
    private func run(lines: [String],
                     transcribe: @escaping (String) throws -> String) -> [String] {
        var remaining = lines[...]
        var written: [String] = []
        BatchServeLoop.run(
            readLine: { remaining.isEmpty ? nil : remaining.removeFirst() },
            transcribe: transcribe,
            write: { written.append($0) }
        )
        return written
    }

    func test_one_result_line_per_input_path() {
        let out = run(lines: ["/a.wav", "/b.wav"]) { "text of \($0)" }

        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(try text(of: out[0]), "text of /a.wav")
        XCTAssertEqual(try text(of: out[1]), "text of /b.wav")
    }

    /// A caller writing one path per line will produce a trailing newline; a blank
    /// line is not a request and must not consume a turn, or every later reply is
    /// off by one and the client reads B's text for A.
    func test_blank_lines_are_skipped_without_replying() {
        let out = run(lines: ["", "  ", "/a.wav"]) { "text of \($0)" }

        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(try text(of: out[0]), "text of /a.wav")
    }

    /// The client blocks on a reply. A failure that emits nothing deadlocks the run
    /// instead of failing one sample, so an error is still exactly one line.
    func test_a_failing_sample_still_answers() {
        struct Boom: Error {}
        let out = run(lines: ["/bad.wav", "/good.wav"]) {
            if $0 == "/bad.wav" { throw Boom() }
            return "ok"
        }

        XCTAssertEqual(out.count, 2)
        XCTAssertNotNil(try? field("error", of: out[0]))
        XCTAssertEqual(try text(of: out[1]), "ok")
    }

    /// Paths are trimmed: the newline the client writes is not part of the filename.
    func test_surrounding_whitespace_is_not_part_of_the_path() {
        var seen: [String] = []
        _ = run(lines: ["  /a.wav  "]) { seen.append($0); return "" }

        XCTAssertEqual(seen, ["/a.wav"])
    }

    func test_each_line_is_self_contained_json() throws {
        let out = run(lines: ["/a.wav"]) { _ in "многострочный\nтекст" }

        XCTAssertEqual(out.count, 1)
        XCTAssertFalse(out[0].contains("\n"), "a newline inside a reply would split one result into two")
        XCTAssertEqual(try text(of: out[0]), "многострочный\nтекст")
    }

    // MARK: - helpers

    private func field(_ key: String, of line: String) throws -> Any {
        let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        guard let value = obj?[key] else { throw NSError(domain: "test", code: 1) }
        return value
    }

    private func text(of line: String) throws -> String {
        try field("text", of: line) as? String ?? ""
    }
}
