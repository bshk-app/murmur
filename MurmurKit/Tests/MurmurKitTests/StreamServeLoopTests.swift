import XCTest
@testable import MurmurKit

final class StreamServeLoopTests: XCTestCase {
    private func run(_ requests: [StreamServeLoop.Request],
                     step: @escaping ([Float]) -> String = { _ in "" },
                     finish: @escaping () -> String = { "" }) -> [String] {
        var remaining = requests[...]
        var written: [String] = []
        StreamServeLoop.run(
            next: { remaining.isEmpty ? nil : remaining.removeFirst() },
            step: step,
            finish: finish,
            write: { written.append($0) }
        )
        return written
    }

    func test_a_chunk_is_answered_with_its_partial() throws {
        let out = run([.chunk([0.1, 0.2])], step: { _ in "привет" })

        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(try field("partial", of: out[0]) as? String, "привет")
    }

    func test_finish_is_answered_with_the_final_text() throws {
        let out = run([.finish], finish: { "привет мир" })

        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(try field("text", of: out[0]) as? String, "привет мир")
    }

    /// The producer paces audio and the client blocks on each reply, so a chunk
    /// that produced no new text must still answer. Staying silent would stall
    /// the paced feed and be scored as the host failing to drain the stream.
    func test_a_chunk_with_no_new_text_still_answers() throws {
        let out = run([.chunk([0.1]), .chunk([0.2])], step: { _ in "" })

        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(try field("partial", of: out[0]) as? String, "")
    }

    /// One utterance per file: after finishing, the next chunk belongs to a new
    /// recording, so the session must be reset or every later transcript carries
    /// the previous file's text.
    func test_finishing_resets_for_the_next_utterance() {
        var finishes = 0
        var stepsSinceFinish: [Int] = []
        var steps = 0
        _ = run([.chunk([1]), .finish, .chunk([1])],
                step: { _ in steps += 1; return "" },
                finish: { finishes += 1; stepsSinceFinish.append(steps); steps = 0; return "" })

        XCTAssertEqual(finishes, 1)
        XCTAssertEqual(stepsSinceFinish, [1], "the first utterance saw exactly one chunk")
        XCTAssertEqual(steps, 1, "the chunk after finish belongs to the next utterance")
    }

    func test_each_reply_is_one_self_contained_line() throws {
        let out = run([.finish], finish: { "две\nстроки" })

        XCTAssertFalse(out[0].contains("\n"), "a newline would split one reply into two")
        XCTAssertEqual(try field("text", of: out[0]) as? String, "две\nстроки")
    }

    private func field(_ key: String, of line: String) throws -> Any {
        let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        guard let v = obj?[key] else { throw NSError(domain: "test", code: 1) }
        return v
    }
}
