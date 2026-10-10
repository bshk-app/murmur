import AppKit
import XCTest
@testable import MurmurKit

/// When the user's clipboard comes back after a paste, and how the text is
/// handed over. On a private pasteboard: the developer's clipboard is not
/// touched.
final class TextInjectorClipboardTests: XCTestCase {
    /// On a CI runner the first of these tests once ran 2.3 s long while the
    /// rest kept time - enough to upset the timings below. Use a pasteboard
    /// and the run loop once before any of them.
    override class func setUp() {
        super.setUp()
        let pb = NSPasteboard(name: NSPasteboard.Name("murmur-test-warmup-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        PasteSource("warm up").write(to: pb)
        _ = pb.string(forType: .string)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    func test_the_clipboard_comes_back_a_moment_after_the_app_took_the_text() {
        XCTAssertEqual(TextInjector.clipboardRestoreTime(firstTaken: 0.6), 0.6 + TextInjector.pasteSettleDelay)
    }

    func test_never_before_the_minimum_hold_however_early_the_text_was_taken() {
        // A slow app's own read comes after a clipboard manager's or Screen
        // Sharing's: an early one must not bring the old clipboard back.
        XCTAssertEqual(TextInjector.clipboardRestoreTime(firstTaken: 0.02), TextInjector.minimumClipboardHold)
    }

    func test_the_hold_outlasts_a_slow_first_paste() {
        // A freshly launched TextEdit on a busy Mac took 0.17 s to read; the
        // fixed 0.12 s this replaces put the old clipboard back first.
        XCTAssertGreaterThan(TextInjector.clipboardRestoreTime(firstTaken: nil), 0.17)
        XCTAssertGreaterThan(TextInjector.minimumClipboardHold, 0.17)
        XCTAssertGreaterThan(TextInjector.minimumClipboardHold, TextInjector.pasteSettleDelay,
                             "Return to send goes before the clipboard comes back")
    }

    func test_text_nobody_takes_still_gives_the_clipboard_back() {
        XCTAssertEqual(TextInjector.clipboardRestoreTime(firstTaken: nil), TextInjector.maximumClipboardHold)
        XCTAssertEqual(TextInjector.clipboardRestoreTime(firstTaken: 1.95), TextInjector.maximumClipboardHold)
    }

    func test_the_text_is_handed_over_when_asked_and_marked_transient() throws {
        let pb = NSPasteboard(name: NSPasteboard.Name("murmur-test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let source = PasteSource("hello ")
        source.write(to: pb)

        let types = pb.types ?? []
        XCTAssertTrue(types.contains(.string) && types.contains(PasteSource.transient), "\(types)")
        XCTAssertNil(source.takenAt, "listing the types is not taking the text")
        XCTAssertEqual(pb.string(forType: .string), "hello ")
        XCTAssertNotNil(source.takenAt)
    }

    // `paste` on a private pasteboard, its keys simulated: "the app" reads
    // the pasteboard when it gets to ⌘V. Each test waits for its restore, so
    // the next starts with none pending.

    /// What happened in a demo take: TextEdit, just launched, read 0.17 s
    /// after ⌘V and got the user's old clipboard back instead of the text.
    func test_a_slow_app_gets_the_dictation_and_the_user_gets_the_clipboard_back() {
        let pb = privatePasteboard(holding: "user's clipboard")
        defer { pb.releaseGlobally() }
        var pasted: String?
        let result = TextInjector.paste("dictation ", submit: false, on: pb, pressPaste: {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) { pasted = pb.string(forType: .string) }
            return true
        }, pressReturn: {})
        XCTAssertEqual(result, .pasted)
        spin(0.3)
        XCTAssertEqual(pasted, "dictation ")
        XCTAssertEqual(pb.string(forType: .string), "dictation ", "held past the read")
        spin(TextInjector.minimumClipboardHold)
        XCTAssertEqual(pb.string(forType: .string), "user's clipboard")
    }

    /// A second paste before the first one's restore: what comes back is the
    /// user's clipboard, not the first dictation.
    func test_back_to_back_pastes_give_back_the_users_clipboard() {
        let pb = privatePasteboard(holding: "user's clipboard")
        defer { pb.releaseGlobally() }
        var pasted: [String?] = []
        let app = { () -> Bool in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { pasted.append(pb.string(forType: .string)) }
            return true
        }
        TextInjector.paste("one ", submit: false, on: pb, pressPaste: app, pressReturn: {})
        spin(0.2)
        TextInjector.paste("two ", submit: false, on: pb, pressPaste: app, pressReturn: {})
        spin(TextInjector.minimumClipboardHold + 0.3)
        XCTAssertEqual(pasted, ["one ", "two "])
        XCTAssertEqual(pb.string(forType: .string), "user's clipboard")
    }

    /// Return goes once the app has taken the text, and before the clipboard
    /// comes back.
    func test_return_follows_the_read() {
        let pb = privatePasteboard(holding: "user's clipboard")
        defer { pb.releaseGlobally() }
        let returns = Presses(), settled = Presses()
        var readAt: DispatchTime?
        TextInjector.paste("send this", submit: true, on: pb, pressPaste: {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) {
                _ = pb.string(forType: .string)
                readAt = .now()
            }
            return true
        }, pressReturn: { [name = pb.name] in returns.record(clipboard: NSPasteboard(name: name).string(forType: .string)) },
           settled: { settled.record(clipboard: $0 ? "landed" : "not landed") })
        spin(TextInjector.minimumClipboardHold + 0.3)
        XCTAssertEqual(settled.count, 1)
        XCTAssertEqual(settled.clipboardAtFirst, "landed")
        XCTAssertEqual(returns.count, 1)
        XCTAssertEqual(returns.clipboardAtFirst, "send this", "before the clipboard came back")
        if let readAt, let at = returns.firstAt {
            XCTAssertGreaterThanOrEqual(at.uptimeNanoseconds, readAt.uptimeNanoseconds)
        } else {
            XCTFail("no read or no Return")
        }
    }

    /// Text no app takes is never sent - and the clipboard still comes back.
    func test_no_return_when_nothing_took_the_text() {
        let pb = privatePasteboard(holding: "user's clipboard")
        defer { pb.releaseGlobally() }
        let returns = Presses()
        let settled = Presses()
        TextInjector.paste("send this", submit: true, on: pb, pressPaste: { true },
                           pressReturn: { returns.record(clipboard: nil) },
                           settled: { settled.record(clipboard: $0 ? "landed" : "not landed") })
        spin(TextInjector.maximumClipboardHold + 0.2)
        XCTAssertEqual(returns.count, 0)
        XCTAssertEqual(settled.count, 1)
        XCTAssertEqual(settled.clipboardAtFirst, "not landed", "a held-back Return must not go either")
        XCTAssertEqual(pb.string(forType: .string), "user's clipboard")
    }

    /// Another app can read the text first - here even before ⌘V is sent.
    /// Murmur cannot tell that read from the target's, so it counts; what it
    /// can promise is no Return earlier than `pasteSettleDelay` after ⌘V,
    /// which is as late as Return ever went before reads were watched.
    func test_another_apps_read_counts_but_return_never_comes_early() {
        let pb = privatePasteboard(holding: "user's clipboard")
        defer { pb.releaseGlobally() }
        let returns = Presses()
        var posted: DispatchTime?
        TextInjector.paste("send this", submit: true, on: pb, pressPaste: {
            _ = pb.string(forType: .string)
            posted = .now()
            return true
        }, pressReturn: { returns.record(clipboard: nil) })
        spin(TextInjector.minimumClipboardHold + 0.3)
        XCTAssertEqual(returns.count, 1)
        if let posted, let at = returns.firstAt {
            XCTAssertGreaterThanOrEqual(Double(at.uptimeNanoseconds - posted.uptimeNanoseconds) / 1e9,
                                        TextInjector.pasteSettleDelay)
        } else {
            XCTFail("no Return")
        }
        XCTAssertEqual(pb.string(forType: .string), "user's clipboard")
    }

    /// A paste landing before the last one's Return: that Return would send
    /// both texts, so it is not pressed. The second paste follows the first
    /// with no turn of the run loop between, so the first one's Return cannot
    /// have gone yet however slow the machine is.
    func test_a_later_paste_cancels_a_pending_return() {
        let pb = privatePasteboard(holding: "user's clipboard")
        defer { pb.releaseGlobally() }
        let returns = Presses(), settled = Presses()
        TextInjector.paste("first", submit: true, on: pb, pressPaste: {
            _ = pb.string(forType: .string)
            return true
        }, pressReturn: { returns.record(clipboard: nil) },
           settled: { settled.record(clipboard: $0 ? "landed" : "not landed") })
        TextInjector.paste("second ", submit: false, on: pb, pressPaste: {
            _ = pb.string(forType: .string)
            return true
        }, pressReturn: {})
        spin(TextInjector.minimumClipboardHold + 0.3)
        XCTAssertEqual(returns.count, 0)
        XCTAssertEqual(settled.count, 1)
        XCTAssertEqual(settled.clipboardAtFirst, "not landed")
        XCTAssertEqual(pb.string(forType: .string), "user's clipboard")
    }

    func test_a_paste_that_cannot_be_sent_stays_on_the_clipboard() {
        let pb = privatePasteboard(holding: "user's clipboard")
        defer { pb.releaseGlobally() }
        XCTAssertEqual(TextInjector.paste("keep me ", submit: false, on: pb, pressPaste: { false }, pressReturn: {}),
                       .failed)
        spin(0.2)
        XCTAssertEqual(pb.string(forType: .string), "keep me ")
    }

    private func privatePasteboard(holding text: String) -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("murmur-test-\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString(text, forType: .string)
        return pb
    }

    private func spin(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}

private final class Presses: @unchecked Sendable {
    private(set) var count = 0
    private(set) var firstAt: DispatchTime?
    private(set) var clipboardAtFirst: String?

    func record(clipboard: String?) {
        if count == 0 { firstAt = .now(); clipboardAtFirst = clipboard }
        count += 1
    }
}
